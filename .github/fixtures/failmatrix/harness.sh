#!/usr/bin/env bash
# ============================================================================
# 失败注入夹具（failmatrix harness）
#
# 在【容器里】对 deploy-naive-caddy.sh 的指定阶段注入失败，然后实测 4 件事：
#   ① 退出码   ② 有没有清晰错误信息   ③ 留下什么残留   ④ 撤销注入后重跑能否恢复
#
# 红线遵守：
#   · 不修改被测脚本一个字节 —— 只用「环境」制造失败（PATH 垫片 / 占位 / 只读 / 占端口）
#   · 不生成被测脚本的副本
#   · 一次只跑一个阶段（串行由 workflow 保证）
#   · 只在容器里跑。绝不在生产服务器或开发机上跑。
#
# 用法：STAGE=<1..7> bash harness.sh
# ============================================================================
set -u

STAGE="${STAGE:-}"
SCRIPT="${SCRIPT:-/opt/deploy-naive-caddy.sh}"
DOMAIN="proxy.test.example"
EMAIL="ops@mail.test"
CERT_DIR="/etc/ssl/naiveproxy"
OUT="${OUT:-/out}"
mkdir -p "$OUT"

say() { printf '[harness] %s\n' "$*"; }

# ---------------------------------------------------------------- 公共环境
# 用自签证书 + --cert-mode file：让阶段 4~7 完全离线、确定性，
# 不会去碰 Let's Encrypt（避免把 CI 变成对外发请求的证书签发）。
prepare_common() {
	mkdir -p "$CERT_DIR"
	openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
		-keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
		-subj "/CN=${DOMAIN}" >/dev/null 2>&1
	cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/chain.pem"
}

DEPLOY_ARGS=(--domain "$DOMAIN" --email "$EMAIL" --cert-mode file
	--tls-cert "$CERT_DIR/fullchain.pem" --tls-key "$CERT_DIR/privkey.pem" --yes)

# ---------------------------------------------------------------- 注入
inject() {
	case "$STAGE" in
	1)
		# 让 need_cmd curl 失败 → 脚本走「安装依赖」分支；
		# 再把包管理器换成必然失败的垫片。
		mv -f /usr/bin/curl /root/curl.hidden
		cat > /usr/local/bin/apt-get <<'SHIM'
#!/bin/sh
echo "E: 注入的失败 —— 包管理器不可用（failmatrix stage 1）" >&2
exit 100
SHIM
		chmod +x /usr/local/bin/apt-get
		;;
	2)
		# 让 GitHub 解析到本机 → 下载必然「连接被拒」，且立刻失败不用等超时。
		printf '127.0.0.1 github.com\n127.0.0.1 api.github.com\n127.0.0.1 objects.githubusercontent.com\n' >>/etc/hosts
		;;
	3)
		# 用普通文件占住 /etc/caddy 这个目录名 → mkdir -p 必然失败。
		rm -rf /etc/caddy
		: >/etc/caddy
		;;
	4)
		# 把 Caddyfile 目标做成目录 → `> /etc/caddy/Caddyfile` 重定向必然失败
		# （root 也绕不过「Is a directory」）。
		mkdir -p /etc/caddy/Caddyfile
		;;
	5)
		# 把 index.html 目标做成目录 → `cat > .../index.html` 必然失败。
		# 注意：dir_has_foreign_content 会把 index.html 排除，所以不会误触「有外来内容」分支。
		mkdir -p /var/www/naive-camouflage/index.html
		;;
	6)
		# 双栈占住 443 → caddy 绑定失败 → Type=notify 的服务起不来。
		cat >/opt/hold443.py <<'PY'
import socket, threading
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(('::', 443))
s.listen(16)
threading.Event().wait()
PY
		setsid python3 /opt/hold443.py >/dev/null 2>&1 </dev/null &
		sleep 1
		ss -ltn 2>/dev/null | grep -q ':443' || say "!! 警告：443 没占住，注入可能无效"
		;;
	7)
		# 目标：让服务跑起来之后立刻被停掉，模拟「启动即崩 / 被 OOM」。
		#
		# 2026-10-15 这版注入【静默失效】过：脚本阶段 7 照样看到「服务进程运行中」。
		# 三个原因，逐个修：
		#  ① ExecStartPost 是同步的，直接在里面 systemctl stop 会死锁 → 必须后台化。
		#  ② 但用普通 `( ... ) &` 后台化还不够：后台进程留在 caddy.service 的 cgroup 里，
		#     服务一停 cgroup 被清理，它自己也被杀掉 → 循环没跑几轮就没了。
		#     改用 setsid 脱离会话（阶段 6 占端口就是这么做的，它生效了）。
		#  ③ 循环时长要盖过「脚本阶段 6 restart → 阶段 7 检查」的窗口，
		#     且必须把日志落到文件，事后能查它到底有没有干活。
		cat >/usr/local/bin/zz-inject-stop-caddy.sh <<'KILL'
