# 变更记录

本文件格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。
**版本号的唯一事实源是脚本里的 `SCRIPT_VERSION`**（`deploy-naive-caddy.sh`），本文件必须与它保持一致。

首个 tag 即 `v2.4.0` —— 版本号早已通过 `--version` 对用户可见，不从 0.1.0 重来。
v2.2.0 / v2.1.0 两条是本次建仓时回填的历史记录（当时未打 tag，日期未记录）。

## [Unreleased]

（暂无）

## [2.7.0] - 2026-10-17

### 「诚实裁决」：把八处「失败了照样报成功」改成真的失败

**主题**：这个版本改的全是**退出码与判定**，不改部署本身做的事。
八处缺陷有同一个形状 —— **脚本知道出了问题，但没让你知道**：报绿、退 0、或者干脆不问。
所以版本名是「诚实裁决」：让退出码和屏幕上的话，跟你真实的处境对上。

**这一版引入了两处用户可见的行为变更**（不是纯 bug 修复）：
非交互下的默认值从「继续」翻成「中止」，以及 `--check` 发现问题时退出码从 0 变 1。
两者都在下面单列，升级前请读一遍。

---

**1. A2 —— `--check` 体检发现问题却退 0（退出码变更）**

`do_check` 会把问题数算出来并打印「有 N 项需要先处理」，然后**什么都不返回**。
于是 `if ./deploy-naive-caddy.sh --check; then` 恒为真 —— 脚本化的调用方把体检当通过了。

- 现在 `do_check` 以问题计数作为返回值，`main` **显式传播**（不依赖 `set -e` 的隐式行为）。
- 无问题退 `0`，有问题退 `1`。体检本身**仍然是只读的**，退 1 只是「有情况」。
- ⚠️ **行为变更**：以前拿 `--check` 当「跑得完就算过」的脚本会看到新退出码。这正是本来的意图。

**2. A —— 非交互下「读不到键盘」被当成「按继续」（行为变更，安全向）**

`confirm()` 在 stdin 不是终端时打一句「已按「继续」处理」就往回走。
预检的每一条警告（域名解析不符、端口被占…）在 Ansible / CI / 管道 / cron 里**全部自动放行**。

- 现在非交互一律**拒绝**（Default-Deny）：「读不到键盘」不等于「回答是继续」。
- 显式放行只有一条路：`--yes`（语义 = 「预检发现问题时别问我」）。**无人值守部署必须加它。**
- ⚠️ 注意这里有个**必须一起做的工程细节**：只改 `confirm()` 的返回值是**无效的**。
  `main` 里是 `preflight || exit 1`，而 `A || B` 会挂起 A 内部的 `errexit`，
  且 `preflight` 的返回值只等于它**自己最后一条命令**（`ok "预检完成"` = 0）。
  实测过：单改 `confirm` 之后单独调 `preflight` 得到 rc=1（看着修好了），
  走 `main` 却照样 rc=0、警告照打、部署继续 —— 典型的「改了但没生效」。
  所以 `preflight` 内的三个 `check_*` 调用点都加了 `|| return 1`，把失败显式抬到返回值上。
- 还有一层只在**循环**里才暴露的漏洞，一并堵上：`check_ports_free` 对 80/443 逐端口循环，
  若循环内 `confirm` 的失败不当场 `return`，那么「80 被占 → 拒绝 → 循环继续 → 443 空闲 →
  `ok`（返回 0）」会让函数的返回值变成 0，失败被后一轮的成功冲掉。
  实测：去掉循环内那两处传播，非交互下 `main` 退 **0** 且照打「预检完成」，部署继续。
- 有终端时行为**完全没变**：按回车取消仍是退出码 0，不报红。

**3. B —— `check_domain_dns` 的两种「核对不了」被混成一个 `else`**

同一个 `else` 同时覆盖「域名查不到 A 记录」和「本机公网 IP 取不到」，且**没有确认**。
前者是确定会失败（证书签发依赖它），后者只是判定不可靠（`get_public_ip` 依赖外部服务）。

- 拆成两支：**查不到 A 记录 → 问人**（与「解析到别的 IP」对齐）；**本机 IP 取不到 → 只警告**。
- 理由：判定不可靠时问人是噪音，还会把「外部 IP 服务不通」变成一次无人值守下的硬停。

**4. G —— 端口三态里的 `unknown` 被当成「空闲」**

