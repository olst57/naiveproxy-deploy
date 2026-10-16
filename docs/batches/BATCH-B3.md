# BATCH B3 — A（非 TTY Default-Deny）+ B（DNS 两分支对齐）+ 版本收尾

> **A 与 B 必须同批**：A 引入 Default-Deny，B 新增一个 `confirm` 点，
> B 的新 `confirm` 一诞生就带新语义，不必回头再审。

## 红线（违反即本批次失败）

1. **只做 A / B / 版本收尾三项。** 不许顺手改别的。
2. **🔴 A 最容易做假修 —— 见下面「陷阱」。只改 `confirm()` 的返回值是【无效】的。**
3. **不许碰生产服务器。**
4. **`--self-test` 失败数必须为 0。**
5. **退出码三档语义不许动**；`126/127/128+n` 禁用。

---

## 🔴 陷阱（A 的核心 —— 不做这个 = 假修）

`main:3058` 是 `preflight || exit 1`。**`||` 会挂起左侧命令的 `errexit`**，
且 `preflight` 的返回值 = **它自己最后一条命令**的值（`1626 ok "预检完成"` = **0**）。

**我在真脚本上实测过**：把 `confirm` 桩成 `return 1`，
- 单独调 `preflight` → rc=1（看着"修好了"）
- 走 `main` 的 `preflight || exit 1` → **rc=0**，警告照打、`ok "预检完成"` 照打、**部署继续**

```
! 域名解析到 9.9.9.9，而本机公网 IP 是 1.2.3.4     ← confirm 走到了
✓ 预检完成                                        ← 却继续了
!! 未拦住                                          ← rc=0
```

⇒ **必须显式传播**：`preflight` 内 **1620-1622** 的三个 `check_*` 调用点要 **`|| return 1`**。
**注意 `A || B` 本身也挂起 `errexit`**，所以"只在 `[ … ] || confirm …` 这一层改 `confirm` 的返回值"**是无效的**。

---

## 任务 B3.1 — A：非 TTY Default-Deny（**4 个判定点**）

**目标**：非 TTY（Ansible / CI / 管道 / cron）下，预检的警告必须**停下**而非放行。

**位置**：`confirm()`（约 **1528-1542**），`[ ! -t 0 ]` 在 **1530**，现为 1531 `warn` + **1532 `return 0`**。

**怎么做**：把 `[ ! -t 0 ]` 分支由"按继续"改为**"拒绝"**。
`--yes` 是唯一显式放行（`-y|--yes` 在约 **2935**）。

**4 个判定点**（全部要一起改，否则只剩 3/4 被堵）：

| # | 位置 | 场景 | 走预检？ |
| --- | --- | --- | --- |
| 1 | **1555** | 域名解析到别的 IP | 是 |
| 2 | **1575** | 秘密域名未解析 | 是 |
| 3 | **1598** | 端口被占（非 caddy）| 是 |
| 4 | **2498** | `--purge` 彻底清理 | **否** —— `do_uninstall`（约 **3054**）在 `preflight`（**3058**）**之前**，卸载路径不走预检 |

**⚠️ 必须盯住两条**：
- `4033` `has "$ub" 'confirm'`（`ub` 由 4032 取得）—— 若把 **2498 的 `confirm` 调用替换掉**（而非改 `confirm` 内部），**会红**
- `4030` `has "$cb" 'exit 0'` + **`4031`** `false_case has "$cb" 'die '` —— **取消路径（有 TTY 按回车）必须仍是 `exit 0`**，不许顺手改掉
  ⇒ **A 只改 `confirm` 内部的分支，不许改动它的调用形态**

**退出码**：拒绝 → **致命 1**。此处 `exit 1` 在**任何阶段之前**，那时还没有密码 ⇒ 不违反"致命失败仍能看到密码"。
（实测复核：密码生成在 `write_config`（阶段 4，约 **2033**），必在 3058 之后。）

**需新增（本次唯一"从零建覆盖"处）**：
1. **行为级（关键）**：非 TTY + 桩 `confirm` 返回 1 → 断言**经 `main` 的 `preflight || exit 1` 路径**仍能拦住（rc=1 且输出**不含**「预检完成」）。
   **必须走 `main`，不能只调 `preflight`** —— 否则重演上面的假绿。
2. 行为：`--yes` + 非 TTY + 有警告 → rc 仍为 **0**。
3. 行为：`--purge` + 非 TTY + 无 `--yes` → 非 0；带 `--yes` → 正常。
4. 结构：`fn_code confirm` 的 `[ ! -t 0 ]` 分支**不得含 `return 0`**。
5. 结构：`fn_body confirm` 仍含 `exit 0`（保 4030/4031 语义）。

---

## 任务 B3.2 — B：`check_domain_dns` 两分支不对称

