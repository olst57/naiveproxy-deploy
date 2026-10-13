#!/usr/bin/env bash
#
# deploy-naive-caddy.sh — NaiveProxy 服务端一键部署 / 升级 / 卸载 / 体检
#
# 后端二进制: caddy-forwardproxy-naive（Caddy + naive padding 层，单二进制）
#             由 klzgrad/forwardproxy 的 Release 资产提供（见下方 GH_REPO）
# 上游项目:   https://github.com/klzgrad/naiveproxy
#
# 第一次用？什么都不加跑一次，会给你一张引导页：
#   ./deploy-naive-caddy.sh
#
# 典型流程：
#   ./deploy-naive-caddy.sh --check --domain proxy.example.com --email ops@mail.test
#   sudo ./deploy-naive-caddy.sh --domain proxy.example.com --email ops@mail.test
#
# 其它：
#   sudo ./deploy-naive-caddy.sh --upgrade                只换二进制，配置不动
#   sudo ./deploy-naive-caddy.sh --reload                 校验并重载配置
#   sudo ./deploy-naive-caddy.sh --rotate-password        换一个代理密码并平滑生效
#   sudo ./deploy-naive-caddy.sh --collect-diagnostics    收集排查信息（密码自动打码）
#   sudo ./deploy-naive-caddy.sh --uninstall --purge      彻底卸载
#   ./deploy-naive-caddy.sh --self-test                   开发者自检（无需 root）
#
# 退出码: 0 成功 / 主动取消 | 1 校验或部署失败
#
set -Eeuo pipefail

SCRIPT_VERSION="2.4.0"
CADDY_FALLBACK_TAG="v2.11.7-naive"
GH_REPO="klzgrad/forwardproxy"
CADDY_BIN="/usr/bin/caddy"
CONF_DIR="/etc/caddy"
CONF_FILE="${CONF_DIR}/Caddyfile"
STATE_FILE="${CONF_DIR}/.naive-deploy-state"
CLIENT_CONF="${CONF_DIR}/client-config.json"
# 伪装站点目录。刻意不用 /var/www/html —— 那是 nginx 的默认 docroot，
# 在已经跑了网站的机器上对它 chown -R / rm -rf 会连带毁掉别人的站点。
WEB_ROOT_DEFAULT="/var/www/naive-camouflage"
WEB_ROOT=""        # 由 --web-root 决定，缺省取 WEB_ROOT_DEFAULT
LOG_DIR="/var/log/caddy"
DEPLOY_LOG="${LOG_DIR}/deploy.log"
DATA_DIR="/var/lib/caddy"
SVC_FILE="/etc/systemd/system/caddy.service"
OPENRC_FILE="/etc/init.d/caddy"
TMP_DIR=""

# ---------------- 运行期状态（全部显式初始化：set -u 下未定义会直接报错） ----------------
DOMAIN=""
EMAIL=""
NAIVE_USER="naive"
NAIVE_PASS=""
USER_EXPLICIT="no"
HTTPS_PORT="443"
ALLOW_PORTS=""
MODE="install"
PURGE="no"
FORCE_CONFIG="no"
BUILD_FROM_SRC="no"
SKIP_VERIFY="no"
ASSUME_YES="no"
SELF_TEST="no"
RELOAD_ONLY="no"
CHECK_ONLY="no"
ROTATE_PASSWORD="no"
DIAGNOSTICS="no"
ASCII_ONLY="no"
PROBE_SECRET=""
PAC_PATH=""
CLIENT_PROTO="https"

# 环境探测结果
OS_ID=""
OS_LIKE=""
OS_NAME=""
INIT=""
PKG=""
ARCH=""

# 部署日志是否可写（决定失败时能不能倒出细节）
DEPLOY_LOG_OK="no"

# ---------------- 阶段表（编号与名字的唯一来源） ----------------
TOTAL_STAGES=7
STAGE_NAMES=(
	"安装系统依赖"
	"安装 Caddy 二进制"
	"创建运行用户与目录"
	"写入 Caddyfile"
	"布置伪装站点"
	"安装并启动服务"
	"验证部署"
)
STAGE_HINT=(
	"约 30 秒，看网络"
	"从 GitHub 下载"
	"建系统用户与目录"
	"渲染配置并校验语法"
	"生成一个正常网站作为伪装"
	"安装服务并启动"
	"实测握手、证书、转发 —— 最长约 80 秒"
)

# ---------------- 颜色与字形 ----------------
C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_RST=""; C_DIM=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
	C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
fi

# 字形默认 UTF-8；--ascii 或 NAIVE_ASCII=1 时换纯 ASCII，
# 照顾 PuTTY / GBK 终端下把标记显示成问号的情况。
G_OK="✓"; G_WARN="!"; G_ERR="✗"; G_DOT="·"; G_STEP="▸"; G_ARROW="→"

setup_glyphs() {
	if [ "$ASCII_ONLY" = "yes" ] || [ -n "${NAIVE_ASCII:-}" ]; then
		G_OK="+"; G_WARN="!"; G_ERR="x"; G_DOT="-"; G_STEP=">"; G_ARROW="->"
	fi
	if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
		C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_RST=""; C_DIM=""
	fi
}

# ---------------- 输出 ----------------
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "  ${C_GRN}${G_OK}${C_RST} $*"; }
warn() { printf '%s\n' "  ${C_YEL}${G_WARN}${C_RST} $*" >&2; }
note() { printf '%s\n' "  ${C_DIM}${G_DOT}${C_RST} $*"; }
err()  { printf '%s\n' "  ${C_RED}${G_ERR}${C_RST} $*" >&2; }
die()  { printf '\n%s\n' "  ${C_RED}${G_ERR}${C_RST} $*" >&2; exit 1; }

section() {
	printf '\n%s\n' "${C_DIM}────────────────────────────────────────────────${C_RST}"
	printf '%s\n' "${C_BLD}${G_STEP} $*${C_RST}"
}

cleanup() {
	if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then rm -rf "${TMP_DIR}"; fi
	# 被 Ctrl-C / 中断时也要把临时 hosts 那行清掉
	if [ "${HOSTS_HACK_ACTIVE:-no}" = "yes" ]; then remove_local_hosts_hack; fi
	return 0
}

# 刻意不注册全局 ERR trap：set -E 会把它继承进 $(...) 子 shell，
# 使探测类函数（返回非 0 属正常）误触发错误处理。
# 部署阶段改用 run_stage + 阶段内显式 return 1 传递失败。
trap cleanup EXIT

# ---------------- 失败处理 ----------------
STATE_BIN=""; STATE_CONF=""; STATE_SVC=""

gather_state() {
	if [ -x "${CADDY_BIN}" ]; then STATE_BIN="已安装"; else STATE_BIN="未安装"; fi
	if [ -f "${CONF_FILE}" ]; then STATE_CONF="已写入"; else STATE_CONF="未写入"; fi
	STATE_SVC="未安装"
	if [ -f "${SVC_FILE}" ] && command -v systemctl >/dev/null 2>&1; then
		if systemctl is-active --quiet caddy 2>/dev/null; then
			STATE_SVC="运行中"
		else
			STATE_SVC="已安装未运行"
		fi
	fi
}

# ---------------- 状态文件读写 ----------------
# 刻意不用 source 读状态文件。source 是把数据当代码执行：
# 文件里只要出现一个引号或分号，读它的那一刻就等于以 root 跑那段内容。
# 这里改成按行取值，绝不 eval。
state_read_one() { # <KEY>  —— 读 STATE_<KEY>= 后面那一段
	local k="$1" v=""
	[ -r "${STATE_FILE}" ] || return 1
	v=$(sed -n "s/^STATE_${k}=//p" "${STATE_FILE}" 2>/dev/null | head -1)
	# 兼容早期写成 STATE_X='value' 的格式：剥掉一层单引号
	case "$v" in
		\'*\') v="${v#\'}"; v="${v%\'}" ;;
	esac
	printf '%s' "$v"
}

state_parse_into_vars() {
	STATE_DOMAIN=$(state_read_one DOMAIN)
	STATE_EMAIL=$(state_read_one EMAIL)
	STATE_USER=$(state_read_one USER)
	STATE_PASS=$(state_read_one PASS)
	STATE_PORT=$(state_read_one PORT)
	STATE_ALLOW_PORTS=$(state_read_one ALLOW_PORTS)
STATE_PROBE_SECRET=$(state_read_one PROBE_SECRET)
STATE_PAC_PATH=$(state_read_one PAC_PATH)
STATE_CLIENT_PROTO=$(state_read_one CLIENT_PROTO)
STATE_TLS_CERT=$(state_read_one TLS_CERT)
STATE_TLS_KEY=$(state_read_one TLS_KEY)
	return 0
}

# 从状态文件读回来的值必须重新过一遍校验器 —— 不信任数据文件。
# 任一值不合规就整体判为不可信，交由调用方走 CREDS_KNOWN=no 分支。
state_revalidate() {
	local bad=0
	if [ -n "${STATE_DOMAIN:-}" ]; then validate_domain "$STATE_DOMAIN" || bad=1; fi
	if [ -n "${STATE_EMAIL:-}" ]; then validate_email "$STATE_EMAIL" || bad=1; fi
	validate_user "${STATE_USER:-}" || bad=1
	validate_port "${STATE_PORT:-443}" || bad=1
	validate_ports_list "${STATE_ALLOW_PORTS:-}" || bad=1
	if [ -n "${STATE_PASS:-}" ]; then validate_password "$STATE_PASS" || bad=1; fi
	if [ -n "${STATE_PROBE_SECRET:-}" ]; then validate_probe_secret "$STATE_PROBE_SECRET" || bad=1; fi
	# PAC 路径与证书路径同样会被按行写回 Caddyfile —— 读回来必须一起过校验。
	# 漏了它们，一个被改坏的状态文件就能把换行注入重新带进配置，
	# 而 state_load 会照常报「可信」，凭据也会照常显示。
	if [ -n "${STATE_PAC_PATH:-}" ]; then validate_path_value "$STATE_PAC_PATH" || bad=1; fi
	if [ -n "${STATE_TLS_CERT:-}" ]; then validate_path_value "$STATE_TLS_CERT" || bad=1; fi
	if [ -n "${STATE_TLS_KEY:-}" ]; then validate_path_value "$STATE_TLS_KEY" || bad=1; fi
	if [ -n "${STATE_CLIENT_PROTO:-}" ]; then validate_client_proto "$STATE_CLIENT_PROTO" || bad=1; fi
	return "$bad"
}

state_load() { # 校验属主/权限后再解析
	[ -r "${STATE_FILE}" ] || return 1
	local owner="" mode=""
	owner=$(stat -c '%U' "${STATE_FILE}" 2>/dev/null || echo '?')
	mode=$(stat -c '%a' "${STATE_FILE}" 2>/dev/null || echo '?')
	if [ "$owner" != "root" ] || [ "$mode" != "600" ]; then
		warn "状态文件 ${STATE_FILE} 的属主/权限异常（${owner} ${mode}），出于安全不予采用"
		return 1
	fi
	state_parse_into_vars
	state_revalidate || { warn "状态文件内容未通过校验，不予采用"; return 1; }
	return 0
}

# 原子写入：先写临时文件再 mv，避免中途失败留下半个文件。
state_write() {
	local tmp="${STATE_FILE}.tmp.$$"
	{
		printf 'STATE_DOMAIN=%s\n' "${DOMAIN}"
		printf 'STATE_EMAIL=%s\n' "${EMAIL}"
		printf 'STATE_USER=%s\n' "${NAIVE_USER}"
		printf 'STATE_PASS=%s\n' "${NAIVE_PASS}"
		printf 'STATE_PORT=%s\n' "${HTTPS_PORT}"
		printf 'STATE_ALLOW_PORTS=%s\n' "${ALLOW_PORTS}"
		printf 'STATE_PROBE_SECRET=%s\n' "${PROBE_SECRET}"
		printf 'STATE_PAC_PATH=%s\n' "${PAC_PATH}"
		printf 'STATE_CLIENT_PROTO=%s\n' "${CLIENT_PROTO}"
		printf 'STATE_TLS_CERT=%s\n' "${TLS_CERT_FILE}"
		printf 'STATE_TLS_KEY=%s\n' "${TLS_KEY_FILE}"
	} > "${tmp}" || return 1
	chmod 0600 "${tmp}" 2>/dev/null || true
	mv -f "${tmp}" "${STATE_FILE}" || { rm -f "${tmp}"; return 1; }
	return 0
}
# 每个阶段配一段「能自助解决」的提示：人话原因 + 一条可复制命令 + 预期结果
stage_advice() {
	case "$1" in
	1) cat <<'ADV'

  最可能的原因：装不上系统依赖（curl / tar / xz），或者这台机器连不上软件源。
  ① 自己试一下（成功的话能看到版本号）：
       sudo apt-get update && sudo apt-get install -y curl tar xz
  ② 报错看不懂，就把 ① 的整段输出发出来。
ADV
		;;
	2) cat <<'ADV'

  最可能的原因：连不上 GitHub 下载（网络 / 防火墙），或者该架构没有预编译包。
  ① 先确认能不能访问 GitHub：
       curl -sI https://github.com | head -1        （应该看到 HTTP/2 200 之类）
  ② 网络没问题的话，改用源码编译（需要 Go，约 3-5 分钟）：
       重新运行同一条命令，并加上 --build-from-source
  ③ 都试过还是不行，把上面命令的完整输出发出来。
ADV
		;;
	3) cat <<'ADV'

  最可能的原因：创建 caddy 系统用户或目录失败，通常是磁盘满或权限异常。
  ① 看磁盘和目录权限：
       df -h /var /etc ; ls -ld /etc/caddy
  ② 把这条的输出发出来。
ADV
		;;
	4) cat <<'ADV'

  最可能的原因：配置语法没通过校验。
  ① 让它把出问题的行号指出来：
       sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  ② 还是不懂，就把 ① 的整段输出发出来。
ADV
		;;
	5) cat <<'ADV'

  最可能的原因：伪装站点目录写不进去（磁盘满或权限异常）。
  ① 看一眼：
       ls -ld /var/www/html ; df -h /var
  ② 把这条的输出发出来。
ADV
		;;
	6) cat <<'ADV'

  最可能的两个原因：端口被占用，或者证书签发失败。
  ① 看服务为什么起不来（会直接写明原因，最有用的一条）：
       sudo systemctl status caddy --no-pager
       sudo journalctl -u caddy -n 50 --no-pager
  ② 如果报端口被占，看是谁占的：
       sudo ss -ltnp | grep -E ':(80|443)'
  ③ 如果报证书相关（certificate / ACME），多半是域名没解析到本机，
     或者套了 Cloudflare 橙云 —— 需要先把橙云切成灰云。
ADV
		;;
	7) cat <<'ADV'

  这一步没能全部通过 —— 可能是服务压根没起来，也可能是几项验证没过。
  ① 先看服务本身有没有报错：
       sudo journalctl -u caddy -n 50 --no-pager
  ② 再看端口和防火墙：
       sudo ss -ltnp | grep -E ':(80|443)'
  ③ 把上面两条的输出发出来。
ADV
		;;
	esac
}

fail_stage() { # <序号> <阶段名> <退出码>
	local idx="$1" name="$2" code="$3"
	cleanup
	printf '\n%s\n' "${C_RED}${C_BLD}${G_ERR} 第 ${idx} 步 / 共 ${TOTAL_STAGES} 步 —— ${name} 失败${C_RST}" >&2
	printf '%s\n' "${C_DIM}  （退出码 ${code}）${C_RST}" >&2
	stage_advice "${idx}" >&2
	printf '\n%s\n' "  当前状态:  二进制 ${STATE_BIN} / 配置 ${STATE_CONF} / 服务 ${STATE_SVC}" >&2
	if [ "${idx}" -gt 1 ]; then
		printf '%s\n' "  前面 $((idx - 1)) 步是成功的，没有白做。" >&2
	fi
	printf '%s\n' "  修好后重新运行同一条命令即可 —— 重跑是安全的，不会重复破坏。" >&2
	printf '%s\n' "  需要求助？把这条命令的完整输出发出来：" >&2
	printf '%s\n' "    sudo $0 --collect-diagnostics" >&2
}

stage_banner() {
	printf '\n%s\n' "${C_DIM}────────────────────────────────────────────────${C_RST}"
	printf '%s\n' "${C_BLD}${G_STEP} $1/${TOTAL_STAGES}  $2${C_RST}${C_DIM}   ${STAGE_HINT[$(($1 - 1))]}${C_RST}"
}

run_stage() { # <序号> <函数...>
	local idx="$1"
	shift
	local name="${STAGE_NAMES[$((idx - 1))]}" rc=0
	stage_banner "${idx}" "${name}"
	# 必须是 if/else：没有 else 的 if 在条件为假时整个语句返回 0，
	# 放在 fi 之后的 $? 永远捕到 0，退出码就会一直是假信息。
	if "$@"; then
		return 0
	else
		rc=$?
	fi
	gather_state
	fail_stage "${idx}" "${name}" "${rc}"
	exit 1
}
# ---------------- 帮助与引导 ----------------
usage() {
	cat <<'USAGE'
NaiveProxy 服务端部署脚本 v2.4.0
把这台服务器变成一台 NaiveProxy 服务端（Caddy + 伪装站点）。

第一次用？按这个顺序走：

  ① 体检（只读，不改任何东西，不需要 sudo）
       ./deploy-naive-caddy.sh --check --domain proxy.example.com --email ops@mail.test

  ② 正式部署（约 1 分钟）
       sudo ./deploy-naive-caddy.sh --domain proxy.example.com --email ops@mail.test

  ③ 后悔药（把 ② 做的全部撤销）
       sudo ./deploy-naive-caddy.sh --uninstall --purge

需要准备：
  · 一个域名，A 记录已经指向这台服务器的 IP
  · 一个邮箱（只用来收证书到期通知）

部署是幂等的：随时重跑同一条命令都安全，每一步改动前都会备份。

基本参数：
  --domain <域名>        必填。已解析到本机的域名，如 proxy.example.com
  --email <邮箱>         必填。证书通知邮箱
  --user <用户名>        代理账号用户名（默认: naive）
  --password <密码>      代理密码（默认自动生成 28 位）。
                         写在命令行会进 shell 历史记录，更稳妥的写法是：
                           NAIVE_PASSWORD='你的密码' sudo -E ./deploy-naive-caddy.sh ...
  --https-port <端口>    HTTPS 监听端口（默认: 443）
  --check                体检：环境 + 前置条件逐条判定 + 配置预览（只读，无需 root）
  -y, --yes              所有确认自动回答「是」

进阶参数：
  --probe-secret <域名>    probe_resistance 的秘密域名。指定后，只有访问这个地址才会触发
                         407、让浏览器弹出凭据框并记住。不指定时 Caddy 用随机值 ——
                         那样你无从得知自己的秘密链接，上游文档给的补救办法就用不上
                         （文档原文：Only this address will trigger a 407 response）。
                         只能用【小写】字母数字、连字符和点，且不能以点开头。
  --serve-pac <路径>       生成 PAC 文件（如 /secret-proxy.pac），供 Android Wi-Fi 代理
                         这类需要 PAC 的客户端。注意：开了 probe_resistance 时路径必须
                         不可预测，否则会削弱抗探测（上游文档明确警告这一点）。
  --tls-cert <文件>       用现成的证书文件，而不是让 Caddy 走 ACME 申请。
                         适用于机器上已有 certbot / acme.sh 签好的证书时。
  --tls-key <文件>        与 --tls-cert 配对的私钥文件，两个必须同时给出。
                         为什么要这个选项：Let's Encrypt 对同一个域名每 7 天只发 5 张
                         证书。反复重装（尤其用 --purge 删掉证书数据后）会把额度用尽，
                         之后要等整整一周才能再签。已有证书就直接复用，零额度消耗。
  --client-proto <协议>    客户端 config.json 用 https|quic（默认 https）。
                         quic 在丢包 / 移动网络下常有更好表现。
  --allow-ports "<列表>"  限定客户端可经代理访问的目标端口，如 "80 443"。
                          留空则不限制。加此项可防止凭据外泄后代理被当任意端口跳板
  --web-root <目录>      伪装站点目录（默认 /var/www/naive-camouflage）。
                         刻意不用 /var/www/html —— 那是 nginx 的默认 docroot，
                         在那里操作会连带影响别人的站点
  --force-config         配置已存在时也重新生成（自动备份原件）
  --build-from-source    用 xcaddy 从源码编译（非 x86_64 架构会自动启用）
  --skip-verify          跳过部署后的连通性验证
  --ascii                用纯 ASCII 标记输出（老终端 / GBK 编码下更稳）
  --dry-run              --check 的旧名字，保留兼容

运维：
  --upgrade              只升级 caddy 二进制，配置不动
  --reload               校验并重载配置
  --rotate-password      换一个代理密码，改配置 + 平滑重载
  --collect-diagnostics  收集排查信息（密码自动打码），求助时把输出发出来
  --uninstall            卸载服务（加 --purge 连站点/日志/数据/用户一起删）
  --self-test            开发者自检，不需要 root
  -V, --version          显示版本
  -h, --help             显示本帮助
USAGE
}