端口探测在缺 `ss` 时返回 `unknown`，而调用方按 `0/1` 理解 ——
`--check` 对可能被占的端口打绿勾，`preflight` 同样一声不响。

- `do_check` 的端口 `*)` 分支计入 `problems`（查不了 ≠ 可以装）。
- `check_ports_free` 的同一分支升级为一次 `confirm`（与「端口被占」同格）。
- 两处口径必须一致，否则同一台机器上 `--check` 与 `preflight` 会给出不同裁决。

**5/6. F1 + F2 —— 开机自启设不上被吞（systemd / openrc 两支）**

`systemctl enable caddy … || true` 把失败吃掉了，摘要照常报「部署完成」。

- 两处都不再吞。**但刻意不改成 `return 1`** —— 那会经 `run_stage` 的 `exit 1`
  跳过 `print_summary`，用户拿不到密码，比原来的 bug 更伤。
- 改为计进 `VERIFY_WARNINGS` → 退出码 **2**（部署完成，但有一项要你知道）。

**7. F3 —— `client-config.json` 写失败被吞（两处调用点，机制不同）**

屏幕上的配置是**另行渲染**的（全仓没有任何地方 `cat` 这个文件），
于是出现最坏的一种：屏幕看着一切正常，文件根本不在。

- 调用点 ①（摘要）：写失败 → `verify_warn` + 摘要如实标注（不再出现「已存到 / 权限 0600」）。
- 调用点 ②（换密码）：写失败 → `die`，但**先保证新密码已打印** ——
  顺序反了就是「新密码已生效、服务已重载，用户却看不到密码」，等于把人锁在门外。

**8. F4 —— 上游没发校验和时，跳过完整性校验是静默的**

- 现在会把「本次未做完整性校验」如实回显到摘要里。
- 退出码**保持 0** —— 上游的行为不该让本机部署变成每次退 2 的假失败。

---

**新增自检覆盖**：403 → 448 条断言。其中 A 是**全程覆盖空洞**（断言块里此前 `-t 0` 命中 0 次，
即「非交互时 confirm 干了什么」从来没被测过）。新增的行为级断言**真跑一遍 `main`**，
而不是只调被改的那个函数 —— 理由见上面第 2 条：只调函数会测出与真机相反的结论。

**未覆盖项**：本版仍**不**在真 VPS 上跑端到端；以上全部为离线自检与沙箱桩验证。
真机验证范围见 `docs/VERIFICATION.md`。

## [2.6.1] - 2026-10-16

### 修复：失败注入矩阵的两处自我欺骗（仅影响 CI 夹具，部署脚本行为不变）

**这一版没有改动 `deploy-naive-caddy.sh` 的部署行为** —— 改的全是 CI 夹具与文档。
但它值得单独发一版，因为下面第 1 条揭示的是一类**方法论缺陷**：
夹具自己犯了它要抓的那种「跑了但报绿」。

**1. 夹具从不验证「注入是否真的生效」**

`harness.sh` 的 `main()` 装完注入只打一句「注入完成」—— 那是**声称**，不是**事实**。
2026-10-15 下载 artifact 原文核对时发现：阶段 7 的 `stage-7/run-a.log` 里写着
「✓ 服务进程运行中」，说明注入**根本没打中**，而矩阵把「退出码 0」记成了
「脚本失败不报错」。**那个读数后来被证实是假的。**

修法：
- 新增 `injection_effective()` / `assert_injection_effective()`：7 个注入点各自给出
  「独立可查」的生效判据（查系统状态确实变成了注入想要的样子，而不是查注入时写的文件在不在）。
- `main()` 里注入后立刻自检，不通过就**当场退出非 0**，并写 `INJECT_EFFECTIVE=no` ——
  绝不让「注入没打中」的读数冒充脚本行为。

**2. 阶段 7 的注入本身是失效的**

三重原因，逐个修：
- `ExecStartPost` 是同步的，直接在里面 `systemctl stop` 会死锁 → 必须后台化；
- 但普通 `( ... ) &` 后台化不够：后台进程留在 `caddy.service` 的 cgroup 里，
  服务一停 cgroup 被清理，注入器自己也被杀掉 → 循环没跑几轮就没了。**改用 `setsid` 脱离会话**；
- 循环时长不够盖过「阶段 6 restart → 阶段 7 检查」的窗口 → 40 轮加到 60 轮，
  并把每轮结果落到 `/var/log/zz-inject.log`，事后可查它到底干没干活。

