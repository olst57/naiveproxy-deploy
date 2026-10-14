# 变更记录

本文件格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。
**版本号的唯一事实源是脚本里的 `SCRIPT_VERSION`**（`deploy-naive-caddy.sh`），本文件必须与它保持一致。

首个 tag 即 `v2.4.0` —— 版本号早已通过 `--version` 对用户可见，不从 0.1.0 重来。
v2.2.0 / v2.1.0 两条是本次建仓时回填的历史记录（当时未打 tag，日期未记录）。

## [Unreleased]

（暂无）

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
