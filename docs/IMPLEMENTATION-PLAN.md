# 实施计划：八项「诚实裁决」修复

> **本文是实施契约，不是设计文档。**
> 输入：`docs/Execution-Flow.md` 第十/十一节 + Planner 计划（2026-10-16）。
> 读者 = 实施者（Claude Code）。**只描述「改什么 / 改成什么样 / 怎么验」，不写补丁。**
>
> 行号基准：`deploy-naive-caddy.sh` @ `716d771`，`SCRIPT_VERSION="2.6.1"`，4649 行。
> **行号会漂 —— 以函数名与语义为准，行号仅作定位参考。**

---

## 零、不可动摇的红线

violating any of these = 本次实施失败：

| # | 红线 | 为什么 |
| --- | --- | --- |
| **R-a** | **退出码三档语义**：`0` 成功（或 `--skip-verify`）｜`1` 致命｜`2` 部署完成但验证未确认。**禁用 `126/127/128+n`**（shell 保留）。 | 三档是本项目唯一的机器可读契约 |
| **R-b** | **退出码 2 的判定必须留在 `print_summary`（3067）之后（3082）**。 | `run_stage` 的 `exit 1` 会跳过 `print_summary` → 用户拿不到密码 |
| **R-c** | **不许造出假失败**。「判不出」不能报成「确认坏了」。 | 假失败比假成功更伤自动化（触发无谓重试/回滚） |
| **R-d** | **不许动 `run_stage`（422-437）的失败语义**。 | 同上 |
| **R-e** | **不许碰生产服务器**（82.139.194.92）。所有验证在本机/沙箱/CI 内。 | — |
| **R-f** | **每项改动与其断言必须同批**。只改代码不改断言 → CI 红；反之亦然。 | 见 §四 批次表 |

---

## 一、两个必须先记住的陷阱

这两条是 Planner 本轮实测发现的、`docs/Execution-Flow.md` **没有记录**的坑。
**它们各自都能让一个"看起来改对了"的实现变成假修。**

### 陷阱 1：A（非 TTY Default-Deny）单改 `confirm()` 无效

`main:3058` 是 `preflight || exit 1`。**`||` 会挂起左侧整个命令的 `errexit`**，
而且 `preflight` 的返回值 = **它自己最后一条命令**的返回值（`1626 ok "预检完成"` = 0）。

实测对比（同一份 preflight，`confirm` 已被改成拒绝）：

```
[A] 裸调 preflight         → rc=1   ← 看起来"修好了"
[B] preflight || exit 1    → rc=0，打印"预检完成"，部署继续   ← 假绿！
```

⇒ **A 必须包含显式传播**：`preflight` 内 `1620-1622` 的三个 `check_*` 调用点要
`|| return 1`。**注意 `A || B` 本身也挂起 `errexit`**，所以"只在 `[ … ] || confirm …`
这一层改 `confirm` 的返回值"是**无效**的。

### 陷阱 2：F3 两个调用点的退出码机制**不同**

```
调用点①  2390  print_summary 内          → verify_warn 可用（能走到 3082 → 退 2）
调用点②  2594  do_rotate_password 内     → verify_warn 静默失效！
```

原因：`main:3052` 是

```bash
if [ "$ROTATE_PASSWORD" = "yes" ]; then do_rotate_password; return 0; fi
```

**`return 0` 无条件丢弃返回值**，永远走不到 3082。⇒ 调用点② 必须走 `die`。

**但 `die` 有顺序陷阱**（`do_rotate_password` 的既有顺序）：

```
2590 落盘新 Caddyfile → 2593 state_write → 2594 写 client-config
→ 2602 ok "密码已更换" → 2603 才打印新密码
```

**若在 2594 直接 `die`：新密码已生效、服务已重载，但用户看不到新密码 → 被锁在门外。**
⇒ 调用点② 必须先保证**新密码已打印**，再把写失败失败化。

---

## 二、Phase 0 — 对齐（无版本号）

### 0.1 行号机检

把本文与 `docs/Execution-Flow.md` 里所有 `行 NNN` / 函数区间抽出来，逐条对源码核一遍，产出差异表。

```bash
cd naiveproxy
grep -nE '^(do_check|main|confirm|check_domain_dns|check_ports_free|print_summary|install_service|install_caddy_binary|verify_deployment|do_rotate_password|preflight|run_stage|do_uninstall)\(\) \{' deploy-naive-caddy.sh
```

**已知需修正（Planner 本轮实测）**：

| 位置 | 现状 | 应为 |
| --- | --- | --- |
| `run_stage` 区间 | **`deploy-naive-caddy.sh:3079` 的脚本注释**引用 `427-434`（注释自身过时） | 定义在 **422**，失败路径 **429-436**（`exit 1` 在 436） |
| `deploy-naive-caddy.sh:3697` / `:4569` 注释 | 「既有 **385** 条断言一行没动」 | 实为 403/406（**脚本注释自身过时**） |
| `deploy-naive-caddy.sh:3193` 注释 | 「**19** 个区段全印」 | 全量自检实跑 **20** 个区段 |
| `.github/workflows/alpine-openrc.yml:77` | 引「`renderers_silent()`（`deploy-naive-caddy.sh:3335`）」 | 实际定义在 **3596** |
| `.github/workflows/alpine-openrc.yml:98` | 引「脚本 **1327** 行注释」 | 该注释实际在 **1341** |
| `docs/Execution-Flow.md:640` / `:658` | 「A 与 4001/4002 必须同批」 | **归 Phase 2**（A 不动无参数路径 ⇒ 4001/4002 不会红）。**本文件 §1.7 已记此修正，但 Execution-Flow 未改** |
| `docs/Execution-Flow.md:655-656` | 「B 必须不晚于 A」 | 改为「**B 与 A 必须同批，且 B 的 `confirm` 必须受 `ASSUME_YES` 管辖**」（理由见 §四） |
| `docs/Execution-Flow.md:618` | `#### H. 计数口径漂移` | 引用时要写 **H**（本文件初版误写成 I） |

### 0.3 派活：回头修 `docs/Execution-Flow.md` 的两处旧措辞

**这是 Phase 0 的产出物之一，不是可选项。** 不做的后果：两份文档带着**互相矛盾**的结论进仓库，
实施者若按 `Execution-Flow.md:640` 做，会在 Phase 1 就动 `4001/4002`（**误伤**）。