**3. 容器 systemd 未就绪时不再产出读数**

阶段 7 那个容器里 `systemctl` 报 `Failed to connect to bus: No such file or directory`。
脚本阶段 6/7 与注入器都重度依赖 `systemctl`，systemd 没起来时整轮结果都没有意义。
原来只 `is-system-running --wait` 等一次就放过；改为最多等 60 秒（接受 `running`/`degraded`），
未就绪则**本轮作废**（写 `INJECT_EFFECTIVE=no` + `NOTE`，跳过该阶段），
不再用未就绪环境跑出一行看似正常的数据。

**4. 阶段 2 的撤销没清干净，被误读成「脚本不可恢复」**

`lift()` 里写的是：

```bash
sed -i '/127\.0\.0\.1 \(github\.com\|api\.github\.com\|…\)/d' /etc/hosts
```

在 BRE 里 `\(` `\)` 是**分组符**，不是字面括号 —— 这个模式**永远匹配不到**。
于是 hosts 里的注入行留着，撤销后重跑照样连不上 github，退出码 1 被矩阵记成
「撤销注入后仍失败 ⇒ 脚本不可恢复」。

实测证据（`stage-2/run-c.log`）：

```
curl: (7) Failed to connect to github.com port 443 after 0 ms: Connection refused
```

修法：改成按**整行精确删除**（`grep -vxF` 逐条过滤），不依赖 BRE 分组；
并在 `lift` 后加**撤销自证** —— 复用 `injection_effective()` 确认注入特征已清零，
结果写进 `result.env` 的 `LIFT_CLEAN`。

**矩阵表同步**：新增「注入生效」「撤销已清」两列，未生效/未清干净的行标
**否 ⇒ 本行不可信**。这样夹具的两类自我欺骗都不会再混进正常行里。

### 修复后的实测矩阵（`.github/workflows/failure-injection.yml`）

| 阶段 | 注入生效 | 退出码(首次) | 撤销已清 | 撤销后 |
| --- | --- | --- | --- | --- |
| 1 安装系统依赖 | yes | 1 | yes | 2 |
| 2 安装 Caddy 二进制 | yes | 1 | yes | 2 |
| 3 创建运行用户与目录 | yes | 1 | yes | 2 |
| 4 写入 Caddyfile | yes | 1 | yes | 2 |
| 5 布置伪装站点 | yes | 1 | yes | 2 |
| 6 安装并启动服务 | yes | 1 | yes | 2 |
| 7 验证部署 | yes | **2** | yes | 2 |

「撤销后 = 2」是 v2.6.0 的预期行为（部署成功、验证项未确认），不是失败。

### 顺带验证：v2.6.0 的退出码 2 在真容器里按设计工作

夹具日志里实测到：

```
════ ! 部署完成，但有 3 项需要你确认（退出码 2）════
  退出码 2 = 部署已完成（不是失败）；复查全过之后就会变成 0。
```

### 其它

- `.github/workflows/alpine-openrc.yml`、`arm64.yml`、`failure-injection.yml` 三个 CI 作业
  并入主干（此前只在侧分支），文档里的「尚未跑过」全部换成实测读数。
- 阶段 7 的注入生效后，「退出码 0」那一行确认是**假读数**而非脚本缺陷 ——
  脚本确实按 v2.6.0 的设计返回 2。

## [2.6.0] - 2026-10-15

### 可观察行为变更：新增退出码 2（部署完成但验证未确认）

**这一版改变了脚本的退出码，属于可观察行为变更** —— 任何 `if sudo ./deploy-naive-caddy.sh; then …`
形式的自动化都会受影响，请先读完这一段。

**原来的问题**：阶段 7 `verify_deployment()` 检查 5 件事，但只有「服务 is-active」会 `return 1`；
另外 4 项（本机 HTTPS 握手 / 证书信息 / 代理转发实测 / 公网可达）只经 `verify_warn()` 累加计数器、
**不改退出码**。于是这 4 项全失败时退出码仍是 **0**，`if sudo ./deploy.sh; then` 会走进「成功」分支。
横幅本身一直是诚实的（「有 N 项需要你确认」），但脚本化的调用方看不到横幅，只能看到 0。

**现在**：

