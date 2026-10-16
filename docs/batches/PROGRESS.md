# 实施进度（v2.7.0）

分支：**`fix/honest-verdict-v2.7.0`**（基于 `main` @ `c7b4f15`）

| 批次 | 内容 | 状态 |
| --- | --- | --- |
| **A** | Phase 0 对齐（行号机检 + 修 Execution-Flow 旧措辞 + `rc_case`）| ⬜ 待做 |
| **B1** | A2（`--check` 退出码）+ G（判不出当没事）| ⬜ 待做 |
| **B2** | F3（两处，机制不同）+ F1/F2（enable 被吞）+ F4 | ⬜ 待做 |
| **B3** | A（非 TTY Default-Deny）+ B（DNS 两分支）+ 版本收尾 | ⬜ 待做 |
| **验收** | 4 个 CI 门禁全绿 → 合并 main → tag v2.7.0 | ⬜ 待做 |

## 实施后的对照基线（现状实测，改前）

| 检查 | 现状 | 改后应为 |
| --- | --- | --- |
| `--check --domain a.example.com` 退出码 | **0** | **1** |
| F3 `print_summary` 的 `CLIENT_CONF … \|\| true` | **2** | **0** |
| F3 `do_rotate_password` 同上 | **2** | **0** |
| F1/F2 `(enable caddy\|rc-update add caddy) … \|\| true` | **2** | **0** |
| G `do_check` 端口 `*)` 分支含 `problems=` | **0** | **≥1** |
| B `fn_body check_domain_dns` 含 `confirm` | **1** | **≥2** |
| A 真实路径（`preflight \|\| exit 1`，桩 `confirm` 返回 1）| **rc=0 + 打印"!! 未拦住"** | **rc=1** |
| `fn_body confirm` 含 `exit 0`（保 4030/4031）| **1** | **≥1** |
| `--self-test` | 406 通过 / 0 失败 / 0 跳过 | 失败 0（条数可增）|

## 关键命令形态（验收用，已实测跑通）

```bash
cd /d/AiWork/AMIA/naiveproxy
lib=$(mktemp); grep -vxF 'main "$@"' deploy-naive-caddy.sh > "$lib"
# $0 位置传真脚本路径（fn_body/fn_code 靠 $0 定位），库从 $1 进
bash -c 'source "$1"; fn_code print_summary' deploy-naive-caddy.sh "$lib"
```
⚠️ **不许用** `bash -c 'source <(grep -vxF "main \"\$@\"" …)'` —— 引号不平衡会「假绿」（输出 0 行）。

## 已确认的关键陷阱（实施时必须处理）

1. **A 单改 `confirm()` = 假修** —— `main:3058` 是 `preflight || exit 1`，`||` 挂起 `errexit`，
   且 `preflight` 返回最后一条命令的值（`1626 ok "预检完成"` = 0）。
   实测：桩 `confirm` 返回 1 后，警告照打、`ok "预检完成"` 照打、**rc=0**。
   ⇒ 必须 `preflight` 内 `1620-1622` 显式 `|| return 1`。
2. **F3 调用点② 不能照抄①** —— `main:3052` 的 `return 0` 弃值，`verify_warn` 静默失效，须走 `die`。
   且 `do_rotate_password` 里新密码在 2603 才打印，**直接 die 会让用户被锁门外**。
3. **Alpine CI 不带 `iproute2`** —— 新断言不许依赖 `ss`，一律走沙箱桩。