| # | 位置 | 改成 |
| --- | --- | --- |
| 1 | `Execution-Flow.md:640` 与 `:658` | 去掉「含 4001/4002 改写」/「A 与 4001/4002 必须同批」；注明「4001/4002 的代价归 Phase 2（无参数分流）」 |
| 2 | `Execution-Flow.md:655-656` | 「B 必须不晚于 A ……」→「**B 与 A 必须同批，且 B 的 `confirm` 必须受 `ASSUME_YES` 管辖**」 |
| 3 | `Execution-Flow.md` §10.4 的 **C** | 不是可并行的杂活 —— **C 是 Phase 3 前置 2 的输入**（前置 2 要记录 7 阶段基线，判据正是 C 描述的两处过时文档）。至少在 C 后面注明这一点 |

### 0.2 新增断言辅助 `rc_case`

- **目标**：让「期望退出码 == N」成为一等断言，而不是用 `true_case`/`false_case` 近似。
- **位置**：`self_test` 内的 `true_case`/`false_case`/`eq_case`/`skip_case`（**3654** 起），新增第 5 个。
- **要点**：新增 `rc_case <名称> <期望码> <命令...>`。**不改动**既有 4 个辅助的语义。
- **⚠️ 必做**：**3779** 的过滤包装器列表 `for st_fn in true_case false_case eq_case skip_case`
  **必须同步加一项** —— 否则 `--self-test <模式>` 的子集过滤会把新辅助漏掉（**不报错，静默漏测**）。
- **退出码取值**：N/A（测试层）。
- **会翻红的现有断言**：无（纯新增）。
- **验收**：
  ```bash
  bash ./deploy-naive-caddy.sh --self-test "帮助"; echo "rc=$?"   # 期望 rc=0
  # ⚠️ 参数是【区段关键词】，不是随便起的名。该关键词必须真的存在于自检输出里
  #    （实测存在：[1] 语法与依赖 … [8] 阶段表一致性）。用不存在的词会 rc=1
  #    并打印「没有任何断言匹配「…」」—— 初版写的 "自检辅助" 就是这种不存在的词。
  #    新增 rc_case 后，应把它所在的区段纳入关键词，并加一条「rc_case 自身可用」的自证断言。
  ```
- **可降级**：Phase 1 各项也可先用 `false_case`（期望非 0）兜住；若工期紧，`rc_case` 可与 Phase 1 合并。

---

## 三、Phase 1 — 诚实裁决（v2.7.0）

八项：**A2 / F3 / F1 / F2 / G / B / A / F4**。

---

### 1.1 A2 — `--check` 发现问题却退 0

| | |
| --- | --- |
| **目标** | `do_check` 发现问题时 `--check` 退 **1**；无问题时退 **0**。**不加任何 `--strict` 开关。** |
| **位置** | `do_check`（**2663**）；`problems` 累加在 2669/2680/2684/2704/2723/2733；结论块 2779-2786；`main` 的 `--check` 分派 **3027**`do_check` / **3028**`return 0` |
| **改动要点** | `do_check` 以其 `problems` 计数作为返回值；`main` **显式传播**（不要依赖 `set -e` 的隐式行为——那是隐式且难读，会被未来 `if do_check; then` 破坏）。**不改** 3082、**不改** `run_stage`、**不改** `print_summary`。 |
| **退出码取值** | `problems > 0 → 1`。理由：`--check` 的产物是「能不能装」的裁决，不是「看看情况」。**为何不造假失败**：`problems` 只由确定性子项累加（DNS / 端口 / 连不上 GitHub / 磁盘）。 |
| **会翻红的现有断言** | **恰好 6 条**：`4006` / `4013` / `4324` / `4561` / `4562` / `4563`。**共同根因**：`a.example.com` 解析不出 A 记录 → 走进「查不到 A 记录」分支 → `problems=1`。 |
| **不会翻红的同类** | `4323` / `4257-4260` / `4557-4560` / `4565` 是 `false_case`（期望非 0）→ 修完仍非 0；`4005`/`4012` 是 `out=$(… \|\| true)` 捕获；`4007-4010`/`4020-4021`/`4023` 只查 stdout/文件。 |
| **⚠️ 改写正解** | **不是**把 `true_case` 无脑改 `false_case` —— 那会让 `4006`「--check 无需 root 即可完成」的语义退化成「必然失败」。应改为**只读性断言**（断言 stdout 含「结论」或 `rc != 126`）。 |
| **新增断言** | ① `false_case "体检发现问题时退出 1" … --check --domain a.example.com …`（与 4006 成对）；② **干净环境必须退 0** —— 走沙箱桩（剥掉 `main "$@"` 后 source，桩 `port_state=free` / `get_public_ip=1.2.3.4` / `resolve_domain_ip=1.2.3.4` / `curl=0`），**这是防「一刀切退 1」的护栏，必须行为级且不依赖 DNS/ss**；③ 可选：`rc != 126/127`。 |
| **验收** | ```bash cd naiveproxy; bash ./deploy-naive-caddy.sh --check --domain a.example.com --email ops@mail.test </dev/null >/tmp/o 2>&1; echo $?``` → 期望 **1**（现状 0）；`grep -q '有 1 项需要先处理' /tmp/o` → 命中；`--self-test` → rc=0 |
| **同批必做** | ① **6 条断言改写**（否则 CI 必红）；② `usage`（**439**，退出码段 **524-532**）补一句「1 也可表示体检发现问题」；③ **CHANGELOG `## [2.7.0]`** —— `ci.yml:74-83` 是硬门禁，版本号无对应标题直接红。 |

---

### 1.2 F3 — `client-config.json` 写失败被吞（**两处调用点**）