| 退出码 | 条件 |
| --- | --- |
| `0` | 全部通过；或用户显式 `--skip-verify` |
| `1` | 致命失败（原有路径，未改动） |
| `2` | **新增** —— 没有跳过验证，且有验证项未确认（`VERIFY_WARNINGS > 0`） |

判定逻辑放在 `main()` 末尾、`print_summary()` **之后**。这一点是刻意的：
阶段函数里写 `exit`/`die` 会经 `run_stage` → `exit 1`，**跳过 `print_summary`**，
用户就拿不到密码与 `client-config.json` 了 —— 那比原来的 bug 更伤用户。
退出码 2 时摘要已经完整打印，凭据照常拿到。

配套文案：横幅末尾补「（退出码 2）」；`usage()` 新增「退出码」小节写明 0/1/2 三段语义。
README 新增「退出码」一节与对应 FAQ 条目。

自检 393 → **406** 条（纯新增，既有 393 条一行未改）。新增的全部是**行为级**断言 ——
真起子进程跑一次 `main` 看退出码，不是匹配源码字符串：

- 有警告时 `main` 退出 **2**（原 bug 是 0）
- `--skip-verify` 时退出 **0**；验证全过时退出 **0**
- 退出 2 时摘要（含密码）**已打印** —— 红线「不许跳过摘要」的行为级复核
- 判定必须在 `print_summary` 之后（静态比对 main 内行号）
- `verify_deployment` 体内没有 `exit`/`die`
- ②③④⑤ 四项仍**只记数、不改退出码**：桩出「证书还没签发完」的真实条件，
  断言四项全记数且退出码仍为 0

**证伪实验**（每条都实测「把 bug 放回去就变红」）：

| 放回去的 bug | 变红的断言 |
| --- | --- |
| 删掉 `return 2` 判定（回到原 bug） | 有警告时退出 2 / 判定在摘要之后 |
| 判定挪到 `print_summary` 之前 | 判定顺序 + 摘要已打印（两条独立红） |
| 判定塞进 `verify_deployment`（`exit 2`） | verify_deployment 里没有 exit |
| 把交握项从记数改成 `return 1` | 四项只记数 |
| 判定条件写反（`-eq 0` 替 `-gt 0`） | 四条行为断言同时红 |

其中「把交握项改成 `return 1`」一条**暴露了本轮写下的一条假绿断言**：
最初写的是 `has "$(fn_code verify_deployment)" 'verify_warn'` —— 函数里有 4 处
`verify_warn`，删掉一处改成 `return 1`，剩下 3 处照样喂饱它，断言全绿。
已改成行为级（真跑一遍数警告数）。这条留在 CHANGELOG 里是因为它正是本项目
反复强调的那类问题：**字符串匹配挡不住「改掉其中一处」的删改**。

版本号 2.5.0 → **2.6.0**（minor：新增了对外可见的退出码语义）。

## [2.5.0] - 2026-10-14

### 新增：acme.sh 证书路径（第四轮）

用户要求：「先检查机器是否有 acme.sh，没有就要装上去。然后申请证书，定时续期。」
此前只有三条路（`--tls-cert` 指定文件 / 给邮箱让 caddy 自签 / `tls internal`），**缺 acme.sh**。

自检 289 → **385** 条。核心事实全部来自真机实测，写进代码注释以防被改回去。

**证书模式自动选择（三层降级，`--cert-mode auto` 默认）**

1. 显式 `--tls-cert`/`--tls-key` → 用文件（行为与 2.4.0 一致，零 ACME 额度消耗）
2. 机器上有 acme.sh **且**给了 Cloudflare 凭据 → acme.sh 申请 + systemd timer 续期
3. 都没有 → 交给 Caddy 自己申请（给邮箱时）

`--cert-mode acme|caddy|file` 可强制指定。自动判断逻辑抽成 `resolve_cert_mode()`，
部署与 `--check` 共用同一份 —— 避免「体检打绿勾、部署才炸」的覆盖漂移。

**几个必须守住的坑（都写了注释说明为什么）**