#!/bin/sh
# 脱离会话 + 脱离 cgroup，否则服务一停它自己也没了。
setsid sh -c '
  echo "[$(date -Is)] injector 启动" >>/var/log/zz-inject.log
  sleep 1
  i=0
  while [ "$i" -lt 60 ]; do
    if systemctl stop caddy >/dev/null 2>&1; then
      echo "[$(date -Is)] 第 $i 轮 stop caddy 成功" >>/var/log/zz-inject.log
    fi
    i=$((i+1))
    sleep 1
  done
  echo "[$(date -Is)] injector 结束（跑了 $i 轮）" >>/var/log/zz-inject.log
' >/dev/null 2>&1 </dev/null &
exit 0
KILL
		chmod +x /usr/local/bin/zz-inject-stop-caddy.sh
		mkdir -p /etc/systemd/system/caddy.service.d
		cat >/etc/systemd/system/caddy.service.d/zz-inject.conf <<'DROPIN'
[Service]
Restart=no
ExecStartPost=/usr/local/bin/zz-inject-stop-caddy.sh
DROPIN
		systemctl daemon-reload
		;;
	esac
}

# ---------------------------------------------------------------- 注入生效自检
# 为什么必须做：inject 装完只打「注入完成」是**声称**，不是**事实**。
# 2026-10-15 实测就踩了：阶段 7 的 ExecStartPost 注入静默失效（caddy 照样活着），
# 矩阵却把「退出码 0」记成「脚本不报错」—— 夹具自己犯了它要抓的那种「跑了但报绿」。
# 所以每个注入点装完必须【独立查一次】，不生效就明确报错，绝不假装跑成功。
injection_effective() {
	case "$STAGE" in
	1)
		# 注入：apt-get 被替换成假命令、curl 被藏起
		[ -x /usr/local/bin/apt-get ] || return 1
		! command -v curl >/dev/null 2>&1 || [ -f /root/curl.hidden ]
		;;
	2)
		# 注入：/etc/hosts 把 github.com 指到 127.0.0.1
		grep -qE '127\.0\.0\.1[[:space:]]+(github\.com|api\.github\.com)' /etc/hosts
		;;
	3)
		# 注入：/etc/caddy 被一个普通文件占住（mkdir -p 必失败）
		[ -e /etc/caddy ] && [ ! -d /etc/caddy ]
		;;
	4)
		# 注入：/etc/caddy/Caddyfile 被做成目录（重定向必失败）
		[ -d /etc/caddy/Caddyfile ]
		;;
	5)
		# 注入：index.html 被做成目录（cat > 必失败）
		[ -d /var/www/naive-camouflage/index.html ]
		;;
	6)
		# 注入：443 被 hold443.py 占住
		ss -ltn 2>/dev/null | grep -q ':443[[:space:]]'
		;;
	7)
		# 注入：drop-in 已落盘且被 systemd 接受。
		# ★ 这是当初失效的那个：只查文件存在不够 —— drop-in 必须真的进了单元配置，
		#   而且要能确认「停服务」确实发生了。这里查三件事：
		#   ① 文件在 ② systemd 已读到该 drop-in（daemon-reload 生效） ③ ExecStopPost 真的会在启动后停掉它
		[ -f /etc/systemd/system/caddy.service.d/zz-inject.conf ] || return 1
		systemctl show caddy -p Restart 2>/dev/null | grep -q 'Restart=no' || return 1
		systemctl cat caddy 2>/dev/null | grep -q 'zz-inject-stop-caddy' || return 1
		# 关键：注入脚本本身必须可执行、且真能停掉服务（服务得先起来才能验证）
		[ -x /usr/local/bin/zz-inject-stop-caddy.sh ]
		;;
	*) return 0 ;;
	esac
}

# 独立验证「失败注入是否真的生效」：装完立刻查，不生效就升级为硬错误。
# 用进程级证据（injection_effective）+ 一步行为探针，避免只查文件存在。
assert_injection_effective() {
	if injection_effective; then
		say "注入生效自检: 通过（阶段 $STAGE）"
		return 0
	fi
	say "！！！注入生效自检: 失败（阶段 $STAGE）—— 这次运行的结果不可信"
	say "    这说明注入没打中，退出码反映的是「没注入」而不是「脚本行为」。"
	return 1
}

