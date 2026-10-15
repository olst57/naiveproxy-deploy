# NaiveProxy 服务端一键部署

> **这是什么**：一个在**你自己的 VPS** 上一键部署 NaiveProxy 服务端的 Bash 脚本（部署 / 升级 / 重载 / 换密码 / 体检 / 卸载）。
> **这不是官方项目**：与 NaiveProxy、forwardproxy 上游**没有**隶属或背书关系，详见 [与上游的关系](#与上游的关系)。
> **不承诺任何网络环境下的可用性**：能否连通、会不会被识别，取决于你的网络、域名与服务器 —— 脚本**不做任何保证**。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![shellcheck: 0 warnings](https://img.shields.io/badge/shellcheck-0%20warnings-brightgreen)](.github/workflows/ci.yml)
[![self-test](https://img.shields.io/badge/self--test-passing-brightgreen)](.github/workflows/ci.yml)

NaiveProxy 的核心是**伪装**：复用 Chrome 网络栈，让流量看起来就是「浏览器在访问一个普通网站」。
因此服务端必须是一台**有域名的 VPS**，走 443 + 真实 TLS 证书，未认证访客看到的是一个正常网页。

```
浏览器 → [naive 客户端] → 审查者 → [Caddy 前置服务器] → 互联网
```

## 一行安装

```bash
curl -O https://raw.githubusercontent.com/olst57/naiveproxy-deploy/main/deploy-naive-caddy.sh
chmod +x deploy-naive-caddy.sh && ./deploy-naive-caddy.sh --check --domain 你的域名 --email 你的邮箱
```

第二行先跑**只读体检**（不需 root、不改系统），全绿再去掉 `--check` 正式部署。

## 与上游的关系

- **不是 fork，也不是官方附属**：本项目只是一个**部署脚本**，不包含 NaiveProxy / forwardproxy 的任何源码，
  与 [`klzgrad/naiveproxy`](https://github.com/klzgrad/naiveproxy)、
  [`klzgrad/forwardproxy`](https://github.com/klzgrad/forwardproxy) 的作者无隶属关系，也未被其背书。
- **运行时从上游 Release 下载二进制并校验 sha256**：脚本从上游仓库的 Release 资产下载
  `caddy-forwardproxy-naive` 单二进制，用 GitHub API 提供的 sha256 比对，不符即中止安装。
- **不对上游二进制做任何修改**：脚本只负责下载、校验、安装、配置、起服务。

## 文件

| 文件 | 说明 |
| --- | --- |
| `deploy-naive-caddy.sh` | 主脚本：部署 / 升级 / 重载 / 换密码 / 体检 / 卸载 |
| `validate-caddyfile.sh` | 安全校验 Caddyfile 的辅助工具（见 [`docs/windows-validation.md`](docs/windows-validation.md)） |
| `examples/Caddyfile` | 服务端配置示例（**脚本运行时不读它**，仅供人工参考） |
| `examples/client-config.json` | 客户端配置示例 |
| `docs/VERIFICATION.md` | 验证记录与计划（真机结果、已验证范围、未覆盖项） |
| `CHANGELOG.md` | 版本变更记录 |

## 前置条件

- 一台 VPS（1 核 512M 起），Debian/Ubuntu、RHEL 系或 Alpine
- 一个域名，A 记录指向服务器 IP，**且已生效**
- 安全组放行 **TCP 443**（80 也建议开着，证书自动续期要用）
- 80/443 没被 Nginx/Apache 占用

## 快速开始

传脚本上服务器后，先给它执行位（不做这步会报 `Permission denied`）：

```bash
chmod +x deploy-naive-caddy.sh
```

然后三步：

```bash
# ① 体检：只读，不改任何东西，不需要 sudo
./deploy-naive-caddy.sh --check --domain proxy.example.com --email ops@mail.test

# ② 正式部署（约 1 分钟）
sudo ./deploy-naive-caddy.sh --domain proxy.example.com --email ops@mail.test

# ③ 后悔药：把 ② 做的全部撤销
sudo ./deploy-naive-caddy.sh --uninstall --purge
```

什么都不加直接跑，会得到一张同样的引导页 —— 不会报错。

不传 `--password` 会自动生成 28 位随机密码，部署结束时连同客户端配置一起打印。

## 参数

### 基本

| 参数 | 说明 |
| --- | --- |
| `--domain <域名>` | 必填。已解析到本机的域名 |
| `--email <邮箱>` | 必填。证书通知邮箱 |
| `--user <用户名>` | 代理账号，默认 `naive` |
| `--password <密码>` | 代理密码，默认自动生成 28 位 |
| `--https-port <端口>` | HTTPS 端口，默认 443 |
| `--check` | 体检：环境 + 前置条件逐条判定 + 配置预览（只读，无需 root） |
| `-y, --yes` | 所有确认自动回答「是」 |

> 密码写在命令行会进 shell 历史记录和 `/proc/<pid>/cmdline`。更稳妥的写法是环境变量：
> ```bash
> NAIVE_PASSWORD='你的密码' sudo -E ./deploy-naive-caddy.sh --domain ... --email ...
> ```
> （`sudo -E` 才能把环境变量带过去。）

### 进阶

| 参数 | 说明 |
| --- | --- |
| `--web-root <目录>` | 伪装站点目录，默认 `/var/www/naive-camouflage` |
| `--probe-secret <域名>` | `probe_resistance` 的秘密域名。**指定后只有这个地址会触发 407**，浏览器据此弹凭据框 |
| `--serve-pac <路径>` | 生成 PAC 文件（Android Wi-Fi 代理由此接入）。开了 `probe_resistance` 时路径必须不可预测 |
| `--client-proto <协议>` | 客户端配置用 `https` 还是 `quic`（默认 https） |
| `--tls-cert <文件>` / `--tls-key <文件>` | 复用现成证书（certbot / acme.sh 签的），**不消耗 ACME 额度** |
| `--cert-mode <方式>` | 证书怎么来：`auto`（默认）/ `acme` / `caddy` / `file`。见下方「证书从哪来」 |
| `--allow-ports "<列表>"` | 限定客户端可经代理访问的目标端口，如 `"80 443"`。留空则不限制。加此项可防止凭据外泄后代理被当作任意端口跳板 |
| `--force-config` | 配置已存在时也重新生成（自动备份原件） |
| `--build-from-source` | 用 xcaddy 从源码编译（非 x86_64 架构会自动启用） |
| `--skip-verify` | 跳过部署后的连通性验证 |
| `--ascii` | 用纯 ASCII 标记输出（PuTTY / GBK 终端下更稳） |
| `--dry-run` | `--check` 的旧名字，保留兼容 |

### 运维

| 参数 | 说明 |
| --- | --- |
| `--upgrade` | 只升级 caddy 二进制，配置不动 |
| `--reload` | 校验并重载配置（校验不过就不重载） |
| `--rotate-password` | 换一个代理密码，改配置 + 平滑重载 |
| `--collect-diagnostics` | 收集排查信息（密码自动打码），求助时把输出发出来 |
| `--uninstall [--purge]` | 卸载；`--purge` 连站点/日志/数据/用户一起删（会二次确认） |
| `--self-test` | 开发者自检：不需要 root，**运行后自报断言数量** |

### 证书从哪来（`--cert-mode`）

`auto`（默认）按三层降级挑一条路，**不会改变已有命令行的行为**：

1. 给了 `--tls-cert`/`--tls-key` → 直接用你的文件（零 ACME 额度消耗，与旧版一致）
2. 机器上有 [acme.sh](https://github.com/acmesh-official/acme.sh) 且给了 Cloudflare 凭据 → 用 acme.sh 申请 + 装 **systemd timer** 自动续期
3. 都没有 → 交给 Caddy 自己向 Let's Encrypt 申请（给邮箱时）

用 `--cert-mode acme|caddy|file` 可以强制指定某一条。

#### acme.sh 这条路

| 参数 | 说明 |
| --- | --- |
| `--cf-token-file <文件>` | Cloudflare API token 的文件路径（`Zone → DNS → Edit` 权限）。**文件里只放 token 一行** |
| `--acme-email <邮箱>` | acme.sh 的通知邮箱，默认沿用 `--email` |
| `--acme-staging` | 用 Let's Encrypt 测试环境，**不消耗生产额度**（调试用） |

没有 acme.sh 时脚本会自动装（**无 cron 的机器加 `--force`**，因为官方安装器否则拒绝安装），
装完**立刻把默认 CA 切成 Let's Encrypt** —— acme.sh 默认指向 ZeroSSL，不切会静默用错 CA。
校验走 **DNS-01 + Cloudflare**，所以 **80 端口不必对外可达**。

**Token 只从文件或环境变量读，不支持命令行直传**（会进 shell 历史）：

```bash
# 方式一：文件
printf '%s\n' '你的CF_Token' | sudo tee /root/.cf-token >/dev/null
sudo chmod 600 /root/.cf-token
sudo ./deploy-naive-caddy.sh --domain proxy.example.com --email ops@mail.test --cf-token-file /root/.cf-token

# 方式二：环境变量
sudo CF_Token='你的CF_Token' -E ./deploy-naive-caddy.sh --domain proxy.example.com --email ops@mail.test
```

证书统一落在 `/etc/ssl/naiveproxy/`（目录 `750 root:caddy`、`fullchain.pem`/`chain.pem` `644`、`privkey.pem` `640`）。

> **续期用 systemd timer，不用 cron。** 真机实测这台机器没有 cron（`crontab` 缺失、`cron` 服务 inactive），
> acme.sh 官方安装器会因此拒绝安装，且它自带的 cron 续期在这个环境下不会跑。OpenRC（Alpine）
> 环境没有 systemd，会退回 acme.sh 自带的 `--install-cronjob`；**连 cron 都没有时会明确警告无法自动续期**，
> 不会假装成功。

> **`systemctl reload caddy` 换不掉证书。** 真机实测：它返回成功，但 TLS 握手读到的仍是旧证书 ——
> 静默失效，直到证书到期那天才发现。续期钩子 `naive-cert-reload.sh` 因此必须用
> `caddy reload --force --config /etc/caddy/Caddyfile`。也**绝不能**写成
> `systemctl reload caddy || caddy reload --force`：前者退出码是 0，兜底永远不会执行。

#### 许可证边界

acme.sh 是 **GPL-3.0**，本仓库是 **MIT**。GPL 限制的是**分发**而非**使用**：
脚本只**调用** acme.sh 的 CLI（边界使用，不是衍生作品），从官方地址 `https://get.acme.sh`
现场获取安装器，**绝不把它的源码 vendor / 复制进本仓库** —— 那会迫使整个仓库变成 GPL-3.0。

## 部署流程（7 个阶段）

| # | 阶段 | 做什么 |
| --- | --- | --- |
| — | 预检 | 识别发行版/架构；核对域名解析；检查 443 **和 80** 是否空闲 |
| 1 | 安装系统依赖 | curl / tar / xz；外部命令输出写进 `/var/log/caddy/deploy.log`，终端只留叙事 |
| 2 | 安装 Caddy 二进制 | 从 GitHub 拉取 `caddy-forwardproxy-naive`，**校验 sha256**（与官方发布记录比对），带重试与失败回退 |
| 3 | 创建运行用户与目录 | 独立 `caddy` 系统用户（nologin），收紧日志与数据目录权限 |
| 4 | 写入 Caddyfile | 渲染 → 仅在排版需要时 `caddy fmt`（会先备份）→ `caddy validate` |
| 5 | 布置伪装站点 | 生成 `/var/www/naive-camouflage/index.html`（刻意不用 `/var/www/html`） |
| 6 | 安装并启动服务 | systemd unit（或 Alpine 的 openrc 脚本）并启动；acme 模式下顺带装续期 timer |
| 7 | 验证部署 | 4 项实测：本机 HTTPS 握手、证书签发者/到期时间/**从握手读到的证书**、代理转发实测、公网可达 |

阶段编号由 `STAGE_NAMES` 数组统一推导，标题与失败提示用同一个名字 —— 不会出现「屏幕上写着第 4 步、报错说第 5 步」。

## 生成的配置

```
{
	order forward_proxy before file_server

	log {
		output file /var/log/caddy/access.log {
			roll_size 20MiB
			roll_keep 5
			roll_keep_for 168h
		}
		# 不记录用户代理访问目标，避免日志侧信道泄露
		exclude http.log.error
	}
}

# 注意: :443 必须写在域名前面 —— 这不是语法要求，而是路由匹配要求：
# 只写域名会生成带 host matcher 的路由，而 forward_proxy 需要无 matcher 的路由
# （客户端会用任意 Host 发请求）。带 :port 前缀才会生成无 matcher 的路由。
:443, proxy.example.com {
	tls ops@mail.test

	encode

	forward_proxy {
		basic_auth tom <密码>
		ports 80 443          # 仅在使用 --allow-ports 时出现
		hide_ip
		hide_via
		probe_resistance
	}

	# 未认证访问者看到的就是这个正常站点（配合 probe_resistance 抗主动探测）
	file_server {
		root /var/www/naive-camouflage
	}
}
```

各指令作用：

- `hide_ip` / `hide_via` — 不向目标站泄露来源 IP，不加 `Via` 头
- `probe_resistance` — 抗主动探测；**必须配合 `basic_auth` 才有意义**，否则裸 `forward_proxy` 是可直接用作开放代理的
- `file_server` — 让未认证访问看起来像普通网站，而不是一个报错页面
- `ports` — 只在你显式传 `--allow-ports` 时出现

## 客户端接入

官方 naive 二进制各平台都有（Windows / macOS / Linux / Android / OpenWrt）。客户端 `config.json`：

```json
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://用户名:密码@proxy.example.com"
}
```

跑起来后本地 `127.0.0.1:1080` 就是一个 SOCKS5 代理。
若 HTTPS 线路不佳，可把 `https://` 换成 `quic://` 试试。

部署结束后脚本会把填好的客户端配置存到 `/etc/caddy/client-config.json`（权限 0600）。

| 平台 | 推荐 |
| --- | --- |
| Windows | 官方 naive 二进制 / v2rayN |
| macOS | 官方 naive 二进制 / sing-box |
| iOS | Shadowrocket / sing-box |
| Android | Exclave / husi / NekoBox |

## 日常运维

```bash
systemctl status caddy              # 状态
journalctl -u caddy -f              # 实时日志（Caddy 自身）
tail -f /var/log/caddy/access.log   # 代理访问日志
sudo ./deploy-naive-caddy.sh --reload           # 校验后重载
sudo ./deploy-naive-caddy.sh --upgrade          # 升级二进制，配置不动
sudo ./deploy-naive-caddy.sh --rotate-password  # 换密码
sudo ./deploy-naive-caddy.sh --collect-diagnostics  # 出问题时收集信息
```

**建议定期升级**：NaiveProxy 需保持与 Chrome 的签名一致，旧版本更容易被识别。

## 安全说明

- 脚本强制密码为 8 位以上纯字母数字，这是为了同时兼容 Caddyfile 语法与代理 URI 编码；自动生成的 28 位随机串满足该约束，强度足够
- 状态文件 `/etc/caddy/.naive-deploy-state`（**隐藏文件**，权限 0600）记录账号密码，供二次执行复用。读取时**绝不 `source`** —— 按行取值、逐项重新校验、先检查属主与权限，所以即使这个文件被改坏也执行不了里面的内容。**忘了密码就查它**：
  ```bash
  sudo cat /etc/caddy/.naive-deploy-state
  ```
- 下载的二进制会**校验 sha256**（与 GitHub 发布记录比对），不符即中止
- 伪装站点写在专属目录 `/var/www/naive-camouflage`，**不动** `/var/www/html`（那是 nginx 的默认 docroot）；
  若目标目录已有其他内容则拒绝接管，`--purge` 也只删自己建的
- 密码疑似泄露时用 `--rotate-password` 一条命令换掉，不必重装
- 配置 0640（root:caddy）、客户端配置 0600；服务以非特权用户运行，仅授予 `CAP_NET_BIND_SERVICE` 以绑定 443
- 担心凭据外泄后被当作任意端口跳板，加上 `--allow-ports "80 443"` 收紧
- 邮箱字段刻意使用保守字符集（字母数字与 `. _ % + -`）。代价是形如 `o'brien@mail.test` 的地址会被拒绝 —— 这个邮箱只用于接收证书到期通知，换一个即可
- `probe_resistance` 可传自定义密钥域名（`probe_resistance your-secret.com`）替代随机值；不传时使用随机值
- **求助时不要把真实密码/域名/公网 IP 贴进 issue** —— 用 `--collect-diagnostics` 收集信息，它会**自动把密码打码**，把它的输出发出来即可

## 常见问题

**证书签发失败**
先确认域名已解析到本机。若套了 Cloudflare 橙云，ACME 验证会被拦截 —— 需要先切灰云。

**服务起来但公网连不上**
多为 NAT 回流受限（在服务器上访问自己的公网域名失败，但外部可以）。用手机流量复测。

**代理转发实测没通过**
注意：因为启用了 `probe_resistance`，凭据错误时**不会**返回 407，而是伪装成普通网站返回 200 + 伪装页
（这是上游 forwardproxy 的文档明确说明的行为）。所以脚本判断的是**响应内容**（要能解析出 `ip=` 那行），不是状态码 ——
只看状态码会对错误部署打绿勾。排查：`sudo grep -A2 basic_auth /etc/caddy/Caddyfile`。

**端口 443 或 80 被占用**
`sudo ss -ltnp | grep -E ':(80|443)'` 看是谁占着。Nginx/Apache 需要先停掉或让位 —— 注意 Caddy 的 hostname 站点会同时用 80，只开 443 是不够的。

**二手部署：配置还在，但看不到密码**
如果 `/etc/caddy/.naive-deploy-state` 丢了，脚本**不会**编一个密码给你 —— 它会明确说无法确认，并让 / 你去配置里查。

**非 x86_64 架构没有预编译包**
加 `--build-from-source`，脚本会自动装好 Go 工具链并用 xcaddy 编译。

## 设计说明

脚本面向的是**有 VPS 但未必精通 Linux** 的人，所以交互上有几个刻意选择：

- **无参数运行给引导页，不是报错。** 用户第一次总会先敲一下看看，这一下不该只换来一行红字。
- **`--check` 合并了原来的 `--dry-run` 和 `--self-test`。** 用户只需要知道一个词。`--self-test` 是给维护者的，归到进阶。
- **失败信息按阶段给「能自助解决」的提示**：一句人话原因 + 一条可复制命令 + 预期结果，而不是丢一个 `journalctl`（它对 7 个阶段里的 5 个是错的 —— 那时服务还没装上）。
- **失败时给状态快照**（`二进制 已安装 / 配置 已写入 / 服务 未运行`），让人知道自己在半成品的哪个位置、前面几步没白做，并明确「重跑是安全的」。
- **「部署完成」和「验证通过」是两个词。** 有验证项没过时会说「有 N 项需要你确认」并列出是哪几项。
- **按回车取消不是错误**，退出码是 0，不是红色 ✗。
- **预览绝不显示假密码** —— 体检阶段显示占位符，真密码只在真的要写配置时生成。
- **参数问题先于权限问题报。** 少写 `--domain` 时告诉你「`--domain` 必填」，而不是「你没有 root 权限」。
- **`--purge` 必须二次确认** —— 唯一不可逆、删目录删用户的操作，不该一个回车就执行。

## 验证与变更记录

- **验证记录、真机结果、已验证范围与未覆盖项** → [`docs/VERIFICATION.md`](docs/VERIFICATION.md)
- **Windows 上校验配置的坑**（`/var/...` 解析、GBK 输出） → [`docs/windows-validation.md`](docs/windows-validation.md)
- **各版本修了什么** → [`CHANGELOG.md`](CHANGELOG.md)

> 一句话概括验证状态：主路径已在真机（Debian 13）端到端跑通并留证；
> Alpine/openrc、arm64 源码编译、失败注入矩阵**尚未覆盖**。详见 `docs/VERIFICATION.md`。
>
> Alpine/openrc 已有 CI 作业（`.github/workflows/alpine-openrc.yml`，真 `alpine:3.20` 容器），
> 但**跑出结果之前不算验证** —— CI 文件存在 ≠ 已验证。
