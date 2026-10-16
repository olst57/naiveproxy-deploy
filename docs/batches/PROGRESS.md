# 实施进度 v2.7.0 —— ✅ 已完成并合并

**v2.7.0 已打 tag 并推送。** PR [#1](https://github.com/olst57/naiveproxy-deploy/pull/1) 已 squash 合并到 `main`。

| 批次 | 内容 | 状态 | commit |
| --- | --- | --- | --- |
| **A** | Phase 0 对齐（`rc_case` + 修过时行号引用）| ✅ | `8dadad9` |
| **B1** | A2（`--check` 退 1）+ G（判不出计入 problems）| ✅ | `63a8968` |
| **B2** | F3（两处机制不同）+ F1/F2（enable 被吞）+ F4 | ✅ | `17caba8` |
| **B3** | A（非 TTY Default-Deny + 显式传播）+ B（DNS 两分支）+ 版本收尾 | ✅ | `c92c405` |
| **验收** | 4 门禁全绿 → 合并 → tag `v2.7.0` | ✅ | `8fe8efb` |

## 最终读数（对照实施前）

| 检查 | 改前 | 改后 |
| --- | --- | --- |
| `--check --domain a.example.com` 退出码 | **0** | **1** |
| A 真实路径（`preflight \|\| exit 1`）| **rc=0 + 打印"未拦住"** | **rc=1** |
| A 端口循环路径 | **未测** | **rc=1** |
| F3 `print_summary` / `do_rotate_password` 的 `\|\| true` | 2 / 2 | **0 / 0** |
| F1/F2 `install_service` 的 `\|\| true` | 2 | **0** |
| G `do_check` 端口 `*)` 分支含 `problems=` | 0 | **1** |
| B `fn_body check_domain_dns` 含 `confirm` | 1 | **2** |
| `--self-test` | 406 / 0 / 0 | **448 / 0 / 0** |
| `shellcheck -x -S style`（CI 门禁）| **exit=1**（B1 起）| **exit=0** |

## CI 门禁（PR #1，commit `c92c405`）

| 门禁 | 结果 |
| --- | --- |
| `CI` 6 步（bash -n / shellcheck / self-test / 可执行位 / lf / 版本一致性）| ✅ success |
| `arm64` | ✅ success |
| `Alpine / OpenRC` | ✅ success |
| `failure-injection` | 未触发（只认 `ci/failmatrix` 或 `main`）|

---

## ⚠️ 教训（本轮真实发生，必须记住）

### 1. 我在验证时把 `git stash` 写进了循环 → 差点丢失 B3 的全部改动

排查 shellcheck 时我写了：
```bash
for c in 8dadad9 63a8968 17caba8 HEAD; do
  git stash -q 2>/dev/null; git checkout -q $c -- deploy-naive-caddy.sh; ...
done
```
**`git stash` 在 `$c=HEAD` 那次把工作区的未提交改动（B3 全部）stash 走了**，而且跑 4 次产生多个 stash。

**恢复方式**（记录下来供下次用）：`git stash list` → 逐个 `git show stash@{N}:<file> | grep SCRIPT_VERSION`
找到目标是 `2.7.0` 的那个 → `git checkout stash@{N} -- <files>` → `git stash clear`。

**规则**：**任何会改动工作区/暂存区的 git 命令，不许放进循环或批量验证脚本。**

### 2. 我提交 B1/B2 时没跑 shellcheck → CI 实际是红的

- B1 提交时我只跑了 `--self-test`，**没跑 shellcheck**。
- B2 时我跑了，但用错判据：我数「SC 条数不增」，而 **CI 要求的是 `shellcheck -x -S style` exit 0**。
- `alpine-openrc.yml` 的 shellcheck 是**信息性、不设门禁**（第 62-64 行注释明说），所以它绿了，掩盖了红灯。

**规则**：**提交前必须跑本仓库 CI 真正执行的每一条命令原文**，不是它的近似。

### 3. B3 实施者发现的「循环洞」（spec 漏写）

`check_ports_free` 是**循环**：端口 80 被拒后循环继续，443 空闲的 `ok` 会**覆盖**失败 →
函数仍返回 0 → 部署继续。

⇒ 只在 `preflight` 内的三个 `check_*` 调用点加 `|| return 1` **不够**，
必须在 `confirm` 的每个调用点也追加 `|| return 1`。

实测量化：只加 preflight 传播 → `main` rc=**0** + 打印「预检完成」（假绿）；
加循环内传播 → rc=**1**。

**规则**：传播失败时，**循环体内的判定点要单独检查** —— 后面迭代的成功会覆盖前面的失败。

---

## 尚未验证 / 已知边界

1. **容器级 F1/F2 断言**（阶段 6 后 `systemctl is-enabled caddy` 须为 `enabled`）
   本机无法执行（Windows 无 systemd）。需 push `ci/failmatrix` 或跑 `failure-injection` 验证。
2. **Alpine 端到端**仍未跑过（`docs/VERIFICATION.md` 自承）—— Phase 3 的 **D** 项因此押后，
   前置是「先建 Alpine E2E 测试床」。
3. **Phase 2 向导**（v2.8.0）未开工（无参数分流 + `wizard_collect` 纯函数）。