# 无参数时的引导页。这是用户第一次接触脚本的地方，
# 所以顺序是：先说清「会做什么、不会做什么」，再给可复制的命令，最后给后悔药。
print_guide() {
	printf '\n%s\n' "${C_BLD}NaiveProxy 部署脚本 v${SCRIPT_VERSION}${C_RST}"
	cat <<'GUIDE'

这个脚本会把当前服务器变成一台 NaiveProxy 服务端（Caddy + 伪装站点）。
它不会动你系统里已有的其他东西；每一步改动前都会备份；
不满意可以用最后那条命令完整还原。

需要你先准备好两样东西：
  · 一个域名，A 记录已经指向这台服务器的 IP
  · 一个邮箱（只用来收证书到期通知，随便一个能收信的就行）

GUIDE
	printf '%s\n\n' "  ${C_BLD}① 先体检${C_RST}${C_DIM}   只读，不改任何东西，不需要 sudo${C_RST}"
	printf '%s\n' "     ./deploy-naive-caddy.sh --check --domain proxy.example.com --email ops@mail.test"
	printf '%s\n' "     ${C_DIM}把域名和邮箱换成你自己的。30 秒给你一份体检报告。${C_RST}"
	printf '\n%s\n\n' "  ${C_BLD}② 体检通过后，正式部署${C_RST}${C_DIM}   约 1 分钟${C_RST}"
	printf '%s\n' "     sudo ./deploy-naive-caddy.sh --domain proxy.example.com --email ops@mail.test"
	printf '%s\n' "     ${C_DIM}结束时会给你客户端配置和连接串。${C_RST}"
	printf '\n%s\n\n' "  ${C_BLD}③ 后悔药：把这次部署的东西全部撤掉${C_RST}"
	printf '%s\n' "     sudo ./deploy-naive-caddy.sh --uninstall --purge"
	printf '\n%s\n' "  ${C_DIM}随时重跑同一条命令都是安全的 —— 它不会重复破坏。${C_RST}"
	printf '\n%s\n\n' "  完整参数：./deploy-naive-caddy.sh --help"
}

# ---------------- 输入校验 ----------------
# 任何用户输入都要先过这一关。
# 为什么必须单独查：grep 是逐行匹配的，'^…$' 挡不住嵌了换行的值 ——
#   printf 'a.com\nevil' | grep -qE '^…$'   会在第一行就匹配成功。
# 而带换行的值会被原样写进 Caddyfile 的 heredoc，等于注入配置指令。
validate_no_ctrl() {
	local v="${1:-}"
	if [ "$(printf '%s' "$v" | tr -d '\001-\037\177')" = "$v" ]; then
		return 0
	fi
	return 1
}

validate_domain() {
	local d="${1:-}"
	[ -n "$d" ] || return 1
	validate_no_ctrl "$d" || return 1
	case "$d" in *://*|*/*|*" "*|*"?"*|*"#"*) return 1 ;; esac
	case "$d" in .*|*.) return 1 ;; esac
	printf '%s' "$d" | grep -qE '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
}

validate_user() {
	local u="${1:-}"
	validate_no_ctrl "$u" || return 1
	printf '%s' "$u" | grep -qE '^[A-Za-z0-9_]{1,32}$'
}

# 邮箱刻意用保守字符集：只允许字母数字与 . _ % + -
# 早先用的是 [^@[:space:]]+，它会放过引号、分号、竖线、斜杠 ——
# 那些字符一旦写进状态文件，被读回来时就是命令执行（或让文件无法解析）。
# probe_resistance 的秘密域名。上游文档明确要求：
#   "Make sure that specified domain name is visitable, does not contain
#    uppercase characters, does not start with dot, etc."
# 所以不能直接复用 validate_domain —— 那个允许大写。
# 用现成的证书文件而不是走 ACME 申请。
# 为什么需要：Let's Encrypt 对同一域名每周只给 5 张证书。
# 反复重装（尤其是用 --purge 把证书数据删了之后）会把额度耗尽，
# 那之后要等整整一周才能再签 —— 真机实测踩过这个坑：
#   HTTP 429 rateLimited - too many certificates (5) already issued
#   for this exact set of identifiers in the last 168h
# 若机器上已有 certbot/acme.sh 签好的证书，用这个选项复用即可，零额度消耗。
TLS_CERT_FILE=""
TLS_KEY_FILE=""

# --tls-cert / --tls-key 的成对与配对检查。--check（只读体检）与正式部署
# 走的是同一条路径 —— 早先 --check 只查「两个都在、文件存在」，
# 于是证书写反（把 fullchain 当私钥传）时体检照打绿勾，正式部署却报错退出。
# 出问题的具体原因由本函数打印，调用方负责给出那句总结性的 die 文案。
check_tls_cert_inputs() {
	if [ -z "${TLS_CERT_FILE}" ] && [ -z "${TLS_KEY_FILE}" ]; then
		return 0
	fi
	if [ -z "${TLS_CERT_FILE}" ] || [ -z "${TLS_KEY_FILE}" ]; then
		err "只给了一个：--tls-cert=[${TLS_CERT_FILE}] --tls-key=[${TLS_KEY_FILE}]"
		return 1
	fi
	if [ ! -f "${TLS_CERT_FILE}" ] || [ ! -f "${TLS_KEY_FILE}" ]; then
		err "文件不存在：${TLS_CERT_FILE} / ${TLS_KEY_FILE}"
		return 1
	fi
	if ! validate_tls_cert_pair "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"; then
		err "公钥对不上：${TLS_CERT_FILE} / ${TLS_KEY_FILE}"
		err "  多半是把 fullchain.pem 和 privkey.pem 传反了。"
		err "  自检办法：两者的公钥指纹必须相同 ——"
		err "    openssl x509 -noout -pubkey -in ${TLS_CERT_FILE} | openssl dgst -md5"
		err "    openssl pkey -pubout -in ${TLS_KEY_FILE} | openssl dgst -md5"
		return 1
	fi
	return 0
}

validate_tls_cert_pair() { # <cert> <key>
	local c="${1:-}" k="${2:-}"
	[ -f "$c" ] || return 1
	[ -f "$k" ] || return 1
	# 证书与私钥必须配对，否则 caddy 起不来。
	# 比对「公钥」而不是 RSA modulus：certbot 默认签 ECDSA 证书，
	# 那时 openssl rsa 拿不到 modulus，会误判成不匹配（真机踩过）。
	# 公钥比对对 RSA 与 ECDSA 都成立。
	local cm="" km=""
	cm=$(openssl x509 -noout -pubkey -in "$c" 2>/dev/null | openssl md5 2>/dev/null || true)
	km=$(openssl pkey -pubout -in "$k" 2>/dev/null | openssl md5 2>/dev/null || true)
	# 取不到就放行：宁可让 caddy 自己报错，也别因为工具差异挡住正确配置
	if [ -n "$cm" ] && [ -n "$km" ] && [ "$cm" != "$km" ]; then
		return 1
	fi
	return 0
}

validate_probe_secret() {
	local s="${1:-}"
	[ -n "$s" ] || return 1
	validate_no_ctrl "$s" || return 1
	# 不许大写
	printf '%s' "$s" | grep -q "[A-Z]" && return 1
	# 不许前导点
	case "$s" in .*) return 1 ;; esac
	# 其余沿用域名规则
	printf '%s' "$s" | grep -qE '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
}

# 客户端协议。上游 USAGE.txt 定义 PROXY-PROTO = "http" | "https" | "quic"；
# 本脚本只放行后两个 —— http 是明文代理，不该做为新手默认。
validate_client_proto() {
	case "${1:-}" in
		https|quic) return 0 ;;
	esac
	return 1
}

# 会被直接插进 Caddyfile 的「路径类」入参：--serve-pac / --tls-cert / --tls-key / --web-root。
# 为什么必须单独查：这些值是按行插进 heredoc 的，一个换行就等于多写一条配置指令。
# 本轮审计实测（真的渲染出来了）：
#   --serve-pac $'/p.pac\n\t\tdisable_insecure_upstreams_check'  → 该指令进了 forward_proxy 块
#   --web-root  $'/x\n\t}\n\trespond "pwned" 200\n\tfile_server {\n\t\troot /tmp'
#                                                  → 站点级别被插进 respond 与第二个 file_server
# 另外 --web-root 含反斜杠还有第二个后果：remove_local_hosts_hack 的 sed 替换会被
# 反斜杠转义打乱，域名行清不掉，永久留在用户的 /etc/hosts 里。
# 单引号刻意不禁止 —— caddy 自己能正确解析它；这里只挡会破坏「行结构」或 shell 转义的字符。
validate_path_value() {
	local p="${1:-}"
	[ -n "$p" ] || return 1
	validate_no_ctrl "$p" || return 1
	printf '%s' "$p" | grep -qE '^[A-Za-z0-9._/+:-]+$'
}

validate_email() {
	local e="${1:-}"
	validate_no_ctrl "$e" || return 1
	printf '%s' "$e" | grep -qE '^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
}

validate_password() {
	local p="${1:-}"
	[ "${#p}" -ge 8 ] || return 1
	validate_no_ctrl "$p" || return 1
	printf '%s' "$p" | grep -qE '^[A-Za-z0-9]+$'
}

validate_ports_list() { # 空格分隔的端口白名单，允许为空
	local p="${1:-}"
	if [ -z "$p" ]; then
		return 0
	fi
	validate_no_ctrl "$p" || return 1
	printf '%s' "$p" | grep -qE '^[0-9]+( [0-9]+)*$' || return 1
	local one
	for one in $p; do
		validate_port "$one" || return 1
	done
}

validate_port() {
	local p="${1:-}"
	validate_no_ctrl "$p" || return 1
	printf '%s' "$p" | grep -qE '^[0-9]{1,5}$' || return 1
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

gen_password() {
	local n="${1:-28}" out=""
	if command -v openssl >/dev/null 2>&1; then
		out=$(openssl rand -base64 64 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$n" || true)
	fi
	if [ "${#out}" -lt "$n" ]; then
		out=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$n" || true)
	fi
	printf '%s' "$out"
}
# 预览时密码位置的占位符（--check / --dry-run 用，绝不显示真实密码）
PASS_PREVIEW="<部署时自动生成>"

# ---------------- 配置渲染 ----------------
render_log_block() {
	cat <<'EOF'
	log {
		output file /var/log/caddy/access.log {
			roll_size 20MiB
			roll_keep 5
			roll_keep_for 168h
		}
		# 不记录用户代理访问目标，避免日志侧信道泄露
		exclude http.log.error
	}
EOF
}

# 替换 render_caddyfile：支持 probe_resistance 秘密域名与 serve_pac

render_caddyfile() { # <域名> <邮箱> <用户名> <密码> <端口> [白名单] [秘密域名] [PAC] [证书] [私钥]
	local domain="$1" email="$2" user="$3" pass="$4" port="$5" allow_ports="${6:-}"
	local probe_secret="${7:-}" pac_path="${8:-}"
	local cert_file="${9:-}" key_file="${10:-}"
	local ports_line="" pac_line=""

	if [ -n "$allow_ports" ]; then
		ports_line=$(printf '\t\tports %s' "$allow_ports")
	fi
	if [ -n "$pac_path" ]; then
		pac_line=$(printf '\t\tserve_pac %s' "$pac_path")
	fi

	# probe_resistance 带不带秘密域名，差别很大：
	#   裸写       -> Caddy 用随机值，用户不知道该访问什么，文档给的补救路径等于没有；
	#   带秘密域名 -> 只有访问这个地址才触发 407，浏览器据此弹凭据框并记住。
	# 上游文档原文：「If your proxy client does not preemptively send credentials, you will
	#   have to visit your secret link in your browser to trigger the authentication. Only
	#   this address will trigger a 407 response.」所以它是可补救性的一部分，不是可选项。
	# 有现成证书就用文件（零 ACME 额度消耗），否则交给 Caddy 自动申请。
	# 用文件时要写成 tls 后跟两个路径（证书 + 私钥），少一个 caddy 会报错。
	# 这段 shell 逻辑必须在 heredoc 之外算好 —— Caddyfile 里不能出现 if/else。
	# 两个路径都为空时退回 `tls <邮箱>`；邮箱也空就退回 `tls internal` ——
	# 和 WEB_ROOT 的自我兜底同理：渲染器被单独调用时也要能产出合法配置，
	# `tls ` 那样只有关键字没有参数是非法的，caddy validate 会直接拒。
	local tls_line=""
	if [ -n "${cert_file}" ] && [ -n "${key_file}" ]; then
		tls_line=$(printf '\ttls %s %s' "${cert_file}" "${key_file}")
	elif [ -n "${email}" ]; then
		tls_line=$(printf '\ttls %s' "${email}")
	else
		tls_line=$(printf '\ttls internal')
	fi
	local probe_line=""
	probe_line=$(printf '\t\tprobe_resistance')
	if [ -n "$probe_secret" ]; then
		probe_line=$(printf '\t\tprobe_resistance %s' "$probe_secret")
	fi

	# 站点地址。两件事必须同时成立：
	#  ① 带 :port 前缀 → 该站点不按 Host 匹配，任何 Host 都进来。
	#     forward_proxy 需要这个（客户端会用任意 Host 发请求）。
	#     实测：只写 example.com 会生成 {"match":[{"host":["example.com"]}]}，
	#     只有 :443 形式才会生成无 matcher 的路由。
	#  ② 端口不是 443 时，域名后面也必须带端口。
	#     实测（官方 caddy adapt）：`:8443, d.com` 会同时监听 :443 和 :8443 ——
	#     那既占用了 443（可能正是用户想避开的），也让 --https-port 失去意义。
	#     写成 `:8443, d.com:8443` 才只监听 :8443。
	local site_addr=":${port}, ${domain}"
	if [ "$port" != "443" ]; then
		site_addr=":${port}, ${domain}:${port}"
	fi

	# 自我防御：WEB_ROOT 空着就会渲染出 `root `（非法配置）。
	# 它由 main 解析，但渲染器不该依赖调用顺序 —— 直接调用时也要能出合法结果。
	if [ -z "$WEB_ROOT" ]; then
		WEB_ROOT="$WEB_ROOT_DEFAULT"
	fi

	cat <<EOF
{
	order forward_proxy before file_server

$(render_log_block)
}

${site_addr} {
${tls_line}

	encode

	forward_proxy {
		basic_auth ${user} ${pass}
${ports_line}
${pac_line}
		hide_ip
		hide_via
${probe_line}
	}

	# 未认证访问者看到的就是这个正常站点（配合 probe_resistance 抗主动探测）
	file_server {
		root ${WEB_ROOT}
	}
}
EOF
}

render_client_config() { # <用户名> <密码> <域名> <端口>
	local user="$1" pass="$2" domain="$3" port="$4" proto="${5:-https}" host="$3"
	# 协议由 --client-proto 决定。上游 USAGE.txt：
	#   PROXY-PROTO = "http" | "https" | "quic"
	# 并注明 QUIC「cannot follow TCP-based proxies in a proxy chain」；
	# 本脚本只生成单跳，所以不受那条限制。
	local scheme="${proto:-https}"
	case "$scheme" in https|quic) : ;; *) scheme=https ;; esac
	if [ "$port" != "443" ]; then host="${domain}:${port}"; fi
	cat <<EOF
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "${scheme}://${user}:${pass}@${host}"
}
EOF
}

render_systemd_unit() {
	cat <<EOF
[Unit]
Description=Caddy (naive forwardproxy)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${CADDY_BIN} run --environ --config ${CONF_FILE}
ExecReload=${CADDY_BIN} reload --config ${CONF_FILE}
Restart=on-failure
RestartSec=2s
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}

# openrc 脚本里必须有 reload()：do_reload 与 do_rotate_password 都会调
# 「rc-service caddy reload」。不定义它的话 --reload 在 Alpine 上必然失败。
# 说明写在 heredoc 外 —— heredoc 的定界符没加引号，里面的反引号会被当成命令替换。
render_openrc_script() {
	cat <<EOF
#!/sbin/openrc-run
name="caddy"
description="Caddy (naive forwardproxy)"
command="${CADDY_BIN}"
command_args="run --environ --config ${CONF_FILE}"
command_user="caddy:caddy"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_DIR}/openrc.log"
error_log="${LOG_DIR}/openrc.log"
depend() { need net; after firewall; }

reload() {
	ebegin "Reloading caddy"
	"${CADDY_BIN}" reload --config "${CONF_FILE}"
	eend \$?
}
EOF
}
# ---------------- 环境探测 ----------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# 需要 root 时给可复制的话，而不是只说「你没权限」。
# 刻意不回显用户原命令 —— 那可能包含密码。
require_root() {
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	printf '\n%s\n' "  ${C_RED}${G_ERR}${C_RST} 这一步需要管理员权限"
	cat <<EOF

  把你刚才那条命令最前面加上 sudo，重跑一次就行。

  如果只是想先看看它会对这台机器做什么 —— 那不需要 sudo：
      $0 --check --domain <你的域名> --email <你的邮箱>

  体检是只读的，不改任何东西。
EOF
	exit 1
}

detect_os() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		OS_ID="${ID:-unknown}"
		OS_LIKE="${ID_LIKE:-}"
		OS_NAME="${PRETTY_NAME:-$OS_ID}"
	else
		OS_ID="unknown"; OS_LIKE=""; OS_NAME="unknown"
	fi
	case "${OS_ID}:${OS_LIKE}" in
		debian*|ubuntu*|*debian*|*ubuntu*) PKG="apt" ;;
		centos*|rhel*|rocky*|almalinux*|fedora*|*rhel*|*fedora*) PKG="dnf" ;;
		alpine*) PKG="apk" ;;
		*) PKG="" ;;
	esac
	INIT=""
	if need_cmd systemctl; then INIT="systemd"
	elif need_cmd rc-update; then INIT="openrc"
	fi
}

detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64) ARCH="x86_64" ;;
		aarch64|arm64) ARCH="arm64" ;;
		armv7l|armv6l) ARCH="arm" ;;
		*) ARCH="$(uname -m)" ;;
	esac
}

# 外部命令的噪声写进日志，终端只留叙事。失败时再从日志里捞关键几行。
setup_deploy_log() {
	if mkdir -p "${LOG_DIR}" 2>/dev/null && : >>"${DEPLOY_LOG}" 2>/dev/null; then
		DEPLOY_LOG_OK="yes"
		return 0
	fi
	DEPLOY_LOG="/dev/null"
	DEPLOY_LOG_OK="no"
	return 0
}

# 日志写不进去时必须说出来。静默返回 0 的话，用户会看到
# 「安装依赖失败」后面什么都没有 —— 而本脚本的承诺正是"把输出发出来"。
show_log_tail() { # <行数>
	if [ "${DEPLOY_LOG_OK}" != "yes" ]; then
		note "详细输出不可用（写不进 ${LOG_DIR}）——请手动跑上一条命令看它自己的输出"
		return 0
	fi
	note "${DEPLOY_LOG} 最后 $1 行："
	tail -n "$1" "${DEPLOY_LOG}" 2>/dev/null | sed 's/^/      /' || true
}

get_public_ip() {
	local ip="" u
	for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
		ip=$(curl -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
		if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
	done
	return 1
}

resolve_domain_ip() {
	local d="$1"
	if need_cmd getent; then
		getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1
		return 0
	fi
	if need_cmd dig; then
		dig +short A "$d" 2>/dev/null | head -1
		return 0
	fi
	return 1
}

# 一次网络请求，tag 与校验和都从同一份 release JSON 取。
CADDY_RELEASE_JSON=""

fetch_caddy_release() {
	if [ -n "${CADDY_RELEASE_JSON}" ]; then
		return 0
	fi
	CADDY_RELEASE_JSON=$(curl -fsSL --max-time 15 \
		"https://api.github.com/repos/${GH_REPO}/releases/latest" 2>/dev/null || true)
	[ -n "${CADDY_RELEASE_JSON}" ]
}

resolve_caddy_tag() {
	local tag=""
	if fetch_caddy_release; then
		tag=$(printf '%s' "${CADDY_RELEASE_JSON}" \
			| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
	fi
	if [ -n "$tag" ]; then printf '%s' "$tag"; else printf '%s' "${CADDY_FALLBACK_TAG}"; fi
}

# 取官方发布的 sha256。取不到就返回空，调用方降级为告警而不是硬失败，
# 免得上游哪天不发 digest 就把部署卡死。
# 这个 release 只有一个资产，所以「唯一那个 digest」没有歧义；
# 上游若改成多资产，这里需要按资产名定位。
resolve_caddy_digest() {
	fetch_caddy_release || return 1
	local d=""
	d=$(printf '%s' "${CADDY_RELEASE_JSON}" \
		| sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"sha256:\([0-9a-fA-F]\{64\}\)".*/\1/p' | head -1)
	[ -n "$d" ] || return 1
	printf '%s' "$d"
}

# ---------------- 端口探测 ----------------
# 端口探测是三态：in-use / free / unknown。
# 早先只返回 0/1，ss 缺失时返回 1 会被当成"空闲" ——
# 于是预检会对一个可能被 Nginx 占着的端口打绿勾，用户拿着"预检全绿"去排查。
port_state() { # <端口> → in-use | free | unknown
	local p="$1"
	if ! need_cmd ss; then
		printf 'unknown'
		return 0
	fi
	if ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"; then
		printf 'in-use'
	else
		printf 'free'
	fi
}

port_in_use() { # 被占用返回 0；空闲或无法判定时返回 1
	[ "$(port_state "$1")" = "in-use" ]
}

port_owner_is_caddy() { # <端口>
	need_cmd ss || return 1
	ss -ltnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" | grep -q caddy
}

show_port_owner() { # <端口>
	need_cmd ss || return 0
	ss -ltnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" >&2 || true
}

# ---------------- 确认 ----------------
# 用户按回车取消不是错误 —— 不要给红色 ✗ 和 exit 1，那会让人以为搞坏了。
confirm() {
	local prompt="$1" ans=""
	if [ ! -t 0 ]; then
		warn "读不到键盘输入，已按「继续」处理"
		return 0
	fi
	read -r -p "  ${prompt} [y/N] " ans
	case "$ans" in
		y|Y|yes|YES) return 0 ;;
		*)
			printf '\n%s\n' "  ${C_DIM}已取消，未做任何改动。${C_RST}"
			exit 0
			;;
	esac
}

# ---------------- 预检项 ----------------
check_domain_dns() {
	local ip="" dns=""
	ip=$(get_public_ip || true)
	dns=$(resolve_domain_ip "${DOMAIN}" || true)
	if [ -n "$ip" ] && [ -n "$dns" ]; then
		if [ "$ip" = "$dns" ]; then
			ok "域名 ${DOMAIN} 已解析到本机（${ip}）"
		else
			warn "域名解析到 ${dns}，而本机公网 IP 是 ${ip}"
			warn "如果之后证书签发失败，通常就是这里。走 CDN 的话请先把 Cloudflare 橙云切成灰云。"
			[ "$ASSUME_YES" = "yes" ] || confirm "仍然继续？"
		fi
	else
		warn "无法自动核对解析（本机 IP=${ip:-未知}，DNS=${dns:-未知}）"
		warn "请确认域名的 A 记录已经指向这台服务器 —— 证书签发依赖它"
	fi
}

# 秘密域名必须也指向本机，否则 TLS 握手就失败 —— 用户手里会拿到一个
# 「访问就报错」的地址，比用随机值还糟。
# 真机实测过：证书只覆盖主域名时，访问秘密域名得到的是
#   tlsv1 alert internal error —— 连 407 都到不了。
check_probe_secret_dns() {
	[ -n "${PROBE_SECRET}" ] || return 0
	local dns=""
	dns=$(resolve_domain_ip "${PROBE_SECRET}" || true)
	if [ -z "$dns" ]; then
		warn "${PROBE_SECRET} 查不到 A 记录 —— 秘密链接会连不上"
		warn "  证书只覆盖已解析的域名。请把 ${PROBE_SECRET} 也指向本机，"
		warn "  否则 TLS 握手会失败（连 407 都触发不了）"
		[ "$ASSUME_YES" = "yes" ] || confirm "仍然继续？"
	else
		ok "秘密域名 ${PROBE_SECRET} 已解析（${dns}）"
	fi
}

check_ports_free() {
	# 80 与 443 都会被占用：443 是站点端口，80 是证书校验与跳转。
	# 即使 --https-port 指定了别的端口，443 也仍然需要检查 ——
	# 早先只查 HTTPS_PORT，用户改端口后就漏查了 443，体检打绿勾而阶段 6 必炸。
	local ports=("80" "443") p=""
	if [ "${HTTPS_PORT}" != "80" ] && [ "${HTTPS_PORT}" != "443" ]; then
		ports+=("${HTTPS_PORT}")
	fi
	for p in "${ports[@]}"; do
		case "$(port_state "$p")" in
			in-use)
				if port_owner_is_caddy "$p"; then
					note "端口 ${p} 已被 caddy 自己占用（重跑的情况，正常）"
				else
					warn "端口 ${p} 已被别的程序占用："
					show_port_owner "$p"
					warn "Caddy 需要 443（对外服务）和 80（证书校验与跳转）。占用者通常是 Nginx / Apache。"
					[ "$ASSUME_YES" = "yes" ] || confirm "仍然继续？"
				fi
				;;
			free)
				ok "端口 ${p} 空闲"
				;;
			*)
				note "端口 ${p}：本机没有 ss 命令，无法判定，请自行确认"
				note "  装上就能自动查：apt install iproute2（或 dnf install iproute / apk add iproute2）"
				;;
		esac
	done
}

preflight() {
	section "预检"
	detect_os; detect_arch
	info "系统 ${OS_NAME}   架构 ${ARCH}   初始化 ${INIT:-未知}   包管理 ${PKG:-未知}"
	if [ -z "$INIT" ]; then
		err "没找到 systemd 或 openrc，本脚本暂不支持这个系统"
		return 1
	fi
	check_domain_dns
	check_probe_secret_dns
	check_ports_free
	if [ ! -d /proc/sys/net ]; then
		warn "这看起来不是 Linux；本脚本请只在目标 VPS 上运行"
	fi
	ok "预检完成"
}
# ---------------- 阶段 1: 系统依赖 ----------------
install_deps() {
	setup_deploy_log
	local have_all=yes c=""
	local need_commands=()
	local pkg_list=()

	# 先看缺什么，只装真正缺的。
	# 早先无条件装一个写死的包名列表，结果在 Debian 13 上翻车：
	#   ① 包名写错 —— xz 不是包名（xz-utils 才是），而 xz 二进制本来就装好了
	#   ② 什么都不缺，却因为包管理器这一个报错就让整个部署失败
	for c in curl tar xz; do
		if ! need_cmd "${c}"; then need_commands+=("${c}"); have_all=no; fi
	done

	if [ "${have_all}" = "yes" ]; then
		note "curl / tar / xz 都已就绪，跳过安装"
		return 0
	fi
	note "缺少: ${need_commands[*]} —— 正在安装（详细输出写进 ${DEPLOY_LOG}）"

	# 同一个命令在各发行版里对应的包名不同（xz 在 Debian 系叫 xz-utils）
	case "${PKG}" in
	apt)
		pkg_list=(ca-certificates xz-utils)
		for c in "${need_commands[@]}"; do
			case "${c}" in
				xz) : ;;  # 已被 xz-utils 覆盖
				*) pkg_list+=("${c}") ;;
			esac
		done
		if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
		       DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg_list[@]}"; } >>"${DEPLOY_LOG}" 2>&1; then
			err "安装依赖失败（apt-get）。缺的是: ${need_commands[*]}"
			show_log_tail 15
			return 1
		fi
		;;
	dnf)
		pkg_list=(ca-certificates xz)
		for c in "${need_commands[@]}"; do
			[ "${c}" = xz ] || pkg_list+=("${c}")
		done
		dnf install -y -q "${pkg_list[@]}" >>"${DEPLOY_LOG}" 2>&1 || {
			err "安装依赖失败（dnf）。缺的是: ${need_commands[*]}"
			show_log_tail 15
			return 1
		}
		;;
	apk)
		pkg_list=(ca-certificates xz)
		for c in "${need_commands[@]}"; do
			[ "${c}" = xz ] || pkg_list+=("${c}")
		done
		apk add --no-cache "${pkg_list[@]}" >>"${DEPLOY_LOG}" 2>&1 || {
			err "安装依赖失败（apk）。缺的是: ${need_commands[*]}"
			show_log_tail 15
			return 1
		}
		;;
	*)
		warn "没识别出包管理器，跳过自动安装"
		;;
	esac

	# 装完再验一遍 —— 以命令是否可用为准，不看包管理器说了什么
	for c in curl tar; do
		if ! need_cmd "${c}"; then
			err "装完之后仍然没有 ${c}，请手动安装后重试"
			return 1
		fi
	done
	ok "依赖就绪"
}

# 覆盖系统文件前先备份 —— 这台机器上可能本来就有发行版装的同名文件
# （比如 apt install caddy 留下的 unit），直接覆盖会让它无法恢复。
# 保证日志目录真的属于 caddy 用户。
# 为什么需要专门做这件事：阶段 4 里我们用 root 跑 `caddy validate` 来校验配置，
# 而 caddy 在校验时会初始化 logger —— 于是 access.log 被以 root:root 0600 创建出来。
# 阶段 6 服务以 caddy 用户运行，打不开自己的日志文件，直接 exit 1 并反复重启。
# 阶段的 chown 在阶段 3，早于这次创建，救不了。
# 验证阶段需要「域名在本机解析到 127.0.0.1」。只在确实需要时加一行，
# 并在脚本退出时精确删掉那一行 —— 不动用户 hosts 里原有的任何内容。
HOSTS_HACK_ACTIVE="no"

node_local_hosts_hack() {
	[ "${HOSTS_HACK_ACTIVE}" = "yes" ] && return 0
	if grep -qE "^[[:space:]]*127[.]0[.]0[.]1[[:space:]]+${DOMAIN}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
		HOSTS_HACK_ACTIVE="yes"
		return 0
	fi
	if printf '127.0.0.1 %s\n' "${DOMAIN}" >> /etc/hosts 2>/dev/null; then
		HOSTS_HACK_ACTIVE="yes"
		note "临时在 /etc/hosts 把 ${DOMAIN} 指向本机（只为本次验证，退出时清理）"
	fi
	return 0
}

remove_local_hosts_hack() {
	[ "${HOSTS_HACK_ACTIVE}" = "yes" ] || return 0
	local esc=""
	esc=$(printf '%s' "${DOMAIN}" | sed 's/[.[\*^$]/\\&/g')
	sed -i "\#^[[:space:]]*127[.]0[.]0[.]1[[:space:]]\{1,\}${esc}[[:space:]]*\$#d" /etc/hosts 2>/dev/null || true
	HOSTS_HACK_ACTIVE="no"
	return 0
}

# 证书文件必须对 caddy 用户可读，否则服务起不来。
# 最常见的来源：certbot 把 /etc/letsencrypt/archive 放在 root:root 0700，
# 而 caddy 以非特权用户运行 —— 真机实测会直接 permission denied 然后崩溃重启。
ensure_cert_readable() {
	[ -n "${TLS_CERT_FILE}" ] || return 0
	id caddy >/dev/null 2>&1 || return 0

	# 先看 caddy 用户能不能真的读到（这才是判据，不看权限位猜）
	if runuser -u caddy -- test -r "${TLS_CERT_FILE}" 2>/dev/null \
	   && runuser -u caddy -- test -r "${TLS_KEY_FILE}" 2>/dev/null; then
		return 0
	fi

	note "caddy 用户读不到证书，正在修权限…"

	# certbot 的典型布局：live/ 下是符号链接，真身在 archive/，
	# 而 archive/ 通常是 root:root 0700 —— 只放开 live/ 没用。
	local d=""
	for d in /etc/letsencrypt/live /etc/letsencrypt/archive; do
		if [ -d "$d" ]; then
			chmod o+rx "$d" 2>/dev/null || true
		fi
	done
	if [ -d /etc/letsencrypt ]; then chmod o+rx /etc/letsencrypt 2>/dev/null || true; fi

	# 逐个文件放开读权限（含符号链接指向的真身）
	local f="" real=""
	for f in "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"; do
		real=$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")
		chmod o+r "$f" 2>/dev/null || true
		if [ "$real" != "$f" ]; then chmod o+r "$real" 2>/dev/null || true; fi
		# 沿途目录也要可进入
		local p="$real"
		while [ "$p" != "/" ] && [ -n "$p" ]; do
			p=$(dirname "$p")
			if [ -d "$p" ]; then chmod o+rx "$p" 2>/dev/null || true; fi
		done
	done

	if runuser -u caddy -- test -r "${TLS_CERT_FILE}" 2>/dev/null \
	   && runuser -u caddy -- test -r "${TLS_KEY_FILE}" 2>/dev/null; then
		ok "证书权限已修好（caddy 用户现在能读）"
	else
		warn "自动修权限没成功。请手工执行（或改用 --tls-cert 指向一份 caddy 可读的副本）："
		warn "  sudo chmod o+rx /etc/letsencrypt/live /etc/letsencrypt/archive"
		warn "  sudo chmod o+r ${TLS_CERT_FILE} ${TLS_KEY_FILE}"
	fi
	return 0
}

ensure_log_dir_owner() {
	if [ -d "${LOG_DIR}" ]; then
		chown -R caddy:caddy "${LOG_DIR}" 2>/dev/null || true
		# setgid：之后新建的日志文件自动继承 caddy 组，免得再被 root 建成孤儿
		chmod 2755 "${LOG_DIR}" 2>/dev/null || true
	fi
	return 0
}

backup_if_exists() {
	local f="$1" bak=""
	if [ ! -f "$f" ]; then
		return 0
	fi
	bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
	if cp -p "$f" "$bak" 2>/dev/null; then
		warn "原有的 ${f} 已备份到 ${bak}"
	else
		warn "备份 ${f} 失败（继续，但原文件会被覆盖）"
	fi
	return 0
}

# ---------------- 阶段 2: caddy 二进制 ----------------
install_caddy_binary() {
	setup_deploy_log
	# 自保：ARCH 是"环境探测结果"，靠调用顺序保证初始化太脆弱。
	if [ -z "${ARCH}" ]; then detect_arch; fi
	if [ "$BUILD_FROM_SRC" = "yes" ] || { [ "${ARCH}" != "x86_64" ] && [ "${ARCH}" != "amd64" ]; }; then
		build_from_source || return 1
	else
		local tag="" url="" src=""
		tag=$(resolve_caddy_tag)
		url="https://github.com/${GH_REPO}/releases/download/${tag}/caddy-forwardproxy-naive.tar.xz"
		note "下载 ${tag}"
		TMP_DIR=$(mktemp -d)
		if ! curl -fL --retry 3 --connect-timeout 15 -o "${TMP_DIR}/caddy.tar.xz" "$url" >>"${DEPLOY_LOG}" 2>&1; then
			err "下载失败：${url}"
			show_log_tail 10
			return 1
		fi
		# 这个二进制会以 root 安装并长期运行，下载完整性必须校验。
		local want="" got=""
		want=$(resolve_caddy_digest || true)
		if [ -n "$want" ]; then
			got=$(sha256sum "${TMP_DIR}/caddy.tar.xz" 2>/dev/null | awk '{print $1}')
			if [ "$got" != "$want" ]; then
				err "下载校验失败 —— 文件与 GitHub 发布记录不符"
				err "  期望 sha256 ${want}"
				err "  实际 sha256 ${got:-（算不出）}"
				err "  可能被篡改或下载损坏。已中止，未安装任何东西。"
				return 1
			fi
			ok "下载校验通过（sha256 与官方发布一致）"
		else
			warn "该发布没有提供校验和，无法验证下载完整性"
		fi

		if ! tar -xJf "${TMP_DIR}/caddy.tar.xz" -C "${TMP_DIR}" >>"${DEPLOY_LOG}" 2>&1; then
			err "解压失败（下载的文件可能不完整）"
			return 1
		fi
		src=$(find "${TMP_DIR}" -type f -name caddy -print -quit)
		if [ -z "$src" ]; then
			err "压缩包里没找到 caddy 二进制"
			return 1
		fi
		install -m 0755 "$src" "${CADDY_BIN}.new" || { err "无法写入 ${CADDY_BIN}"; return 1; }
		mv -f "${CADDY_BIN}.new" "${CADDY_BIN}" || { err "无法替换 ${CADDY_BIN}"; return 1; }
	fi
	ok "已安装: $("${CADDY_BIN}" version 2>&1 | head -1)"
	if need_cmd setcap; then
		setcap cap_net_bind_service=+ep "${CADDY_BIN}" 2>/dev/null || true
	fi
}

