# BATCH A — Phase 0 对齐（不碰部署逻辑）

## 红线（违反即本批次失败）

1. **只做本文件列的 3 件事。** 不许顺手改别的、不许"顺便优化"。范围外改动 = 失败。
2. **不许碰生产服务器**（82.139.194.92）。不 ssh / 不 scp / 不跑真部署路径。
3. **不许改 `deploy-naive-caddy.sh` 的部署逻辑**（本批次只加测试辅助 + 改文档）。
4. **跑完必须 `bash ./deploy-naive-caddy.sh --self-test` → 406 通过 / 0 失败**（加 `rc_case` 后条数可能 +N，但**失败必须为 0**）。
5. **退出码三档语义不许动**：`0` 成功｜`1` 致命｜`2` 验证未确认。禁用 `126/127/128+n`。

---

## 任务 A1 — 行号机检（产出差异表，不改代码）

**做什么**：把 `docs/Execution-Flow.md` 与 `docs/IMPLEMENTATION-PLAN.md` 里所有 `行 NNN`、函数区间抽出来，逐条对 `deploy-naive-caddy.sh` 核。

**怎么做**：
```bash
cd naiveproxy
grep -nE '^(do_check|main|confirm|check_domain_dns|check_ports_free|print_summary|install_service|install_caddy_binary|verify_deployment|do_rotate_password|preflight|run_stage|do_uninstall|verify_warn|port_state)\(\) \{' deploy-naive-caddy.sh
```

**产出**：把差异写进 `docs/IMPLEMENTATION-PLAN.md` 的 §0.1 表格（已有一张表，**追加你新发现的**，不要删已有的）。

**已知需修（已确认，直接改）**：
| 位置 | 现状 | 应为 |
| --- | --- | --- |
| `deploy-naive-caddy.sh:3697` / `:4569` 注释 | 「既有 **385** 条断言一行没动」 | 403/406 |
| `deploy-naive-caddy.sh:3193` 注释 | 「**19** 个区段全印」 | **20** |
| `.github/workflows/alpine-openrc.yml:77` | 引 `renderers_silent()` @ 脚本 `3335` | `3596` |
| `.github/workflows/alpine-openrc.yml:98` | 引「脚本 **1327** 行注释」 | `1341` |

---

## 任务 A2 — 修 `docs/Execution-Flow.md` 两处旧措辞（**必须做，否则两份文档互相矛盾**）

| # | 位置 | 改成 |
| --- | --- | --- |
| 1 | `:640` 与 `:658` | 去掉「含 4001/4002 改写」「A 与 4001/4002 必须同批」，注明「**4001/4002 的代价归 Phase 2（无参数分流）**」 |
| 2 | `:655-656` | 「B 必须不晚于 A ……」→「**B 与 A 必须同批，且 B 的 `confirm` 必须受 `ASSUME_YES` 管辖**」 |
| 3 | `§10.4` 的 **C**（文档滞后）后 | 补一句：**C 是 Phase 3 前置 2 的输入**（前置 2 要记录 7 阶段基线，判据正是 C 描述的两处过时文档） |

**为什么**：不改的话，实施者按 `:640` 会在 Phase 1 就动 `4001/4002`（误伤 —— A 不动无参数路径，那两条不会红）。

---

## 任务 A3 — 新增断言辅助 `rc_case`

**目标**：让「期望退出码 == N」成为一等断言。

**位置**：`self_test` 里的 `true_case`/`false_case`/`eq_case`/`skip_case`（约 **3654** 起）。

**怎么做**：
1. 新增第 5 个辅助 `rc_case <名称> <期望码> <命令...>`：跑命令，比对实际退出码与期望码，相等 PASS 否则 FAIL。
2. **必须**同步扩展 **3779** 的过滤包装器列表：
   ```bash
   for st_fn in true_case false_case eq_case skip_case
   ```
   **加上 `rc_case`** —— 否则 `--self-test <模式>` 的子集过滤会**静默漏测**（不报错！）。
3. 加一条 `rc_case` 的**自证断言**（证明它自己可用）。

**验收**：
```bash
cd naiveproxy
bash -n deploy-naive-caddy.sh && echo "语法 OK"
bash ./deploy-naive-caddy.sh --self-test; echo "rc=$?"      # 必须 rc=0，失败 0
bash ./deploy-naive-caddy.sh --self-test "帮助"; echo "rc=$?"  # 子集模式也要 rc=0
```
**⚠️ `--self-test` 的参数是【区段关键词】，词必须真实存在于输出里；**用不存在的词会 rc=1。

---

## 完成后报告（逐条给证据，不要只说"做完了"）

1. A1 差异表：**新增**了哪几条（贴出来）
2. A2：改了哪几行（`文件:行号` + 前后文）
3. A3：`rc_case` 加在哪个区段；`3779` 那行改成什么；自证断言的名字
4. 自检结果：`--self-test` 的 **通过/失败/跳过** 三个数 + `rc=`
5. `git status --short`（应只有预期文件）

## 红线复述（同开头，违反即失败）

1. **只做 A1/A2/A3 三件事，范围外一律不动**
2. **不碰生产服务器**
3. **不改部署逻辑**
4. **`--self-test` 失败数必须为 0**
5. **退出码三档语义不许动**