| | |
| --- | --- |
| **目标** | 写失败**必须被用户看到**；摘要**不得**再广告「已存到 X，权限 0600」这个未验证的事实。 |
| **调用点 ①** | `print_summary` 内 **2389-2392**（2390 写、2391 `chmod … \|\| true`）；广告在 **2428**；屏幕上那份是 **2429 另行渲染**（不是 `cat`）。⇒ **屏幕永远正确、文件可能根本不在**（全仓无任何地方 `cat` 该文件）。 |
| **调用点 ②** | `do_rotate_password`（定义 **2548**）内 **2594**（写）、**2595**（`chmod … \|\| true`）；广告在 **2604**。 |
| **要点 ①** | 写失败 → **`verify_warn`** + 摘要如实标注（未写成时不得出现「已存到/权限 0600」）。 |
| **要点 ②** | 写失败 → **`die`**，但**必须先保证新密码已打印**（见 §一 陷阱 2）。 |
| **退出码取值** | **逐点不同**：① → `verify_warn`（收尾退 **2**）。② → `die`（退 **1**）—— 因为 `main:3052` 的 `return 0` 会让 `verify_warn` 静默失效。**为何不造假失败**：写失败是确定性事实（重定向到不可写路径必然失败），不是「判不出」。 |
| **会翻红的现有断言** | **无**。`4021` 提到 `CLIENT_CONF` 但走 `--check`（不写该文件）；`print_summary` 的 **8 条**（4037/4038/4130/4131/4160/4161/4163/4634）都是 `fn_body` 字符串匹配，无一条匹配 `已存到`/`0600`。 |
| **⚠️ 必须盯住** | `4618`（`verify_items_only_count`）要求「4 项全失败时 `VERIFY_WARNINGS == 4` 且 `verify_deployment` 退 0」。它直调 `verify_deployment`，不受 F3 影响；且 `_verify_exit_sandbox` 里 `CREDS_KNOWN=yes`（**3462**，实读确认）⇒ F3 分支**会触发**，行为级断言测得到。⇒ 0 条翻红（依据是全量自检 406/0），但**必须作为回归项跑**。 |
| **新增断言** | ① 结构：`fn_code print_summary` 不得含 `CLIENT_CONF … \|\| true`（用 `fn_code` 而非 `fn_body` —— 注释会喂饱断言）；② 结构：`fn_code do_rotate_password` 同理；③ 结构：`fn_body do_rotate_password` 在打印新密码之前出现 `die` 即 FAIL（**锁住顺序陷阱**）；④ 行为①：沙箱 `CREDS_KNOWN=yes` + `CLIENT_CONF` 不可写 → `print_summary` 后 `VERIFY_WARNINGS > 0` 且 stdout 不含 `已存到`；⑤ 行为②：沙箱 `CLIENT_CONF` 不可写 → `do_rotate_password` **非 0** 退出且 stdout **含**新密码。 |
| **验收** | 见 §五 ④。**现状各 2**（`render_client_config … > "${CLIENT_CONF}" \|\| true` + `chmod 0600 "${CLIENT_CONF}" … \|\| true`），改后应为 **0/0** |

---

### 1.3 F1 — `systemctl enable caddy` 被吞

| | |
| --- | --- |
| **目标** | enable 失败导致「重启后不自启」必须说出去，不能让「部署完成」盖过。 |
| **位置** | `install_service`（**2148**）systemd 分支 **2156**：`systemctl enable caddy >/dev/null 2>&1 \|\| true`（对照卸载侧 `do_uninstall:2508` 有 `systemctl disable caddy`） |
| **要点** | 失败 → **`verify_warn`** + 明确文案（「重启后不会自启」）。**阶段函数仍返回 0**（不要 `return 1`）。 |
| **退出码取值** | `verify_warn` → 收尾退 **2**。链路：阶段退 0 → `run_stage` 退 0 → `3067 print_summary` → `3082` 判 `VERIFY_WARNINGS > 0` → **2**。**用户仍拿到密码（R-b 保住）**。**不用 1**：会经 `run_stage:436 exit 1` 跳过摘要 → 代理其实现在能用，却让用户丢密码 = **假失败**。 |
| **⚠️ 语义张力** | `usage`（524-532）把 2 定义为「未确认」，这里其实是「已确认有问题」。建议措辞放宽为「部署可用，但有需处理或未能确认的事项」，**同批**更新 `usage` 与 `print_summary` 横幅（`4634` 断言要求横幅含 `退出码 2`，**放宽时必须保留该子串**）。 |
| **会翻红的现有断言** | **无**（断言块里 `enable` / `is-enabled` 命中 0 次；`4110`/`4197`/`4473`/`4477` 都是 `fn_body` 结构匹配）。 |
| **新增断言** | ① 结构：`fn_code install_service` 不得出现 `systemctl enable caddy` 与 `\|\| true` 同行；② **行为级**：failure-injection 容器内（systemd 真跑 + `--yes`）阶段 6 后断言 `systemctl is-enabled caddy` 为 `enabled` —— 夹具 `residue()` 已打印 `svc-enabled:`（`.github/fixtures/failmatrix/harness.sh:271`），**可直接把该读数提升为判定项**；③ 断言 `install_service` 在 enable 失败时**仍返回 0**。 |
| **验收** | ```bash bash -c 'source "$1"; fn_code install_service' \| grep -nE 'enable caddy.*\|\|[[:space:]]*true'``` → 期望无输出（rc=1） |

---

### 1.4 F2 — `rc-update add caddy default` 被吞

| | |
| --- | --- |
| **目标** | 同 F1，openrc（Alpine）侧。 |
| **位置** | `install_service` openrc 分支（`elif [ "$INIT" = "openrc" ]` 在 **2163**）**2168**：`rc-update add caddy default >/dev/null 2>&1 \|\| true`（对照卸载 `2513`） |
| **要点 / 退出码** | 与 F1 **完全同处理**（`verify_warn`、阶段返回 0）。 |
| **会翻红的现有断言** | **无**（`rc-update` 命中 0 次）。 |
| **新增断言** | ① 结构：`fn_code install_service` 不得出现 `rc-update add caddy` 与 `\|\| true` 同行；② 行为：`alpine-openrc.yml` 加一步「真跑 `rc-update add` 后查 `rc-update show \| grep caddy`」。**⚠️ 该 workflow 不含 `iproute2`**（`alpine-openrc.yml:34`/`:40` 的 `apk add` 清单里没有）⇒ **新断言必须不依赖 `ss`**（见 1.5）。 |
| **⚠️ 批次** | **F1 与 F2 必须同批**（同一函数、同一族）。漏一个 =「修了 systemd 忘了 openrc」，而这正是 §九 承认的「Alpine 从未端到端跑过」最容易漏的地方。 |

---

### 1.5 G — 「判不出」被记成 `note`

