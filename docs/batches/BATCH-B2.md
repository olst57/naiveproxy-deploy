# BATCH B2 — F3（client-config 静默失败）+ F1/F2（enable 被吞）+ F4（未校验不告知）

## 红线（违反即本批次失败）

1. **只做 F3 / F1 / F2 / F4 四项。** 不许顺手改别的。
2. **不许改用 `run_stage`（约 422-437）让阶段返回 1** —— 那会跳过 `print_summary`，**用户拿不到密码**，违反红线。
3. **F3 调用点② 有【顺序陷阱】**（见下），**必须**先保证新密码已打印再失败化，否则用户被锁在门外。
4. **F4 必须保持退出码 0**（不许算 `verify_warn`）。
5. **不许碰生产服务器**；**`--self-test` 失败数必须为 0**。

---

## 任务 B2.1 — F3：`client-config.json` 写失败被吞（**两处调用点，机制不同！**）

**现状**：写失败被 `|| true` 吞掉，而摘要照广告「已存到 X，权限 0600」。

**调用点①（首次部署）** — `print_summary` 内约 **2389-2392**（2390 写、2391 `chmod`），广告在 **2428**。
⚠️ **2429 是【重新渲染】打到屏幕**（不是 `cat` 那个文件）⇒ **屏幕永远显示正确 JSON，即使文件没写成**。

**调用点②（换密码）** — `do_rotate_password`（定义约 **2548**）内 **2594**（写）、**2595**（`chmod`），广告在 **2604**。

### 两处的退出码机制【不同】—— 这是本任务的核心

| | 调用点① `print_summary` | 调用点② `do_rotate_password` |
| --- | --- | --- |
| 机制 | **`verify_warn`**（能走到 3082 → 收尾退 **2**）| **`die`**（退 **1**）|
| 为什么 | 摘要已打印，`verify_warn` 在这里天然生效 | `main:3052` 是 `if [ "$ROTATE_PASSWORD" = "yes" ]; then do_rotate_password; return 0; fi` —— **`return 0` 无条件弃值**，`verify_warn` 只加计数器、**退出码仍是 0**（= 换个地方假绿）|

### 🔴 调用点② 的顺序陷阱（必须处理）

`do_rotate_password` 的既有顺序：
```
2590 落盘新 Caddyfile → 2593 state_write → 2594 写 client-config
→ 2602 ok "密码已更换" → 2603 才打印新密码
```
**若在 2594 直接 `die`：新密码已生效、服务已重载，但用户看不到新密码 → 被锁在门外。**

**两种解法（任选，推荐第一种）**：
- **（推荐）把 2594/2595 移到 2603 打印新密码之后** —— 最简单、最少状态
- 保留原位，但**先打印新密码**再失败化（双段式）

**⚠️ 必须写 `|| die "…"` 而不是只去掉 `|| true`** —— `set -Eeuo pipefail` 下裸 `render_client_config > file` 失败会直接终止脚本（不经你的 `die` 文案）。参照 2590/2593 的既有写法。

### 需新增断言

1. **结构**：`fn_code print_summary` / `fn_code do_rotate_password` **不得**含 `CLIENT_CONF … || true`（用 `fn_code` 而非 `fn_body` —— 注释会喂饱断言）。
2. **结构**：`fn_body do_rotate_password` 中「打印新密码」**必须早于**「写失败的失败化」。
3. **行为①**：沙箱里 `CREDS_KNOWN=yes` + `CLIENT_CONF` 指向不可写路径 → 调 `print_summary` → `VERIFY_WARNINGS > 0` 且 stdout **不含**「已存到」。
4. **行为②**：沙箱里 `CLIENT_CONF` 不可写 → 调 `do_rotate_password` → **非 0 退出**且 stdout **含**新密码。
   ⚠️ 注意：`_verify_exit_sandbox` 里 `CREDS_KNOWN` 实为 **`yes`**（约 **3462**）—— 行为断言**测得到**。

**注意**：`4618`（`verify_items_only_count`）要求 4 项全失败时 `VERIFY_WARNINGS == 4`。它直调 `verify_deployment`，不受 F3 影响，但**必须作为回归项跑**。