| # | 坑 | 后果 | 做法 |
| --- | --- | --- | --- |
| 1 | `systemctl reload caddy` 换不掉证书（真机实测：返回成功、握手仍旧证书） | 续期「成功」但一直用旧证书，到期那天才发现 | 续期钩子用 `caddy reload --force`；**绝不**写 `systemctl reload \|\| caddy reload`（前者退出码 0，兜底永不执行） |
| 2 | 这台机器没有 cron | acme.sh 官方安装器拒绝安装；它自带的 cron 续期不会跑 | 无 cron 时安装器加 `--force`；续期用 **systemd timer** |
| 3 | acme.sh 默认 CA 是 ZeroSSL（源码 `DEFAULT_CA=$CA_ZEROSSL`） | 静默签发 ZeroSSL 证书 | 装完立刻 `--set-default-ca --server letsencrypt` |
| 4 | ECDSA 证书目录是 `<域名>_ecc` | 漏 `--ecc` 找不到证书 | `--install-cert` 与 `--issue` 都带 `--ecc` |
| 5 | `acme.sh --issue` 在「未到续期窗口」时返回 **2**（`RENEW_SKIP`） | `\|\| return 1` 会把正常跳过误报成失败 | 显式把退出码 2 当「跳过」处理 |

**其它**

- Cloudflare token **只从文件（`--cf-token-file`）或环境变量（`CF_Token`）读**，不支持命令行直传 —— 那会进 shell 历史
- 证书统一落 `/etc/ssl/naiveproxy/`：目录 `750 root:caddy`、`fullchain.pem`/`chain.pem` `644`、`privkey.pem` `640`
- 验证阶段报告**握手里**读到的证书的 DNS 名 / 签发者 / 到期时间（判据是 `openssl s_client`，不是盘上文件 —— 正是坑 1 的教训）
- 许可证边界：acme.sh 是 **GPL-3.0**、本仓库 **MIT**。只调用其 CLI，**不 vendor 源码**；自检有 `no_vendored_acme` 守着这条线
- OpenRC（Alpine）环境退回 acme.sh 自带 `--install-cronjob`；**连 cron 都没有时明确警告无法自动续期**，不假装成功

**一处只有写代码时才会碰到的坑（不在规格里）**

acme.sh 的 `--install-cert` 会**立刻执行一次 `--reloadcmd`** —— 而那时（阶段 4）
Caddyfile 还没写、caddy 服务还没装。续期脚本若此时报错退出，`installcert`
判定失败，**整个阶段 4 会挂掉**，尽管证书其实已经装好了。
`naive-cert-reload.sh` 因此对「配置还不存在」和「服务没在跑」两种情况**成功退出**，
只在这两种情况之外才真的判失败。

**证伪实验（10 个变异体，全部被断言抓红）**

| 变异 | 被抓红的断言 |
| --- | --- |
| reload 改回 `systemctl reload caddy \|\| …` | 「续期脚本没有 systemctl reload 兜底」 |
| `--install-cert` 去掉 `--ecc` | 「install-cert 带 --ecc」 |
| `--issue` 退出码 2 当失败 | 「issue 的退出码 2 当跳过处理」 |
| 去掉 `--set-default-ca` | 「切 CA 用 --set-default-ca」等 2 条 |
| 私钥权限改 644 | 「收敛函数设私钥 640」 |
| 验证改读盘上文件 | 「验证用 openssl s_client 读握手」等 2 条 |
| auto 模式跳过 acme.sh 探测 | 「降级②：有 acme.sh 且有 token 就选 acme」 |
| 安装器去掉 `--force` | 「无 cron 时安装器加 --force」 |
| 去掉 token 字符集校验 | 「含空格的 token 被拒」等 2 条 |
| OpenRC 无 cron 时不设 `RENEW_METHOD=none`（假成功） | 「OpenRC 无 cron 时不谎报续期已开」 |

> 其中两条（`--ecc`、`s_client`）第一轮**没被抓到** —— 断言匹配到了注释里解释性的话，
> 而不是真正的命令行。新增 `fn_code()`（剥注释取函数体）后才把这两条锁死。
> 这正是「证伪实验」的价值：不做它，这两条断言就是假的。

## [2.4.0] - 2026-10-13

### 第三轮：独立审计修掉 6 个缺陷

前两轮的改动是主对话直接写的。这一轮**把编码交给 Claude（Developer 通道，Claude Code ACP）独立审计**，
结果在新增代码里又找出 **6 个真缺陷**。自检 236 → **289** 条。

