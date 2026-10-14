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
# ================ 区域索引（按文件顺序；行号会漂所以不写行号）================
# 下面每条顶格（列首）的 `# ---------------- 标题 ----------------` 就是一个区段。
# 按顺序列标题、不列行号：行号一改文件就漂，标题才是稳的锚。
# 改标题了就顺手改这里，别让索引漂掉。
# （函数体内缩进的同类注释不属于区段，故不在此列。）
# ST_INDEX_BEGIN
#     ～ acme.sh 证书路径的落点（真机已验证的布局）
#     ～ 运行期状态（全部显式初始化：set -u 下未定义会直接报错）
#     ～ 证书模式（三层降级，见 --cert-mode）
#     ～ 阶段表（编号与名字的唯一来源）
#     ～ 颜色与字形
#     ～ 输出
#     ～ 失败处理
#     ～ 状态文件读写
#     ～ 帮助与引导
#     ～ 输入校验
#     ～ acme.sh 的续期钩子（reload 脚本 + systemd timer）
#     ～ 配置渲染
#     ～ 环境探测
#     ～ 端口探测
#     ～ 确认
#     ～ 预检项
#     ～ 阶段 1: 系统依赖
#     ～ 阶段 2: caddy 二进制
#     ～ 阶段 3: 用户与目录
#     ～ 阶段 4: 配置
#     ～ 阶段 5: 伪装站点
#     ～ 阶段 5: 伪装站点
#     ～ 阶段 6: 服务
#     ～ 阶段 7: 验证
#     ～ 汇总
#     ～ 卸载
#     ～ 换密码
#     ～ 求助诊断
#     ～ 体检（只读）
#     ～ 重载 / 升级
#     ～ 参数校验
#     ～ 参数解析
#     ～ 主流程
#     ～ 自检用的顶层辅助
#     ～ 开发者自检
#     ～ 子集过滤（--self-test <模式>）
# ST_INDEX_END
#
set -Eeuo pipefail

SCRIPT_VERSION="2.5.0"
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

# ---------------- acme.sh 证书路径的落点（真机已验证的布局） ----------------
# 统一到一个目录，而不是直接把 caddy 指到 ~/.acme.sh 里去：
#   ~/.acme.sh 是 0700 root，caddy 以非特权用户运行，读不到。
# 这里的 750 root:caddy + 文件 644/640 正是为了「caddy 用户能读、别人不能读私钥」。
CERT_DIR="/etc/ssl/naiveproxy"
CERT_FILE="${CERT_DIR}/fullchain.pem"
CERT_KEY_FILE="${CERT_DIR}/privkey.pem"
CERT_CHAIN_FILE="${CERT_DIR}/chain.pem"
# acme.sh 的安装位置（官方默认 ~/.acme.sh）与续期钩子
ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
ACME_RELOAD_SH="/usr/local/bin/naive-cert-reload.sh"
ACME_TIMER="/etc/systemd/system/acme-sh-renew.timer"
ACME_SERVICE="/etc/systemd/system/acme-sh-renew.service"

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
# --self-test 的可选过滤模式：非空时只跑匹配的断言（见 self_test 内的子集过滤）。
SELF_TEST_PATTERN=""
RELOAD_ONLY="no"
CHECK_ONLY="no"
ROTATE_PASSWORD="no"
DIAGNOSTICS="no"
ASCII_ONLY="no"
PROBE_SECRET=""
PAC_PATH=""
CLIENT_PROTO="https"

# ---------------- 证书模式（三层降级，见 --cert-mode） ----------------
# CERT_MODE 是「用户要求」，CERT_MODE_ACTUAL 是「实际选中」。分开是因为 auto
# 要探测机器有没有 acme.sh 才能定，而探测结果必须能被 --check 只读地预演。
CERT_MODE="auto"
CERT_MODE_ACTUAL=""
# Cloudflare 凭据只从文件或环境变量读，绝不从命令行传（会进 shell 历史）
CF_TOKEN_FILE=""
CF_TOKEN=""
ACME_EMAIL=""       # 未显式给就沿用 --email
ACME_STAGING="no"   # --acme-staging：用 letsencrypt_test，不消耗生产额度
RENEW_METHOD=""     # systemd | cron | none —— 续期到底靠什么在跑
# 我们到底知不知道现有配置用的是哪种证书模式。保留旧配置、又读不到状态文件时
# 只能回答「不知道」—— 这时候绝不猜，猜错会把用户引到错误方向。
CERT_MODE_KNOWN="yes"

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
STATE_CERT_MODE=$(state_read_one CERT_MODE)
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
	# 证书模式同样会被读回来参与决策，必须一起过校验器。
	# 一个被改坏的 STATE_CERT_MODE 会让重跑时选错证书路径。
	if [ -n "${STATE_CERT_MODE:-}" ]; then validate_cert_mode "$STATE_CERT_MODE" || bad=1; fi
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
		printf 'STATE_CERT_MODE=%s\n' "${CERT_MODE_ACTUAL}"
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
NaiveProxy 服务端部署脚本 v2.5.0
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
  --cert-mode <方式>      证书怎么来，四选一（默认 auto）：
                           auto   自动判断：给了 --tls-cert 就用文件；否则机器上有
                                  acme.sh 就用它；再否则交给 Caddy 自己申请
                           acme   强制用 acme.sh 申请（需要 Cloudflare token）
                           caddy  强制交给 Caddy 自己向 Let's Encrypt 申请
                           file   强制使用 --tls-cert/--tls-key 指定的文件

证书续期（acme.sh 方式）：
  --cf-token-file <文件>  Cloudflare API token 的文件路径，用于 acme.sh 的 DNS-01 校验。
                         文件里只放 token 一行，不要带 export 或引号。
                         为什么不支持 --cf-token 直接传值：命令行参数会进 shell 历史，
                         也可能出现在 ps 输出里。另一个办法是用环境变量：
                           sudo CF_Token='你的token' -E ./deploy-naive-caddy.sh ...
                         为什么要 Cloudflare token：DNS-01 走 Cloudflare API 加一条
                         临时 TXT 记录来证明域名归你，不需要 80 端口对外可达。
                         token 需要有 Zone → DNS → Edit 权限。
  --acme-email <邮箱>     acme.sh 的证书通知邮箱，默认沿用 --email
  --acme-staging          用 Let's Encrypt 的测试环境（letsencrypt_test）。
                         调试时不消耗生产额度 —— 正式用别加这个。

注意：acme.sh 是 GPL-3.0 许可，本脚本是 MIT。我们只「调用」它的命令行，
不把它的源码打包进本仓库 —— 这是许可边界，也是它能被安全使用的前提。
安装器从官方地址 https://get.acme.sh 现场获取。
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
  --self-test [关键词]   开发者自检，不需要 root。跑满全部要一两分钟；
                         加上关键词就只跑相关的几条，通常几秒出结果。
                         关键词匹配什么（不区分大小写）：
                            · 断言的文字说明，如 state_、tls-cert、密码
                            · 或它所在小节的标题，如 状态、证书、密码生成
                         例：--self-test state_    名字或小节含 state_ 的
                             --self-test 状态     同上，用中文小节名挑
                         不带关键词 = 跑全量（与以前完全一致）。
                         一个都没匹配上会明确报错并非零退出，不会假装通过。
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

# ================ 证书模式：自动选择 / acme.sh 安装 / 续期 ================
# 三层降级（--cert-mode auto）：
#   ① 显式给了 --tls-cert/--tls-key  → 用现成文件（零额度消耗，行为与旧版一致）
#   ② 机器上有 acme.sh               → 用 acme.sh 申请 + 装 systemd timer 续期
#   ③ 都没有                         → 交给 caddy 自己向 ACME 申请（给邮箱时）
#
# 许可证边界（必须守住）：acme.sh 是 GPL-3.0，本仓库是 MIT。
# 我们只「调用它的 CLI」，绝不把它的源码 vendor/复制进本仓库 ——
# 调用是边界使用、不是衍生作品；一旦把代码搬进来，整个仓库就得跟着变 GPL-3.0。

# --cert-mode 的取值校验
validate_cert_mode() {
	case "${1:-}" in
		auto|acme|caddy|file) return 0 ;;
	esac
	return 1
}

# 机器上有没有可用的 acme.sh。两个位置都认：
#   · PATH 里的 acme.sh（发行版包管理器装的）
#   · ~/.acme.sh/acme.sh（官方安装器装的默认位置）
# 只探测、不改动 —— --check 也要用它做只读预演。
detect_acme_sh() {
	if command -v acme.sh >/dev/null 2>&1; then
		printf '%s' "$(command -v acme.sh)"
		return 0
	fi
	if [ -x "${ACME_BIN}" ]; then
		printf '%s' "${ACME_BIN}"
		return 0
	fi
	return 1
}

# 是否显式指定了证书文件（模式 ①）。判据只认这两个变量，
# 不从 CERT_MODE 反推 —— auto 模式下它们是空的，语义才一致。
cert_files_given() {
	[ -n "${TLS_CERT_FILE}" ] || [ -n "${TLS_KEY_FILE}" ]
}

# 自动模式下的三层降级决策。这是 --cert-mode auto 的全部逻辑所在，
# 单独成函数是为了让 --check 与正式部署调用同一份判断（避免两条路径漂移）。
# 输出：file | acme | caddy —— 不写任何全局变量，便于被 --check 只读调用。
resolve_cert_mode() {
	# ① 显式文件最优先：用户既然给了，就照他的来
	if cert_files_given; then
		printf 'file'
		return 0
	fi
	# ② 机器上有 acme.sh 就优先用它 —— 前提是能拿到 Cloudflare 凭据来跑 DNS-01，
	#    否则退回到 caddy。为什么要有这个前提：acme.sh 侧我们只实现了 dns_cf；
	#    没有凭据就硬走 acme.sh 会卡在申请环节，不如交给 caddy 的 HTTP-01。
	if [ -n "${CF_TOKEN}" ] && detect_acme_sh >/dev/null 2>&1; then
		printf 'acme'
		return 0
	fi
	# ③ 兜底：交给 caddy 自己申请（有邮箱时），都没有就是 tls internal
	printf 'caddy'
}

# 最终拍板：把用户要求（CERT_MODE）和自动判断合到一起，写进 CERT_MODE_ACTUAL。
# 显式 --cert-mode 时它是硬覆盖：用户说要 file 就必须 file（缺文件由校验器拦）。
decide_cert_mode() {
	case "${CERT_MODE}" in
		file|acme|caddy) CERT_MODE_ACTUAL="${CERT_MODE}" ;;
		*) CERT_MODE_ACTUAL="$(resolve_cert_mode)" ;;
	esac
	# acme 模式必须有 Cloudflare 凭据，否则申请必失败。这里直接报人话，
	# 别让用户等到阶段 6 才看到一句 ACME 错误。
	if [ "${CERT_MODE_ACTUAL}" = "acme" ] && [ -z "${CF_TOKEN}" ]; then
		err "选了 acme.sh 管证书（--cert-mode acme），但没给 Cloudflare 凭据。"
		err "  DNS-01 校验需要它。两种给法（都不会进 shell 历史）："
		err "    ① 文件：--cf-token-file /root/.cf-token   （内容只放 token 一行）"
		err "    ② 环境变量：sudo CF_Token='...' -E $0 --cert-mode acme ..."
		err "  Cloudflare 后台 → My Profile → API Tokens → 建一个带 Zone:DNS:Edit 权限的 token。"
		return 1
	fi
	return 0
}