---

## 任务 B2.2 — F1 / F2：开机自启被吞（**必须同批**）

**F1**：`install_service`（约 **2148**）systemd 分支 **2156**：`systemctl enable caddy >/dev/null 2>&1 || true`
**F2**：同函数 openrc 分支（`elif` 约 **2163**）**2168**：`rc-update add caddy default >/dev/null 2>&1 || true`

**目标**：失败 → **`verify_warn`**（→ 收尾退 **2**）+ 明确文案（"重启后不会自启"）。
**⚠️ 阶段函数仍返回 0** —— 不要 `return 1`（那会经 `run_stage:436 exit 1` 跳过摘要，用户丢密码 = 假失败）。

**需新增**：
1. 结构：`fn_code install_service` 不得出现 `(systemctl enable caddy|rc-update add caddy)` 与 `|| true` 同行。
2. 行为：failure-injection 容器内（systemd 真跑、带 `--yes`）阶段 6 后断言 `systemctl is-enabled caddy` 为 `enabled`。

**⚠️ 语义张力（同批处理）**：`usage`（约 524-532）把 2 定义为「未确认」，这里是「已确认有问题」。
若放宽措辞，**必须保留 `print_summary` 横幅里的 `退出码 2` 子串**（断言 `4634` 盯着它）。

---

## 任务 B2.3 — F4：未做完整性校验不告知（**只补文案，退出码保持 0**）

**位置**：`install_caddy_binary`（约 **1843**）：`want=$(resolve_caddy_digest || true)` 在 **1862**，guard `if [ -n "$want" ]` **1863**，**1874** `warn "该发布没有提供校验和…"`。

**目标**：让"未校验"在 **`print_summary`（约 2385）里回显**，而不是一行灰字过去。
（与 `VERIFY_SKIPPED` 同族的「状态回显」模式 —— 需要一个跨阶段标志。）

**⚠️ 退出码必须保持 0**。理由：① 是否提供 digest 是**上游**行为，不是本机部署质量；② 用户本地**无法修复**它，变成非零 = **每次部署都退 2** 的假失败；③ 上游侧已有守门（`upstream-drift.yml` 每日查 digest 并 `::error::`）。

**需新增**：结构断言（`fn_body install_caddy_binary` 的无 digest 分支必须设状态；`fn_body print_summary` 必须引用它）+ 行为断言（桩 `resolve_caddy_digest` 返回 1 → **退出码仍为 0**）。

---

## 验收（跑完贴原始输出）

```bash
cd naiveproxy
bash -n deploy-naive-caddy.sh && echo "语法 OK"
lib=$(mktemp); grep -vxF 'main "$@"' deploy-naive-caddy.sh > "$lib"

# ① F3 两处调用点都不得再有 || true（现状各 2）
for f in print_summary do_rotate_password; do
  printf "  %s: " "$f"
  bash -c 'source "$1"; fn_code "$2"' deploy-naive-caddy.sh "$lib" "$f" \
    | grep -cE 'CLIENT_CONF.*\|\|[[:space:]]*true'
done
# 期望 0 / 0

# ② F1/F2（现状 2）
bash -c 'source "$1"; fn_code install_service' deploy-naive-caddy.sh "$lib" \
  | grep -cE '(enable caddy|rc-update add caddy).*\|\|[[:space:]]*true'
# 期望 0

# ③ 回归：4618 那条不受影响
bash ./deploy-naive-caddy.sh --self-test; echo "rc=$?"
```

## 完成后报告

1. F3 调用点① 改了什么（贴片段）；② 改了什么（**说明你选了哪种解法**）
2. F1/F2 改了什么
3. F4 的跨阶段标志叫什么、`print_summary` 怎么引用
4. 新增断言逐条（名字 + 内容）
5. 验收 ①②③ 原始输出
6. `git status --short`

## 红线复述（违反即失败）

1. **只做 F3 / F1 / F2 / F4**
2. **不让阶段函数返回 1**（会跳过摘要 → 用户丢密码）
3. **F3 调用点② 必须先打印新密码再失败化**
4. **F4 退出码保持 0**
5. **不碰生产服务器；`--self-test` 失败数为 0**