**位置**：`check_domain_dns`（约 **1545**）：相等 → `ok`（1551）；**解析到别的 IP** → `warn` + **`confirm`（1555）**；
**`else`（1557-1560）** ← 同一个 `else` **同时覆盖**「域名查不到 A 记录」与「本机公网 IP 拿不到」，**且无 `confirm`**。

**怎么做**：把 `else` **一分为二**：
- **(c) `dns` 为空**（域名真查不到）→ `warn` + **`confirm`**（与 1555 对齐）
- **(d) `dns` 非空但 `ip` 为空**（本机公网 IP 拿不到）→ **只 `warn`、不 `confirm`**
  （理由：判定不可靠时问人是噪音 —— `get_public_ip` 依赖外部 IP 服务，任一不可达即返回 1）

**⚠️ 写法硬约束**：新增的 `confirm` **必须写在 `[ "$ASSUME_YES" = "yes" ] ||` 之下**（与 1555/1575/1598 同格），
否则 `--yes` 的 CI 夹具（`.github/fixtures/failmatrix/harness.sh:40` 的 `DEPLOY_ARGS` 末位即 `--yes`）会被自己的警告拦住。

**退出码**：**只补 `confirm`，不引入新的独立退出码**。非 TTY 下由 A 统一裁决。

**需新增**：
1. 结构：`fn_body check_domain_dns` 含 **≥2** 处 `confirm`（现状 1）。
2. 结构：`confirm` 所在分支与「`ip` 为空」的判定**可分** —— 不得让"本机 IP 拿不到"落到带 `confirm` 的分支。
3. 行为（沙箱桩）：桩 `get_public_ip` 失败 + `resolve_domain_ip` 返回空 → **出现 `confirm`**；
   桩 `get_public_ip` 失败 + `resolve_domain_ip` 返回 `9.9.9.9` → **不出现 `confirm`**。

---

## 任务 B3.3 — 版本收尾（**必须同批**，否则 CI 红）

1. `SCRIPT_VERSION`（约 **74**）`2.6.1` → **`2.7.0`**
2. `CHANGELOG.md` 加 **`## [2.7.0]`** 标题
   ⚠️ **`ci.yml:74-83` 是硬门禁**：`grep -qE "^## \[${ver}\]" CHANGELOG.md`，无对应标题直接 `exit 1`
3. 用户可见行为变更的文案：
   - `usage`（约 **439**；退出码段 524-532）→ 补「1 也可表示体检发现问题」
   - `usage:470` 的 `--yes` 说明 ← 现写「所有确认自动回答「是」」，与新语义（"预检发现问题时别问我"）**必须对齐，二者必居其一**
   - `README.md:91` 的 `--check` 表、**`README.md:92`** 的 `--yes` 行（**不是 115**，115 是 `--dry-run`）

---

## 验收（跑完贴原始输出）

```bash
cd naiveproxy
bash -n deploy-naive-caddy.sh && echo "语法 OK"
lib=$(mktemp); grep -vxF 'main "$@"' deploy-naive-caddy.sh > "$lib"

# ① 🔴 A：真实路径必须拦住（关键！现状 rc=0 且打印 "!! 未拦住"）
bash -c 'source "$1"; trap - EXIT
  ASSUME_YES=no; INIT=systemd; detect_os(){ :; }; detect_arch(){ :; }
  confirm(){ return 1; }; get_public_ip(){ printf 1.2.3.4; }; resolve_domain_ip(){ printf 9.9.9.9; }
  preflight || exit 1; echo "!! 未拦住"' deploy-naive-caddy.sh "$lib"; echo "rc=$?"
# 期望 rc=1 且无 "!! 未拦住"

# ② B：>=2 处 confirm（现状 1）
bash -c 'source "$1"; fn_body check_domain_dns' deploy-naive-caddy.sh "$lib" | grep -c 'confirm'

# ③ 保 4030/4031 语义
bash -c 'source "$1"; fn_body confirm' deploy-naive-caddy.sh "$lib" | grep -c 'exit 0'   # >=1

# ④ 版本一致性
grep -n 'SCRIPT_VERSION=' deploy-naive-caddy.sh | head -1
grep -n '^## \[2\.7\.0\]' CHANGELOG.md

# ⑤ 全量自检
bash ./deploy-naive-caddy.sh --self-test; echo "rc=$?"
```

## 完成后报告

1. A：`confirm` 改了哪几行 + **preflight 里怎么显式传播的**（贴片段）
2. A：4 个判定点各自怎么处理
3. A：新增断言逐条（**特别是那条"必须走 main"的行为断言**）
4. B：`else` 怎么拆的（贴片段）
5. 版本 + 文案：改了哪几处（`文件:行号`）
6. 验收 ①-⑤ 原始输出
7. `git status --short`

## 红线复述（违反即失败）

1. **只做 A / B / 版本收尾**
2. **🔴 A 必须显式传播 —— 只改 `confirm` 返回值是假修**
3. **不碰生产服务器**
4. **`--self-test` 失败数为 0**
5. **退出码三档语义不许动**