build_from_source() {
	note "从源码编译（架构 ${ARCH}）—— 需要 Go，约 3-5 分钟"
	if ! need_cmd go; then
		note "没检测到 Go，尝试安装"
		case "${PKG}" in
			apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go >>"${DEPLOY_LOG}" 2>&1 || true ;;
			dnf) dnf install -y -q golang >>"${DEPLOY_LOG}" 2>&1 || true ;;
			apk) apk add --no-cache go >>"${DEPLOY_LOG}" 2>&1 || true ;;
			*) : ;;
		esac
	fi
	if ! need_cmd go; then
		# 上游 Caddy 2.11.x 用 Go 1.26 构建；发行版自带的 Go 通常太旧
		# （Debian 12 是 1.19，Ubuntu 24.04 是 1.22），不足以编译。
		err "Go 不可用 —— 这个构建需要 Go 1.26+"
		err "  发行版自带的 Go 一般太旧（Debian 12: 1.19 / Ubuntu 24.04: 1.22）。"
		err "  装新版本的便捷办法：https://go.dev/dl/ 下载对应架构的压缩包，"
		err "  解到 /usr/local/go 后把 /usr/local/go/bin 加进 PATH。"
		err "  另外：1 GB 内存的机器编译大型 Go 程序容易 OOM，建议先加 swap。"
		return 1
	fi
	local xcaddy="${HOME}/go/bin/xcaddy"
	if [ ! -x "$xcaddy" ]; then
		note "安装 xcaddy"
		if ! go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest >>"${DEPLOY_LOG}" 2>&1; then
			err "xcaddy 安装失败"
			show_log_tail 10
			return 1
		fi
	fi
	if [ ! -x "$xcaddy" ]; then
		err "xcaddy 不可用（${xcaddy}）"
		return 1
	fi
	TMP_DIR=$(mktemp -d)
	if ! ( cd "${TMP_DIR}" && "$xcaddy" build --output caddy \
		--with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive ) >>"${DEPLOY_LOG}" 2>&1; then
		err "编译失败"
		show_log_tail 15
		return 1
	fi
	install -m 0755 "${TMP_DIR}/caddy" "${CADDY_BIN}.new" || { err "无法写入 ${CADDY_BIN}"; return 1; }
	mv -f "${CADDY_BIN}.new" "${CADDY_BIN}"
}

# ---------------- 阶段 3: 用户与目录 ----------------
setup_user_and_dirs() {
	if ! id caddy >/dev/null 2>&1; then
		case "${PKG}" in
			apk)
				addgroup -S caddy 2>/dev/null || true
				adduser -S -D -H -h "${DATA_DIR}" -s /sbin/nologin -G caddy caddy 2>/dev/null \
					|| adduser -S -D -H -h "${DATA_DIR}" -s /sbin/nologin caddy \
					|| { err "创建 caddy 用户失败"; return 1; }
				;;
			*)
				groupadd --system caddy 2>/dev/null || true
				useradd --system --gid caddy --create-home --home-dir "${DATA_DIR}" \
					--shell /usr/sbin/nologin --comment "Caddy web server" caddy \
					|| { err "创建 caddy 用户失败"; return 1; }
				;;
		esac
		ok "已创建 caddy 系统用户"
	else
		note "caddy 用户已存在"
	fi
	mkdir -p "${CONF_DIR}" "${LOG_DIR}" "${DATA_DIR}" "${WEB_ROOT}" \
		|| { err "创建目录失败（磁盘满？）"; return 1; }
	mkdir -p "${DATA_DIR}/.local/share/caddy" "${DATA_DIR}/.config/caddy" || true
	chown -R caddy:caddy "${LOG_DIR}" "${DATA_DIR}" || { err "设置目录属主失败"; return 1; }
	ok "目录就绪: ${CONF_DIR} / ${LOG_DIR} / ${WEB_ROOT}"
}

# ---------------- 阶段 4: 配置 ----------------
# CREDS_KNOWN=no 表示「配置保留着，但我们不知道里面的账号密码」。
# 这种情况下绝不打印任何凭据，也跳过需要密码的验证 ——
# 否则会给用户一个不在配置里的密码，把他引到错误方向。
CREDS_KNOWN="no"

write_config() {
	if [ -f "${CONF_FILE}" ] && [ "$FORCE_CONFIG" != "yes" ]; then
		note "配置已存在，保留现有配置（要重建请加 --force-config）"
		CREDS_KNOWN="no"
		if state_load; then
			if [ "$USER_EXPLICIT" != "yes" ] && [ -n "${STATE_USER:-}" ]; then
				NAIVE_USER="$STATE_USER"
			fi
			# 用户这次指定的域名若与现有配置不同，必须说出来：
			# 否则他会以为部署的是新域名，而实际生效的是旧的。
			if [ -n "$DOMAIN" ] && [ -n "${STATE_DOMAIN:-}" ] && [ "$DOMAIN" != "$STATE_DOMAIN" ]; then
				warn "你指定的域名 ${DOMAIN} 与现有配置里的 ${STATE_DOMAIN} 不一致"
				warn "本次按幂等原则保留现有配置。真要换域名，请加 --force-config"
			fi
			NAIVE_PASS="${STATE_PASS:-}"
			DOMAIN="${STATE_DOMAIN:-$DOMAIN}"
			HTTPS_PORT="${STATE_PORT:-$HTTPS_PORT}"
			ALLOW_PORTS="${STATE_ALLOW_PORTS:-$ALLOW_PORTS}"
			PROBE_SECRET="${STATE_PROBE_SECRET:-$PROBE_SECRET}"
			PAC_PATH="${STATE_PAC_PATH:-$PAC_PATH}"
			CLIENT_PROTO="${STATE_CLIENT_PROTO:-$CLIENT_PROTO}"
			TLS_CERT_FILE="${STATE_TLS_CERT:-$TLS_CERT_FILE}"
			TLS_KEY_FILE="${STATE_TLS_KEY:-$TLS_KEY_FILE}"
			if [ -n "$NAIVE_PASS" ]; then
				CREDS_KNOWN="yes"
				ok "已从上次部署记录恢复账号: ${NAIVE_USER}"
			fi
		else
			warn "读不到可用的凭据记录（${STATE_FILE}）"
		fi
		if [ "$CREDS_KNOWN" != "yes" ]; then
			warn "找不到凭据记录（${STATE_FILE}），无法确认现有配置里的账号密码"
			warn "本次不会显示任何凭据 —— 免得给你一个错的密码"
			warn "要查看现有账号: sudo grep -A2 basic_auth ${CONF_FILE}"
		fi
	else
		if [ -f "${CONF_FILE}" ]; then
			local bak=""
			bak="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
			cp -p "${CONF_FILE}" "$bak" || { err "备份原配置失败"; return 1; }
			warn "已备份原配置到 ${bak}"
		fi
		# --force-config 不等于要换密码：状态文件里还存着旧密码，能复用就复用，
		# 否则所有已配置的客户端会在用户毫无察觉的情况下全部失效。
		if [ -z "$NAIVE_PASS" ]; then
			if state_load && [ -n "${STATE_PASS:-}" ]; then
				NAIVE_PASS="$STATE_PASS"
				note "沿用现有密码（要换密码请用 --rotate-password）"
			else
				NAIVE_PASS=$(gen_password 28)
				note "未指定密码，已自动生成 28 位 —— 部署结束时会显示，留意最后一屏"
			fi
		fi
		render_caddyfile "$DOMAIN" "$EMAIL" "$NAIVE_USER" "$NAIVE_PASS" "$HTTPS_PORT" "$ALLOW_PORTS" "$PROBE_SECRET" "$PAC_PATH" "$TLS_CERT_FILE" "$TLS_KEY_FILE" > "${CONF_FILE}" \
			|| { err "写入 ${CONF_FILE} 失败"; return 1; }
			chmod 0640 "${CONF_FILE}" || { err "设置 ${CONF_FILE} 权限失败"; return 1; }
			# 这里的 chown 不能吞掉失败：属主不对的话 caddy 用户读不到自己的配置，
			# 阶段 4 却报成功，一直到阶段 6/7 才炸 —— 那时排查方向全错。
			chown root:caddy "${CONF_FILE}" || { err "设置 ${CONF_FILE} 属主失败（caddy 用户/组是否存在？）"; return 1; }
			state_write || { err "写入状态文件失败"; return 1; }
		CREDS_KNOWN="yes"
		ok "配置已写入 ${CONF_FILE}"
	fi

	# 只在格式确实需要调整时才写回。
	# 早先这里无条件 fmt --overwrite —— 于是「保留现有配置」其实改写了用户的文件，
	# 用户手写的注释和排版会被静默重排，还没有备份。
	local fmt_tmp="${CONF_FILE}.fmt.$$"
	if "${CADDY_BIN}" fmt "${CONF_FILE}" > "${fmt_tmp}" 2>/dev/null; then
		if ! cmp -s "${fmt_tmp}" "${CONF_FILE}"; then
			backup_if_exists "${CONF_FILE}"
			if mv -f "${fmt_tmp}" "${CONF_FILE}"; then
				chmod 0640 "${CONF_FILE}" 2>/dev/null || true
				chown root:caddy "${CONF_FILE}" 2>/dev/null || true
				note "配置排版已规范化（原文件已备份）"
			fi
		fi
	fi
	rm -f "${fmt_tmp}"

	if "${CADDY_BIN}" validate --config "${CONF_FILE}" --adapter caddyfile >/dev/null 2>&1; then
		ok "配置语法校验通过"
	else
		err "配置语法校验失败，出错细节："
		"${CADDY_BIN}" validate --config "${CONF_FILE}" --adapter caddyfile 2>&1 | sed 's/^/      /' >&2 || true
		return 1
	fi
}
# ---------------- 阶段 5: 伪装站点 ----------------
# 目录里除我们的伪装页之外还有别的东西吗（有 = 不是我们的地盘）
dir_has_foreign_content() {
	local d="${1:-}" n=""
	[ -d "$d" ] || return 1
	n=$(find "$d" -mindepth 1 -maxdepth 1 ! -name index.html 2>/dev/null | wc -l | tr -d ' ')
	[ "${n:-0}" -gt 0 ]
}

# 这个 index.html 是不是本脚本生成的伪装页
is_our_camouflage() {
	[ -f "${1:-}/index.html" ] || return 1
	grep -q 'This site is under construction' "${1:-}/index.html" 2>/dev/null
}