| # | 缺陷 | 后果 | 修法 |
| --- | --- | --- | --- |
| 1 | **`--serve-pac` 无任何校验** | 值是按行插进 heredoc 的，一个换行就能**注入任意 forwardproxy 指令**（实测渲染出 `disable_insecure_upstreams_check`） | 新增 `validate_path_value()` 白名单校验 |
| 2 | **`--web-root` 同样的注入** | 可在站点级插入 `respond` 与第二个 `file_server`；反斜杠还会打乱 `remove_local_hosts_hack` 的 sed，导致临时 hosts 行清不掉、永久留在用户机器上 | 同上 |
| 3 | **`state_revalidate` 漏校 4 个新状态键** | 状态文件里的 `STATE_PAC_PATH` 等被改坏后仍被判为「可信」，注入值被带回渲染器。写入侧写了五个键，**读取侧的校验没跟上** | 补齐四个键的校验 |
| 4 | **`--check` 与正式部署的校验覆盖漂移** | 非法 `--probe-secret` 会被原样渲染进预览并提示「可以正式部署了」；证书写反（cert 当 key 传）体检打绿勾、正式部署才报错 | 抽出 `check_tls_cert_inputs()` 两条路径共用，`--check` 补齐全部新选项校验 |
| 5 | `--tls-key` 缺等号形式 | `--tls-cert=/a.pem` 可用，但 `--tls-key=/k.pem` 被当未知参数拒绝 | 补 `--tls-key=*` |
| 6 | 邮箱为空时渲染出非法的裸 `tls` | 只有关键字没有参数，`caddy validate` 必然拒绝。同文件里 `WEB_ROOT` 已有自我兜底，`tls` 漏了 | 邮箱为空时退回 `tls internal` |

**验证方式（每个修复都做了证伪实验）**：把 bug 放回去，确认断言变红。8/8 全部成功证伪 ——
例如停用 `validate_path_value` 后，PAC 注入**真的重现**（渲染出 `disable_insecure_upstreams_check`），
同时 6 条断言变红。原 236 条断言经「抽掉新增段落实跑」验证**逐字未动**（仍是 236 通过）。

### 按官方文档补齐

对照上游文档逐条核对后补上的能力。**共同点：都是"文档规定了、但脚本没暴露"的缺口，
而不是做错的地方** —— 主流路径本来就与文档一致。

| 补了什么 | 文档出处 | 为什么重要 |
| --- | --- | --- |
| `--probe-secret` | forwardproxy README：`probe_resistance [secretlink.tld]`，并写明 *"you will have to visit your **secret link** in your browser to trigger the authentication. **Only this address will trigger a 407 response**"* | 脚本原先硬编码裸 `probe_resistance`（随机值）。**用户无从得知自己的秘密链接，文档给的唯一补救路径就断了**。现在可指定，并在摘要里明确列出该地址 |
| `--serve-pac` | forwardproxy README：`serve_pac [/path.pac]`，并警告开了 probe_resistance 时 *"PAC file should also be served at a **secret location**"* | Android 的 Wi-Fi 系统代理需要 PAC。真机实测确认：**PAC 只在秘密域名上可取**（主域名返回 404），与文档警告一致 |
| `--client-proto quic` | USAGE.txt：`PROXY-PROTO = "http" | "https" | "quic"`；主 README 也推荐 *"Or `quic://user:<密码>@example.com`, if it works better"* | 项目 README 早就建议线路不佳时试 QUIC，但脚本永远只生成 `https://`，用户手工改了还会被 `--rotate-password` 覆盖 |
| `--tls-cert` / `--tls-key` | 无直接文档出处，来自**真机踩坑** | Let's Encrypt 对同一域名**每 7 天只发 5 张**证书。我在验证过程中反复重装（含 `--purge` 删掉证书数据）把额度用尽，之后要等一整周。已有证书时用这两个选项复用，零消耗 |
| 秘密域名解析检查 | 文档要求 *"Make sure that specified domain name is visitable"* | 真机实测：证书只覆盖主域名时，访问秘密域名得到 `tlsv1 alert internal error` —— 连 407 都到不了。现在预检会明确警告 |
| 证书可读性自动修复 | 无文档出处，真机踩坑 | certbot 把 `/etc/letsencrypt/archive` 放成 `root:root 0700`，而 caddy 以非特权用户运行 → `permission denied` → 崩溃重启。现在启动服务前会检测并自动放开 |
| 客户端 `host-resolver-rules` 提示 | USAGE.txt：`--host-resolver-rules="MAP proxy.example.com 1.2.3.4"` | 服务端侧我们早就承认"域名可能在本机解析不通"（验证阶段为此临时改 hosts），但客户端侧只字未提。现在摘要里给出这行配置 |