| | |
| --- | --- |
| **目标** | `ss` 缺失导致端口**根本没查**时，不得再打 `ok "预检完成"`（**1626**）而不作声。 |
| **位置（两份重复逻辑，必须同批）** | 预检：`check_ports_free`（**1581**）的 `*)` 分支 **1604-1607**（`note` 在 **1605**）。体检：`do_check` 内另一份等价循环 **2695-2715**，`*)` 分支 **2710-2713**（`note` 在 2711）。三态来源：`port_state`（**1499-1510**，`unknown` 在 1502）。 |
| **退出码取值（逐处不同）** | `do_check`（2710-2713）→ **`problems++`**（`--check` 退 1）。理由：`--check` 的契约是「能不能装」，「我查不了」≠「可以装」——这是**诚实地说我不知道**，不是猜错。`check_ports_free`（1604-1607）→ **升级为一次 `confirm`**（与 **1598** 端口被占同格）：TTY 下让人决定，非 TTY 下由 A（1.7）的 Default-Deny 兜住。 |
| **会翻红的现有断言** | **无**。`4035`/`4173`/`4191`/`4192` 都是结构/命令存在性断言，改 `*)` 分支不影响。 |
| **⚠️ 环境差异（关键）** | G 使 `--check` 在**无 `ss`** 的机器上退 1。**本机实测无 `ss`**（`port_state 443` = `unknown`）；`ci.yml` 的 ubuntu-latest **自带** `iproute2`；`alpine-openrc.yml` 的 `alpine:3.20` **不带**。⇒ **1.1 改写后的 6 条断言绝不能依赖 `ss`**，否则「ubuntu 绿、Alpine 红」。**建议一律走沙箱桩 `port_state`。** |
| **新增断言** | ① 结构：`fn_code do_check` 的端口 `*)` 分支必须含 `problems=`；② 行为（**桩掉 `ss`，确定性**）：沙箱里 `need_cmd ss` 失败 → `problems ≥ 1` → `--check` 非 0；③ `eq_case`：两处 `unknown` 文案同源（防再次各改各的）。 |
| **验收** | ```bash bash -c 'source "$1"; fn_code do_check' \| sed -n '/^[[:space:]]*\*)/,/;;/p' \| grep -c 'problems='``` → 期望 **≥1** |
| **⚠️ 批次** | **必须与 1.1 同批**（G 改 `do_check` 的退出码**输入**，A2 改**输出**；分两批会出现中间坏版本）。**必须在 1.7 (A) 之前** —— G 新增了一个 `confirm` 点，它的非 TTY 语义要由 A 统一定义。 |

---

### 1.6 B — `check_domain_dns` 两分支不对称

| | |
| --- | --- |
| **目标** | 让「查不到 A 记录」与「解析到别的 IP」**行为对齐**，并把被错误合并进同一 `else` 的两种情形分开。 |
| **位置** | `check_domain_dns`（**1545**）：相等 → `ok`（1551）；**解析到别的 IP** → `warn` + **`confirm`（1555）**；**`else`（1557-1560）** ← 同一个 `else` **同时覆盖**「域名查不到 A 记录」与「本机公网 IP 拿不到」（1558 把两者一起打印），**且完全没有 `confirm`**。 |
| **改动要点** | 把 `else` **一分为二**：**(c) `dns` 为空**（域名真查不到）→ `warn` + **`confirm`**（与 1555 对齐）；**(d) `dns` 非空但 `ip` 为空**（本机公网 IP 拿不到）→ **只 `warn`、不 `confirm`**。理由：判定不可靠时问人是噪音（`get_public_ip:1439` 依赖外部 IP 服务，任一不可达即返回 1）。 |
| **退出码取值** | **只补 `confirm`，不引入新的独立退出码**。TTY 下走 `y/N`；非 TTY 下由 A（1.7）的 Default-Deny 决定。理由：B 是「补上那个没被问的问题」，退出码语义由 A 统一裁决，B 不该自带一套。 |
| **会翻红的现有断言** | **无**（`check_domain_dns` 在断言块命中 0 次；`4126` 只查 `preflight` 含 `check_probe_secret_dns`，不动）。 |
| **⚠️ 写法硬约束** | B 新增的 `confirm` **必须写在 `[ "$ASSUME_YES" = "yes" ] \|\|` 之下**（与 1555/1575/1598 同格），否则 `--yes` 的 CI 夹具（`harness.sh:40` 的 `DEPLOY_ARGS` 末位即 `--yes`）会被自己的警告拦住。 |
| **新增断言** | ① 结构：`fn_body check_domain_dns` 含 **≥2** 处 `confirm`（现状 1）；② 结构（**B 最该锁的一条**）：`confirm` 所在分支与「`ip` 为空」的判定**必须可分** —— 不得让「本机 IP 拿不到」落到带 `confirm` 的分支；③ 行为（沙箱桩）：桩 `get_public_ip` 失败 + `resolve_domain_ip` 返回空 → **出现 `confirm`**；桩 `get_public_ip` 失败 + `resolve_domain_ip` 返回 `9.9.9.9` → **不出现 `confirm`**。 |
| **验收** | ```bash bash -c 'source "$1"; fn_body check_domain_dns' \| grep -c 'confirm'``` → 期望 **2**（现状 1） |

---

### 1.7 A — `confirm()` 非 TTY 默认「继续」（**4 个判定点**）