# Cloudflare token 的来源集中处理。刻意只支持「文件」和「环境变量」两条路，
# 绝不做 --cf-token <值>：命令行参数会原样落进 ~/.bash_history 和 ps 输出。
load_cf_token() {
	# 环境变量优先（用户可能已经 export 了）
	if [ -n "${CF_Token:-}" ]; then
		CF_TOKEN="${CF_Token}"
		return 0
	fi
	[ -n "${CF_TOKEN_FILE}" ] || return 0
	if [ ! -f "${CF_TOKEN_FILE}" ]; then
		err "指定的 token 文件不存在: ${CF_TOKEN_FILE}"
		return 1
	fi
	# 只取第一行、去掉首尾空白与可能的引号；token 里不会有空格。
	CF_TOKEN="$(head -1 "${CF_TOKEN_FILE}" 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
	CF_TOKEN="${CF_TOKEN%\"}"; CF_TOKEN="${CF_TOKEN#\"}"
	if [ -z "${CF_TOKEN}" ]; then
		err "token 文件 ${CF_TOKEN_FILE} 是空的（里面应该只有一行 token）"
		return 1
	fi
	# token 会被 export 给 acme.sh。做个字符集校验，免得文件里混进奇怪内容
	# 被当成命令的一部分 —— 这是从「用户可控文件」到「子进程环境」的边界。
	printf '%s' "${CF_TOKEN}" | grep -qE '^[A-Za-z0-9_-]+$' || {
		err "token 文件里的内容不像一个 Cloudflare API token（只允许字母数字、下划线、连字符）"
		err "  常见原因：文件里还留了 'export CF_Token=' 前缀，或者有多余的引号。"
		err "  正确做法：文件里只放 token 本身，一行，不带任何前后缀。"
		return 1
	}
	return 0
}

# 官方安装器的一行式命令。无 cron 的机器必须加 --force，否则安装器会
# 拒绝安装（真机实测：Debian 13 无 crontab，官方安装器直接报错退出）。
# 这里把「有没有 cron」探出来，决定要不要 --force，而不是无脑带上 ——
# 无脑 --force 会掩盖安装器将来对别的环境不满足条件的告警。
install_acme_sh() {
	# TMP_DIR 正常由阶段 2 建好，但别依赖调用顺序 —— 没建就自己建一个，
	# 否则 installer 会变成 "/get-acme.sh" 写进根目录。
	if [ -z "${TMP_DIR}" ] || [ ! -d "${TMP_DIR}" ]; then
		TMP_DIR=$(mktemp -d) || { err "创建临时目录失败"; return 1; }
	fi
	local installer="${TMP_DIR}/get-acme.sh" force="" email="${ACME_EMAIL:-${EMAIL}}"
	if ! need_cmd curl; then
		err "装 acme.sh 需要 curl，但本机没有"
		return 1
	fi
	if ! need_cmd crontab && ! need_cmd fcrontab; then
		force="--force"
		note "本机没有 cron —— acme.sh 安装器需要 --force 才肯装（续期改用 systemd timer）"
	fi
	note "从官方地址获取 acme.sh 安装器：https://get.acme.sh"
	if ! curl -fsSL --max-time 30 "https://get.acme.sh" -o "${installer}" >>"${DEPLOY_LOG}" 2>&1; then
		err "下载 acme.sh 安装器失败（网络问题？）"
		show_log_tail 10
		return 1
	fi
	# 只看它是不是个可执行的 shell 脚本，不 vendor 它的内容。
	if ! head -1 "${installer}" 2>/dev/null | grep -q '^#!.*sh'; then
		err "下载到的安装器看起来不是 shell 脚本，已中止（可能被劫持）"
		return 1
	fi
	# 官方用法就是 curl | sh。这里先下载到临时文件再执行，便于先做一次检查。
	# 重定向掉 acme.sh 自己的安装日志，装完再回读关键几行。
	note "安装 acme.sh（日志写入 ${DEPLOY_LOG}）…"
	if ! sh "${installer}" "email=${email}" ${force} >>"${DEPLOY_LOG}" 2>&1; then
		err "acme.sh 安装失败"
		show_log_tail 15
		err "  手动安装办法：curl https://get.acme.sh | sh -s email=${email} --force"
		return 1
	fi
	if ! detect_acme_sh >/dev/null 2>&1; then
		err "安装器跑完了，但仍找不到 acme.sh（既不在 PATH，也不在 ${ACME_BIN}）"
		return 1
	fi
	ok "acme.sh 已安装"
	return 0
}

# 不管 acme.sh 是新装的还是机器上本来就有的，都要把默认 CA 切成 Let's Encrypt。
# 为什么必须显式切：acme.sh 的 DEFAULT_CA 默认指向 ZeroSSL（源码 DEFAULT_CA=$CA_ZEROSSL），
# 不切的话证书会静默地由 ZeroSSL 签发 —— 用户以为拿到的是 Let's Encrypt。
# 这一步是幂等的：已是 LE 时再设一次无副作用。
set_acme_default_ca() {
	local bin=""
	bin=$(detect_acme_sh) || return 1
	if "${bin}" --set-default-ca --server letsencrypt >>"${DEPLOY_LOG}" 2>&1; then
		ok "acme.sh 默认 CA 已设为 Let's Encrypt"
		return 0
	fi
	warn "设置 acme.sh 默认 CA 失败（不影响申请时用 --server 显式指定）"
	return 0
}

# acme.sh 装完（或检测到已装）后的统一收尾：切 CA、把 token 交给它持久化。
# token 交给 acme.sh 的方式是「写进它自己的 account.conf」——
# dns_cf 插件会 _saveaccountconf_mutable CF_Token，续期时从那里读，
# 所以 timer 触发的续期不需要我们再注入环境变量。
prepare_acme_sh() {
	[ -n "${CF_TOKEN}" ] || return 0
	local bin=""
	bin=$(detect_acme_sh) || return 1
	# 让 dns_cf 插件把 token 落到 account.conf。--register-account 只是最轻的
	# 一次调用，会顺带触发凭据持久化；失败也不致命（申请那一步还会再存一次）。
	CF_Token="${CF_TOKEN}" "${bin}" --register-account \
		--accountemail "${ACME_EMAIL:-${EMAIL}}" >>"${DEPLOY_LOG}" 2>&1 || true
	return 0
}

# acme 模式的「开工准备」：装 acme.sh（缺则装）、切默认 CA、落地 reload 脚本。
# 全是幂等操作，重跑安全。刻意不在这里申请证书 —— 申请是有额度消耗的外部动作，
# 只在真的要重写配置时（write_config 的渲染分支）才做。
acme_prepare() {
	if ! detect_acme_sh >/dev/null 2>&1; then
		note "机器上没有 acme.sh，开始安装（用户要求：没有就要装上）"
		install_acme_sh || return 1
	else
		note "机器上已有 acme.sh: $(detect_acme_sh)"
	fi
	# 装完立刻切 CA —— 否则默认会静默用 ZeroSSL（源码 DEFAULT_CA=$CA_ZEROSSL）
	set_acme_default_ca
	# token 交给 acme.sh 自己持久化到 account.conf
	prepare_acme_sh
	# reload 脚本必须先落地：issue 时的 --reloadcmd 会立刻执行它
	render_acme_reload_script > "${ACME_RELOAD_SH}" || { err "写入 ${ACME_RELOAD_SH} 失败"; return 1; }
	chmod 0755 "${ACME_RELOAD_SH}" || { err "设置 ${ACME_RELOAD_SH} 权限失败"; return 1; }
	ok "证书续期钩子已就绪: ${ACME_RELOAD_SH}"
	return 0
}

# ---------------- acme.sh 的续期钩子（reload 脚本 + systemd timer） ----------------
# 这个脚本的职责只有一件事：修权限 + 让 caddy 真的读到新证书。
# 为什么 reload 不能用 `systemctl reload caddy`（事实 1，真机实测）：
#   它返回 0，但 TLS 握手读到的仍是旧证书 —— 静默失效，到期那天才发现。
#   必须用 `caddy reload --force --config ...`，它才会真正换成新证书。
# 也绝不要写成 `systemctl reload caddy || caddy reload --force`：
#   前者退出码是 0，|| 右边的兜底永远不会执行，续期就静默失效了。
render_acme_reload_script() {
	cat <<EOF
#!/usr/bin/env bash
#
# naive-cert-reload.sh —— acme.sh 续期后，让 caddy 真正用上新证书
#
# 由 deploy-naive-caddy.sh 生成，可被覆盖重装。手工改这里的内容会在下次部署时丢失。
#
# 为什么需要这个脚本，而不是在 acme.sh 的 --reloadcmd 里直接写一行 reload：
#   ① 证书是我们用 --install-cert 落到 ${CERT_DIR}/ 的，属主/权限得收拾干净，
#      否则 caddy 用户读不到、服务起不来（而且是在半夜续期时才炸）。
#   ② \`systemctl reload caddy\` 在真机上返回成功但握手仍是旧证书（静默失效）。
#      必须 \`caddy reload --force\`。这里把它固化成代码，避免以后有人改回去。
#
set -Eeuo pipefail

CERT_DIR="${CERT_DIR}"
CERT_FILE="${CERT_FILE}"
KEY_FILE="${CERT_KEY_FILE}"
CADDY_BIN="${CADDY_BIN}"
CONF_FILE="${CONF_FILE}"

log() { printf '[naive-cert-reload] %s\n' "\$*"; }
die() { printf '[naive-cert-reload] 错误: %s\n' "\$*" >&2; exit 1; }

[ -d "\${CERT_DIR}" ] || die "证书目录不存在: \${CERT_DIR}"
[ -s "\${CERT_FILE}" ] || die "证书文件为空: \${CERT_FILE}"
[ -s "\${KEY_FILE}" ] || die "私钥文件为空: \${KEY_FILE}"

# 属主收敛为 root:caddy。私钥 640（只有 caddy 组能读），全链 644。
log "修正证书权限…"
chown root:caddy "\${CERT_FILE}" "\${KEY_FILE}" 2>/dev/null || true
[ -f "\${CERT_DIR}/chain.pem" ] && chown root:caddy "\${CERT_DIR}/chain.pem" 2>/dev/null || true
chmod 0750 "\${CERT_DIR}" 2>/dev/null || true
chmod 0644 "\${CERT_FILE}" 2>/dev/null || true
[ -f "\${CERT_DIR}/chain.pem" ] && chmod 0644 "\${CERT_DIR}/chain.pem" 2>/dev/null || true
chmod 0640 "\${KEY_FILE}" 2>/dev/null || true

# 判据是「caddy 用户能不能真读到」，不是权限位看着对不对
if id caddy >/dev/null 2>&1; then
	if ! runuser -u caddy -- test -r "\${CERT_FILE}" 2>/dev/null ||
	   ! runuser -u caddy -- test -r "\${KEY_FILE}" 2>/dev/null; then
		die "caddy 用户仍读不到证书 —— 服务会起不来。请检查 \${CERT_DIR} 的属主与权限。"
	fi
fi

[ -x "\${CADDY_BIN}" ] || die "找不到 caddy: \${CADDY_BIN}"

# 首次安装时，acme.sh 的 --install-cert 会立刻调这个脚本一次 —— 而那一刻
# Caddyfile 还没写、服务还没装。没有东西可重载，直接成功退出即可
# （权限已经修好，后面阶段启动 caddy 时会读到新证书）。
# 如果这里反过来报错退出，acme.sh 的 installcert 会判定失败，整个阶段 4 挂掉。
if [ ! -f "\${CONF_FILE}" ]; then
	log "配置 \${CONF_FILE} 还不存在（首次安装的中间步骤）—— 证书已就位，跳过 reload"
	exit 0
fi

# 主路径：caddy reload --force。它会真正替换进程里的证书。
# 兜底才用 restart —— restart 会断开现有连接，非必要不用。
if "\${CADDY_BIN}" reload --force --config "\${CONF_FILE}" 2>/dev/null; then
	log "caddy reload --force 成功"
	exit 0
fi

# 服务本来就没在跑时，reload 失败是正常的（没有进程可重载）——
# 证书已就位，等它启动时自然会读到新的，不必判失败。
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet caddy 2>/dev/null; then
	log "caddy 服务未运行 —— 证书已就位，跳过 reload（下次启动会读到新证书）"
	exit 0
fi

log "caddy reload 失败，改用 systemctl restart 兜底"
if command -v systemctl >/dev/null 2>&1; then
	systemctl restart caddy || die "systemctl restart caddy 也失败了"
elif command -v rc-service >/dev/null 2>&1; then
	rc-service caddy restart || die "rc-service caddy restart 也失败了"
else
	die "没有可用的服务管理器来重启 caddy"
fi
log "重启完成"
EOF
}