# ---------------- 阶段 5: 伪装站点 ----------------
write_camouflage_site() {
	if dir_has_foreign_content "${WEB_ROOT}"; then
		err "${WEB_ROOT} 里已经有别的内容，不敢动它"
		err "  这不是本脚本建的目录。换个目录重跑：--web-root /var/www/naive-camouflage"
		err "  或者你先自行确认并清理该目录。"
		return 1
	elif is_our_camouflage "${WEB_ROOT}"; then
		note "伪装首页已存在，保留"
	else
		mkdir -p "${WEB_ROOT}" || { err "创建 ${WEB_ROOT} 失败"; return 1; }
		# 用 if ! 包住：set -e 下不带兜底的重定向失败会直接终止 shell，
		# 下面那句补写判断就永远拿不到执行权，失败会以一行裸报错收场。
		if ! cat > "${WEB_ROOT}/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:42rem;
margin:12vh auto;padding:0 1.5rem;line-height:1.7;color:#222}
h1{font-weight:600;margin-bottom:.25rem}
p{color:#555}
hr{border:none;border-top:1px solid #e5e5e5;margin:2rem 0}
small{color:#999}
</style>
</head>
<body>
<h1>Hello</h1>
<p>This site is under construction.</p>
<hr>
<small>&copy; 2026</small>
</body>
</html>
HTMLEOF
		then
			err "写入伪装首页失败（磁盘满或权限异常？）"
			return 1
		fi
		ok "已生成伪装首页"
	fi
	# 只动自己管理的目录
	chown -R root:root "${WEB_ROOT}" 2>/dev/null || true
	chmod -R a+rX "${WEB_ROOT}" 2>/dev/null || true
}

# ---------------- 阶段 6: 服务 ----------------
install_service() {
	# 启动前再修一次日志属主：阶段 4 的 root 校验可能刚创建过 root 属主的日志
	ensure_cert_readable
	ensure_log_dir_owner
	if [ "$INIT" = "systemd" ]; then
		backup_if_exists "${SVC_FILE}"
		render_systemd_unit > "${SVC_FILE}" || { err "写入 ${SVC_FILE} 失败"; return 1; }
		systemctl daemon-reload || true
		systemctl enable caddy >/dev/null 2>&1 || true
		if systemctl is-active --quiet caddy; then
			systemctl restart caddy || { err "重启 caddy 失败"; return 1; }
		else
			systemctl start caddy || { err "启动 caddy 失败"; return 1; }
		fi
		ok "systemd 服务已启动"
	elif [ "$INIT" = "openrc" ]; then
		mkdir -p /run
		backup_if_exists "${OPENRC_FILE}"
		render_openrc_script > "${OPENRC_FILE}" || { err "写入 ${OPENRC_FILE} 失败"; return 1; }
		chmod +x "${OPENRC_FILE}"
		rc-update add caddy default >/dev/null 2>&1 || true
		rc-service caddy restart || rc-service caddy start || { err "启动 caddy 失败"; return 1; }
		ok "openrc 服务已启动"
	else
		err "没找到 systemd 或 openrc"
		return 1
	fi
}

# ---------------- 阶段 7: 验证 ----------------
# 验证失败只记数，不中断 —— 但要传到 summary，「完成」和「验证通过」必须是两个词。
VERIFY_WARNINGS=0
# 跳过验证 != 验证通过。摘要必须能区分这两件事。
VERIFY_SKIPPED="no"
VERIFY_NOTES=()

verify_warn() { # <一句话说明这一项没通过>
	VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
	VERIFY_NOTES+=("$1")
}

verify_deployment() {
	if [ "$SKIP_VERIFY" = "yes" ]; then
		VERIFY_SKIPPED="yes"
		note "已按 --skip-verify 跳过验证"
		return 0
	fi
	sleep 2

	if [ "$INIT" = "systemd" ]; then
		if systemctl is-active --quiet caddy; then
			ok "服务进程运行中"
		else
			err "服务没起来。最近的日志："
			journalctl -u caddy -n 30 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
			return 1
		fi
	fi

	local code="" issuer="" pub=""

	note "在本机自测 HTTPS 握手…"
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
		--resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" "https://${DOMAIN}:${HTTPS_PORT}/" 2>/dev/null || true)
	if [ "$code" = "200" ]; then
		ok "服务器本机自测通过（HTTPS 正常，返回 200）"
	else
		warn "本机 HTTPS 返回码 ${code:-无} —— 证书可能还在签发中"
		note "等 30 秒后重跑同一条命令即可；一直失败看 journalctl -u caddy"
		verify_warn "本机 HTTPS 握手"
	fi

	issuer=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "${DOMAIN}" 2>/dev/null \
		| openssl x509 -noout -issuer 2>/dev/null || true)
	if [ -n "$issuer" ]; then
		ok "证书签发者: ${issuer}"
	else
		warn "读不到证书信息（多半是证书还没签发完）"
		verify_warn "证书信息"
	fi

	if [ "$CREDS_KNOWN" = "yes" ]; then
		note "用你的账号密码，实测经这台服务器访问外网…"
		# 必须断言响应内容，不能只看状态码。
		# 上游 forwardproxy 文档明说：开了 probe_resistance 之后，
		# 凭据错误时「不再返回 407，而是伪装成普通 Caddy 站点」——
		# 也就是说错密码照样返回 200（伪装页）。只看 http_code 会对错误部署打绿勾。
		# 代理地址必须用「证书签的那个域名」，不能用 127.0.0.1。
		# 本机回环测试时 curl 会拿代理地址当 TLS SNI，而证书只对域名有效 ——
		# 用 IP 会导致 SNI 不匹配，TLS 还没走到认证那一步就失败了。
		# 真机实测：用 IP 一律报 tlsv1 alert internal error，用域名则正常转发。
		# 域名在本机解析不通时（NAT 回流受限之类），临时借一下 /etc/hosts。
		local PROXY_TEST_HOST="${DOMAIN}"
		if ! curl -sS -o /dev/null --max-time 5 -k "https://${DOMAIN}/" 2>/dev/null; then
			node_local_hosts_hack
		fi

		local trace="" via_ip="" sip=""
		trace=$(curl -sS -k --max-time 20 \
			-x "https://${NAIVE_USER}:${NAIVE_PASS}@${PROXY_TEST_HOST}:${HTTPS_PORT}" \
			"https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)
		via_ip=$(printf '%s' "$trace" | sed -n 's/^ip=//p' | head -1)
		if [ -n "$via_ip" ]; then
			sip=$(get_public_ip || true)
			if [ -n "$sip" ] && [ "$via_ip" != "$sip" ]; then
				warn "代理通了，但出口 IP 是 ${via_ip}，而本机是 ${sip}（上游还有别的代理？）"
			fi
			ok "已经用你的账号密码，实测经这台服务器成功访问了外网（出口 IP ${via_ip}）"
		else
			warn "代理转发实测没拿到预期响应 —— 大概率是凭据不对"
			note "注意：开了 probe_resistance 之后凭据错误不会报 407，而是返回伪装页，"
			note "      所以这里看的是响应内容而不是状态码。"
			note "核对账号密码：sudo grep -A2 basic_auth ${CONF_FILE}"
			verify_warn "代理转发实测"
		fi
	else
		note "跳过代理转发实测（不知道现有配置里的密码，不拿错密码去试）"
	fi

	note "从公网侧访问一次…"
	pub=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://${DOMAIN}/" 2>/dev/null || true)
	if [ "$pub" = "200" ]; then
		ok "公网访问正常"
	else
		warn "公网访问返回码 ${pub:-无}"
		note "很多主机不允许从内部访问自己的公网地址（NAT 回流受限），用手机流量再试一次更准"
		verify_warn "公网可达"
	fi
}
# ---------------- 汇总 ----------------
mask_conf_password() { # 读出配置但把密码打码
	# 用 BRE 而不是 sed -E：busybox 的老版本 sed 只认 -r，不认 -E。
	sed 's/^\([[:space:]]*basic_auth[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}\).*$/\1********/' "$1"
}

print_summary() {
	local host="${DOMAIN}"
	if [ "$HTTPS_PORT" != "443" ]; then host="${DOMAIN}:${HTTPS_PORT}"; fi

	if [ "$CREDS_KNOWN" = "yes" ]; then
		render_client_config "$NAIVE_USER" "$NAIVE_PASS" "$DOMAIN" "$HTTPS_PORT" "$CLIENT_PROTO" > "${CLIENT_CONF}" || true
		chmod 0600 "${CLIENT_CONF}" 2>/dev/null || true
	fi

	# 「部署完成」和「验证通过」必须是两个词 —— 别让用户以为一切正常
	if [ "${VERIFY_SKIPPED}" = "yes" ]; then
		printf '\n%s\n' "${C_YEL}${C_BLD}════════ ${G_WARN} 部署完成，但已跳过验证（未确认）════════${C_RST}"
		printf '%s\n' "  ${C_DIM}用了 --skip-verify，这一步没有实测。想确认就重跑一次不带该参数的命令。${C_RST}"
	elif [ "${VERIFY_WARNINGS}" -eq 0 ]; then
		printf '\n%s\n' "${C_GRN}${C_BLD}════════ ${G_OK} 部署完成，验证全部通过 ════════${C_RST}"
	else
		printf '\n%s\n' "${C_YEL}${C_BLD}════════ ${G_WARN} 部署完成，但有 ${VERIFY_WARNINGS} 项需要你确认 ════════${C_RST}"
		local n=""
		for n in "${VERIFY_NOTES[@]}"; do
			printf '%s\n' "  ${C_YEL}${G_WARN}${C_RST} ${n}"
		done
		printf '%s\n' "  ${C_DIM}这几项多半几十秒内会自己好（证书还在签发）。过一会儿重跑同一条命令即可复查。${C_RST}"
	fi

	printf '\n%s\n' "  ${C_BLD}服务端${C_RST}"
	info "  域名      ${DOMAIN}"
	info "  端口      ${HTTPS_PORT}"
	info "  配置文件  ${CONF_FILE}"
	info "  日志      ${LOG_DIR}/access.log"

	if [ "$CREDS_KNOWN" = "yes" ]; then
		printf '%s\n' "  ${C_BLD}账号密码${C_RST}"
		printf '%s\n' "    用户名    ${NAIVE_USER}"
		printf '%s\n' "    密码      ${C_BLD}${NAIVE_PASS}${C_RST}   ${C_DIM}← 现在复制这一串${C_RST}"
		printf '\n%s\n\n' "    ${C_DIM}忘了密码？  sudo cat ${STATE_FILE}${C_RST}"

		printf '%s\n' "  ${C_BLD}客户端 config.json${C_RST}${C_DIM}（已存到 ${CLIENT_CONF}，权限 0600）${C_RST}"
		render_client_config "$NAIVE_USER" "$NAIVE_PASS" "$DOMAIN" "$HTTPS_PORT" "$CLIENT_PROTO" | sed 's/^/    /'
		printf '\n%s\n\n' "    ${C_DIM}连接串    https://${NAIVE_USER}:${NAIVE_PASS}@${host}${C_RST}"
		printf '\n%s\n' "  ${C_BLD}客户端连不上时${C_RST}"
		if [ -n "${PROBE_SECRET}" ]; then
			info "  浏览器访问这个地址会弹出凭据框："
			info "    https://${PROBE_SECRET}/"
			info "  （这是 probe_resistance 的秘密链接，只有这个地址会触发 407）"
		else
			note "  秘密链接当前是随机值。上游文档说：客户端若不预先发送凭据，"
			note "  需要访问秘密链接来触发 407。要固定地址就加 --probe-secret <域名>"
		fi
		if [ -n "${PAC_PATH}" ]; then
			if [ -n "${PROBE_SECRET}" ]; then
				info "  PAC 文件:  https://${PROBE_SECRET}${PAC_PATH}"
				info "  （实测：PAC 只在秘密域名上可取，主域名会 404 —— 这正是文档要求的" 
				info "    「secret location」；取它时也要带 basic_auth 凭据）"
			else
				warn "  PAC 文件在 https://${DOMAIN}${PAC_PATH} —— 但没设 --probe-secret 时"
				warn "  没有秘密域名，PAC 路径可预测，会削弱抗探测（上游文档明确警告）"
			fi
		fi
		note "  若客户端解析不到域名，在它的 config.json 里加一行："
		note "    \"host-resolver-rules\": \"MAP ${DOMAIN} <服务器IP>\""
	else
		printf '%s\n' "  ${C_BLD}账号密码${C_RST}"
		warn "现有配置是保留的，但凭据记录缺失，所以这里不显示密码（免得给你一个错的）"
		info "  查看现有账号: sudo grep -A2 basic_auth ${CONF_FILE}"
		printf '\n'
	fi

	printf '%s\n' "  ${C_YEL}${C_BLD}【必做】否则客户端连不上${C_RST}"
	info "去你买 VPS 的那个网站的控制台（阿里云 / 腾讯云 / Vultr / ...），"
	info "在「安全组」或「防火墙」里放行 TCP ${HTTPS_PORT}，顺便把 80 也放行"
	info "（证书到期自动续期要用 80）。这一步不做，前面全白干。"
	printf '\n'

	printf '%s\n' "  ${C_BLD}接下来（在你自己的电脑上）${C_RST}"
	info "1. 下载 naive 客户端（各平台下载地址见 README）"
	info "2. 把上面的 config.json 存到客户端同目录"
	info "3. 启动客户端，系统代理设为 SOCKS5 127.0.0.1:1080"
	info "4. 验证一下："
	info "     curl -x socks5h://127.0.0.1:1080 -I https://www.google.com"
	info "   看到 HTTP/2 200 就成了"
	printf '\n'
	info "想确认服务真的活着？浏览器打开 https://${DOMAIN}/ ，应该看到一个普通网页。"
	printf '\n'

	printf '%s\n' "  ${C_BLD}常用命令${C_RST}"
	info "  状态      systemctl status caddy"
	info "  日志      journalctl -u caddy -f"
	info "  重载      sudo $0 --reload"
	info "  升级      sudo $0 --upgrade"
	info "  换密码    sudo $0 --rotate-password"
	info "  出问题    sudo $0 --collect-diagnostics"
	printf '\n'

	if need_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
		note "检测到 ufw 已启用，可执行: ufw allow ${HTTPS_PORT}/tcp && ufw allow 80/tcp"
	elif need_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		note "检测到 firewalld 已启用: firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload"
	fi
}

# ---------------- 卸载 ----------------
do_uninstall() {
	section "卸载"
	if [ "$PURGE" = "yes" ]; then
		warn "--purge 会删除配置、伪装站点、日志、数据目录，以及 caddy 系统用户。这一步不可撤销。"
		if [ "$ASSUME_YES" != "yes" ]; then
			confirm "确定要彻底清理吗？"
		fi
	fi

	if [ "$INIT" = "systemd" ]; then
		systemctl stop caddy 2>/dev/null || true
		systemctl disable caddy 2>/dev/null || true
		rm -f "${SVC_FILE}"
		systemctl daemon-reload 2>/dev/null || true
	elif [ "$INIT" = "openrc" ]; then
		rc-service caddy stop 2>/dev/null || true
		rc-update del caddy default 2>/dev/null || true
		rm -f "${OPENRC_FILE}"
	fi
	ok "服务已停止并移除"

	if [ "$PURGE" = "yes" ]; then
		rm -f "${CONF_FILE}" "${STATE_FILE}" "${CLIENT_CONF}"
		# 只删自己建的伪装目录；里面若有别的内容，宁可留着等用户确认
		if dir_has_foreign_content "${WEB_ROOT}"; then
			warn "${WEB_ROOT} 里有别的内容，没有删除（请自行确认后处理）"
		elif [ -d "${WEB_ROOT}" ]; then
			rm -rf "${WEB_ROOT}"
		fi
		rm -rf "${LOG_DIR}" "${DATA_DIR}"
		if id caddy >/dev/null 2>&1; then userdel -r caddy 2>/dev/null || true; fi
		rm -f "${CADDY_BIN}"
		ok "已清理配置、站点、日志、数据与 caddy 用户"
	else
		note "配置与数据已保留（彻底清理请加 --purge）"
	fi
}

# ---------------- 换密码 ----------------
# 这是把「我好像泄露了密码」从重装降级成一条命令的关键。
do_rotate_password() {
	section "更换代理密码"
	if [ ! -f "${CONF_FILE}" ]; then
		die "找不到 ${CONF_FILE} —— 先完成一次部署再换密码"
	fi
	if [ ! -r "${STATE_FILE}" ]; then
		die "找不到凭据记录 ${STATE_FILE}，没法安全地重写配置。请先用 --force-config 重新部署一次。"
	fi
	state_load || die "状态文件 ${STATE_FILE} 不可用或内容未通过校验，不能安全地重写配置"
	DOMAIN="${STATE_DOMAIN:-$DOMAIN}"
	EMAIL="${STATE_EMAIL:-$EMAIL}"
	NAIVE_USER="${STATE_USER:-${NAIVE_USER:-naive}}"
	HTTPS_PORT="${STATE_PORT:-443}"
	ALLOW_PORTS="${STATE_ALLOW_PORTS:-}"
	PROBE_SECRET="${STATE_PROBE_SECRET:-}"
	PAC_PATH="${STATE_PAC_PATH:-}"
	CLIENT_PROTO="${STATE_CLIENT_PROTO:-https}"
	TLS_CERT_FILE="${STATE_TLS_CERT:-}"
	TLS_KEY_FILE="${STATE_TLS_KEY:-}"
	if [ -z "$DOMAIN" ]; then
		die "凭据记录里没有域名，无法重写配置"
	fi

	NAIVE_PASS=$(gen_password 28)
	local bak=""
	bak="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
	cp -p "${CONF_FILE}" "$bak" || die "备份原配置失败"

	# 先写临时文件、校验通过再落盘。这样不存在「写坏了再回滚」的窗口，
	# 也就不会出现「消息说已回滚、实际没有回滚」这种假信息。
	local newconf="${CONF_FILE}.new.$$"
	render_caddyfile "$DOMAIN" "$EMAIL" "$NAIVE_USER" "$NAIVE_PASS" "$HTTPS_PORT" "$ALLOW_PORTS" "$PROBE_SECRET" "$PAC_PATH" "$TLS_CERT_FILE" "$TLS_KEY_FILE" > "${newconf}" \
		|| { rm -f "${newconf}"; die "生成新配置失败（原配置未动）"; }
	chmod 0640 "${newconf}" 2>/dev/null || true
	"${CADDY_BIN}" fmt --overwrite "${newconf}" >/dev/null 2>&1 || true
	if ! "${CADDY_BIN}" validate --config "${newconf}" --adapter caddyfile >/dev/null 2>&1; then
		rm -f "${newconf}"
		die "新配置没通过校验，原配置未做任何改动（备份仍在 ${bak}）"
	fi
	mv -f "${newconf}" "${CONF_FILE}" || { rm -f "${newconf}"; die "替换配置失败"; }
	chown root:caddy "${CONF_FILE}" || die "设置 ${CONF_FILE} 属主失败"

	state_write || die "更新状态文件失败"
	render_client_config "$NAIVE_USER" "$NAIVE_PASS" "$DOMAIN" "$HTTPS_PORT" "$CLIENT_PROTO" > "${CLIENT_CONF}" || true
	chmod 0600 "${CLIENT_CONF}" 2>/dev/null || true

	if [ "$INIT" = "systemd" ]; then
		systemctl reload caddy || systemctl restart caddy || die "重载服务失败"
	else
		rc-service caddy reload || rc-service caddy restart || die "重载服务失败"
	fi
	ok "密码已更换，服务已平滑重载"
	info "  新密码    ${NAIVE_PASS}"
	info "  客户端配置已更新: ${CLIENT_CONF}"
	warn "记得在客户端也改成新密码 —— 旧密码已经失效"
}

# ---------------- 求助诊断 ----------------
# 让「求助」变成一条命令：把该给的都收集好，密码自动打码。
do_collect_diagnostics() {
	printf '%s\n' "NaiveProxy 部署排查信息"
	printf '%s\n' "生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
	printf '%s\n' "脚本版本: ${SCRIPT_VERSION}"
	printf '%s\n' "---------------- 系统 ----------------"
	detect_os; detect_arch
	printf '发行版: %s\n' "${OS_NAME}"
	printf '内核: %s\n' "$(uname -srm)"
	printf '架构: %s  初始化: %s  包管理: %s\n' "${ARCH}" "${INIT:-未知}" "${PKG:-未知}"
	printf '是否 root: %s\n' "$([ "$(id -u)" -eq 0 ] && echo 是 || echo 否)"
	printf '磁盘 /: %s\n' "$(df -Ph / 2>/dev/null | awk 'NR==2{print $4" 可用，已用 "$5}')"

	printf '%s\n' "---------------- caddy ----------------"
	if [ -x "${CADDY_BIN}" ]; then
		printf '二进制: %s\n' "$("${CADDY_BIN}" version 2>&1 | head -1)"
	else
		printf '二进制: 未安装（%s 不存在）\n' "${CADDY_BIN}"
	fi
	if [ -f "${CONF_FILE}" ]; then
		printf '配置校验:\n'
		"${CADDY_BIN}" validate --config "${CONF_FILE}" --adapter caddyfile 2>&1 | sed 's/^/  /' || true
		printf '配置内容（密码已打码）:\n'
		mask_conf_password "${CONF_FILE}" | sed 's/^/  /' || true
	else
		printf '配置: %s 不存在\n' "${CONF_FILE}"
	fi

	printf '%s\n' "---------------- 服务 ----------------"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl status caddy --no-pager -n 5 2>&1 | sed 's/^/  /' || true
		printf '最近日志:\n'
		journalctl -u caddy -n 40 --no-pager 2>&1 | sed 's/^/  /' || true
	else
		printf '没有 systemctl\n'
	fi

	printf '%s\n' "---------------- 网络 ----------------"
	if need_cmd ss; then
		printf '监听端口:\n'
		ss -ltnp 2>/dev/null | grep -E ':(80|443)' | sed 's/^/  /' || printf '  （80/443 都没在监听）\n'
	fi
	printf '公网 IP: %s\n' "$(get_public_ip || echo 取不到)"
	if state_load; then
		if [ -n "${STATE_DOMAIN:-}" ]; then
			printf '域名 %s 解析到: %s\n' "${STATE_DOMAIN}" "$(resolve_domain_ip "${STATE_DOMAIN}" || echo 查不到)"
		fi
	fi
	printf '%s\n' "----------------------------------------"
	printf '%s\n' "把以上全部内容复制发出来即可。密码已自动打码。"
}
# ---------------- 体检（只读） ----------------
# 这是用户最早会跑的只读命令：环境 + 前置条件逐条判定 + 配置预览。
# 不需要 root，绝不写任何文件。
do_check() {
	section "体检（只读，不会改动这台机器上的任何东西）"
	detect_os; detect_arch
	info "系统 ${OS_NAME:-未知}   架构 ${ARCH:-未知}   初始化 ${INIT:-未知}   包管理 ${PKG:-未知}"
	printf '\n'

	local problems=0 ip="" dns="" p="" ports=() avail=""

	# 1) 域名解析
	if [ -n "$DOMAIN" ]; then
		ip=$(get_public_ip || true)
		dns=$(resolve_domain_ip "$DOMAIN" || true)
		if [ -n "$dns" ] && [ -n "$ip" ] && [ "$ip" = "$dns" ]; then
			ok "域名 ${DOMAIN} 已指向本机（${ip}）"
		elif [ -n "$dns" ]; then
			warn "域名 ${DOMAIN} 指向 ${dns}，而本机公网 IP 是 ${ip:-未知}"
			info "  ${G_ARROW} 证书签发会失败。如果要走 CDN，请先把 Cloudflare 橙云切成灰云"
			problems=$((problems + 1))
		else
			warn "域名 ${DOMAIN} 查不到 A 记录"
			info "  ${G_ARROW} 先去域名服务商加一条指向 ${ip:-本机 IP} 的 A 记录，通常几分钟生效"
			problems=$((problems + 1))
		fi
	else
		note "没提供 --domain，跳过域名检查（加上它能查得更全）"
	fi

	# 2) 端口（沿预检的同一套：80 + 443 + 自定义端口）
	ports=("80" "443")
	if [ "${HTTPS_PORT:-443}" != "80" ] && [ "${HTTPS_PORT:-443}" != "443" ]; then
		ports+=("${HTTPS_PORT:-443}")
	fi
	for p in "${ports[@]}"; do
		case "$(port_state "$p")" in
		in-use)
			if port_owner_is_caddy "$p"; then
				note "端口 ${p} 已被 caddy 自己占用（说明之前部署过，正常）"
			else
				warn "端口 ${p} 被别的程序占用"
				show_port_owner "$p"
				info "  ${G_ARROW} Caddy 需要 443（对外服务）和 80（证书校验）。占用者通常是 Nginx / Apache"
				problems=$((problems + 1))
			fi
			;;
		free)
			ok "端口 ${p} 空闲"
			;;
		*)
			note "端口 ${p}：本机没有 ss 命令，无法判定（不算问题，但请自行确认）"
			note "  装上就能自动查：apt install iproute2"
			;;
		esac
	done

	# 3) 能不能访问 GitHub（第 2 步要从那里下 caddy）
	if curl -fsS -o /dev/null --max-time 10 https://github.com 2>/dev/null; then
		ok "能访问 GitHub（下载 caddy 需要）"
	else
		warn "连不上 GitHub"
		info "  ${G_ARROW} 第 2 步会失败。先解决网络，或者改用 --build-from-source"
		problems=$((problems + 1))
	fi

	# 4) 磁盘
	avail=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)
	if [ -n "$avail" ] && [ "$avail" -gt 204800 ] 2>/dev/null; then
		ok "根分区剩余 $((avail / 1024)) MB，够用"
	else
		warn "根分区剩余不足 200 MB（或读不到）"
		info "  ${G_ARROW} 可能装不下 caddy 和证书，先清理一下"
		problems=$((problems + 1))
	fi

	# 5) 是不是已经部署过
	if [ -f "${CONF_FILE}" ]; then
		note "检测到已经部署过（${CONF_FILE} 存在）"
		if [ -r "${STATE_FILE}" ]; then
			ok "凭据记录在，重跑会复用现有账号密码，不会换掉"
		else
			warn "但凭据记录 ${STATE_FILE} 缺失 —— 重跑时不会显示密码"
			info "  ${G_ARROW} 想看现有账号: sudo grep -A2 basic_auth ${CONF_FILE}"
		fi
	else
		note "全新部署（还没有 ${CONF_FILE}）"
	fi

	# 6) 权限
	if [ "$(id -u)" -eq 0 ]; then
		ok "当前是 root，正式部署可以直接跑"
	else
		note "当前不是 root —— 体检不需要，但正式部署要加 sudo"
	fi

	# 配置预览
	if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
		section "配置预览"
		note "密码位置是占位符 —— 正式部署时才会生成真密码"
		printf '\n'
		render_caddyfile "$DOMAIN" "$EMAIL" "${NAIVE_USER:-naive}" "${PASS_PREVIEW}" "${HTTPS_PORT:-443}" "$ALLOW_PORTS" "$PROBE_SECRET" "$PAC_PATH" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
		printf '\n'
		info "客户端 config.json 会是这样："
		render_client_config "${NAIVE_USER:-naive}" "${PASS_PREVIEW}" "$DOMAIN" "${HTTPS_PORT:-443}" "$CLIENT_PROTO" | sed 's/^/    /'
		printf '\n'
	fi

	section "结论"
	if [ "$problems" -eq 0 ]; then
		ok "没发现问题，可以正式部署了。"
		printf '\n%s\n' "  ${C_BLD}下一步：${C_RST}"
		printf '%s\n' "    sudo $0 --domain ${DOMAIN:-<你的域名>} --email ${EMAIL:-<你的邮箱>}"
	else
		warn "有 ${problems} 项需要先处理（上面标 ${G_WARN} 的）。处理完再跑一次 --check 复查。"
	fi
	printf '\n%s\n\n' "  ${C_DIM}体检是只读的 —— 刚才没有改动这台机器上的任何东西。${C_RST}"
}

# ---------------- 重载 / 升级 ----------------
do_reload() {
	section "校验并重载配置"
	if [ ! -f "${CONF_FILE}" ]; then
		die "找不到 ${CONF_FILE} —— 先完成一次部署"
	fi
	need_cmd "${CADDY_BIN}" || die "找不到 ${CADDY_BIN}"
	"${CADDY_BIN}" validate --config "${CONF_FILE}" --adapter caddyfile \
		|| die "配置校验没通过，没有重载（服务仍在用旧配置运行）"
	if [ "$INIT" = "systemd" ]; then
		systemctl reload caddy || die "重载失败"
	else
		rc-service caddy reload || die "重载失败"
	fi
	ok "配置已校验并重载"
}