| | |
| --- | --- |
| **目标** | 非 TTY（Ansible / CI / 管道 / cron）下，预检的警告必须**停下**而非放行（Default-Deny）。 |
| **位置** | `confirm()`（**1528-1542**）：`[ ! -t 0 ]` 在 **1530**，现为 1531 `warn` + **1532 `return 0`**（默认前进）。 |
| **4 个判定点** | ①**1555** 域名解析到别的 IP（走预检）②**1575** 秘密域名未解析（走预检）③**1598** 端口被占（走预检）④**2498** `--purge`（**不走预检** —— `do_uninstall` **3054** 在 `preflight` **3058** 之前） |
| **TTY 读点** | 全脚本 3 处 `-t` 判断：**183** `[ -t 1 ]` 上色、**196** `[ -t 1 ]` 再清色、**1530** `[ ! -t 0 ]` 读键盘。⇒ **唯一要改的是 1530** —— 注意 **1530 是全脚本唯一的 `-t 0`**，183/196 判的是 stdout（上色），与「有没有人」无关。 |
| **改动要点** | `[ ! -t 0 ]` 分支由「按继续」改为「**拒绝**」；`--yes` 是唯一显式放行（`2935` `-y\|--yes) ASSUME_YES="yes"`）。**`--yes` 语义 = 「预检发现问题时别问我」**。 |
| **🔴 必做** | **见 §一 陷阱 1** —— 单改 `confirm()` 不成立。`preflight` 内 **1620-1622** 三个 `check_*` 调用点必须 `\|\| return 1`，且在**调用链上显式传递**（`A \|\| B` 本身也挂起 `errexit`）。 |
| **退出码取值** | **拒绝 → 致命 1**。理由：这是「结构性无人值守」被拦下，属「没开始部署」。**为何不造假失败**：只在**非 TTY 且无 `--yes` 且确有警告**时触发；带 `--yes` 就放行（CI 夹具已带）。**不违反 R-b**：此处 `exit 1` 在**任何阶段之前**，此时**根本还没有密码**。 |
| **会翻红的现有断言** | **A 本身：0 条** —— 断言块里 `-t 0` 命中 **0** 次（**这正是文档自承的覆盖空洞**）。 |
| **⚠️ 必须盯住两条** | `4033` `true_case "--purge 需要二次确认" has "$ub" 'confirm'`（`ub` 由 **4032** `ub=$(fn_body do_uninstall)` 取得） —— 若实现把 **2498 的 `confirm` 调用替换掉**（而非保留 `confirm` 本身），**会翻红**。`4030` `true_case "取消退出码是 0" has "$cb" 'exit 0'`（`cb` 由 **4029** 取得）；**4031** `false_case "取消不再走 die" has "$cb" 'die '` 也作用于 `fn_body confirm` —— **A 若把 `confirm` 重写成「拒绝时 die」，4031 与 4030 一起红** —— **取消路径（有 TTY 按回车）必须仍是 `exit 0`**，不能顺手改掉。 |
| **文档归属修正** | `docs/Execution-Flow.md` §10.2.1 把 `4001/4002` 算作 A 的代价 —— **归 Phase 2**（A 单独落地不动无参数路径）。 |
| **新增断言（本次唯一「从零建覆盖」）** | ① **行为级（关键）**：非 TTY + 桩 `confirm` 返回 1 → 断言 **经 `main` 的 `preflight \|\| exit 1` 路径**仍能拦住（rc=1 且输出**不含**「预检完成」）。**必须走 `main`，不能只调 `preflight`** —— 否则重演陷阱 1 的假绿。② 行为：`--yes` + 非 TTY + 有警告 → rc **0**。③ 行为：`--purge` + 非 TTY + 无 `--yes` → 非 0；带 `--yes` → 正常。④ 结构：`confirm` 的 `[ ! -t 0 ]` 分支**不得含 `return 0`**。⑤ 结构：`fn_body confirm` 仍含 `exit 0`（保 4030 语义）。 |
| **验收** | 见 §五 验收命令集 |
| **同批必做** | 用户可见行为变更 ⇒ CHANGELOG + `README`（`README.md:91` 的 `--check` 表、`README.md:92` 的 `--yes` 行；**不是 115** —— 115 是 `--dry-run`）+ `usage:470` 的 `--yes` 说明。**`usage:470` 现写「所有确认自动回答「是」」，与新语义必须对齐 —— 二者必居其一，不许都留着。** |

---

### 1.8 F4 — 上游没发校验和时跳过完整性校验

| | |
| --- | --- |
| **目标** | 让「未校验」在**摘要里回显**，而不是一行灰字 `warn` 过去。 |
| **位置** | `install_caddy_binary`（**1843**）：`want=$(resolve_caddy_digest \|\| true)` 在 **1862**，guard `if [ -n "$want" ]` 在 **1863**，**1874** `warn "该发布没有提供校验和…"`。 |
| **改动要点** | **只补文案与回显**：在 `print_summary`（**2385**）里如实标注「本次未做完整性校验」。需要一个跨阶段标志（与 `VERIFY_SKIPPED` 同族的「状态回显」模式）。 |
| **退出码取值** | **保持 0**。**明确反对算作 `verify_warn`**：① 是否提供 digest 是**上游**行为，不是本机部署质量；② 用户本地**无法修复**它，变成非零 = **每次部署都退 2** 的假失败；③ 上游侧已有守门（`upstream-drift.yml` 每日检查 digest 并 `::error::` + 开 issue）—— **该在 CI 解决的事，不转嫁给终端用户**。 |
| **会翻红的现有断言** | **无**（`4166`/`4167` 都只查 `resolve_caddy_digest` 与 `下载校验失败`，不依赖 1874 文案）。 |
| **新增断言** | ① 结构：`fn_body install_caddy_binary` 的无 digest 分支必须设置可回显状态；② 结构：`fn_body print_summary` 必须引用该状态（机检关键字）；③ 行为：桩 `resolve_caddy_digest` 返回 1 → **退出码仍为 0**（锁住「不做假失败」的决定）。 |
| **验收** | ```bash bash ./deploy-naive-caddy.sh --self-test "校验"; echo "rc=$?"``` → **0** |
| **批次** | **必须与 1.2 同批**（同一函数 `print_summary`、同一改动窗口）。 |

---

## 四、批次与依赖

### 必须同批（否则 CI 直接红 / 出现中间坏版本）

| 批次 | 内容 | 为什么 |
| --- | --- | --- |
| **批次 1** | A2 改动 + **6 条断言改写** + **G（1.5）** | 只改代码不改断言 → CI 必红；G 改 `do_check` 的退出码**输入**，A2 改**输出**，分两批会出现中间坏版本 |
| **批次 1** | **F1 + F2** | 同一函数 `install_service` 的两个分支 |
| **批次 1** | **F3 两处调用点（2390 / 2594）** | 两处**退出码机制不同**（`verify_warn` vs `die`），分两批会让实施者以为「照抄 ① 就行」 |
| **批次 2** | **A（1.7）** + 其新增断言 + **B（1.6）** | A 引入 Default-Deny；B 新增一个 `confirm` 点。**B 与 A 同批**（见下） |
| **批次 2** | `usage:470` 的 `--yes` 文案 + `README` + `CHANGELOG` | 用户可见行为变更，文案不同批 = 文档说谎 |
| **全批** | 每次 `SCRIPT_VERSION` 提升 + `CHANGELOG.md` 的 `## [x.y.z]` 标题 | **`ci.yml:74-83` 硬门禁**：版本号无对应标题 → CI 红 |
| **批次 1 或 2** | **F4（1.8）** 与 **F3 的 `print_summary` 改动** | 同一函数、同一改动窗口 |