# ---------------------------------------------------------------- 撤销注入
lift() {
	case "$STAGE" in
	1)
		rm -f /usr/local/bin/apt-get
		[ -f /root/curl.hidden ] && mv -f /root/curl.hidden /usr/bin/curl
		;;
	2)
		sed -i '/127\.0\.0\.1 \(github\.com\|api\.github\.com\|objects\.githubusercontent\.com\)/d' /etc/hosts
		;;
	3) rm -f /etc/caddy ;;
	4) rm -rf /etc/caddy/Caddyfile ;;
	5) rm -rf /var/www/naive-camouflage/index.html ;;
	6)
		pkill -f hold443.py >/dev/null 2>&1
		sleep 1
		;;
	7)
		rm -f /etc/systemd/system/caddy.service.d/zz-inject.conf
		pkill -f zz-inject-stop-caddy >/dev/null 2>&1
		systemctl daemon-reload
		;;
	esac
	return 0
}

# ---------------------------------------------------------------- 跑一次
run_deploy() { # <输出文件> → stdout 打印退出码
	local out="$1" rc=0
	bash "$SCRIPT" "${DEPLOY_ARGS[@]}" >"$out" 2>&1
	rc=$?
	printf '%s' "$rc"
}

# ---------------------------------------------------------------- 残留快照
residue() {
	local p=""
	{
		printf 'user-caddy: '
		id caddy 2>/dev/null || echo '(无)'
		for p in /usr/bin/caddy /etc/caddy /etc/caddy/Caddyfile /var/log/caddy \
			/var/lib/caddy /var/www/naive-camouflage /etc/systemd/system/caddy.service \
			/etc/ssl/naiveproxy; do
			if [ -e "$p" ]; then printf 'exists: %s\n' "$(ls -ld "$p" 2>&1)"
			else printf 'absent: %s\n' "$p"; fi
		done
		printf 'svc-active:  '; systemctl is-active caddy 2>&1 || true
		printf 'svc-enabled: '; systemctl is-enabled caddy 2>&1 || true
		printf 'ports-80-443: '
		ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -E ':(80|443)$' | tr '\n' ' '
		echo
		printf 'hosts-残留行数: '
		grep -c "$DOMAIN" /etc/hosts 2>/dev/null || echo 0
		printf 'leaked-tmpdirs: '
		ls -d /tmp/tmp.* 2>/dev/null | wc -l
	}
}

# ---------------------------------------------------------------- 主流程
main() {
	say "stage=$STAGE  script=$SCRIPT"
	prepare_common
	inject

	# 注入生效自检：不通过就【立刻退出非 0】。
	# 绝不能继续跑 —— 否则矩阵会拿「注入没打中」的读数冒充「脚本行为」，
	# 这正是 2026-10-15 那次阶段 7 假结论的成因。
	if ! assert_injection_effective; then
		{
			echo "STAGE=$STAGE"
			echo "INJECT_EFFECTIVE=no"
			echo "RC_FIRST=na"
			echo "RC_RERUN=na"
			echo "RC_RECOVER=na"
			echo "HAS_STAGE_BANNER=na"
			echo "HAS_ERR_GLYPH=na"
			echo "HAS_FAIL_WORD=na"
			echo "RERUN_STABLE=na"
		} >"$OUT/result.env"
		cat "$OUT/result.env"
		return 1
	fi
	say "注入完成"

	local rc_a rc_b rc_c
	rc_a=$(run_deploy "$OUT/run-a.log"); residue >"$OUT/residue-a.txt"
	say "第一次退出码 = $rc_a"

	say "重跑（注入仍在）"
	rc_b=$(run_deploy "$OUT/run-b.log"); residue >"$OUT/residue-b.txt"
	say "第二次退出码 = $rc_b"

	say "撤销注入后重跑"
	lift
	rc_c=$(run_deploy "$OUT/run-c.log"); residue >"$OUT/residue-c.txt"
	say "恢复跑退出码 = $rc_c"

	local banner="no" glyph="no" failmsg="no"
	grep -q "第 ${STAGE} 步 / 共 7 步" "$OUT/run-a.log" && banner="yes"
	grep -q '✗' "$OUT/run-a.log" && glyph="yes"
	grep -q '失败' "$OUT/run-a.log" && failmsg="yes"

	{
		echo "STAGE=$STAGE"
		echo "INJECT_EFFECTIVE=yes"
		echo "RC_FIRST=$rc_a"
		echo "RC_RERUN=$rc_b"
		echo "RC_RECOVER=$rc_c"
		echo "HAS_STAGE_BANNER=$banner"
		echo "HAS_ERR_GLYPH=$glyph"
		echo "HAS_FAIL_WORD=$failmsg"
		echo "RERUN_STABLE=$([ "$rc_a" = "$rc_b" ] && echo yes || echo no)"
	} >"$OUT/result.env"
	cat "$OUT/result.env"
}

main