do_upgrade() {
	section "升级 caddy 二进制"
	install_deps || die "依赖准备失败"
	install_caddy_binary || die "二进制升级失败"
	if [ "$INIT" = "systemd" ]; then
		systemctl restart caddy || die "重启服务失败"
	else
		rc-service caddy restart || die "重启服务失败"
	fi
	ok "升级完成，配置未改动"
}
# ---------------- 参数校验 ----------------
# 刻意不在这里生成密码 —— 预览（--check / --dry-run）不该凭空造一个
# 永远不会被用到的密码。真密码在 write_config 里、真的要写配置时才生成。
validate_inputs() {
	[ -n "$DOMAIN" ] || die "--domain 必填（试试 --help）"
	[ -n "$EMAIL" ] || die "--email 必填（试试 --help）"
	validate_domain "$DOMAIN" || die "域名格式不合法: ${DOMAIN}"
	validate_email "$EMAIL" || die "邮箱格式不合法: ${EMAIL}"
	validate_user "$NAIVE_USER" || die "用户名只能字母数字下划线，最长 32: ${NAIVE_USER}"
	validate_port "$HTTPS_PORT" || die "端口不合法: ${HTTPS_PORT}"
	validate_ports_list "$ALLOW_PORTS" || die "--allow-ports 格式不合法: ${ALLOW_PORTS}（应为空格分隔的端口号）"
	if [ -n "$PROBE_SECRET" ]; then
		validate_probe_secret "$PROBE_SECRET" || die "--probe-secret 不合法: ${PROBE_SECRET}（只能小写字母数字与连字符/点，不能大写、不能以点开头）"
	fi
	# 证书与私钥必须成对出现，且要真的配对 —— 否则 caddy 起不来。
	# 与 --check 共用 check_tls_cert_inputs，避免两条路径的覆盖范围再次漂移。
	check_tls_cert_inputs || die "--tls-cert 与 --tls-key 必须同时给出"
	validate_client_proto "$CLIENT_PROTO" \
		|| die "--client-proto 只能是 https 或 quic，收到: ${CLIENT_PROTO}"
	# 会成为 Caddyfile 与文件系统路径的入参。空值一律拒绝 ——
	# 上游 serve_pac 在无参时会退回 /proxy.pac，那是个可预测路径，
	# 开了 probe_resistance 就该避开的正是这种情况，所以宁可报错也不要静默兜底。
	if [ -n "${WEB_ROOT}" ]; then
		validate_path_value "$WEB_ROOT" || die "--web-root 不合法: ${WEB_ROOT}（不能含空格、引号、换行等字符）"
	fi
	if [ -n "${PAC_PATH}" ]; then
		validate_path_value "$PAC_PATH" || die "--serve-pac 不合法: ${PAC_PATH}（应为不含空格与换行的路径，如 /secret-proxy.pac）"
	fi
	if [ -n "$NAIVE_PASS" ]; then
		validate_password "$NAIVE_PASS" || die "密码需 8 位以上纯字母数字（Caddyfile 与 URI 兼容性要求）"
	fi
}

# ---------------- 参数解析 ----------------
# --xxx 后面没跟值时，`shift 2` 会越界。bash 在非 POSIX 模式下
# 越界的 shift 不打印任何消息、只返回 1 —— set -e 于是直接终止脚本。
# 用户拿到的是「stdout 和 stderr 全空、退出码 1」，完全无从判断。
need_value() {
	if [ "$2" -lt 2 ]; then
		die "$1 后面需要一个值（例如 $1 $3）"
	fi
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--domain) need_value "$1" "$#" "example.com"; DOMAIN="$2"; shift 2 ;;
			--domain=*) DOMAIN="${1#*=}"; shift ;;
			--email) need_value "$1" "$#" "you@example.com"; EMAIL="$2"; shift 2 ;;
			--email=*) EMAIL="${1#*=}"; shift ;;
			--user) need_value "$1" "$#" "tom"; NAIVE_USER="$2"; USER_EXPLICIT="yes"; shift 2 ;;
			--user=*) NAIVE_USER="${1#*=}"; USER_EXPLICIT="yes"; shift ;;
			--password) need_value "$1" "$#" "MyPass1234"; NAIVE_PASS="$2"; shift 2 ;;
			--password=*) NAIVE_PASS="${1#*=}"; shift ;;
			--https-port) need_value "$1" "$#" "443"; HTTPS_PORT="$2"; shift 2 ;;
			--https-port=*) HTTPS_PORT="${1#*=}"; shift ;;
			--allow-ports) need_value "$1" "$#" '"80 443"'; ALLOW_PORTS="$2"; shift 2 ;;
			--allow-ports=*) ALLOW_PORTS="${1#*=}"; shift ;;
			--web-root) need_value "$1" "$#" "/var/www/naive-camouflage"; WEB_ROOT="$2"; shift 2 ;;
			--web-root=*) WEB_ROOT="${1#*=}"; shift ;;
			--probe-secret) need_value "$1" "$#" "your-secret.example.com"; PROBE_SECRET="$2"; shift 2 ;;
			--probe-secret=*) PROBE_SECRET="${1#*=}"; shift ;;
			--serve-pac) need_value "$1" "$#" "/secret-proxy.pac"; PAC_PATH="$2"; shift 2 ;;
			--serve-pac=*) PAC_PATH="${1#*=}"; shift ;;
			--client-proto) need_value "$1" "$#" "quic"; CLIENT_PROTO="$2"; shift 2 ;;
			--client-proto=*) CLIENT_PROTO="${1#*=}"; shift ;;
			--tls-cert) need_value "$1" "$#" "/etc/letsencrypt/live/example.com/fullchain.pem"; TLS_CERT_FILE="$2"; shift 2 ;;
			--tls-cert=*) TLS_CERT_FILE="${1#*=}"; shift ;;
			--tls-key) need_value "$1" "$#" "/etc/letsencrypt/live/example.com/privkey.pem"; TLS_KEY_FILE="$2"; shift 2 ;;
			--tls-key=*) TLS_KEY_FILE="${1#*=}"; shift ;;
			--check|--dry-run) CHECK_ONLY="yes"; shift ;;
			--upgrade) MODE="upgrade"; shift ;;
			--reload) RELOAD_ONLY="yes"; shift ;;
			--rotate-password) ROTATE_PASSWORD="yes"; shift ;;
			--collect-diagnostics) DIAGNOSTICS="yes"; shift ;;
			--build-from-source) BUILD_FROM_SRC="yes"; shift ;;
			--force-config) FORCE_CONFIG="yes"; shift ;;
			--skip-verify) SKIP_VERIFY="yes"; shift ;;
			--ascii) ASCII_ONLY="yes"; shift ;;
			-y|--yes) ASSUME_YES="yes"; shift ;;
			--uninstall) MODE="uninstall"; shift ;;
			--purge) PURGE="yes"; shift ;;
			--self-test) SELF_TEST="yes"; shift ;;
			-V|--version) printf '%s\n' "${SCRIPT_VERSION}"; exit 0 ;;
			-h|--help) usage; exit 0 ;;
			--) shift; break ;;
			--*) die "未知参数: $1（试试 --help）" ;;
			*) die "多余的位置参数: $1（试试 --help）" ;;
		esac
	done
	if [ -z "$NAIVE_PASS" ] && [ -n "${NAIVE_PASSWORD:-}" ]; then
		NAIVE_PASS="${NAIVE_PASSWORD}"
	fi
	if [ -z "$NAIVE_USER" ]; then NAIVE_USER="naive"; fi
}

# ---------------- 主流程 ----------------
main() {
	# 无参数 = 引导页。这是用户第一次接触脚本的地方，
	# 不该给他一行红字 + exit 1。
	if [ "$#" -eq 0 ]; then
		setup_glyphs
		print_guide
		return 0
	fi

	parse_args "$@"
	# 伪装目录必须在任何渲染之前定下来（--check 的预览也要用它）
	if [ -z "$WEB_ROOT" ]; then
		WEB_ROOT="$WEB_ROOT_DEFAULT"
	fi
	setup_glyphs

	if [ "$SELF_TEST" = "yes" ]; then
		self_test
		return 0
	fi

	# --check 是只读体检，刻意放在 root 检查之前
	if [ "$CHECK_ONLY" = "yes" ]; then
		if [ -n "$DOMAIN" ] && ! validate_domain "$DOMAIN"; then
			die "域名格式不合法: ${DOMAIN}"
		fi
		if [ -n "$EMAIL" ] && ! validate_email "$EMAIL"; then
			die "邮箱格式不合法: ${EMAIL}"
		fi
		if [ -n "$NAIVE_PASS" ] && ! validate_password "$NAIVE_PASS"; then
			die "密码需 8 位以上纯字母数字"
		fi
		# 端口与白名单也要校：否则 --check 会说"可以部署了"，
		# 接着正式部署立刻被 validate_inputs 拒掉；预览里还会渲染出非法值。
		if ! validate_port "$HTTPS_PORT"; then
			die "端口格式不合法: ${HTTPS_PORT}"
		fi
		if ! validate_ports_list "$ALLOW_PORTS"; then
			die "--allow-ports 格式不合法: ${ALLOW_PORTS}（应为空格分隔的端口号）"
		fi
		if ! validate_user "$NAIVE_USER"; then
			die "用户名只能字母数字下划线，最长 32: ${NAIVE_USER}"
		fi
		# 证书与私钥必须成对，且要真的配对（--check 不调用 validate_inputs，这里要单独校）。
		# 与正式部署共用 check_tls_cert_inputs —— 否则「体检说没问题、部署立刻失败」。
		check_tls_cert_inputs || die "--tls-cert 与 --tls-key 必须同时给出"
		# 本轮新增的入参在 --check 下也必须校一遍，否则体检会:
		#   ① 渲染出一个正式部署必然拒绝的预览（实测 --probe-secret Bad.Example.COM
		#      在预览里原样渲染成 probe_resistance Bad.Example.COM）
		#   ② 打印「可以正式部署了」
		if [ -n "$PROBE_SECRET" ] && ! validate_probe_secret "$PROBE_SECRET"; then
			die "--probe-secret 不合法: ${PROBE_SECRET}（只能小写字母数字与连字符/点，不能大写、不能以点开头）"
		fi
		if ! validate_client_proto "$CLIENT_PROTO"; then
			die "--client-proto 只能是 https 或 quic，收到: ${CLIENT_PROTO}"
		fi
		if [ -n "$PAC_PATH" ] && ! validate_path_value "$PAC_PATH"; then
			die "--serve-pac 不合法: ${PAC_PATH}（应为不含空格与换行的路径，如 /secret-proxy.pac）"
		fi
		if ! validate_path_value "$WEB_ROOT"; then
			die "--web-root 不合法: ${WEB_ROOT}（不能含空格、引号、换行等字符）"
		fi
		do_check
		return 0
	fi

	# 求助诊断：不强制 root（拿不全也比拿不到强）
	if [ "$DIAGNOSTICS" = "yes" ]; then
		do_collect_diagnostics
		return 0
	fi

	# 参数问题必须先于权限问题告诉用户。
	# 否则「你少写了 --domain」会被显示成「你没有 root 权限」，
	# 用户就会跑去加 sudo，然后被同一句话拦第二次。
	if [ "$MODE" = "install" ] && [ "$ROTATE_PASSWORD" = "no" ] && [ "$RELOAD_ONLY" = "no" ]; then
		validate_inputs
	fi

	require_root
	detect_os
	# detect_arch 必须在这里调：正常安装路径靠 preflight 调到它，
	# 但 --upgrade / --reload / --rotate-password 都不走 preflight。
	# 漏了它 ARCH 就是空串，install_caddy_binary 会把空串判成"非 x86_64"，
	# 于是本该下载预编译包的机器跑去源码编译。
	detect_arch

	if [ "$ROTATE_PASSWORD" = "yes" ]; then do_rotate_password; return 0; fi
	if [ "$RELOAD_ONLY" = "yes" ]; then do_reload; return 0; fi
	if [ "$MODE" = "uninstall" ]; then do_uninstall; return 0; fi
	if [ "$MODE" = "upgrade" ]; then do_upgrade; return 0; fi

	# ---------------- 正式部署 ----------------
	preflight || exit 1

	run_stage 1 install_deps
	run_stage 2 install_caddy_binary
	run_stage 3 setup_user_and_dirs
	run_stage 4 write_config
	run_stage 5 write_camouflage_site
	run_stage 6 install_service
	run_stage 7 verify_deployment
	print_summary
}