### 必须先后

1. **G → A**（1.5 在 1.7 前）：G 新增了一个 `confirm` 判定，其非 TTY 语义应由 A 统一定义。
2. **A2 → Phase 2 向导**：A2 是向导成立的前提（退出码是唯一稳定契约）。
3. **F3 调用点① → 调用点②**（同批次内按此顺序）：① 的机制简单可验证；② 先要处理「新密码必须已打印」的顺序问题。

### 📌 对 `docs/Execution-Flow.md` §11 一处措辞的修正（Planner 提出，我复核同意）

原文写「**B 必须不晚于 A** ……顺序反了的话，A 只是把三个漏子改成三个拒绝，还是漏一个」。

**这句只在「只发 A 不发 B」时成立。** 若 A、B **同批发布**，则「B 晚于 A」反而**更安全**：
B 新加的 `confirm` 一诞生就带着 Default-Deny 语义，不必回头再审一遍。

⇒ **真正的硬约束不是次序，而是**「B 的 `confirm` 必须受 `ASSUME_YES` 管辖」（见 1.6）。
**实施时按「同批」处理。**

### 关于 `run_stage` / `print_summary` / 3082 的明确回答

| 组件 | 要动吗 | 理由 |
| --- | --- | --- |
| `run_stage`（**422-437**） | **不动** | F1/F2 走 `verify_warn` ⇒ 阶段返回 0 ⇒ `run_stage` 退 0 ⇒ 摘要照打。**动它（让阶段返回 1）会经 436 `exit 1` 跳过 `print_summary`，直接违反 R-b。** |
| `print_summary`（**2385**，调用点 **3067**） | **要动**（1.2、1.8） | 只改**内部文案与错误处理**，**不动它在 `main` 里的位置**。位置是红线：`exit2_check_after_summary`（3492）与 `summary_printed_before_exit2`（3421）盯着它 |
| 退出码判定（**3082**） | **原则上不动** | F1/F2/F3① 靠 `VERIFY_WARNINGS` 自然生效。唯一例外是把 F3② 纳入 2，那需要改 **3052** 的 `return 0`（不是 3082）—— **本计划选择不改**，改走 `die`（理由见 1.2）。**正确理由**（Designer 复核后修正）：(a) `3053`-`3055` 的 `… ; return 0` 是同一族既有分派风格，单独改 3052 会让 `--rotate-password` 与 `--reload`/`--uninstall`/`--upgrade` 不一致；(b) `do_rotate_password` 内已有 9 处 `|| die` 早退（2556/2577/2583/2588/2590/2591/2593/2598/2600），返回值通道已被 `die` 独占，加 `return` 通道是**新增语义面**。**（初版写的「会牵动 4030/4033」是错的 —— 全断言区无一提及 `ROTATE_PASSWORD`。）** |

---

## 五、验收命令集（实施完成后逐条跑）

> **⚠️ 命令形态必须用「脚本自己的惯用形态」。**
> 本文件初版写的 `bash -c 'source <(grep -vxF "main ..." ...)'` **跑不通**：
> 引号不平衡会让 `grep` 的模式变成 `main "`；且 `source` 后 `$0` 变成占位符，
> `fn_body` / `fn_code` 内部的 `awk … "$0"` 会报 `cannot open file`。
> **最坏的后果是「假绿」** —— 得 0 行输出，恰好等于期望的 0。

> **正确形态**（照抄脚本自身 `:3278` / `:3456` / `:3319` 的写法）：

```bash
# ① 剥离 main 调用，产出可 source 的库
lib=$(mktemp); grep -vxF 'main "$@"' deploy-naive-caddy.sh > "$lib"
# ② $0 位置传真脚本路径（fn_body/fn_code 靠 $0 定位），库从 $1 进
bash -c 'source "$1"; fn_body <函数名>' deploy-naive-caddy.sh "$lib"
```

```bash
cd /d/AiWork/AMIA/naiveproxy

# ⓪ 公共前置：剥离 main 调用，产出可 source 的库（所有 fn_body/fn_code 验收都靠它）
lib=$(mktemp); grep -vxF 'main "$@"' deploy-naive-caddy.sh > "$lib"

# ① 语法
bash -n deploy-naive-caddy.sh

# ② 全量自检（必须 406+ 通过 / 0 失败）
bash ./deploy-naive-caddy.sh --self-test; echo "rc=$?"

# ③ A2：--check 有问题必须退 1（现状退 0）
bash ./deploy-naive-caddy.sh --check --domain a.example.com --email ops@mail.test </dev/null >/tmp/o 2>&1
echo "A2 exit=$?（期望 1）"; grep -o '有 .* 项需要先处理' /tmp/o

# ④ F3：两处调用点都不得再有 `|| true`
for f in print_summary do_rotate_password; do
  printf "  %s: " "$f"
  bash -c 'source "$1"; fn_code "$2"' deploy-naive-caddy.sh "$lib" "$f" \
    | grep -cE 'CLIENT_CONF.*\|\|[[:space:]]*true'
done
# 期望：两个都是 0（现状：各 2 —— 写文件 + chmod 各一条 || true）

# ⑤ F1/F2：enable / rc-update 不得与 || true 同行
bash -c 'source "$1"; fn_code install_service' \
  | grep -cE '(enable caddy|rc-update add caddy).*\|\|[[:space:]]*true'
# 期望：0

# ⑥ G：do_check 的端口 *) 分支必须计入 problems
bash -c 'source "$1"; fn_code do_check' \
  | sed -n '/^[[:space:]]*\*)/,/;;/p' | grep -c 'problems='
# 期望：>=1

# ⑦ B：check_domain_dns 必须 >=2 处 confirm
bash -c 'source "$1"; fn_body check_domain_dns' deploy-naive-caddy.sh "$lib" | grep -c 'confirm'
# 期望：2（现状 1）

# ⑧ A：真实路径必须拦住（关键 —— 不能只调 preflight）
bash -c 'source "$1"; trap - EXIT
  ASSUME_YES=no; INIT=systemd; detect_os(){ :; }; detect_arch(){ :; }
  confirm(){ return 1; }; get_public_ip(){ printf 1.2.3.4; }; resolve_domain_ip(){ printf 9.9.9.9; }
  preflight || exit 1; echo "!! 未拦住"' deploy-naive-caddy.sh "$lib"; echo "rc=$?"
# 期望：rc=1 且无 "!! 未拦住"（现状：rc=0 且打印 "!! 未拦住"）

# ⑨ A：--yes 必须仍放行
# （走沙箱，ASSUME_YES=yes，期望 rc=0）

# ⑩ confirm 的取消路径不许被改坏
bash -c 'source "$1"; fn_body confirm' deploy-naive-caddy.sh "$lib" | grep -c 'exit 0'
# 期望：>=1
```

