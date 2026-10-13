#!/usr/bin/env bash
#
# validate-caddyfile.sh — 安全地校验/规范化本项目的 Caddyfile
#
# 为什么需要它：配置里有 `output file /var/log/caddy/access.log`。在 Windows 上
# 用官方 caddy 跑 validate / fmt 时，Git Bash 会把 `/var/...` 解析成「当前盘符下的
# \var\...」，于是 caddy 真会在宿主机上建出 D:\var\log\caddy\access.log。
# 这个坑踩过不止一次，所以固化成工具：只在自己的临时目录里工作。
#
# 做法：复制到临时目录 → 日志输出整块换成 discard → 剥掉 naive 专有指令
#      → 校验 + 对比 fmt → 删临时目录。全程不写宿主机其他位置。
#
# 用法:
#   ./validate-caddyfile.sh                  # 校验同目录的 Caddyfile
#   ./validate-caddyfile.sh other.Caddyfile
#   CADDY=/path/to/caddy ./validate-caddyfile.sh
#
set -Eeuo pipefail

TARGET="${1:-Caddyfile}"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET_PATH="$TARGET"
[ -f "$TARGET_PATH" ] || TARGET_PATH="${SCRIPT_DIR}/${TARGET}"
[ -f "$TARGET_PATH" ] || { printf '找不到配置文件: %s\n' "$TARGET" >&2; exit 1; }

find_caddy() {
	if [ -n "${CADDY:-}" ]; then printf '%s' "$CADDY"; return 0; fi
	local c=""
	for c in caddy caddy.exe; do
		if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
	done
	for c in "${SCRIPT_DIR}/caddy" "${SCRIPT_DIR}/caddy.exe"; do
		if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
	done
	return 1
}

find_python() {
	local p=""
	for p in python3 python; do
		if command -v "$p" >/dev/null 2>&1 \
		   && printf '{}' | "$p" -c 'import json,sys;json.load(sys.stdin)' >/dev/null 2>&1; then
			printf '%s' "$p"; return 0
		fi
	done
	return 1
}

CADDY_BIN=$(find_caddy) || {
	printf '找不到 caddy。可用环境变量指定，例如:\n  CADDY=/tmp/caddy.exe %s\n' "$0" >&2
	exit 1
}
# 后面要 cd 进临时目录，所以先转绝对路径
case "$CADDY_BIN" in
	/*|[A-Za-z]:*) : ;;
	*) CADDY_BIN="${PWD}/${CADDY_BIN}" ;;
esac
[ -x "$CADDY_BIN" ] || { printf 'caddy 不可执行: %s\n' "$CADDY_BIN" >&2; exit 1; }

WORK=$(mktemp -d)
# shellcheck disable=SC2329  # cleanup 由 trap ... EXIT 间接调用，shellcheck 0.11.0 的
# 「函数从未被调用」启发式看不见 trap，会对它误报（本文件结尾有显式 exit，更易触发）。
# 保留 trap 形式是刻意选择：EXIT trap 在 set -e 下异常退出时也会执行，比在所有出口手写
# rm -rf 更可靠。详见 https://www.shellcheck.net/wiki/SC2329
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FULL="${WORK}/full.Caddyfile"
PLAIN="${WORK}/plain.Caddyfile"

# 把 `output file …{ … }` 整块换成 `output discard`。
# 只换 output 那一行不够：块里的 roll_size/roll_keep/roll_keep_for 是 file writer 的
# 子指令，discard 不认；而保留 file 输出又会让 caddy 在宿主机上真建目录。
sanitize_log() {
	local py=""
	if py=$(find_python); then
		PYTHONIOENCODING=utf-8 "$py" "${WORK}/sanitize.py" "$1"
		return 0
	fi
	awk '
		/^[[:space:]]*output file / { print "\t\toutput discard"; inblk = 1; next }
		inblk && /^[[:space:]]*\}[[:space:]]*$/ { inblk = 0; next }
		inblk { next }
		{ print }
	' "$1"
}

# 剥掉 naive 构建专有的指令（官方 caddy 不认识它们）
strip_naive_only() {
	local py=""
	if py=$(find_python); then
		PYTHONIOENCODING=utf-8 "$py" "${WORK}/strip.py" "$1"
		return 0
	fi
	awk '
		/^[[:space:]]*order forward_proxy/ { next }
		/^[[:space:]]*forward_proxy \{/ { skip = 1; next }
		skip && /^[[:space:]]*\}[[:space:]]*$/ { skip = 0; next }
		skip { next }
		{ print }
	' "$1"
}

cat > "${WORK}/sanitize.py" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
pat = re.compile(r'^(\s*)output file [^\n]*\{(?:.*?\n)*?\1\}', re.M | re.S)
s = pat.sub(lambda m: m.group(1) + 'output discard', s)
# 必须写字节：Windows 上 Python 的 stdout 默认走控制台代码页（GBK），
# 直接 sys.stdout.write 会把中文编成 GBK，下游按 UTF-8 读就炸。
sys.stdout.buffer.write(s.encode('utf-8'))
PYEOF

cat > "${WORK}/strip.py" <<'PYEOF'
import re, sys
TAB, NL = chr(9), chr(10)
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace(TAB + 'order forward_proxy before file_server' + NL + NL, '')
s = re.sub(TAB + r'forward_proxy \{.*?' + NL + TAB + r'\}' + NL + NL, '', s, flags=re.S)
sys.stdout.buffer.write(s.encode('utf-8'))
PYEOF

sanitize_log "${TARGET_PATH}" > "${FULL}"
strip_naive_only "${FULL}" > "${PLAIN}"

if grep -q 'forward_proxy' "${PLAIN}"; then
	printf '警告：剥离后仍残留 forward_proxy，结果可能不代表真实配置\n' >&2
fi
if grep -q 'output file' "${FULL}"; then
	printf '警告：日志输出未被替换成 discard —— 校验可能在宿主机上建目录！\n' >&2
fi

printf 'caddy      %s\n' "$("${CADDY_BIN}" version 2>&1 | head -1)"
printf '校验对象   %s\n' "${TARGET_PATH}"
printf '工作目录   %s（结束时删除）\n\n' "${WORK}"

printf '── validate（已剥离 naive 专有指令，日志改为 discard）──\n'
VALIDATE_RC=0
( cd "${WORK}" && "${CADDY_BIN}" validate --config "${PLAIN}" --adapter caddyfile ) || VALIDATE_RC=$?

printf '\n── 与 caddy fmt 对比 ──\n'
if ( cd "${WORK}" && "${CADDY_BIN}" fmt "${FULL}" ) > "${WORK}/fmt.out" 2>/dev/null; then
	if cmp -s "${FULL}" "${WORK}/fmt.out"; then
		printf '已经是 caddy 规范格式（fmt 无改动）\n'
	else
		printf 'fmt 会改动以下位置：\n'
		diff "${FULL}" "${WORK}/fmt.out" | head -40 || true
	fi
else
	printf 'fmt 执行失败（跳过对比）\n'
fi

printf '\n── 结论 ──\n'
if [ "${VALIDATE_RC}" -eq 0 ]; then
	printf '配置有效（在剥离 naive 专有指令后校验通过）\n'
else
	printf '配置校验失败，退出码 %s\n' "${VALIDATE_RC}"
fi
printf '宿主文件系统未被改动。\n'
exit "${VALIDATE_RC}"