# systemd timer：每天跑一次 acme.sh 的 --cron。
# 为什么不用 cron：真机实测这台机器没有 cron（crontab 缺失、cron inactive）。
# timer 里带 RandomizedDelaySec，避免所有机器在同一秒打 ACME 服务器。
render_acme_renew_service() {
	cat <<EOF
[Unit]
Description=acme.sh 证书续期（naiveproxy）
Documentation=https://github.com/acmesh-official/acme.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# 用 acme.sh 自己的 --cron 走一遍所有证书；没到期它会自己跳过。
# 环境里显式带上 HOME，否则 acme.sh 找不到 ~/.acme.sh。
Environment=HOME=${HOME}
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME}
EOF
}

render_acme_renew_timer() {
	cat <<'EOF'
[Unit]
Description=每天触发一次 acme.sh 证书续期

[Timer]
# 每天一次即可 —— acme.sh 自己按 ARI 算出真正的续期窗口，没到期会跳过。
OnCalendar=daily
# 打散到 1 小时内，避免整点惊群
RandomizedDelaySec=3600
# 机器关机期间错过的那次，开机后补跑
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# 安装续期机制。systemd 环境用 timer；OpenRC 环境没有 systemd，
# 必须退回到「cron 或 acme.sh 自带 --cron 配合 crond」，并且在没有可靠
# 定时机制时明确警告 —— 静默没有续期，等于证书到期那天整个服务挂掉。
install_renewal() {
	if [ "${INIT}" = "systemd" ]; then
		render_acme_reload_script > "${ACME_RELOAD_SH}" || { err "写入 ${ACME_RELOAD_SH} 失败"; return 1; }
		chmod 0755 "${ACME_RELOAD_SH}"
		render_acme_renew_service > "${ACME_SERVICE}" || { err "写入 ${ACME_SERVICE} 失败"; return 1; }
		render_acme_renew_timer > "${ACME_TIMER}" || { err "写入 ${ACME_TIMER} 失败"; return 1; }
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable --now acme-sh-renew.timer >/dev/null 2>&1 || {
			# 不因为 enable 失败就把整个部署判死 —— 证书本身已经装好了，
			# 但必须把「续期没起来」这件事明确告诉用户。
			warn "启用 acme-sh-renew.timer 失败 —— 证书不会自动续期"
			warn "  手动启用：sudo systemctl enable --now acme-sh-renew.timer"
			RENEW_METHOD="none"
			return 0
		}
		ok "续期定时器已启用（systemd timer，每天跑一次）"
		RENEW_METHOD="systemd"
		return 0
	fi

	# OpenRC：没有 systemd。acme.sh 需要 cron 或等价物才能定时。
	if need_cmd crontab; then
		# 用 acme.sh 自带的 --install-cronjob 最稳：它写的是它自己认识的那条。
		local bin=""
		bin=$(detect_acme_sh) || bin="${ACME_BIN}"
		if "${bin}" --install-cronjob >>"${DEPLOY_LOG}" 2>&1; then
			ok "续期 cron 任务已安装（OpenRC 环境）"
			RENEW_METHOD="cron"
			return 0
		fi
		warn "acme.sh 的 --install-cronjob 失败"
	fi
	# 走到这里说明 OpenRC 且没有可用的 cron —— 明确警告，不假装成功
	warn "本机是 OpenRC 且没有可用的 cron，无法自动续期！"
	warn "  acme.sh 已装好，但证书到期前需要你手动执行一次："
	warn "    ${ACME_BIN} --cron --home ${ACME_HOME}"
	warn "  或者先装个 cron（如：apk add busybox-initscripts && rc-update add crond）"
	RENEW_METHOD="none"
	return 0
}

# 用 acme.sh 申请证书并装到统一落点。这是 --cert-mode acme 的核心动作。
# 关键点（都在真机上踩过/核对过源码）：
#   · 默认签 ECDSA 证书 → 所有后续命令都要带 --ecc，证书目录是 <域名>_ecc
#   · --issue 在「域名没变、未到续期窗口」时返回 2（RENEW_SKIP），不是 0 ——
#     所以不能写 `--issue ... || return 1`，那会把正常跳过误报成失败
#   · 装证书时用 --fullchain-file / --key-file / --ca-file 把文件落到
#     /etc/ssl/naiveproxy/，并用 --reloadcmd 指向我们的 reload 脚本
issue_cert_with_acme() {
	local bin="" domain="${DOMAIN}"
	local server="letsencrypt"
	[ "${ACME_STAGING}" = "yes" ] && server="letsencrypt_test"

	bin=$(detect_acme_sh) || { err "找不到 acme.sh"; return 1; }
	[ -n "${CF_TOKEN}" ] || { err "acme.sh 申请证书需要 Cloudflare token（--cf-token-file 或 CF_Token 环境变量）"; return 1; }

	mkdir -p "${CERT_DIR}" || { err "创建 ${CERT_DIR} 失败"; return 1; }
	chmod 0750 "${CERT_DIR}" 2>/dev/null || true

	note "用 acme.sh 向 ${server} 申请 ${domain} 的证书（DNS-01 / Cloudflare）…"
	note "  走 DNS-01 就不需要 80 端口 —— 域名不必暴露 HTTP。"

	# dns_cf 插件从环境变量读 token。export 出去，acme.sh 会自己存进 account.conf，
	# 之后续期（timer 触发）不再依赖我们注入环境变量。
	local rc=0
	CF_Token="${CF_TOKEN}" "${bin}" --issue --dns dns_cf -d "${domain}" \
		--server "${server}" --keylength ec-256 >>"${DEPLOY_LOG}" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
		err "acme.sh 申请证书失败（退出码 ${rc}）"
		show_log_tail 20
		err "  常见原因：Cloudflare token 权限不足 / 域名不在该账号下 / A 记录未生效"
		return 1
	fi
	if [ "$rc" -eq 2 ]; then
		note "证书已在有效期内，acme.sh 跳过本次申请（正常）"
	fi

	# 装到统一落点。--ecc 必须带：不带的话 certbot 风格的目录会找不到证书
	# （证书在 <域名>_ecc/ 下）。
	# --reloadcmd 指向我们生成的 reload 脚本：续期成功后 acme.sh 会自己调它，
	# 由它用 caddy reload --force 把新证书真正换进进程。
	if ! CF_Token="${CF_TOKEN}" "${bin}" --install-cert -d "${domain}" --ecc \
		--fullchain-file "${CERT_FILE}" \
		--key-file "${CERT_KEY_FILE}" \
		--ca-file "${CERT_CHAIN_FILE}" \
		--reloadcmd "${ACME_RELOAD_SH}" >>"${DEPLOY_LOG}" 2>&1; then
		err "acme.sh 安装证书到 ${CERT_DIR} 失败"
		show_log_tail 15
		return 1
	fi
	ok "证书已申请并安装到 ${CERT_DIR}/"
	return 0
}

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

# 我们自己管的证书目录（acme.sh 那一路）用固定布局，直接设成确定的权限，
# 不走 ensure_cert_readable 那套「试探着放开 o+rx」的兜底逻辑 ——
# o+rx 是给 certbot 的 /etc/letsencrypt 用的；我们自己的目录应当是
# 750 root:caddy + 私钥 640，让别人连目录都进不去。
normalize_cert_layout() {
	[ -d "${CERT_DIR}" ] || return 0
	chown root:caddy "${CERT_DIR}" 2>/dev/null || true
	chmod 0750 "${CERT_DIR}" 2>/dev/null || true
	local f=""
	for f in "${CERT_FILE}" "${CERT_CHAIN_FILE}"; do
		[ -f "$f" ] || continue
		chown root:caddy "$f" 2>/dev/null || true
		chmod 0644 "$f" 2>/dev/null || true
	done
	if [ -f "${CERT_KEY_FILE}" ]; then
		chown root:caddy "${CERT_KEY_FILE}" 2>/dev/null || true
		chmod 0640 "${CERT_KEY_FILE}" 2>/dev/null || true
	fi
	return 0
}

# 证书文件必须对 caddy 用户可读，否则服务起不来。
# 最常见的来源：certbot 把 /etc/letsencrypt/archive 放在 root:root 0700，
# 而 caddy 以非特权用户运行 —— 真机实测会直接 permission denied 然后崩溃重启。
ensure_cert_readable() {
	[ -n "${TLS_CERT_FILE}" ] || return 0
	id caddy >/dev/null 2>&1 || return 0

	# 我们自己的证书目录有确定布局，直接按它收敛权限，不需要下面的「试探」
	if [ "${TLS_CERT_FILE}" = "${CERT_FILE}" ]; then
		normalize_cert_layout
		if runuser -u caddy -- test -r "${TLS_CERT_FILE}" 2>/dev/null \
		   && runuser -u caddy -- test -r "${TLS_KEY_FILE}" 2>/dev/null; then
			return 0
		fi
		warn "caddy 用户读不到 ${CERT_DIR} 里的证书，自动修权限没成功"
		warn "  手动检查：sudo ls -l ${CERT_DIR}"
		return 0
	fi

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
			# 现有配置是怎么管证书的，重跑时要沿用 —— 否则「保留配置」的这条
			# 幂等路径会把 CERT_MODE_ACTUAL 落回 auto，后面 install_service
			# 判断「要不要装续期」就会错。
			if [ -n "${STATE_CERT_MODE:-}" ]; then
				CERT_MODE_ACTUAL="${STATE_CERT_MODE}"
			else
				# 旧版本写的状态文件没有这个键，或者状态文件压根读不到。
				# 不猜 —— 摘要里如实说「不知道」，并给出查看办法。
				CERT_MODE_KNOWN="no"
			fi
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
		# acme.sh 那一路：先把证书申请/装好，再把渲染器的证书路径指过去。
		# 顺序很重要 —— 证书必须先就位，否则下面 caddy validate 会因为
		# Caddyfile 里引用了不存在的证书文件而失败。
		if [ "${CERT_MODE_ACTUAL}" = "acme" ]; then
			acme_prepare || { err "准备 acme.sh 失败"; return 1; }
			issue_cert_with_acme || { err "用 acme.sh 申请证书失败"; return 1; }
			TLS_CERT_FILE="${CERT_FILE}"
			TLS_KEY_FILE="${CERT_KEY_FILE}"
			# 申请阶段 acme.sh 的 --reloadcmd 已经跑过一次（那时 caddy 还没配好，
			# 失败很正常）；这里再正规地修一次权限，确保后续 caddy 能读到。
			normalize_cert_layout
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
	# acme.sh 那一路才需要装续期机制。文件模式与 caddy 自签都不归我们管续期。
	if [ "${CERT_MODE_ACTUAL}" = "acme" ]; then
		install_renewal
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

	# 证书判据必须是「TLS 握手里读到的那张」，不能看盘上文件 —— 这正是事实 1
	# 那个坑的教训：systemctl reload 之后盘上的文件是新的，握手读到的却是旧的。
	# 一次 s_client 抓下来，subject / issuer / 到期时间都从同一张证书取，避免不一致。
	local hs_cert=""
	hs_cert=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "${DOMAIN}" 2>/dev/null \
		| openssl x509 -noout -subject -issuer -enddate 2>/dev/null || true)
	issuer=$(printf '%s' "$hs_cert" | sed -n 's/^issuer=//p' | head -1)
	local hs_subject="" hs_end=""
	hs_subject=$(printf '%s' "$hs_cert" | sed -n 's/^subject=//p' | head -1)
	hs_end=$(printf '%s' "$hs_cert" | sed -n 's/^notAfter=//p' | head -1)
	if [ -n "$issuer" ]; then
		ok "握手证书签发者: ${issuer}"
		[ -n "$hs_subject" ] && note "  DNS 名: ${hs_subject}"
		[ -n "$hs_end" ] && note "  到期时间: ${hs_end}"
	else
		warn "读不到握手里的证书信息（多半是证书还没签发完）"
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

# 体检里的「证书会怎么走」预演。只读 —— 不装任何东西、不申请任何证书。
# 与正式部署共用 resolve_cert_mode，所以这里说的就是部署时真会发生的事。
report_cert_plan() {
	local bin="" mode=""
	printf '\n'
	note "证书处理方式（--cert-mode ${CERT_MODE}）"
	mode="${CERT_MODE_ACTUAL:-$(resolve_cert_mode)}"
	case "$mode" in
		file)
			ok "用你指定的证书文件（不消耗任何 ACME 额度）"
			info "    ${TLS_CERT_FILE}"
			;;
		acme)
			bin=$(detect_acme_sh || true)
			if [ -n "$bin" ]; then
				ok "机器上已有 acme.sh（${bin}），将用它申请 Let's Encrypt 证书"
			else
				note "机器上没有 acme.sh —— 正式部署时会自动装上（用户要求：没有就装）"
				info "  ${G_ARROW} 安装需要能访问 https://get.acme.sh"
			fi
			info "    证书落点: ${CERT_DIR}/"
			if [ "${INIT}" = "systemd" ]; then
				ok "续期方式: systemd timer（每天检查一次，自动续）"
			elif need_cmd crontab; then
				ok "续期方式: cron"
			else
				# 不谎称是 OpenRC —— INIT 可能是空的（本机既没 systemd 也没 openrc）
				warn "续期方式: 本机没有可用的定时机制（无 systemd，也无 cron）—— 无法自动续期"
				info "  ${G_ARROW} 装上 cron 或改用有 systemd 的系统；在那之前需要手动续期："
				info "    sudo ${ACME_BIN} --cron --home ${ACME_HOME}"
			fi
			;;
		*)
			if [ -n "${EMAIL:-}" ]; then
				ok "交给 Caddy 自己向 Let's Encrypt 申请（HTTP-01，需要 80 端口可达）"
			else
				note "没有邮箱也没有 acme.sh —— 会退回自签证书（tls internal）"
				info "  ${G_ARROW} 自签证书客户端不信任，仅适合内网测试。正式用请加 --email 或 --cf-token-file"
			fi
			;;
	esac
	return 0
}