---

## 六、Phase 2 — 向导（v2.8.0，粗粒度）

### 2.1 无参数分流

- **现状**：`main:2965-2969` = `if [ "$#" -eq 0 ]; then setup_glyphs; print_guide; return 0; fi` —— **无条件**打印引导页并 `return 0`。
- **目标**：无参数 + **有可交互终端** → 进向导；无参数 + **无终端** → **拒绝，`exit 1`**，给出**可直接粘贴的参数示例**。
- **会翻红的现有断言（这是 Phase 2 的真实代价，不是 A 的）**：
  - `4001` `true_case "无参数进入引导页" has "$out" '① 先体检'` → 在 CI（无 TTY）下翻红（**归因**：`true_case` 只看退出码 —— 无参数改退 1 后即红；不是「输出变了」）
  - `4002` `true_case "无参数不报错" bash "$0"`（`true_case` = **期望退 0**）→ **必然翻红**
  - 改法：`4002` → `false_case`；`4001` → 断言输出含**参数示例**（如 `--domain`）
- **新增断言**：`false_case "无参数+非TTY 被拒绝" bash "$0"`；`true_case "给出可粘贴示例" has "$out" '\-\-domain'`；TTY 分支用伪终端（`script -qec`）验证，**不引入伪终端工具则标 SKIP，不许假装覆盖**。
- **验收**：`bash ./deploy-naive-caddy.sh </dev/null; echo $?` → **1**（现状 0）

### 2.2 向导 = 参数生成器（纯函数 `wizard_collect → argv`）

- **不得**实现任何部署逻辑（否则产生一条**没有断言覆盖的旁路**）。
- **退出码**：**成功收尾一律 `exit 0`**，包括 `--check` 返回 1 时 —— 「发现问题并提示用户」是向导的**正常功能**，不是失败。退出码**只用于分叉文案**。
- **新增断言**（把向导的唯一新逻辑纳入现有覆盖网）：
  ```bash
  printf 'proxy.example.com\nops@mail.test\n\n' | wizard_collect
  # 期望：--domain proxy.example.com --email ops@mail.test --cert-mode acme
  ```

### 2.3 交棒执行

`main --yes --<同一组参数>`；向导自身成功收尾 `exit 0`。

### Phase 2 明确不做

执行前二次确认 / 真后台执行（`nohup`/`&`）/ 为 detach 的 tmux 特判 / 追求 TTY 判断绝对精确 / 单独的 `--force` 开关（复用 `-y/--yes`）。

---

## 七、Phase 3 — 押后项 D（v2.9.0）

### 7.1 D — 非 systemd 机器上阶段 7 的失败路径为空

- **目标**：openrc / `INIT` 为空的机器上，阶段 7 也能**区分**「服务确认死了（1）」与「判不出（2）」。
- **位置**：`verify_deployment`（**2193**）内**唯一的 `return 1`** 在 **2207**，被 `if [ "$INIT" = "systemd" ]`（**2201**）包住。`INIT` 只在 `detect_os` 赋值（1402-1405），取值只有 `systemd`/`openrc`/`""`。
- **要点**：按 `INIT` 分派到各自服务管理器（`systemctl is-active` / `rc-service caddy status`），**兜底**用已有的 `port_state`（1499）。**不经 `pidof`/`pgrep`**（新依赖，且「存在叫 caddy 的进程」≠「服务在服务」）。
- **退出码**：**确认死了 → `return 1`**；**判不出 → `verify_warn`（→2）**，**绝不报 1**（R-c）。
- **会翻红的断言**：**`4618` `verify_items_only_count`（3452）** —— 它要求「4 项全失败时 `VERIFY_WARNINGS == 4`」（判定在 3479）。D 让「判不出」计入 `verify_warn` 后会变成 5 → **立即红**。**处理**：把 3479 的 `"4"` 改为 **`-ge 4`**，注释写明「警告数取决于 `INIT` 分派」。**这不是改动错了，是那条断言把「恰好 4」写死了。**
- **新增断言**：① `INIT=openrc` + `rc-service` 恒失败 → `verify_deployment` **退 1**；② `INIT=""` + `port_state=unknown` → **退 0 但 `VERIFY_WARNINGS ≥ 1`**；③ `INIT=systemd` → 行为与今天完全一致（回归保护）；④ 结构：`fn_code verify_deployment` 里 `return 1` 的位置必须在 `INIT` 分派**之后**。

### 7.2 D 的硬前置（不做完不许动 D）

| # | 前置 | 为什么 | 机检 |
| --- | --- | --- | --- |
| 1 | **建 Alpine/openrc E2E 测试床**（真起 caddy、真签证书、真查服务状态） | `docs/VERIFICATION.md` 自承 Alpine 只在容器里跑过 `--self-test`，**端到端从未跑过**。在从未被执行的路径上改退出码 = 拿用户当测试床 | 扩 `alpine-openrc.yml`：跑完整 7 阶段断言 `rc=0`，再断言 `rc-service caddy status` 成功 |
| 2 | 先跑一次 **failure-injection 矩阵**，记录 7 阶段**当前基线** | 改 D 会动阶段 7，没有基线无法判断变化是 D 造成还是环境抖动 | `failure-injection.yml`（`workflow_dispatch`, `stages=7`） |
| 3 | 复核 `4618` 的判定口径 | 见上，「4」写死了 | 沙箱复现（今日 `rc=0 warns=4`） |

---

## 八、全局风险表