**刻意没做的**（文档提到但不影响新手，做了反而增加面积）：`acl`（不写=继承文档的安全默认）、`upstream`
（与 `--allow-ports` 天然冲突）、`dial_timeout` / `max_idle_conns`（默认值即合理）、
`redir://` 监听与多跳 proxy chain（长尾）、以及 sysctl 调优（属宿主机级，会波及同机其他服务）。

顺带修掉一个真机发现的隐蔽写法错误：`tls` 行原先是 shell 的 `if/else` 写进了 heredoc ——
**Caddyfile 里不能出现 shell 语法**。已改为在 heredoc 外算好再送入，并加了断言防止复发。

### 修复（真机验证暴露的 3 个 bug）

首次在真实 VPS（Debian 13）上端到端执行所暴露、纯静态推理看不见的问题。完整背景见
[`docs/VERIFICATION.md`](docs/VERIFICATION.md)。

- **apt 包名写错**：脚本装 `xz`，Debian 系里包名是 `xz-utils`，部署在阶段 1 就失败。
  改为 `install_deps` **只装确实缺的命令**并按发行版映射包名
- **日志属主时序耦合（致命）**：root 跑 `caddy validate` 会创建 `root:root 0600` 的 `access.log`，
  服务用户打不开 → 崩溃重启（实测 29 次）。新增 `ensure_log_dir_owner()`，日志目录设 `setgid 2755`
- **验证假失败**：阶段 7 用 `127.0.0.1` 当代理地址，curl 拿它当 TLS SNI 与实际证书不符 → 服务正常也永远报失败。
  改为用真实域名做 SNI，域名本机解析不通时临时借一行 `/etc/hosts` 并在退出时精确删除

## [2.2.0]

第二轮独立评审（规划视角）做了一件很值的事：它先做了**零成本取证**，把几个"要靠租机器才知道"的问题
直接变成了事实。以下每条都自己复现核实过。

| 严重度 | 问题 | 后果 |
| --- | --- | --- |
| 高 | 阶段 7 的代理判据是 `http_code == 200`。但启用 `probe_resistance` 后，**凭据错误时不再返回 407，而是伪装成普通网站返回 200**（上游 forwardproxy 文档原文） | **对错误部署打绿勾**，还告诉用户"已用你的账号密码实测成功访问外网"。改为断言响应内容（能否解析出 `ip=`） |
| 高 | `--skip-verify` 时 `verify_deployment` 提前返回，从不累加 `VERIFY_WARNINGS`，摘要照走绿色分支 | 跳过验证被报成「**部署完成，验证全部通过**」。改为三分支，「跳过」单独一档 |
| 高 | `--https-port 8443` 渲染成 `:8443, d.com`，实测（官方 caddy adapt）会**同时监听 :443 和 :8443**；而预检只查 `80 + HTTPS_PORT`，**从不查 443** | `--https-port` 不是逃生舱；体检打绿勾而阶段 6 必炸。改为 `:8443, d.com:8443` 并把 443 纳入预检 |
| 高 | 伪装站点默认写入 `/var/www/html`，无条件 `chown -R root:root` + `chmod -R a+rX`，`--purge` 还会 `rm -rf` 它 | 那正是 **nginx 的默认 docroot** —— 在已经跑了网站的机器上会连带毁掉别人的站点。改为专属目录 `/var/www/naive-camouflage`，且拒绝接管已有内容的目录、purge 只删自己的 |
| 中 | 以 root 安装的二进制**不做任何校验和验证** | 供应链风险。改为从 GitHub API 取官方 sha256 比对，不符即中止且不安装 |
| 中 | `caddy fmt --overwrite` 在 if/else **之外**，两条路径都执行 | 文案说「保留现有配置」，实际改写了用户的文件（手写注释与排版被静默重排），还没有备份。改为先 diff、有变化才写并备份 |
| 低 | 渲染器的 `root` 依赖 `WEB_ROOT` 已被解析，直接调用会渲染出非法的 `root `（空值） | 加了兜底，渲染器不再依赖调用顺序 |
| 低 | 内置注释称「`:443` 必须写在域名前，否则 Caddy 报 unsupported protocol scheme」 | **原因是错的**（实测倒过来写照样能 adapt）。真实原因是路由匹配：只写 `d.com` 会生成 `{"match":{"host":["d.com"]}}`，而带 `:443` 才生成无 matcher 的路由 —— 这**正是 forward_proxy 需要的**（客户端会用任意 Host）。错误理由会推导出错误改法 |
| 低 | `--build-from-source` 的提示写「Go 1.21+」 | 上游 Caddy 2.11.x 用 Go 1.26 构建，发行版自带的 Go（Debian 12: 1.19 / Ubuntu 24.04: 1.22）不够用；且 1 GB 内存编译易 OOM。提示已改正并给出安装路径 |
| 低 | `--force-config` 会重新生成密码 | 已配置的客户端在用户毫无察觉时全部失效。改为优先复用状态文件里的密码 |