# 证书模式的人话说明。用户最关心两件事：证书是谁签的、会不会自动续期。
# 这一段刻意不打印任何密钥内容，只讲模式和续期机制。
print_cert_summary() {
	printf '%s\n' "  ${C_BLD}证书${C_RST}"
	if [ "${CERT_MODE_KNOWN}" != "yes" ]; then
		note "  现有配置保留着，但凭据/状态记录缺失，无法确认它用的是哪种证书方式"
		info "  查看办法: sudo grep -n 'tls ' ${CONF_FILE}"
		printf '\n'
		return 0
	fi
	case "${CERT_MODE_ACTUAL}" in
		acme)
			info "  方式      acme.sh 申请（Let's Encrypt，DNS-01）"
			info "  落点      ${CERT_DIR}/"
			case "${RENEW_METHOD}" in
				systemd)
					info "  自动续期  已开启（systemd timer，每天检查一次）"
					note "           查看状态: systemctl list-timers acme-sh-renew.timer"
					;;
				cron)
					info "  自动续期  已开启（cron）"
					;;
				*)
					warn "  自动续期  未开启 —— 证书到期前需要手动执行："
					warn "            ${ACME_BIN} --cron --home ${ACME_HOME}"
					warn "            （建议尽快装上 cron 或改用 systemd 环境）"
					;;
			esac
			note "           想立刻手动续一次: sudo ${ACME_BIN} --cron --home ${ACME_HOME}"
			;;
		file)
			info "  方式      使用你提供的现成证书文件"
			info "  证书      ${TLS_CERT_FILE}"
			info "  私钥      ${TLS_KEY_FILE}"
			note "           续期由提供证书的那个工具负责（certbot / acme.sh 等），本脚本不管"
			;;
		*)
			info "  方式      Caddy 自动向 Let's Encrypt 申请（HTTP-01）"
			note "           续期由 Caddy 自己负责，通常无需你干预"
			;;
	esac
	printf '\n'
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

	# 证书这一环单独说清楚：用户最关心的两个问题是「谁签的」和「会不会自动续」。
	print_cert_summary

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
		# 先拆我们自己的续期 timer —— 否则它会每天照常跑，而 caddy 已经没了。
		if [ -f "${ACME_TIMER}" ]; then
			systemctl disable --now acme-sh-renew.timer 2>/dev/null || true
		fi
		systemctl stop caddy 2>/dev/null || true
		systemctl disable caddy 2>/dev/null || true
		rm -f "${SVC_FILE}" "${ACME_TIMER}" "${ACME_SERVICE}"
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
		# 只删「本脚本生成的」东西。刻意不删 acme.sh 本身，也不删它签的证书 ——
		# acme.sh 可能还在给这台机器上的别的域名管证书，连根拔掉会伤到用户。
		rm -f "${ACME_RELOAD_SH}"
		ok "已清理配置、站点、日志、数据与 caddy 用户"
		if [ -d "${CERT_DIR}" ]; then
			warn "保留了证书目录 ${CERT_DIR}（重装可复用它，省一次 Let's Encrypt 额度）"
			warn "  确实要删：sudo rm -rf ${CERT_DIR}"
		fi
		if [ -d "${ACME_HOME}" ]; then
			note "acme.sh 本身（${ACME_HOME}）也保留了 —— 它可能还在管别的域名"
			note "  确实要删：sudo ${ACME_BIN} --uninstall && sudo rm -rf ${ACME_HOME}"
		fi
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
	# 换密码要重写整个 Caddyfile，证书这一环必须沿用原来的处理方式，
	# 否则 A 模式部署的机器一次换密码就可能把证书路径改没了。
	CERT_MODE_ACTUAL="${STATE_CERT_MODE:-${CERT_MODE_ACTUAL}}"
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

	# 7) 证书会怎么走 —— 这是用户最容易一头雾水的一环，体检里必须预演一遍
	report_cert_plan

	# 配置预览
	if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
		section "配置预览"
		note "密码位置是占位符 —— 正式部署时才会生成真密码"
		printf '\n'
		# 预览必须与实际会渲染出的配置一致。acme 模式下正式部署会把 tls 指到
		# 统一落点的证书文件，预览也要照这个来 —— 否则用户看到的 `tls <邮箱>`
		# 和实际写进去的证书路径对不上，等于预览在说谎。
		local pv_cert="${TLS_CERT_FILE}" pv_key="${TLS_KEY_FILE}"
		if [ "${CERT_MODE_ACTUAL:-}" = "acme" ]; then
			pv_cert="${CERT_FILE}"; pv_key="${CERT_KEY_FILE}"
			note "acme 模式：证书会由 acme.sh 申请并装到 ${CERT_DIR}/ ，配置里引用这两个文件"
		fi
		render_caddyfile "$DOMAIN" "$EMAIL" "${NAIVE_USER:-naive}" "${PASS_PREVIEW}" "${HTTPS_PORT:-443}" "$ALLOW_PORTS" "$PROBE_SECRET" "$PAC_PATH" "$pv_cert" "$pv_key"
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
# 证书模式相关选项的校验。--check（只读体检）与正式部署两条路径都调用它，
# 免得又出现「体检打绿勾、部署才炸」的覆盖漂移。
validate_cert_options() {
	validate_cert_mode "${CERT_MODE}" \
		|| die "--cert-mode 只能是 auto|acme|caddy|file，收到: ${CERT_MODE}"
	# 显式 file 模式却没给文件 → 当场拒，别等到渲染出 tls 空指令。
	if [ "${CERT_MODE}" = "file" ] && ! cert_files_given; then
		die "--cert-mode file 需要同时给出 --tls-cert 与 --tls-key"
	fi
	# --tls-cert/--tls-key 与 --cert-mode acme/caddy 互斥：两个都给了是自相矛盾，
	# 不如直接说清楚，别让脚本替用户猜。
	if cert_files_given && { [ "${CERT_MODE}" = "acme" ] || [ "${CERT_MODE}" = "caddy" ]; }; then
		die "既给了 --tls-cert/--tls-key，又指定 --cert-mode ${CERT_MODE} —— 两者冲突。去掉一个。"
	fi
	if [ -n "${CF_TOKEN_FILE}" ]; then
		validate_path_value "${CF_TOKEN_FILE}" \
			|| die "--cf-token-file 不合法: ${CF_TOKEN_FILE}（应为不含空格与换行的路径）"
	fi
	if [ -n "${ACME_EMAIL}" ]; then
		validate_email "${ACME_EMAIL}" || die "--acme-email 格式不合法: ${ACME_EMAIL}"
	fi
	# token 文件与环境变量此时就要读进来 —— 因为下面 resolve_cert_mode 要靠
	# CF_TOKEN 是否为空来决定 auto 模式走不走 acme.sh。
	load_cf_token || return 1
	# 自动/显式选定最终模式。失败时给出人话与补救命令。
	decide_cert_mode || return 1
	return 0
}

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
	# 证书模式相关的选项（--cert-mode / --cf-token-file / --acme-email / CF_Token）
	validate_cert_options || exit 1
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
			--cert-mode) need_value "$1" "$#" "auto"; CERT_MODE="$2"; shift 2 ;;
			--cert-mode=*) CERT_MODE="${1#*=}"; shift ;;
			--cf-token-file) need_value "$1" "$#" "/root/.cf-token"; CF_TOKEN_FILE="$2"; shift 2 ;;
			--cf-token-file=*) CF_TOKEN_FILE="${1#*=}"; shift ;;
			--acme-email) need_value "$1" "$#" "you@example.com"; ACME_EMAIL="$2"; shift 2 ;;
			--acme-email=*) ACME_EMAIL="${1#*=}"; shift ;;
			--acme-staging) ACME_STAGING="yes"; shift ;;
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
			--self-test)
				SELF_TEST="yes"; shift
				# 可选过滤模式：紧跟着的下一个参数不以 - 开头就当成模式吃掉。
				# 不这么做，`--self-test state_` 会被当成「多余的位置参数」直接报错，
				# 而带空格正是最顺手的写法。
				if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
					SELF_TEST_PATTERN="$1"; shift
				fi
				;;
			--self-test=*) SELF_TEST="yes"; SELF_TEST_PATTERN="${1#*=}"; shift ;;
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
		# 证书模式相关选项也要在体检里校。共用 validate_cert_options ——
		# 它同时负责选定 CERT_MODE_ACTUAL，do_check 的预览要用这个值。
		validate_cert_options || exit 1
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