| # | 风险 | 触发条件 | 影响 | 缓解 |
| --- | --- | --- | --- | --- |
| **R1** | **A 的显式传播漏做** | 按 `Execution-Flow` §10.4 字面实施 | **A 变成假修**：隔离测试绿、真实路径照放行 | 新增断言**必须经 `main` 的 `preflight \|\| exit 1` 路径**（§一 陷阱 1 已给实测反例） |
| **R2** | **G 让 `--check` 在无 `ss` 机器上退 1**，而 Alpine CI 不带 `iproute2` | ubuntu 绿、Alpine 红 | 1.1 的 6 条改写断言**必须 ss 无关**（走沙箱桩） |
| **R3** | **F3 调用点② 直接 `die` 会丢新密码** | 照抄调用点① 的写法 | 用户被锁门外 | 新增断言「新密码打印必须先于写失败失败化」（1.2 断言③） |
| **R4** | **F3 调用点② 用 `verify_warn` 会静默失效** | 以为「和 ① 一样」 | `main:3052` 的 `return 0` 吞掉一切，退出码仍 0 | 明确 ② 走 `die` |
| **R5** | **`4033` 因 A 替换 `confirm` 调用而翻红** | A 的实现改动 `do_uninstall:2498` | CI 红，误判为「自己改错了」 | 保留 `confirm` 调用形态；A 只改 `confirm` **内部**分支 |
| **R6** | **`4030` 语义被误改** | 顺手把 `confirm` 里 `exit 0`（1539）也改掉 | 按回车取消变成非 0 → 语义倒退 | 结构断言锁 `fn_body confirm` 仍含 `exit 0` |
| **R7** | **版本号提升未加 CHANGELOG 标题** | 只改 `SCRIPT_VERSION`（74） | `ci.yml:74-83` 硬红 | 每版同批加 `## [x.y.z]` |
| **R8** | **`4618` 的「恰好 4」** | D 让「判不出」计入 `verify_warn` | 断言红 | 改为 `-ge 4`（Phase 3） |
| **R9** | 环境噪声（DNS / apt / 网络） | 新断言直接打真网络 | 偶发假红 | 一切新断言走**沙箱桩**（§五 已照此设计） |
| **R10** | **failure-injection 夹具不用 `--purge`** | `DEPLOY_ARGS`（`harness.sh:40`）只有 install 路径 | A 的 purge 判定点**无 CI 覆盖** | 至少加一条沙箱断言；理想是给夹具加 purge 场景 |

---

## 九、明确不做

1. **不加 `--strict` / 任何「严格模式」开关** —— 诚实必须是默认行为。
2. **不把 F1/F2/enable 失败做成致命 `1`** —— 会造成假失败并让用户丢密码。
3. **不改 `run_stage`（422-437）** 的失败语义。
4. **不改退出码判定位置**（`print_summary` 3067 必须仍在 3082 之前）。
5. **不动 `3052` 的 `return 0` 分派**（F3② 走 `die` 而非改分派）。
6. **不用 `pidof`/`pgrep` 判服务存活**（D）。
7. **不改 TTY 读点 183/196**（只管好不好看，不管危不危险）。
8. **不把 `docs/Execution-Flow.md` 的 C（文档滞后）与 **H**（计数口径；**初版误写成 I**）混进代码 PR** —— 它们是文档修复，属独立小 PR。**但 ⚠️ C 是 Phase 3 前置 2 的输入**（前置 2 要「记录 7 阶段当前基线」，而其判据正是 C 所描述的两处过时文档）⇒ **若前置 2 早于 C，则基线读数以 CI 记录为准，不以文档为准。**
9. **不碰生产服务器** —— 所有验收在本机/沙箱/CI 内。
10. **不实现向导的部署逻辑** —— 向导只做：收集参数 → 调 `--check` → 翻译退出码。

---

## 十、UNVERIFIED 清单

> 规则：查不出证据的不猜，标 UNVERIFIED 放过。

| # | 条目 | 为什么没核实 | 需要谁确认 |
| --- | --- | --- | --- |
| **U1** | ~~「135 个顶层函数」~~ **（幽灵条目，已降级）** | `grep -n '135' docs/Execution-Flow.md` **零命中** —— 该说法**不在文档里**，出处不明。实测列首 `name() {` = **138~141**（口径不同）。**Phase 0 不必找它** | — |
| **U2** | 「自检 **406** 条」与「403 个字面 `_case`」的对账 | **实测：字面 403，实跑 406，差 +3。** 已定位 `:3955` 的 `for i in 1 2 3 4 5 6 7` 循环体含 1 条 `_case` 字面（展开 +7-1=+6）。**+6 与 +3 对不上，来源未定位** | 实施者（Phase 0 可插桩确认） |
| **U3** | `alpine-openrc.yml` 的 **392/0/1** 读数 | 需真跑 `alpine:3.20` 容器；本机为 Windows Git Bash | CI 运行记录 |
| **U4** | `arm64.yml` 的「源码构建 47 秒 / 模块名已核对」 | 需真 ARM runner | CI 运行记录 |
| **U5** | **failure-injection 矩阵当前 7 阶段读数** | 需 Docker + systemd PID 1 容器，本机未跑 | CI 记录（Phase 3 前置 2 会产出） |
| **U6** | `systemctl enable` / `rc-update add` **真失败时**是否真能走到 `verify_warn` | 只能在真机/容器制造 enable 失败 | failure-injection 夹具（可加一条注入） |
| **U7** | `Execution-Flow.md` §1-9 中**未被这八项触及**的细节 | 只按 §11 八项 + §10 逐条回源码核过，其余抽查未逐行核 | Phase 0 一并核 |
| **U8** | `ci.yml:74-83`（版本号↔CHANGELOG 门禁）、`harness.sh:271`（`svc-enabled`）、`harness.sh:40`（`--yes`）、`3452`/`3479`/`3492`/`3421`/`3779` 等**交叉引用** | **来自 Planner 报告，本文件未逐条复核** | **Phase 0 机检**（这正是 0.1 的职责） |
| **U9** | A2 修完后 6 条改写的**具体措辞**是否会让别的断言连带红 | 只能实测；已排除 `fn_body`/`has` 交叉影响的可能，但改写文本若含 `结论`/`--domain` 等高频子串可能被误命中 | 实施者（改完立刻跑全量自检） |