另外修了测试基础设施一个隐蔽问题：`fn_body`（结构性断言用的函数体提取）原本"遇到列首 `}` 就结束"，
而渲染器的 heredoc 里就含列首 `}`，导致函数体被腰斩、**断言在残缺文本上悄悄变成空断言**。
现在改成跟 bash 一样跟踪 heredoc 状态。顺带发现一条断言因为 `${` 在 `grep -E` 里是元字符而**永远匹配不上**
（等于没测）—— 已修。

## [2.1.0]

一次独立代码评审（在 v2.0.0 上做，逐条复现后确认）查出的真实缺陷：

| 严重度 | 问题 | 后果 |
| --- | --- | --- |
| 高 | 邮箱校验接受单引号/分号；状态文件用 `source` 读回 | 二次执行 / `--rotate-password` / `--collect-diagnostics` 时**以 root 执行注入命令**；合法撇号邮箱则让状态文件永久无法解析 |
| 中 | `--upgrade` 路径没调 `detect_arch`，`ARCH` 是空串 | 本该下载预编译包的 x86_64 机器跑去**源码编译** 3-5 分钟 |
| 中 | `--rotate-password` 校验失败时提示「已回滚」，但**没有任何回滚** | 假信息 + 配置与状态文件密码永久不一致，下次 restart 起不来 |
| 中 | 选项缺值（如 `--domain` 后面没跟值）触发 `shift 2` 越界 | **stdout 与 stderr 全空、退出码 1**，用户完全无从判断 |
| 中 | 配置已存在时，用户新指定的 `--domain` 被静默忽略 | 以为部署了新域名，实际生效的是旧域名 |
| 中 | 没有 `ss` 时端口探测返回「未占用」 | 预检对一个可能被 Nginx 占着的端口**打绿勾** |
| 低 | 写伪装首页的 heredoc 没兜底 | 磁盘满时绕过整个失败处理，只剩一行裸报错 |
| 低 | `chmod` 没兜底、`chown` 被 `\|\| true` 吞掉 | 属主不对时阶段 4 报成功，失败推迟到阶段 6/7，排查方向全错 |
| 低 | 阶段 7 的建议第一句是「服务已经在跑了」，而该阶段有个「服务没起来就判失败」的分支 | 自相矛盾的假信息 |
| 低 | `--force-config` 会重新生成密码 | 已配置的客户端在用户毫无察觉时全部失效 |
| 低 | 日志目录创建失败后，失败信息里什么都不倒 | 「安装依赖失败」后面一片空白 |
| 低 | `--check` 不校验端口与 `--allow-ports` | 体检说「可以部署」，正式部署立刻被拒；预览里还渲染出非法值 |
| 低 | 覆盖 systemd unit 前不备份，与「每一步改动前都会备份」的承诺不符 | 机器上原有的同路径文件（如 `apt install caddy` 留下的）被静默覆盖、卸载后无法恢复 |
| 低 | openrc 模板没定义 `reload()` | `--reload` 在 Alpine 上必然失败 |
| 低 | `mask_conf_password` 用了 `sed -E` | busybox 的老版 sed 只认 `-r` |
| 低 | 预检依赖 `ss`，但 Alpine 上并不预装 | 见上一条「端口三态」 —— 现改为如实说「无法判定」并尽力补装 |

同族问题的共同点：**都发生在「两次运行之间的状态往返」和「探测失败被当成成功」** —— 这两类天然需要跑两遍或制造失败才暴露，所以结构性断言和 shellcheck 都看不见。为此新增了一整组行为级断言（状态文件往返一致性、注入抵抗、选项缺值输出非空、端口三态）。