# 区域索引的成员：从 ST_INDEX_BEGIN..ST_INDEX_END 里取出「 ～ 标题」列表，
# 打印成一行一标题。语法见文件头那段索引的说明。
section_index_members() {
	awk '
		/^# ST_INDEX_BEGIN$/ { inx = 1; next }
		/^# ST_INDEX_END$/   { inx = 0; next }
		!inx { next }
		{
			sub(/^#[ \t]*～[ \t]*/, "")
			gsub(/[ \t]+$/, "")
			print
		}
	' "$0"
}

# 源码里全部顶格区段标题（列首的 `# ---- 标题 ----`），按出现顺序。
# 只认列首：函数体内缩进的同类注释不是区段，混进来会让下面的比对假红。
section_index_titles() {
	awk '/^# -{16}.*-{16}[ \t]*$/ {
		sub(/^# -+[ \t]*/, ""); sub(/[ \t]*-+[ \t]*$/, ""); print
	}' "$0"
}

# 索引必须与源码里的区段标题「逐条一致且同序」。任一侧多一条、少一条、
# 换来顺序都会红 —— 这才叫索引没漂；只对字数或首尾的弱断言挡不住漂。
# 预期索引「永远含自身这条」，因为它就是一条顶格区段。
index_lists_all_sections() {
	local want="" got=""
	want=$(section_index_titles)
	got=$(section_index_members)
	if [ "$want" = "$got" ]; then
		return 0
	fi
	printf '  区域索引与源码区段标题不一致（- 索引应有 / + 索引实有）：\n' >&2
	diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/    /' >&2
	return 1
}

# 索引里不许出现裸行号（如「阶段 1: 系统依赖 1613」）。那些行号是随手行号，
# 唯一的效果就是改一次文件就漂一次。要稳定只能靠标题。
# 注意别误判标题里的数字：「阶段 1」这种短数字不算行号，所以只逮 3 位以上
# 或者是「标题 空格 数字」这种行号形状。
index_has_line_numbers() {
	local hits=""
	hits=$(section_index_members \
		| grep -nE '[^0-9][0-9]{3,}[[:space:]]*$|[[:space:]][0-9]{1,4}[[:space:]]*$' || true)
	if [ -z "$hits" ]; then
		return 1
	fi
	printf '  索引里出现了疑似行号的数字：\n%s\n' "$hits" >&2
	return 0
}

# 下面这几条会起子进程跑 --self-test。子进程一律带 AMIA_ST_NESTED=1：
# 过滤正常时子进程只跑命中的小段（如 [2] 密码生成），根本到不了本节；
# 但过滤要是坏了（证伪实验①：st_want/st_match 永远返回 0），子进程会跑满全量、
# 再一次进本节、又去起子进程 —— 不拦就是无限链，一路 spawn 到把机器拖垮。
# 本节的断言见到这个旗标就只跳过、不下蛋。
_self_test_nested_skip() {
	if [ "${AMIA_ST_NESTED:-0}" = "1" ]; then
		printf '  跳过：处于子集自检的子进程内（防递归）\n' >&2
		return 0
	fi
	return 1
}

# 行为级：子集过滤命中关键词时必须真的跑、并且退出 0。
# 这条起真子进程，但只跑「密码生成」这种小模式（实测 < 1 秒）；
# 绝不能拿全量断言起子进程，那等于自检里嵌自检、把进程生灭翻倍。
self_test_subset_hits() {
	_self_test_nested_skip && return 0
	local out="" rc=0
	out=$(AMIA_ST_NESTED=1 bash "$0" --self-test "密码生成" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		printf '  期望子集自检命中时退出 0，实得 %s。输出：\n%s\n' "$rc" "$out" >&2
		return 1
	fi
	if ! printf '%s' "$out" | grep -q '子集自检：模式'; then
		printf '  命中时未打印子集自检的行首提示。输出：\n%s\n' "$out" >&2
		return 1
	fi
	return 0
}

# 行为级：关键词一条都匹配不上时必须「报错 + 非 0 退出」。
# 这是本项目反复踩的假通过 —— 静默跑 0 条还报全过，等于自检根本没跑。
# 这条断言就是给「零命中要报错」那段逻辑上的锁。
self_test_subset_missing_errors() {
	_self_test_nested_skip && return 0
	local out="" rc=0
	out=$(AMIA_ST_NESTED=1 bash "$0" --self-test "zzz不存在的关键词zzz" 2>&1) || rc=$?
	if [ "$rc" -eq 0 ]; then
		printf '  期望零命中时报错退出，实得 0。输出：\n%s\n' "$out" >&2
		return 1
	fi
	if ! printf '%s' "$out" | grep -q '没有任何断言匹配'; then
		printf '  零命中时未给出「没有任何断言匹配」的提示。输出：\n%s\n' "$out" >&2
		return 1
	fi
	return 0
}

# 行为级：子集必须「只跑命中的区段」——不多跑。这条是给「过滤静默失效」上的锁。
# 报数行（命中 N / 共 M、另有 K 条被过滤）是 awk 单独扫出来的，跟实际执行无关：
# 过滤整个坏掉时它照样印得漂漂亮亮。所以只能看行为——数真跑出来的区段标题：
# 过滤在，跑「密码生成」只会印 [2] 一个区段；过滤没了（证伪实验①），19 个区段全印。
# 不用「PASS 条数 ≤ 报数」比：报数自身对 [2] 少算一条（既有实现的老毛病，本任务不动），
# 拿它当基准会把一条正确的实现判红。
self_test_subset_isolates_sections() {
	_self_test_nested_skip && return 0
	local out="" rc=0 nsec=0 total=0
	out=$(AMIA_ST_NESTED=1 bash "$0" --self-test "密码生成" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		printf '  子集自检退出 %s。输出：\n%s\n' "$rc" "$out" >&2
		return 1
	fi
	if ! printf '%s' "$out" | grep -q '\[2\] 密码生成'; then
		printf '  子集没跑到目标区段 [2] 密码生成。输出：\n%s\n' "$out" >&2
		return 1
	fi
	# 真跑出来的区段数（只认 `[N] 标题` 的行首形态，PASS 行不会命中）。
	nsec=$(printf '%s' "$out" | grep -cE '^\[[0-9]+\] ')
	total=$(printf '%s' "$out" | sed -n 's/.*共 \([0-9][0-9]*\) 条断言.*/\1/p')
	if [ -z "$total" ]; then
		printf '  读不到报数行里的「共 N 条断言」。输出：\n%s\n' "$out" >&2
		return 1
	fi
	# 上限 2：目标区段 [2] 一个，外加一点余地。过滤正常时是 1，
	# 过滤失效时是整个区段数（十几到二十几），差了一个数量级。
	if [ "$nsec" -gt 2 ]; then
		printf '  子集跑了 %s 个区段（共 %s 条断言），远超命中范围 —— 过滤没生效。\n' \
			"$nsec" "$total" >&2
		printf '  实际跑到的区段：\n%s\n' \
			"$(printf '%s' "$out" | grep -E '^\[[0-9]+\] ' | sed 's/^/    /')" >&2
		return 1
	fi
	return 0
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

# 取函数体，但剥掉注释行。
# 为什么需要：代码级断言（「这里必须调用 X」「这里必须带 --ecc」）如果直接
# 在含注释的函数体上匹配，注释里那句解释性的话会把断言「喂饱」——
# 于是把真正的命令行删掉、断言依然绿。证伪实验实测到过两次：
#   --install-cert ... --ecc 被删（注释里还留着「--ecc 必须带」）→ 断言仍通过
#   openssl s_client 被换成读盘上的文件（注释里还留着「s_client」）→ 断言仍通过
# 所以要断「代码里有没有」，就必须先把注释去掉。
fn_code() {
	fn_body "$1" | grep -v '^[[:space:]]*#' || true
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

# 行为级：OpenRC 且没有 cron 时，install_renewal 必须「警告 + 标记 none」，
# 绝不能返回 0 又不设 RENEW_METHOD（那会让摘要谎称续期已开）。
# 把 install_renewal 挪进子 shell 跑一次，观察它的输出与 RENEW_METHOD。
no_fake_renewal_on_openrc() {
	local lib="" out="" rc=0
	# 用 source 加载主脚本会执行 main；剥掉最后那行 main "$@" 再 source
	lib=$(mktemp) || return 1
	grep -vxF 'main "$@"' "$0" > "$lib" || { rm -f "$lib"; return 1; }
	# shellcheck disable=SC2016  # 子 shell 里刻意用单引号延迟展开 $1
	out=$(bash -c '
		source "$1"
		DEPLOY_LOG=/dev/null
		INIT=openrc
		# 桩：crontab 不存在（模拟真机无 cron），其余命令照常探测
		need_cmd() { [ "$1" = crontab ] && return 1; command -v "$1" >/dev/null 2>&1; }
		RENEW_METHOD=""
		install_renewal >/dev/null 2>&1
		printf "RENEW_METHOD=%s\n" "${RENEW_METHOD}"
	' _ "$lib" 2>/dev/null) || rc=$?
	rm -f "$lib"
	if printf '%s' "$out" | grep -q '^RENEW_METHOD=none$'; then
		return 0
	fi
	printf '  期望 OpenRC 无 cron 时 RENEW_METHOD=none。实际输出：\n%s\n' "$out" >&2
	return 1
}

# 许可证边界（MIT 仓库不得混入 GPL-3.0 的 acme.sh 实现）。
# 判据：acme.sh 内部有几个标志性的、只有它自己的实现才会有的函数名。
# 我们只调用它的 CLI，不该出现这些名字 —— 一旦出现就说明有人把它的代码搬了进来。
# 用 grep -c 而不是 has：这里要读整个 180KB 文件，避免管道 SIGPIPE。
no_vendored_acme() {
	local n=""
	n=$(grep -cE '^_initpath\(\)|^_send_signed_request\(\)|^_readaccountconf_mutable\(\)|^_createkey\(\)' "$0" 2>/dev/null || true)
	[ "${n:-0}" -eq 0 ]
}

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

# 自检结束时的统计行。全量与子集共用同一个格式化点，避免两处文案各改各的。
# 参数: <通过> <失败> <跳过> <被过滤>；被过滤 >0 时才追加说明。
self_test_report() {
	printf '\n----------------------------------------\n'
	if [ "$4" -gt 0 ]; then
		printf '结果: %s%s 通过%s / %s%s 失败%s / %s%s 跳过%s（另有 %s 条被过滤）\n' \
			"$C_GRN" "$1" "$C_RST" "$C_RED" "$2" "$C_RST" "$C_YEL" "$3" "$C_RST" "$4"
	else
		printf '结果: %s%s 通过%s / %s%s 失败%s / %s%s 跳过%s\n' \
			"$C_GRN" "$1" "$C_RST" "$C_RED" "$2" "$C_RST" "$C_YEL" "$3" "$C_RST"
	fi
	if [ "$2" -ne 0 ]; then
		printf '%s\n' "自检未通过，请勿部署。"
		return 1
	fi
	printf '%s\n' "自检全部通过。"
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

	# 用 <<< 而不是管道：大输入 + 匹配在开头时 grep 会提前退出，
# 管道写法在 set -o pipefail 下会让「匹配成功」也返回 141（SIGPIPE）——
# 表现为断言偶发假失败。herestring 没有上游进程，不存在这个问题。
has() { grep -qE "$2" <<< "$1"; }
	# has 的反面。单独定义是因为 false_case 看的是「退出码非 0」，
	# 而管道 + pipefail 下 grep 无匹配本来就是非 0，语义正好对得上。
	# 同 has()：管道写法在 pipefail 下会因 SIGPIPE 产生偶发假失败。
not_has() { if grep -qE "$2" <<< "$1"; then return 1; fi; return 0; }

	skip_case() { printf '  %sSKIP%s %s\n' "$C_YEL" "$C_RST" "$1"; skip=$((skip + 1)); }

	brace_l() { printf '%s' "$1" | tr -cd '{' | wc -c | tr -d ' '; }
	brace_r() { printf '%s' "$1" | tr -cd '}' | wc -c | tr -d ' '; }

	tab_indent_ok() { printf '%s' "$1" | grep -q "^$(printf '\t')"; }
# ---------------- 子集过滤（--self-test <模式>） ----------------
	# 现有 385 条断言一行都没动，过滤是这么实现的：
	#   ① 区段级 —— 断言区以 `[N] 标题` 分段，整段不匹配就整段不执行，
	#      连段内的准备代码（建临时目录 / 渲染配置 / 签证书）一起省掉；
	#   ② 断言级 —— 段里不匹配的断言，交给辅助函数时直接不跑也不计数。
	#      这一层非有不可：断言把子进程当「尾随参数」传（如 `bash "$0" --check`），
	#      子进程只在辅助函数内部才起，不拦在这里就照样要跑满几秒。
	# 一条断言会被执行，当且仅当：断言那一行含关键词，或它所在区段的标题含关键词。
	# 被过滤掉的不算「跳过」、也不计失败，所以不影响退出码。help 口径与此一致。
	st_total=0 st_kept=0 st_secs="" st_lines=""

	st_want() { # <区段号> —— 这一段要不要跑
		if [ -z "${SELF_TEST_PATTERN}" ]; then return 0; fi
		case " ${st_secs} " in
			*" $1 "*) return 0 ;;
		esac
		return 1
	}
	st_match() { # <源码行号> —— 这一条断言要不要跑
		if [ -z "${SELF_TEST_PATTERN}" ]; then return 0; fi
		case " ${st_lines} " in
			*" $1 "*) return 0 ;;
		esac
		return 1
	}

	if [ -n "${SELF_TEST_PATTERN}" ]; then
		local st_scan=""
		# 扫源码一次：得出断言总数、要跑的断言行号、要保留的区段号。
		# 用 $0 而不是函数体 —— 行号必须与 BASH_LINENO 对得上，否则断言级过滤会错位。
		# 认区段标题只认 `printf '...\n[数字] ...'`：本函数里还有别的 printf
		# （打印状态文件内容、拼渲染结果），放宽了会把它们当成区段标题，编号一错，
		# 过滤就整个失效 —— 而且会静默失效（跑 0 条还报全过）。
		# shellcheck disable=SC2016  # awk 程序里的 $0/NR 交给 awk，不是 shell 变量
		st_scan=$(awk -v pat="${SELF_TEST_PATTERN}" '
			/^# ST_ASSERT_BEGIN$/ { inb = 1; next }
			/^# ST_ASSERT_END$/   { inb = 0; next }
			!inb { next }
			{
				if ($0 ~ /^[ \t]*printf .*\[[0-9]+\]/) {
					nsec++
					if (index(tolower($0), tolower(pat)) > 0) hit[nsec] = 1
					next
				}
				if ($0 ~ /^[ \t]*(true|false|eq|skip)_case /) {
					na++
					aln[na] = NR
					asec[na] = nsec
					if (index(tolower($0), tolower(pat)) > 0) amatch[na] = 1
				}
			}
			END {
				kept = 0; secs = ""; lns = ""
				# 一条断言要跑：自己的行命中，或所在区段标题命中（两者独立）。
				for (i = 1; i <= na; i++) {
					if (amatch[i] || hit[asec[i]]) { kept++; lns = lns " " aln[i] }
				}
				# 区段只有当它「还有要跑的断言」时才保留。注意不能用「标题命中」
				# 当保留条件：关键词是 state_ 这种标识符时根本没标题命中，
				# 那样会把所有区段都跳过，跑 0 条还报全过 —— 正是要避免的假通过。
				for (s = 1; s <= nsec; s++) {
					for (i = 1; i <= na; i++) {
						if (asec[i] == s && (amatch[i] || hit[s])) { secs = secs " " s; break }
					}
				}
				printf "TOTAL %d\nKEPT %d\nSECS%s\nLINES%s\n", na, kept, secs, lns
			}
		' "$0") || st_scan=""
		st_total=$(printf '%s\n' "$st_scan" | sed -n 's/^TOTAL //p')
		st_kept=$(printf '%s\n' "$st_scan" | sed -n 's/^KEPT //p')
		st_secs=$(printf '%s\n' "$st_scan" | sed -n 's/^SECS//p')
		st_lines=$(printf '%s\n' "$st_scan" | sed -n 's/^LINES//p')
		# 一条都没匹配上必须当场报错：否则 --self-test typo 会「跑 0 条、报全过」，
		# 正是本项目反复踩的那种假通过。
		if [ "${st_kept:-0}" -eq 0 ]; then
			err "没有任何断言匹配「${SELF_TEST_PATTERN}」—— 换个关键词，或去掉关键词跑全量自检"
			return 1
		fi
		printf '子集自检：模式「%s」，命中 %s / 共 %s 条断言\n' \
			"${SELF_TEST_PATTERN}" "$st_kept" "$st_total"
		# 断言级过滤：把四个辅助函数换成「先问该不该跑、再转交原实现」的包装器。
		# 原实现用 declare -f 拷出来（不是重写的），语义与原来逐字一致。
		local st_fn="" st_def=""
		for st_fn in true_case false_case eq_case skip_case; do
			st_def=$(declare -f "$st_fn")
			eval "_st_orig_${st_fn}${st_def#"${st_fn}"}"
		done
		true_case() {
			if st_match "${BASH_LINENO[0]}"; then _st_orig_true_case "$@"; fi
		}
		false_case() {
			if st_match "${BASH_LINENO[0]}"; then _st_orig_false_case "$@"; fi
		}
		eq_case() {
			if st_match "${BASH_LINENO[0]}"; then _st_orig_eq_case "$@"; fi
		}
		skip_case() {
			if st_match "${BASH_LINENO[0]}"; then _st_orig_skip_case "$@"; fi
		}
	fi



	printf '%s\n' "离线自检 v${SCRIPT_VERSION}（无需 root，不修改系统）"

# ST_ASSERT_BEGIN
	if st_want 1; then
	printf '\n[1] 语法与依赖\n'
	true_case "bash -n 通过" bash -n "$0"
	true_case "curl 可用" command -v curl
	true_case "本文件有可执行位" test -x "$0"

	fi
	if st_want 2; then
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

	fi
	if st_want 3; then
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

	fi
	if st_want 4; then
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
	fi
	if st_want 5; then
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

	fi
	if st_want 6; then
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

	fi
	if st_want 7; then
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

	fi
	if st_want 8; then
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

	fi
	if st_want 9; then
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

	fi
	if st_want 10; then
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

	fi
	if st_want 11; then
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

	fi
	if st_want 12; then
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

	fi
	if st_want 13; then
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

	fi
	if st_want 14; then
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

	fi
	if st_want 15; then
	printf '\n[15] 第二轮评审修复的锁定断言\n'
	fi
	if st_want 16; then
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

	fi
	if st_want 17; then
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

	fi
	if st_want 18; then
	printf '\n[18] acme.sh 证书路径（第四轮新增）\n'
	# ---- 18a) 证书模式的取值与自动选择 ----
	true_case "cert-mode 校验器已定义" command -v validate_cert_mode
	true_case "接受 auto" validate_cert_mode auto
	true_case "接受 acme" validate_cert_mode acme
	true_case "接受 caddy" validate_cert_mode caddy
	true_case "接受 file" validate_cert_mode file
	false_case "拒绝空 cert-mode" validate_cert_mode ''
	false_case "拒绝任意 cert-mode" validate_cert_mode zerossl
	false_case "拒绝大小写不符" validate_cert_mode AUTO

	# 三层降级的决策逻辑：直接测 resolve_cert_mode，不依赖本机装没装 acme.sh。
	# 用「保存/恢复全局 + 桩函数」的方式把每条分支都跑到，避免 CI 环境差异导致漏测。
	local sv_cert="${TLS_CERT_FILE}" sv_key="${TLS_KEY_FILE}" sv_tok="${CF_TOKEN}"
	local mode=""

	# ① 给了文件 → file（最高优先）
	TLS_CERT_FILE="/tmp/c.pem"; TLS_KEY_FILE="/tmp/k.pem"; CF_TOKEN=""
	eq_case "降级①：给了证书文件就选 file" "file" "$(resolve_cert_mode)"

	# ② 没文件、有 token + 有 acme.sh → acme
	# detect_acme_sh 是探测函数，用桩替代，让「有 acme.sh」这条分支可测
	local _orig_detect_acme
	_orig_detect_acme=$(declare -f detect_acme_sh)
	detect_acme_sh() { printf '%s' "/usr/local/bin/acme.sh"; return 0; }
	TLS_CERT_FILE=""; TLS_KEY_FILE=""; CF_TOKEN="tok"
	eq_case "降级②：有 acme.sh 且有 token 就选 acme" "acme" "$(resolve_cert_mode)"

	# ③ 没文件、没 token（哪怕有 acme.sh）→ caddy（没有凭据申请不了 DNS-01）
	CF_TOKEN=""
	eq_case "降级③：没有 Cloudflare token 就退回 caddy" "caddy" "$(resolve_cert_mode)"

	# ④ 没文件、有 token、但没有 acme.sh → caddy
	eval "$_orig_detect_acme"
	detect_acme_sh() { return 1; }
	CF_TOKEN="tok"
	eq_case "降级④：有 token 但没 acme.sh 仍退回 caddy" "caddy" "$(resolve_cert_mode)"
	eval "$_orig_detect_acme"

	TLS_CERT_FILE="${sv_cert}"; TLS_KEY_FILE="${sv_key}"; CF_TOKEN="${sv_tok}"

	# decide_cert_mode：显式 --cert-mode 是硬覆盖
	local sv_mode="${CERT_MODE}" sv_actual="${CERT_MODE_ACTUAL}" sv_tok2="${CF_TOKEN}"
	CERT_MODE="caddy"; CF_TOKEN=""; CERT_MODE_ACTUAL=""
	true_case "显式 caddy 模式被直接采纳" decide_cert_mode
	eq_case "显式 caddy 覆盖了自动判断" "caddy" "${CERT_MODE_ACTUAL}"
	CERT_MODE="acme"; CF_TOKEN=""
	false_case "显式 acme 但没 token 被拒" decide_cert_mode
	CERT_MODE="${sv_mode}"; CERT_MODE_ACTUAL="${sv_actual}"; CF_TOKEN="${sv_tok2}"

	# ---- 18b) Cloudflare token 只从文件/环境变量来 ----
	true_case "token 载入函数已定义" command -v load_cf_token
	local tdir_tok="" saved_tokfile="${CF_TOKEN_FILE}" saved_tok="${CF_TOKEN}" saved_envtok="${CF_Token:-}"
	tdir_tok=$(mktemp -d)
	unset CF_Token
	CF_TOKEN_FILE="${tdir_tok}/t"; CF_TOKEN=""
	printf 'AbC123_-xyz\n' > "${tdir_tok}/t"
	true_case "从文件读 token 成功" load_cf_token
	eq_case "token 内容正确" "AbC123_-xyz" "${CF_TOKEN}"
	# 换行/回车/空白都要被剥掉：token 里本来就不该有这些
	printf '  AbC123_-xyz  \r\n' > "${tdir_tok}/t"; CF_TOKEN=""
	load_cf_token
	eq_case "token 首尾空白与回车被剥掉" "AbC123_-xyz" "${CF_TOKEN}"
	# 含非法字符（如空格、等号、引号）必须拒绝 —— 它是从文件流向子进程环境的
	printf 'abc def\n' > "${tdir_tok}/t"; CF_TOKEN=""
	false_case "含空格的 token 被拒" load_cf_token
	printf 'export CF_Token=abc\n' > "${tdir_tok}/t"; CF_TOKEN=""
	false_case "带 export 前缀的 token 被拒" load_cf_token
	# 环境变量优先于文件
	printf 'fromfile\n' > "${tdir_tok}/t"
	CF_TOKEN_FILE="${tdir_tok}/t"; CF_TOKEN=""
	CF_Token="fromenv"
	load_cf_token
	eq_case "环境变量优先于文件" "fromenv" "${CF_TOKEN}"
	unset CF_Token
	CF_TOKEN_FILE="${saved_tokfile}"; CF_TOKEN="${saved_tok}"
	if [ -n "${saved_envtok}" ]; then CF_Token="${saved_envtok}"; fi
	rm -rf "${tdir_tok}"

	# 关键边界：命令行不能有 --cf-token（会进 shell 历史）。
	# 否则用户会以为「能直接传」，然后 token 留在 ~/.bash_history 里。
	# 认「选项列表里的 --cf-token」（行首两空格开始）—— 正文里提到它是正当的。
	false_case "帮助的选项列表里没有 --cf-token" has "$(bash "$0" --help)" '^  --cf-token '
	false_case "参数解析里没有 --cf-token" has "$(fn_body parse_args)" '\-\-cf-token\)'
	true_case "帮助里收录 --cf-token-file" has "$(bash "$0" --help)" 'cf-token-file'
	true_case "帮助里说明为何不直接传值" has "$(bash "$0" --help)" 'shell 历史'

	# ---- 18c) 续期：reload 脚本与 systemd timer ----
	true_case "reload 脚本渲染器已定义" command -v render_acme_reload_script
	true_case "timer 渲染器已定义" command -v render_acme_renew_timer
	true_case "renew service 渲染器已定义" command -v render_acme_renew_service

	local rl="" svc="" tmr=""
	rl=$(render_acme_reload_script)
	svc=$(render_acme_renew_service)
	tmr=$(render_acme_renew_timer)

	# 事实 1 的固化：必须用 caddy reload --force，不能只 systemctl reload。
	# 剥掉注释行再断言 —— 注释里正当地解释了「为什么不用 systemctl reload」。
	local rl_code=""
	rl_code=$(printf '%s' "$rl" | grep -v '^[[:space:]]*#' || true)
	true_case "续期脚本用 caddy reload --force" has "$rl_code" 'reload --force'
	# 绝不能有 `systemctl reload caddy || ...` —— 它退出码是 0，兜底永不执行
	false_case "续期脚本没有 systemctl reload 兜底（会静默失效）" has "$rl_code" 'systemctl reload caddy'
	true_case "续期脚本有 restart 兜底" has "$rl_code" 'systemctl restart caddy'
	# 首次安装：--install-cert 会在阶段 4（Caddyfile 还没写）就调这个脚本一次。
	# 那时没有东西可重载，必须成功退出 —— 否则 acme.sh 判 installcert 失败，
	# 整个阶段 4 挂掉，而证书其实已经装好了。
	# 模式里的 $ 和 { } 都是 grep -E 的元字符，必须转义，否则永远匹配不上（假绿）。
	true_case "配置不存在时跳过 reload（首次安装）" has "$rl_code" '! -f "\$\{CONF_FILE\}"'
	true_case "服务未运行时跳过 reload" has "$rl_code" 'is-active --quiet caddy'
	# 权限收敛：真机上验证过的 750/644/640 布局
	true_case "目录权限 750" has "$rl_code" 'chmod 0750'
	true_case "全链 644" has "$rl_code" 'chmod 0644'
	true_case "私钥 640" has "$rl_code" 'chmod 0640'
	true_case "属主收敛为 root:caddy" has "$rl_code" 'chown root:caddy'
	# 判据是 caddy 用户能否真读到，不是权限位看着对
	true_case "用 runuser 实测 caddy 可读" has "$rl_code" 'runuser -u caddy'

	# timer：每天 + 随机延迟 + 补跑（与真机上验证过的 unit 对齐）
	true_case "timer 用 OnCalendar=daily" has "$tmr" '^OnCalendar=daily$'
	true_case "timer 有随机延迟" has "$tmr" 'RandomizedDelaySec=3600'
	true_case "timer 开机补跑" has "$tmr" '^Persistent=true$'
	true_case "timer 挂到 timers.target" has "$tmr" 'WantedBy=timers.target'
	# service：oneshot + 跑 acme.sh --cron
	true_case "renew service 是 oneshot" has "$svc" '^Type=oneshot$'
	true_case "renew service 调 acme.sh --cron" has "$svc" '\-\-cron'
	# 注意：grep -E 会把模式开头的 -- 当成选项结束符，所以这里用空格前缀而不是 \-\-。
	true_case "renew service 带上 --home" has "$svc" ' --home '
	# 生成的脚本必须是合法 bash（与主脚本同样对待）
	# 写进临时文件再 bash -n，验证渲染产物本身能过语法检查
	local rlf=""
	rlf=$(mktemp)
	printf '%s\n' "$rl" > "$rlf"
	true_case "渲染出的 reload 脚本通过 bash -n" bash -n "$rlf"
	rm -f "$rlf"

	# ---- 18d) 调用点贯通：不装续期就没有自动续期 ----
	true_case "acme 模式才装续期" has "$(fn_body install_service)" 'CERT_MODE_ACTUAL'
	# 体检预览必须与实际渲染一致：acme 模式下预览也要把 tls 指到统一落点，
	# 否则用户看到的 `tls <邮箱>` 和真正写进去的证书路径对不上（预览在说谎）。
	true_case "体检预览在 acme 模式下指到统一落点" has "$(fn_code do_check)" 'CERT_FILE'
	true_case "install_service 调用 install_renewal" has "$(fn_body install_service)" 'install_renewal'
	true_case "OpenRC 无 cron 时明确警告" has "$(fn_body install_renewal)" '无法自动续期'
	true_case "OpenRC 有 cron 时才装 cron 任务" has "$(fn_body install_renewal)" 'crontab'
	# 没有可靠定时机制时不能假装成功：RENEW_METHOD 必须落到 none，
	# 摘要才会照实说「未开启自动续期」，而不是打绿勾。
	true_case "无定时机制时标记为 none" has "$(fn_code install_renewal)" 'RENEW_METHOD="none"'
	true_case "有 systemd 时标记为 systemd" has "$(fn_code install_renewal)" 'RENEW_METHOD="systemd"'
	# 行为级：OpenRC + 无 cron 必须真的警告且不改用假成功
	true_case "OpenRC 无 cron 时不谎报续期已开" no_fake_renewal_on_openrc
	# acme 模式的申请与落点
	true_case "申请函数已定义" command -v issue_cert_with_acme
	# ECDSA 证书必须带 --ecc，否则找不到 <域名>_ecc 目录（真机踩过）。
	# 用剥掉注释的 fn_code：否则注释里那句「--ecc 必须带」会让断言假绿。
	true_case "install-cert 带 --ecc" has "$(fn_code issue_cert_with_acme)" '\-\-ecc'
	# --issue 跳过时返回 2，不能当成失败
	true_case "issue 的退出码 2 当跳过处理" has "$(fn_code issue_cert_with_acme)" 'rc.*-ne 2'
	true_case "DNS-01 走 dns_cf" has "$(fn_code issue_cert_with_acme)" 'dns_cf'
	true_case "staging 用 letsencrypt_test" has "$(fn_code issue_cert_with_acme)" 'letsencrypt_test'
	# 装完立刻切 CA —— 不切会静默用 ZeroSSL（源码 DEFAULT_CA=$CA_ZEROSSL）
	true_case "切默认 CA 的函数已定义" command -v set_acme_default_ca
	true_case "切 CA 用 --set-default-ca" has "$(fn_body set_acme_default_ca)" 'set-default-ca'
	true_case "切 CA 指到 letsencrypt" has "$(fn_body set_acme_default_ca)" 'server letsencrypt'
	true_case "acme_prepare 会调用切 CA" has "$(fn_body acme_prepare)" 'set_acme_default_ca'
	# 无 cron 时必须 --force（官方安装器否则拒绝安装）
	true_case "无 cron 时安装器加 --force" has "$(fn_body install_acme_sh)" 'force="--force"'
	true_case "安装前检查是否有 cron" has "$(fn_body install_acme_sh)" 'need_cmd crontab'
	# 许可证边界：绝不 vendor acme.sh 源码
	true_case "从官方地址拉安装器（不 vendor）" has "$(fn_body install_acme_sh)" 'get.acme.sh'
	# 注意：这里刻意不用 has "$(cat "$0")" —— 本文件 180KB，管道喂给提前退出的
	# grep 会让 printf 吃到 SIGPIPE，pipefail 下成功的匹配也会变成退出码 141。
	# 改判「源码里有没有把 acme.sh 的实现搬进来」的标志性函数名。
	true_case "仓库里没有内嵌 acme.sh 的实现" no_vendored_acme
	true_case "帮助里点明 GPL/MIT 边界" has "$(bash "$0" --help)" 'GPL'

	# ---- 18e) 证书落点统一 ----
	true_case "证书目录常量存在" has "$(grep -m1 '^CERT_DIR=' "$0")" '/etc/ssl/naiveproxy'
	true_case "全链落点常量" has "$(grep -m1 '^CERT_FILE=' "$0")" 'fullchain[.]pem'
	true_case "私钥落点常量" has "$(grep -m1 '^CERT_KEY_FILE=' "$0")" 'privkey[.]pem'
	true_case "布局收敛函数已定义" command -v normalize_cert_layout
	true_case "收敛函数设目录 750" has "$(fn_body normalize_cert_layout)" 'chmod 0750'
	true_case "收敛函数设私钥 640" has "$(fn_body normalize_cert_layout)" 'chmod 0640'
	true_case "收敛函数设全链 644" has "$(fn_body normalize_cert_layout)" 'chmod 0644'
	# ensure_cert_readable 要认得我们自己的目录，走确定布局而非 o+rx 兜底
	true_case "ensure_cert_readable 认得统一落点" has "$(fn_body ensure_cert_readable)" 'normalize_cert_layout'

	# ---- 18f) 验证阶段：证书判据必须来自握手（事实 1 的教训）----
	# 用 fn_code：注释里提到 s_client 不算数，必须是代码里真的连了握手。
	# 证伪实测：把这一行换成读盘上的文件、注释不动时，只有 fn_code 能把变红。
	true_case "验证用 openssl s_client 读握手" has "$(fn_code verify_deployment)" 's_client'
	true_case "s_client 连的是本机端口（不是读文件）" has "$(fn_code verify_deployment)" 'connect "127[.]0[.]0[.]1'
	true_case "验证报告签发者" has "$(fn_code verify_deployment)" 'issuer'
	true_case "验证报告到期时间" has "$(fn_code verify_deployment)" 'enddate'
	true_case "验证报告 DNS 名" has "$(fn_code verify_deployment)" 'subject'

	# ---- 18g) 状态文件贯通（新键往返 + 再校验） ----
	true_case "状态写入保存证书模式" has "$(fn_body state_write)" 'STATE_CERT_MODE'
	true_case "状态读取解析证书模式" has "$(fn_body state_parse_into_vars)" 'STATE_CERT_MODE'
	true_case "状态再校验覆盖证书模式" has "$(fn_body state_revalidate)" 'STATE_CERT_MODE'
	local saved_state3="${STATE_FILE}" tdir3=""
	tdir3=$(mktemp -d)
	STATE_FILE="${tdir3}/state"
	DOMAIN="a.example.com"; EMAIL="o@m.test"; NAIVE_USER="tom"
	NAIVE_PASS="Aa12345678"; HTTPS_PORT="443"; ALLOW_PORTS=""
	PROBE_SECRET=""; PAC_PATH=""; CLIENT_PROTO="https"
	TLS_CERT_FILE="${CERT_FILE}"; TLS_KEY_FILE="${CERT_KEY_FILE}"
	CERT_MODE_ACTUAL="acme"
	state_write
	DOMAIN=""; EMAIL=""; NAIVE_USER=""; NAIVE_PASS=""; HTTPS_PORT=""
	CERT_MODE_ACTUAL=""
	state_parse_into_vars
	eq_case "往返：证书模式" "acme" "${STATE_CERT_MODE}"
	true_case "往返后仍通过再校验" state_revalidate
	# 被改坏的证书模式必须在再校验时被拦下
	printf 'STATE_DOMAIN=a.example.com\nSTATE_USER=tom\nSTATE_PASS=Aa12345678\nSTATE_PORT=443\nSTATE_CERT_MODE=bogus\n' > "${STATE_FILE}"
	state_parse_into_vars
	false_case "状态文件里的非法证书模式被拦下" state_revalidate
	rm -rf "${tdir3}"
	STATE_FILE="${saved_state3}"

	# ---- 18h) 行为级：真实命令行 ----
	false_case "体检拒绝非法 cert-mode" bash "$0" --check --domain a.example.com --email o@m.test --cert-mode bogus
	false_case "体检拒绝 --cert-mode file 却无文件" bash "$0" --check --domain a.example.com --email o@m.test --cert-mode file
	false_case "体检拒绝 --cert-mode acme 却无 token" bash "$0" --check --domain a.example.com --email o@m.test --cert-mode acme
	false_case "体检拒绝不存在的 token 文件" bash "$0" --check --domain a.example.com --email o@m.test --cf-token-file /nonexistent/cf
	true_case "体检接受 auto 模式（无 token 时退 caddy）" bash "$0" --check --domain a.example.com --email o@m.test --cert-mode auto
	true_case "体检默认就是 auto" bash "$0" --check --domain a.example.com --email o@m.test
	true_case "--acme-staging 被接受" bash "$0" --check --domain a.example.com --email o@m.test --acme-staging
	# --cert-mode= 等号形式（与 --tls-cert= 同源的一致性要求）
	false_case "cert-mode= 等号形式同样生效" bash "$0" --check --domain a.example.com --email o@m.test --cert-mode=bogus

	fi
	# ---- 19) 子集自检自身的收尾（SC2295 / 区域索引 / 过滤行为）----
	# 这一节单独成节，不混进上面任何既有区段：既有 385 条一行没动，这里纯新增。
	if st_want 19; then
	printf '\n[19] 子集自检收尾（SC2295 / 区域索引 / 过滤行为）\n'

	# ---- 19a) SC2295：${st_def#…} 的展开式必须单独加引号 ----
	# 裸写 ${st_def#${st_fn}} 时 st_fn 会被当 glob 模式匹配。当下值恰好是纯字面量
	# 所以没出错，但一旦有特殊字符（* ? [）就会静默截错，包装器被定义成残体，
	# 表现为「断言静默变成空断言」。用 fn_code 断，注释里写到的样子不算数。
	true_case "去前缀展开式的变量带引号（SC2295）" \
		has "$(fn_code self_test)" '\$\{st_def#"\$\{st_fn\}"\}'
	true_case "不再出现未加引号的去前缀展开式" \
		not_has "$(fn_code self_test)" '\$\{st_def#\$\{st_fn\}\}'

	# ---- 19b) 区段索引：存在、覆盖全部区段标题、且不写死行号 ----
	true_case "文件头有区域索引" has "$(head -80 "$0")" '区域索引'
	true_case "索引列齐了全部区段标题" index_lists_all_sections
	false_case "索引里不写死精确行号" index_has_line_numbers

	# ---- 19c) 过滤行为：命中要跑、零命中要报错 ----
	# 这两条是真行为级：起真子进程跑 --self-test，看它的退出码与输出。
	# 注意这里刻意只跑小模式（「密码生成」子集 < 1 秒）；绝不能对全量断言起子进程 ——
	# 那等于在自检里再嵌一轮 78 秒自检，会成倍放大进程生灭。
	true_case "子集命中关键词时正常跑并退出 0" self_test_subset_hits
	true_case "子集零命中时退出非 0 且给出提示" self_test_subset_missing_errors
	# 过滤「静默失效」（最危险的一种坏法）：报数行照旧漂亮，实际却跑满全量。
	# 只数真跑出来的 PASS，不看报数行，才逮得住。
	true_case "子集只跑命中的断言、不多跑" self_test_subset_isolates_sections

	fi
# ST_ASSERT_END
	if self_test_report "$pass" "$fail" "$skip" "$((st_total - st_kept))"; then
		return 0
	fi
	return 1
}

main "$@"