# ---------------- 自检用的顶层辅助 ----------------
# 取源码里某个函数的函数体，用于结构性断言（放顶层，供多个辅助函数复用）
fn_body() {
	# 不能简单地"遇到列首 } 就结束"：渲染器的 heredoc 里就含列首的 }，
	# 那样会把函数体腰斩，断言就在残缺的文本上悄悄变成空断言
	# （曾因此让一条断言永远匹配不上，等于没测）。
	# 所以这里跟 bash 一样跟踪 heredoc 状态：只有不在 heredoc 里时，
	# 列首的 } 才算函数结束。
	awk -v fn="$1" '
		function hd_open(line, s) {
			if (match(line, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
				s = substr(line, RSTART, RLENGTH)
				gsub(/<<-?[ \t]*/, "", s)
				gsub(/[\047"]/, "", s)
				return s
			}
			return ""
		}
		$0 ~ "^" fn "\\(\\)" { inside = 1 }
		!inside { next }
		{
			if (hd != "") {
				print
				if ($0 == hd) { hd = "" }
				next
			}
			print
			d = hd_open($0)
			if (d != "") { hd = d; next }
			if ($0 ~ /^\}[[:space:]]*$/) { exit }
		}
	' "$0"
}

# 行为级验证：run_stage 必须把真实的退出码传给 fail_stage。
# 曾经的写法（在 fi 之后再取 $?）永远传到 0 —— 那是假信息，比不显示更糟。
# 这条断言是行为级的：真的跑一次失败阶段，看输出里的数字。
stage_rc_propagates() {
	local lib="" out="" rc=0
	lib=$(mktemp) || return 1
	grep -vxF 'main "$@"' "$0" > "$lib" || { rm -f "$lib"; return 1; }
	out=$(bash -c '
		source "$1"
		stub_failing_stage() { return 7; }
		run_stage 1 stub_failing_stage
	' _ "$lib" 2>&1) || rc=$?
	rm -f "$lib"
	if printf '%s' "$out" | grep -q '退出码 7'; then
		return 0
	fi
	printf '  期望失败信息里出现「退出码 7」。实际输出：
%s
' "$out" >&2
	return 1
}

# 阶段函数必须用 `err … ; return 1` 传递失败；用 die 会 exit 并绕开 fail_stage。
no_bare_die_in_stages() {
	local fn="" body=""
	for fn in install_deps install_caddy_binary build_from_source setup_user_and_dirs \
	          write_config write_camouflage_site install_service verify_deployment; do
		body=$(fn_body "$fn")
		if printf '%s' "$body" | grep -qE '(^|[^a-z_])die[[:space:]]+"'; then
			printf '  阶段函数 %s 里出现了 die（会 exit 并绕开 fail_stage）\n' "$fn" >&2
			return 1
		fi
		if ! printf '%s' "$body" | grep -q .; then
			printf '  取不到阶段函数 %s 的函数体（fn_body 解析失败）\n' "$fn" >&2
			return 1
		fi
	done
	return 0
}
# ---------------- 开发者自检 ----------------
is_valid_json() {
	local py="$1" text="$2"
	printf '%s' "$text" | "$py" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
}

test_not_exists() { [ ! -e "$1" ]; }

# 状态文件绝不能再被 source（那是把数据当代码执行）。
# 注意这里的正则写在 grep 的参数里，而本行以 `hits=` 开头 —— 不会自匹配。
cannot_find_source() {
	local hits=""
	hits=$(grep -nE '^[[:space:]]*\.[[:space:]]+"?\$\{STATE_FILE\}"?' "$0" 2>/dev/null || true)
	if [ -n "$hits" ]; then
		printf '  源码里仍有 source 状态文件的写法：\n%s\n' "$hits" >&2
		return 1
	fi
	return 0
}

# 渲染器必须静默。不带引号的 heredoc 里，反引号和 $( ) 都会被求值 ——
# 曾经在 openrc 模板的注释里写了反引号，结果渲染时真的去跑了那条命令。
renderers_silent() {
	local lib="" out="" rc=0
	lib=$(mktemp) || return 1
	grep -vxF 'main "$@"' "$0" > "$lib" || { rm -f "$lib"; return 1; }
	out=$(bash -c '
		. "$1"
		render_log_block >/dev/null
		render_openrc_script >/dev/null
		render_systemd_unit >/dev/null
		render_client_config u Aa12345678 a.b.c 443 >/dev/null
	' _ "$lib" 2>&1) || rc=$?
	rm -f "$lib"
	if [ -n "$out" ]; then
		printf '  渲染时产生了意外输出（heredoc 里的命令替换被执行了？）：\n%s\n' "$out" >&2
		return 1
	fi
	return 0
}

# stage_advice 7 曾断言「服务已经在跑了」，而 verify_deployment 有一个
# 「服务没起来 → 整个阶段判失败」的分支 —— 两者直接矛盾。
stage7_advice_honest() {
	local body=""
	body=$(fn_body stage_advice)
	if printf '%s' "$body" | grep -q '服务已经在跑了'; then
		printf '  stage_advice 7 仍在断言「服务已经在跑了」，与阶段 7 的失败分支矛盾\n' >&2
		return 1
	fi
	if ! printf '%s' "$body" | grep -q '服务压根没起来'; then
		printf '  stage_advice 7 的措辞未更新（应为中性描述）\n' >&2
		return 1
	fi
	return 0
}

self_test() {
	local pass=0 fail=0 skip=0 rc=0

	true_case() {
		local name="$1"; shift
		if "$@" >/dev/null 2>&1; then
			printf '  %sPASS%s %s\n' "$C_GRN" "$C_RST" "$name"; pass=$((pass + 1))
		else
			rc=$?
			printf '  %sFAIL%s %s（期望 0，实得 %s）\n' "$C_RED" "$C_RST" "$name" "$rc"; fail=$((fail + 1))
		fi
	}

	false_case() {
		local name="$1"; shift
		if "$@" >/dev/null 2>&1; then
			printf '  %sFAIL%s %s（期望非 0，实得 0）\n' "$C_RED" "$C_RST" "$name"; fail=$((fail + 1))
		else
			printf '  %sPASS%s %s\n' "$C_GRN" "$C_RST" "$name"; pass=$((pass + 1))
		fi
	}

	eq_case() {
		if [ "$2" = "$3" ]; then
			printf '  %sPASS%s %s\n' "$C_GRN" "$C_RST" "$1"; pass=$((pass + 1))
		else
			printf '  %sFAIL%s %s（期望 %s，实得 %s）\n' "$C_RED" "$C_RST" "$1" "$2" "$3"; fail=$((fail + 1))
		fi
	}

	has() { printf '%s' "$1" | grep -qE "$2"; }

	skip_case() { printf '  %sSKIP%s %s\n' "$C_YEL" "$C_RST" "$1"; skip=$((skip + 1)); }

	brace_l() { printf '%s' "$1" | tr -cd '{' | wc -c | tr -d ' '; }
	brace_r() { printf '%s' "$1" | tr -cd '}' | wc -c | tr -d ' '; }

	tab_indent_ok() { printf '%s' "$1" | grep -q "^$(printf '\t')"; }


	printf '%s\n' "离线自检 v${SCRIPT_VERSION}（无需 root，不修改系统）"

	printf '\n[1] 语法与依赖\n'
	true_case "bash -n 通过" bash -n "$0"
	true_case "curl 可用" command -v curl
	true_case "本文件有可执行位" test -x "$0"

	printf '\n[2] 密码生成\n'
	local p1="" p2=""
	p1=$(gen_password 28)
	p2=$(gen_password 28)
	eq_case "默认长度 28" "28" "${#p1}"
	eq_case "可指定长度 12" "12" "$(gen_password 12 | wc -c | tr -d ' ')"
	true_case "仅含字母数字" has "$p1" '^[A-Za-z0-9]+$'
	if [ "$p1" != "$p2" ]; then
		printf '  %sPASS%s 两次生成不重复\n' "$C_GRN" "$C_RST"; pass=$((pass + 1))
	else
		printf '  %sFAIL%s 两次生成不重复\n' "$C_RED" "$C_RST"; fail=$((fail + 1))
	fi
	true_case "生成结果能通过密码校验" validate_password "$p1"

	printf '\n[3] 校验函数 · 应当接受\n'
	true_case "正常域名" validate_domain proxy.example.com
	true_case "多级域名" validate_domain a.b.c.example.co.uk
	true_case "带连字符域名" validate_domain my-proxy.example.com
	true_case "正常用户名" validate_user naive01
	true_case "下划线用户名" validate_user naive_user
	true_case "正常邮箱" validate_email ops@mail.test
	true_case "带点邮箱" validate_email first.last@mail.test
	true_case "端口 443" validate_port 443
	true_case "端口 8443" validate_port 8443
	true_case "8 位密码" validate_password Abcd1234
	true_case "端口白名单留空" validate_ports_list ""
	true_case "端口白名单单项" validate_ports_list "443"
	true_case "端口白名单多项" validate_ports_list "80 443"

	printf '\n[4] 校验函数 · 应当拒绝\n'
	false_case "空域名" validate_domain ""
	false_case "带协议头" validate_domain "https://a.example.com"
	false_case "含路径斜杠" validate_domain "a.example.com/x"
	false_case "单 label" validate_domain localhost
	false_case "纯数字 TLD" validate_domain "a.123"
	false_case "64 字符 label" validate_domain "$(printf 'a%.0s' $(seq 1 64)).com"
	false_case "前导点" validate_domain ".example.com"
	false_case "含空格域名" validate_domain "a b.example.com"
	false_case "含问号域名" validate_domain "a.example.com?x=1"
	false_case "空用户名" validate_user ""
	false_case "含空格用户名" validate_user "a b"
	false_case "含双引号用户名" validate_user 'a"b'
	false_case "含斜杠用户名" validate_user "a/b"
	false_case "33 字符用户名" validate_user "$(printf 'a%.0s' $(seq 1 33))"
	false_case "无 @ 邮箱" validate_email ab.com
	false_case "空邮箱" validate_email ""
	false_case "邮箱含空格" validate_email "a b@mail.test"
	false_case "端口 0" validate_port 0
	false_case "端口 70000" validate_port 70000
	false_case "端口非数字" validate_port abc
	false_case "7 位密码" validate_password Abcd123
	false_case "含特殊字符密码" validate_password 'Abcd1234#'
	false_case "含空格密码" validate_password 'Abcd 1234'
	false_case "端口白名单含字母" validate_ports_list "80 abc"
	false_case "端口白名单含分号" validate_ports_list "80;443"
	false_case "端口白名单含逗号" validate_ports_list "80,443"
	false_case "端口白名单越界" validate_ports_list "80 70000"
	printf '\n[5] Caddyfile 渲染\n'
	local r="" rl=""
	r=$(render_caddyfile example.com ops@mail.test tom Abcd1234 443)
	true_case "含 order forward_proxy" has "$r" 'order forward_proxy before file_server'
	true_case "443 写在域名之前" has "$r" '^:443, example\.com \{'
	true_case "含 tls 邮箱" has "$r" 'tls ops@mail\.test'
	true_case "含 probe_resistance" has "$r" 'probe_resistance'
	true_case "含 hide_ip" has "$r" 'hide_ip'
	true_case "含 hide_via" has "$r" 'hide_via'
	true_case "凭据正确注入" has "$r" 'basic_auth tom Abcd1234'
	true_case "含 file_server 伪装" has "$r" 'file_server'
	true_case "日志轮转 roll_size" has "$r" 'roll_size 20MiB'
	true_case "日志轮转 roll_keep_for" has "$r" 'roll_keep_for 168h'
	true_case "排除错误日志" has "$r" 'exclude http\.log\.error'
	true_case "缩进用制表符" tab_indent_ok "$r"
	eq_case "Caddyfile 花括号配平" "$(brace_l "$r")" "$(brace_r "$r")"
	# 端口语义：非 443 时域名后也必须带端口。
	# 实测（官方 caddy adapt）：`:8443, d.com` 会同时监听 :443 和 :8443 ——
	# 那等于 --https-port 白设，还会去占用户想避开的 443。
	true_case "443 时域名不带端口" has "$(render_caddyfile a.example.com ops@mail.test u Abcd1234 443)" '^:443, a\.example\.com \{'
	true_case "非 443 时域名带上端口" has "$(render_caddyfile a.example.com ops@mail.test u Abcd1234 8443)" '^:8443, a\.example\.com:8443 \{'
	true_case "端口白名单渲染为真制表符" has "$(render_caddyfile a.example.com ops@mail.test u Abcd1234 443 '80 443')" "$(printf '\t\t')ports 80 443"
	false_case "未启用白名单时无 ports 行" has "$r" 'ports '
	rl=$(render_log_block)
	true_case "日志块含 roll_keep" has "$rl" 'roll_keep 5'
	eq_case "日志块花括号配平" "$(brace_l "$rl")" "$(brace_r "$rl")"

	printf '\n[6] 客户端配置\n'
	local cj=""
	cj=$(render_client_config tom Abcd1234 example.com 443)
	true_case "443 时保留裸域名" has "$cj" 'example\.com"'
	true_case "listen 指向本地 socks5" has "$cj" '"listen": "socks://127\.0\.0\.1:1080"'
	true_case "端口非 443 时拼接" has "$(render_client_config u Abcd1234 example.com 8443)" 'example\.com:8443'
	true_case "凭据拼进 URI" has "$cj" 'https://tom:Abcd1234@example\.com'
	local PYC="" c=""
	for c in python3 python; do
		if command -v "$c" >/dev/null 2>&1 && printf '{}' | "$c" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
			PYC="$c"; break
		fi
	done
	if [ -n "$PYC" ]; then
		true_case "生成的是合法 JSON" is_valid_json "$PYC" "$cj"
	else
		skip_case "合法 JSON 校验（本机无可用 python）"
	fi

	printf '\n[7] 服务单元\n'
	local u="" oc=""
	u=$(render_systemd_unit)
	true_case "Type=notify" has "$u" '^Type=notify$'
	true_case "Restart=on-failure" has "$u" '^Restart=on-failure$'
	true_case "RestartSec 存在" has "$u" '^RestartSec=2s$'
	true_case "AmbientCapabilities 已授权" has "$u" 'AmbientCapabilities=CAP_NET_BIND_SERVICE'
	true_case "ProtectHome" has "$u" '^ProtectHome=true$'
	true_case "NoNewPrivileges" has "$u" '^NoNewPrivileges=true$'
	true_case "LimitNOFILE" has "$u" '^LimitNOFILE=1048576$'
	true_case "ExecReload 可重载" has "$u" '^ExecReload='
	true_case "[Install] 段存在" has "$u" 'WantedBy=multi-user\.target'
	oc=$(render_openrc_script)
	true_case "openrc 脚本含 shebang" has "$oc" '^#!/sbin/openrc-run$'
	true_case "openrc 保留运行时变量" has "$oc" 'RC_SVCNAME'

	printf '\n[8] 阶段表一致性（编号断层曾是真 bug）\n'
	eq_case "TOTAL_STAGES 等于阶段名数量" "$TOTAL_STAGES" "${#STAGE_NAMES[@]}"
	eq_case "提示数与阶段数一致" "${#STAGE_NAMES[@]}" "${#STAGE_HINT[@]}"
	eq_case "阶段数是 7" "7" "$TOTAL_STAGES"
	local i="" stages_uniq=""
	stages_uniq=$(printf '%s\n' "${STAGE_NAMES[@]}" | sort -u | wc -l | tr -d ' ')
	eq_case "阶段名无重复" "${#STAGE_NAMES[@]}" "$stages_uniq"
	true_case "阶段标题编号由 TOTAL_STAGES 推导（不会再漂移）" has "$(fn_body stage_banner)" 'TOTAL_STAGES'
	# 模式用变量拼出来，免得这行测试自己把要搜的字符串写进源码里（自指）
	local steppat="ste"
	steppat="${steppat}p \""
	false_case "不再用 step 打印阶段标题" grep -q "$steppat" "$0"
	local tab=""
	tab=$(printf '\t')
	for i in 1 2 3 4 5 6 7; do
		true_case "stage_advice 覆盖第 ${i} 步" has "$(fn_body stage_advice)" "^${tab}${i}) cat"
	done

	printf '\n[9] 失败出口\n'
	local fb=""
	fb=$(fn_body fail_stage)
	true_case "失败时给当前状态快照" has "$fb" '当前状态'
	true_case "失败时给求助命令" has "$fb" 'collect-diagnostics'
	true_case "说明重跑是安全的" has "$fb" '重跑是安全的'
	false_case "不再用 journalctl 兜底所有阶段" has "$fb" 'journalctl'
	false_case "不再误导到 access.log" has "$fb" 'access\.log'
	true_case "run_stage 已定义" command -v run_stage
	true_case "gather_state 已定义" command -v gather_state
	true_case "没有全局 ERR trap" has "$(grep -n '^trap ' "$0")" '^[0-9]+:trap cleanup EXIT$'
	true_case "阶段内不用裸 die（会用 exit 绕开失败处理）" no_bare_die_in_stages
	true_case "阶段失败的退出码会真实传递（曾会假报 0）" stage_rc_propagates

	printf '\n[10] 用户可见行为\n'
	true_case "--version 正常退出" bash "$0" --version
	true_case "--help 正常退出" bash "$0" --help
	true_case "--help 含新手三步" has "$(bash "$0" --help)" '后悔药'
	true_case "--help 收录 NAIVE_PASSWORD 用法" has "$(bash "$0" --help)" 'NAIVE_PASSWORD'
	false_case "未知参数被拒" bash "$0" --not-a-flag
	false_case "多余位置参数被拒" bash "$0" junk
	false_case "缺 --domain 被拒" bash "$0" --email ops@mail.test
	false_case "缺 --email 被拒" bash "$0" --domain a.example.com
	false_case "非法域名被拒" bash "$0" --domain 'https://a.example.com' --email ops@mail.test
	false_case "非法端口被拒" bash "$0" --domain a.example.com --email ops@mail.test --https-port 99999
	false_case "非法用户名被拒" bash "$0" --domain a.example.com --email ops@mail.test --user 'a b'
	false_case "非法密码被拒" bash "$0" --domain a.example.com --email ops@mail.test --password 'short'
	if [ "$(id -u)" -ne 0 ]; then
		false_case "非 root 安装被拦" bash "$0" --domain a.example.com --email ops@mail.test --yes
	else
		skip_case "非 root 拦截（当前是 root）"
	fi

	printf '\n[11] 只读性与诚实性（这几条对应修掉的 bug）\n'
	local out="" before="" after=""
	out=$(bash "$0" 2>&1 || true)
	true_case "无参数进入引导页" has "$out" '① 先体检'
	true_case "无参数不报错" bash "$0"

	before=$(find "${CONF_DIR}" "${CADDY_BIN}" -maxdepth 1 2>/dev/null | sort | tr '\n' ' ' || true)
	out=$(bash "$0" --check --domain a.example.com --email ops@mail.test 2>&1 || true)
	true_case "--check 无需 root 即可完成" bash "$0" --check --domain a.example.com --email ops@mail.test
	true_case "--check 输出体检结论" has "$out" '结论'
	false_case "--check 不凭空生成密码（曾会打印一个假密码）" has "$out" '已自动生成'
	true_case "--check 密码位置显示占位符" has "$out" '部署时自动生成'
	false_case "--check 不打印任何真实密码形态" has "$out" 'basic_auth tom [A-Za-z0-9]{8,}'
	local aout=""
	aout=$(NAIVE_ASCII=1 bash "$0" --check --domain a.example.com 2>&1 || true)
	true_case "ASCII 模式可用（老终端兜底）" env NAIVE_ASCII=1 bash "$0" --check --domain a.example.com
	false_case "ASCII 模式下不出现 UTF-8 标记" has "$aout" '✓'
	# 断言必须绑在"与外部工具无关"的字形上：
	# 之前绑的是 "+ 端口 …空闲"，而端口探测改成三态后，
	# 没有 ss 的机器会输出"无法判定"，这个断言就白红了。
	true_case "ASCII 模式下字形已替换（段落标记）" has "$aout" '> 体检'
	true_case "ASCII 模式下字形已替换（条目前缀）" has "$aout" '^  ! |^  - |^  \+ '
	true_case "--check 未创建状态文件" test_not_exists "${STATE_FILE}"
	true_case "--check 未创建客户端配置" test_not_exists "${CLIENT_CONF}"
	after=$(find "${CONF_DIR}" "${CADDY_BIN}" -maxdepth 1 2>/dev/null | sort | tr '\n' ' ' || true)
	eq_case "--check 没改动系统" "$before" "$after"

	printf '\n[12] 敏感信息与破坏性操作\n'
	local cb="" ub="" pb=""
	cb=$(fn_body confirm)
	true_case "取消退出码是 0（取消不是错误）" has "$cb" 'exit 0'
	false_case "取消不再走 die" has "$cb" 'die '
	ub=$(fn_body do_uninstall)
	true_case "--purge 需要二次确认" has "$ub" 'confirm'
	pb=$(fn_body check_ports_free)
	true_case "预检包含 80 端口" has "$pb" '"80"'
	true_case "mask_conf_password 已定义" command -v mask_conf_password
	true_case "摘要里有密码找回途径" has "$(fn_body print_summary)" 'STATE_FILE'
	true_case "摘要把安全组标为必做" has "$(fn_body print_summary)" '必做'

	printf '\n[13] 输入加固（换行 / 引号 / 分号注入）\n'
	false_case "邮箱含单引号被拒" validate_email "$(printf '%s' "o'brien@mail.test")"
	false_case "邮箱含分号被拒" validate_email "a;b@mail.test"
	false_case "邮箱含竖线被拒" validate_email "a|b@mail.test"
	false_case "邮箱含斜杠被拒" validate_email "a/b@mail.test"
	true_case "正常邮箱仍被接受" validate_email ops@mail.test
	true_case "带点带加号邮箱被接受" validate_email first.last+tag@mail.test
	false_case "域名含换行被拒" validate_domain "$(printf 'a.example.com\nx')"
	false_case "端口含换行被拒" validate_port "$(printf '443\n9')"
	false_case "用户名含换行被拒" validate_user "$(printf 'tom\nx')"
	false_case "密码含换行被拒" validate_password "$(printf 'Aa12345678\nx')"
	false_case "端口白名单含换行被拒" validate_ports_list "$(printf '80\n443')"

	printf '\n[14] 状态文件往返与注入抵抗\n'
	local saved_state="${STATE_FILE}" tdir=""
	tdir=$(mktemp -d)
	STATE_FILE="${tdir}/state"

	DOMAIN="a.example.com"; EMAIL="ops@mail.test"; NAIVE_USER="tom"
	NAIVE_PASS="Aa12345678"; HTTPS_PORT="8443"; ALLOW_PORTS="80 443"
	state_write
	true_case "状态文件已写入" test -s "${STATE_FILE}"

	DOMAIN=""; EMAIL=""; NAIVE_USER=""; NAIVE_PASS=""; HTTPS_PORT=""; ALLOW_PORTS=""
	state_parse_into_vars
	eq_case "往返：域名" "a.example.com" "${STATE_DOMAIN}"
	eq_case "往返：邮箱" "ops@mail.test" "${STATE_EMAIL}"
	eq_case "往返：用户名" "tom" "${STATE_USER}"
	eq_case "往返：密码" "Aa12345678" "${STATE_PASS}"
	eq_case "往返：端口" "8443" "${STATE_PORT}"
	eq_case "往返：端口白名单" "80 443" "${STATE_ALLOW_PORTS}"
	true_case "往返后仍通过再校验" state_revalidate

	# 核心断言：手写一个含 payload 的状态文件。
	# 早先这里用的是 source，读它的那一刻就会以 root 执行里面的命令。
	local pwned="${tdir}/PWNED_MARKER"
	printf "STATE_DOMAIN=a.example.com\nSTATE_EMAIL=';touch %s;echo'@mail.test\nSTATE_USER=tom\nSTATE_PASS=Aa12345678\nSTATE_PORT=443\nSTATE_ALLOW_PORTS=\n" "$pwned" > "${STATE_FILE}"
	state_parse_into_vars
	true_case "恶意状态文件不会被求值执行" test_not_exists "$pwned"
	false_case "恶意值被再校验拦下" state_revalidate

	# 兼容早期写成 STATE_X='value' 的格式
	printf "STATE_DOMAIN='b.example.com'\nSTATE_USER='tom'\nSTATE_PASS='Aa12345678'\nSTATE_PORT='443'\n" > "${STATE_FILE}"
	state_parse_into_vars
	eq_case "兼容旧格式（剥一层引号）" "b.example.com" "${STATE_DOMAIN}"

	# 损坏/被截断的状态文件不应让脚本崩掉
	printf 'STATE_DOMAIN=' > "${STATE_FILE}"
	state_parse_into_vars
	eq_case "截断文件解析为空值" "" "${STATE_DOMAIN}"
	false_case "截断文件在再校验时被拦下" state_revalidate

	rm -rf "${tdir}"
	STATE_FILE="${saved_state}"

	printf '\n[15] 第二轮评审修复的锁定断言\n'
	printf '\n[16] 官方文档对齐（probe-secret / serve_pac / quic）\n'
	# 证书权限：certbot 把 archive/ 放成 root:root 0700，caddy 以非特权用户运行会读不到
	# 真机实测：直接 permission denied + 崩溃重启
	true_case "有证书可读性检查函数" command -v ensure_cert_readable
	true_case "检查以 caddy 用户能否真读到为准" has "$(fn_body ensure_cert_readable)" 'runuser -u caddy'
	true_case "会自动放开 letsencrypt 目录" has "$(fn_body ensure_cert_readable)" 'letsencrypt/archive'
	true_case "启动服务前调用权限修复" has "$(fn_body install_service)" 'ensure_cert_readable'
	true_case "配对校验用 pubkey 比对（兼容 ECDSA）" has "$(fn_body validate_tls_cert_pair)" 'x509 -noout -pubkey'
	false_case "配对校验不再执行 openssl rsa（ECDSA 会误判）" has "$(fn_body validate_tls_cert_pair)" '[|] openssl rsa'
	# --tls-cert / --tls-key：复用现成证书，零 ACME 额度消耗
	# （真机踩过 429 rateLimit：同一域名每周上限 5 张）
	true_case "默认走 ACME 申请" has "$(render_caddyfile a.example.com ops@m.test u Pw12345678 443)" 'tls ops@m\.test'
	true_case "给证书文件时改用文件" has "$(render_caddyfile a.example.com ops@m.test u Pw12345678 443 '' '' '' /tmp/c.pem /tmp/k.pem)" 'tls /tmp/c[.]pem /tmp/k[.]pem'
	true_case "证书与私钥必须成对" has "$(fn_body validate_inputs)" 'tls-cert 与 --tls-key 必须同时给出'
	true_case "--check 也校验证书成对" has "$(fn_body main)" 'tls-cert 与 --tls-key 必须同时给出'
	true_case "证书配对校验函数存在" command -v validate_tls_cert_pair
	true_case "状态文件保存证书路径" has "$(fn_body state_write)" 'STATE_TLS_CERT'
	true_case "帮助收录 --tls-cert" has "$(bash "$0" --help)" 'tls-cert'
	# Caddyfile 里不能出现 shell 语法 —— 这条断言防的是「把 if/else 写进 heredoc」
	false_case "渲染结果里没有 shell 的 if" has "$(render_caddyfile a.example.com ops@m.test u Pw12345678 443)" '^[[:space:]]*if '
	false_case "渲染结果里没有 fi" has "$(render_caddyfile a.example.com ops@m.test u Pw12345678 443)" '^[[:space:]]*fi$'
	# 秘密域名必须能被解析 —— 否则 TLS 握手失败，用户拿到一个访问就报错的地址
	true_case "预检会检查秘密域名解析" has "$(fn_body preflight)" 'check_probe_secret_dns'
	true_case "秘密域名检查在无 secret 时短路" has "$(fn_body check_probe_secret_dns)" 'return 0'
	true_case "秘密域名检查会做解析" has "$(fn_body check_probe_secret_dns)" 'resolve_domain_ip'
	# PAC 只在秘密域名上可取（真机实测：主域名 404，秘密域名 200）
	true_case "PAC 提示走秘密域名分支" has "$(fn_body print_summary)" 'PAC 文件'
	true_case "PAC 提示会提到 secret location" has "$(fn_body print_summary)" 'secret location'
	# probe_resistance 的秘密域名 —— 上游文档规定「只有这个地址触发 407」。
	# 裸写等于用随机值，用户无从得知自己的秘密链接，文档给的补救路径就断了。
	local rr="" rr2=""
	rr=$(render_caddyfile a.example.com o@m.test u Pw12345678 443 '' sec.example.com)
	true_case "指定 secret 时渲染出秘密域名" has "$rr" 'probe_resistance sec[.]example[.]com'
	true_case "secret 用真制表符缩进" has "$rr" "$(printf '\t\t')probe_resistance"
	rr2=$(render_caddyfile a.example.com o@m.test u Pw12345678 443)
	true_case "不指定时退化为裸 probe_resistance" has "$rr2" 'probe_resistance$'
	true_case "serve_pac 可渲染" has "$(render_caddyfile a.example.com o@m.test u Pw12345678 443 '' '' /secret-proxy.pac)" 'serve_pac /secret-proxy[.]pac'

	# 文档对秘密域名的两条硬要求：不许大写、不许以点开头
	true_case "合法 secret 通过" validate_probe_secret ok.example.com
	false_case "拒绝大写 secret（文档明确要求）" validate_probe_secret Up.Example.com
	false_case "拒绝前导点 secret（文档明确要求）" validate_probe_secret .example.com
	false_case "拒绝空 secret" validate_probe_secret ''
	false_case "拒绝带斜杠的 secret" validate_probe_secret 'a/b.com'

	# 客户端协议（上游 USAGE.txt: PROXY-PROTO = http | https | quic）
	true_case "客户端默认 https" has "$(render_client_config u Pw12345678 a.example.com 443)" 'https://'
	true_case "可切到 quic" has "$(render_client_config u Pw12345678 a.example.com 443 quic)" 'quic://'
	false_case "非法协议回退 https（不产生怪方案名）" has "$(render_client_config u Pw12345678 a.example.com 443 bogus)" 'bogus://'

	# 选项、状态文件、摘要的贯通性
	true_case "帮助收录 --probe-secret" has "$(bash "$0" --help)" 'probe-secret'
	true_case "帮助收录 --serve-pac" has "$(bash "$0" --help)" 'serve-pac'
	true_case "帮助收录 --client-proto" has "$(bash "$0" --help)" 'client-proto'
	true_case "状态文件保存 secret" has "$(fn_body state_write)" 'STATE_PROBE_SECRET'
	true_case "状态恢复时再校验 secret" has "$(fn_body state_revalidate)" 'validate_probe_secret'
	true_case "摘要里说明秘密链接" has "$(fn_body print_summary)" 'PROBE_SECRET'
	true_case "摘要提示 host-resolver-rules" has "$(fn_body print_summary)" 'host-resolver-rules'
	true_case "--check 的预览也带 secret" has "$(fn_body do_check)" 'PROBE_SECRET'
	true_case "跳过验证不谎称通过" has "$(fn_body print_summary)" 'VERIFY_SKIPPED'
	false_case "代理判据不再只看状态码" has "$(fn_body verify_deployment)" 'via" = "200"'
	true_case "代理判据改为断言响应内容" has "$(fn_body verify_deployment)" 'ip='
	true_case "下载会校验 sha256" has "$(fn_body install_caddy_binary)" 'resolve_caddy_digest'
	true_case "校验失败会中止安装" has "$(fn_body install_caddy_binary)" '下载校验失败'
	true_case "fmt 只在内容变化时才写回" has "$(fn_body write_config)" 'cmp -s'
	# 先剥掉注释行：注释里提到这个词是允许的，命令行才算
	local wc_nc=""
	wc_nc=$(fn_body write_config | grep -v '^[[:space:]]*#' || true)
	false_case "不再无条件 fmt --overwrite" has "$wc_nc" 'fmt --overwrite'
	true_case "预检始终检查 443" has "$(fn_body check_ports_free)" '"443"'
	true_case "体检也始终检查 443" has "$(fn_body do_check)" '"443"'
	true_case "伪装目录默认不在 /var/www/html" has "$(grep -m1 '^WEB_ROOT_DEFAULT=' "$0")" 'naive-camouflage'
	true_case "拒绝接管别人的目录" has "$(fn_body write_camouflage_site)" 'dir_has_foreign_content'
	true_case "purge 不无条件删伪装目录" has "$(fn_body do_uninstall)" 'dir_has_foreign_content'
	true_case "--help 收录 --web-root" has "$(bash "$0" --help)" 'web-root'
	# 不写 \${...}：${ 在 grep -E 里是元字符，写错就永远匹配不上（等于没测）
	true_case "渲染器用 WEB_ROOT 变量而非硬编码路径" has "$(fn_body render_caddyfile)" 'WEB_ROOT'
	true_case "渲染器确实渲染出了 root 指令" has "$(fn_body render_caddyfile)" '^[[:space:]]*root '
	# WEB_ROOT 由 main 解析，但渲染器不该依赖调用顺序：空值会渲染出非法的 `root `
	true_case "WEB_ROOT 为空时渲染器自我兜底" has "$(fn_body render_caddyfile)" 'WEB_ROOT_DEFAULT'
	false_case "渲染器里没有硬编码 /var/www/html" has "$(fn_body render_caddyfile)" '/var/www/html'
	local out=""
	out=$(bash "$0" --domain 2>&1 || true)
	true_case "选项缺值会给出人话（曾静默 exit 1）" has "$out" '需要一个值'
	true_case "选项缺值提示出现在源码所用函数中" has "$(fn_body need_value)" 'die'
	true_case "main 里调用了 detect_arch（--upgrade 曾漏调）" has "$(fn_body main)" 'detect_arch'
	true_case "install_caddy_binary 对空 ARCH 自保" has "$(fn_body install_caddy_binary)" 'detect_arch'
	true_case "端口探测是三态函数" command -v port_state
	true_case "端口无法判定时不冒充空闲" has "$(fn_body port_state)" 'unknown'
	true_case "状态读取不再使用 source" cannot_find_source
	true_case "渲染器全程静默（heredoc 无意外命令替换）" renderers_silent
	true_case "openrc 脚本定义了 reload()" has "$(render_openrc_script)" '^reload\(\) \{'
	true_case "openrc reload 保留 \$? 到运行时" has "$(render_openrc_script)" 'eend \$\?'
	true_case "覆盖服务单元前会备份" has "$(fn_body install_service)" 'backup_if_exists'
	true_case "阶段 7 的建议不再自相矛盾" stage7_advice_honest
	true_case "日志不可写时不再沉默" has "$(fn_body show_log_tail)" 'DEPLOY_LOG_OK'
	true_case "rotate 不再声称未发生的回滚" has "$(fn_body do_rotate_password)" '原配置未做任何改动'
	# 只针对 die 消息里的断言 —— 注释里提到这个词是允许的
	false_case "rotate 的 die 消息不再谎称已回滚" has "$(fn_body do_rotate_password)" 'die "[^"]*已回滚'

	printf '\n[17] 第三轮审计修复的锁定断言（路径入参注入 / 校验覆盖漂移）\n'
	# 根因：--serve-pac 与 --web-root 的值是按行插进 heredoc 的，却从来没有校验器。
	# 实测渲染出来的注入：
	#   --serve-pac $'/p.pac\n\t\tdisable_insecure_upstreams_check'
	#   --web-root  $'/x\n\t}\n\trespond "pwned" 200\n\tfile_server {\n\t\troot /tmp'
	# --web-root 里的反斜杠还有第二个后果：remove_local_hosts_hack 的 sed 会被
	# 转义打乱，临时加进 /etc/hosts 的那行清不掉，永久留在用户机器上。
	true_case "路径校验器已定义" command -v validate_path_value
	true_case "接受绝对路径" validate_path_value /secret-proxy.pac
	true_case "接受多级目录" validate_path_value /var/www/naive-camouflage
	true_case "接受证书路径" validate_path_value /etc/letsencrypt/live/a.example.com/fullchain.pem
	false_case "拒绝空路径" validate_path_value ''
	false_case "拒绝含换行的路径（会注入配置行）" validate_path_value "$(printf '/p.pac\n\thide_ip')"
	false_case "拒绝含空格的路径（Caddyfile 会拆成两个 token）" validate_path_value '/var/www/a b'
	false_case "拒绝含反斜杠的路径（会破坏 sed 转义）" validate_path_value '/var/www/x\y'
	false_case "拒绝含单引号的路径" validate_path_value "/a'b"
	false_case "拒绝含分号的路径" validate_path_value '/a;b'
	false_case "拒绝含美元符的路径" validate_path_value "/a\$b"

	# 客户端协议：上游 USAGE.txt 的 PROXY-PROTO 有三种，本脚本刻意只放行 https/quic
	true_case "协议校验器已定义" command -v validate_client_proto
	true_case "接受 https" validate_client_proto https
	true_case "接受 quic" validate_client_proto quic
	false_case "拒绝 http（明文代理，不做新手默认）" validate_client_proto http
	false_case "拒绝空协议" validate_client_proto ''
	false_case "拒绝任意协议名" validate_client_proto socks

	# 调用点：新入参必须在「正式部署」和「只读体检」两条路径上都接上。
	# 漏接的后果不是报错而是静默失败 ---- 体检打绿勾、部署才炸。
	true_case "正式部署校验路径入口" has "$(fn_body validate_inputs)" 'validate_path_value'
	true_case "正式部署校验客户端协议" has "$(fn_body validate_inputs)" 'validate_client_proto'
	true_case "体检也校验路径入口" has "$(fn_body main)" 'validate_path_value'
	true_case "体检也校验客户端协议" has "$(fn_body main)" 'validate_client_proto'
	true_case "体检也校验秘密域名" has "$(fn_body main)" 'validate_probe_secret'
	# --check 曾只查「证书文件在不在」，不查配对 ----
	# 于是 fullchain 和 privkey 传反时体检打绿勾、部署立刻失败。
	true_case "体检走与部署同一套证书检查" has "$(fn_body main)" 'check_tls_cert_inputs'
	true_case "部署也走同一套证书检查" has "$(fn_body validate_inputs)" 'check_tls_cert_inputs'
	true_case "成对检查复用配对校验" has "$(fn_body check_tls_cert_inputs)" 'validate_tls_cert_pair'
	# 状态文件读回来也要过校验器：否则被改坏的状态文件能把注入重新带回配置
	true_case "状态再校验覆盖 PAC 路径" has "$(fn_body state_revalidate)" 'STATE_PAC_PATH'
	true_case "状态再校验覆盖证书路径" has "$(fn_body state_revalidate)" 'STATE_TLS_CERT'
	true_case "状态再校验覆盖私钥路径" has "$(fn_body state_revalidate)" 'STATE_TLS_KEY'
	true_case "状态再校验覆盖客户端协议" has "$(fn_body state_revalidate)" 'validate_client_proto'
	true_case "状态写入保存 PAC 路径" has "$(fn_body state_write)" 'STATE_PAC_PATH'
	true_case "状态写入保存客户端协议" has "$(fn_body state_write)" 'STATE_CLIENT_PROTO'
	# 参数解析：--tls-cert 有 --tls-cert= 形式，--tls-key 曾经漏了
	true_case "--tls-cert= 等号形式存在" has "$(fn_body parse_args)" '\-\-tls-cert='
	true_case "--tls-key= 等号形式存在" has "$(fn_body parse_args)" '\-\-tls-key='

	# 行为级：体检对非法入参必须当场拒绝，而不是渲染进预览还报「可以部署了」
	false_case "体检拒绝大写秘密域名（曾原样渲染进预览）" bash "$0" --check --domain a.example.com --email o@m.test --probe-secret Bad.Example.COM
	false_case "体检拒绝非法客户端协议" bash "$0" --check --domain a.example.com --email o@m.test --client-proto bogus
	false_case "体检拒绝带换行的 PAC 路径" bash "$0" --check --domain a.example.com --email o@m.test --serve-pac "$(printf '/p.pac\n\thide_ip')"
	false_case "体检拒绝带空格的伪装目录" bash "$0" --check --domain a.example.com --email o@m.test --web-root '/var/www/a b'
	false_case "正式部署同样拒绝非法客户端协议" bash "$0" --domain a.example.com --email o@m.test --client-proto bogus
	false_case "正式部署同样拒绝带反斜杠的伪装目录" bash "$0" --domain a.example.com --email o@m.test --web-root '/var/www/x\y'

	# 渲染器自保：邮箱为空时不能渲染出只有关键字没有参数的 `tls`
	# （和 WEB_ROOT 的兜底同理 ---- 单独调用渲染器也要产出合法配置）
	local ntls=""
	ntls=$(render_caddyfile a.example.com '' u Pw12345678 443)
	true_case "邮箱为空时渲染合法 tls 指令" has "$ntls" '^[[:space:]]*tls internal$'
	false_case "邮箱为空时不渲染裸 tls" has "$ntls" '^[[:space:]]*tls[[:space:]]*$'

	# 状态文件往返回归（写 / 读 / 恢复三向都要对上新键）
	local saved_state2="${STATE_FILE}" tdir2=""
	tdir2=$(mktemp -d)
	STATE_FILE="${tdir2}/state"
	DOMAIN="a.example.com"; EMAIL="o@m.test"; NAIVE_USER="tom"
	NAIVE_PASS="Aa12345678"; HTTPS_PORT="443"; ALLOW_PORTS=""
	PROBE_SECRET="sec.example.com"; PAC_PATH="/secret-proxy.pac"
	CLIENT_PROTO="quic"; TLS_CERT_FILE="/etc/c.pem"; TLS_KEY_FILE="/etc/k.pem"
	state_write
	DOMAIN=""; EMAIL=""; NAIVE_USER=""; NAIVE_PASS=""; HTTPS_PORT=""; ALLOW_PORTS=""
	PROBE_SECRET=""; PAC_PATH=""; CLIENT_PROTO=""; TLS_CERT_FILE=""; TLS_KEY_FILE=""
	state_parse_into_vars
	eq_case "往返：秘密域名" "sec.example.com" "${STATE_PROBE_SECRET}"
	eq_case "往返：PAC 路径" "/secret-proxy.pac" "${STATE_PAC_PATH}"
	eq_case "往返：客户端协议" "quic" "${STATE_CLIENT_PROTO}"
	eq_case "往返：证书路径" "/etc/c.pem" "${STATE_TLS_CERT}"
	eq_case "往返：私钥路径" "/etc/k.pem" "${STATE_TLS_KEY}"
	true_case "往返后仍通过再校验" state_revalidate
	# 被改坏的状态文件必须在再校验时被拦下（注入不会经由状态文件回到配置里）
	printf 'STATE_DOMAIN=a.example.com\nSTATE_USER=tom\nSTATE_PASS=Aa12345678\nSTATE_PORT=443\nSTATE_PAC_PATH=/p.pac x\n' > "${STATE_FILE}"
	state_parse_into_vars
	false_case "状态文件里的非法 PAC 路径被拦下" state_revalidate
	printf 'STATE_DOMAIN=a.example.com\nSTATE_USER=tom\nSTATE_PASS=Aa12345678\nSTATE_PORT=443\nSTATE_CLIENT_PROTO=bogus\n' > "${STATE_FILE}"
	state_parse_into_vars
	false_case "状态文件里的非法协议被拦下" state_revalidate
	rm -rf "${tdir2}"
	STATE_FILE="${saved_state2}"

	# 证书配对：行为级 ---- 自己签一对出来真的比一次
	if command -v openssl >/dev/null 2>&1; then
		local cdir="" ok_cert="no"
		cdir=$(mktemp -d)
		# 刻意用 -config 而不是 -subj：Git Bash 会把 -subj "/CN=x" 当路径改写
		# （MSYS_NO_PATHCONV 也拦不住），于是 openssl 报 "Error adding extensions"
		# 而静默失败。写进配置文件的 CN 不含斜杠，不会被改写。
		cat > "${cdir}/openssl.cnf" <<'SSLCNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = selftest.invalid
[v3]
basicConstraints = CA:TRUE
SSLCNF
		if openssl req -x509 -newkey rsa:2048 -keyout "${cdir}/k.pem" \
			-out "${cdir}/c.pem" -days 2 -nodes -config "${cdir}/openssl.cnf" >/dev/null 2>&1; then
			ok_cert="yes"
		fi
		if [ "$ok_cert" = "yes" ]; then
			true_case "匹配的证书/私钥被接受" validate_tls_cert_pair "${cdir}/c.pem" "${cdir}/k.pem"
			false_case "写反（证书当私钥）被拒绝" validate_tls_cert_pair "${cdir}/c.pem" "${cdir}/c.pem"
			false_case "体检拒绝写反的证书对" bash "$0" --check --domain a.example.com --email o@m.test --tls-cert "${cdir}/c.pem" --tls-key "${cdir}/c.pem"
			true_case "--tls-cert= 等号形式可用" bash "$0" --check --domain a.example.com --email o@m.test --tls-cert="${cdir}/c.pem" --tls-key="${cdir}/k.pem"
		else
			skip_case "证书配对行为断言（本机 openssl 签不出证书）"
		fi
		rm -rf "${cdir}"
	else
		skip_case "证书配对行为断言（本机无 openssl）"
	fi

	printf '\n----------------------------------------\n'
	printf '结果: %s%d 通过%s / %s%d 失败%s / %s%d 跳过%s\n' \
		"$C_GRN" "$pass" "$C_RST" "$C_RED" "$fail" "$C_RST" "$C_YEL" "$skip" "$C_RST"
	if [ "$fail" -ne 0 ]; then
		printf '%s\n' "自检未通过，请勿部署。"
		return 1
	fi
	printf '%s\n' "自检全部通过。"
	return 0
}

main "$@"
