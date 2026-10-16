# BATCH B1 — A2（`--check` 退出码）+ G（判不出当没事）

> **两者必须同批**：G 改的是 `do_check` 的退出码**输入**（`problems`），A2 改的是**输出**（返回值）。
> 分两批会出现中间坏版本。

## 红线（违反即本批次失败）

1. **只做 A2 与 G 两项。** 不许顺手改 F3/F1/F2/A/B/F4（那是下一批）。
2. **不加 `--strict` / 任何"严格模式"开关** —— 诚实必须是默认行为。
3. **不许改 `run_stage`（约 422-437）**、**不许改 `print_summary` 的位置**（约 3067）、**不许改退出码判定**（约 3082）。
4. **不许碰生产服务器。**
5. **`--self-test` 失败数必须为 0**（本批会动 6 条断言，改完必须全绿）。

---

## 任务 B1.1 — A2：`do_check` 发现问题却退 0

**现状（实测）**：`bash ./deploy-naive-caddy.sh --check --domain a.example.com --email ops@mail.test` 打印「有 1 项需要先处理」但 **`rc=0`**。

**目标**：`problems > 0 → `--check` 退 **1**；无问题 → 退 **0**。

**位置**：`do_check()`（约 **2663**），`problems` 累加在 2669/2680/2684/2704/2723/2733，结论块 2779-2786；`main` 的 `--check` 分派 **3027**`do_check` / **3028**`return 0`。

**怎么做**：`do_check` 以 `problems` 计数作为返回值；`main` **显式传播**（不要依赖 `set -e` 的隐式行为）。

**必改的 6 条断言**（它们拿 `a.example.com` 做 `--check` 却期望退 0）：
`:4006` `:4013` `:4324` `:4561` `:4562` `:4563`

**⚠️ 改写的正解**：**不是**无脑改成 `false_case` —— 那会让 `4006`「--check 无需 root 即可完成」的语义退化成"必然失败"。应改为**只读性断言**（例如断言 stdout 含「结论」，或断言 `rc != 126`；用你新加的 `rc_case` 更贴切）。

**需新增**：
1. `false_case`（或 `rc_case`）断言「体检发现问题时退出非 0」—— 与 `4006` 成对。
2. **干净环境必须退 0**（防"一刀切退 1"的护栏）：走沙箱桩（剥掉 `main "$@"` 后 source，桩 `port_state=free` / `get_public_ip=1.2.3.4` / `resolve_domain_ip=1.2.3.4` / `curl` 成功）。

---

## 任务 B1.2 — G：`unknown` 端口被当"没问题"

**现状**：`ss` 缺失时 `port_state` 返回 `unknown`，但两处都只 `note` 一行，**不计入 problems、不 confirm**，随后照打 `ok "预检完成"`（约 **1626**）。

**位置（两份重复逻辑，必须同批改）**：
- 预检：`check_ports_free()`（约 **1581**）的 `*)` 分支 **1604-1607**（`note` 在 1605）
- 体检：`do_check()` 内另一份等价循环 **2695-2715**，`*)` 分支 **2710-2713**（`note` 在 2711）
- 三态来源：`port_state()`（约 **1499-1510**，`unknown` 在 1502）

**怎么做（两处口径必须一致，否则 `--check` 与 `preflight` 会对同一台机器给出不同裁决）**：
- `do_check`（2710-2713）→ **`problems++`**（于是 `--check` 退 1）。理由：「我查不了」≠「可以装」。
- `check_ports_free`（1604-1607）→ **升级为一次 `confirm`**（与 **1598** 端口被占同格）。
  **⚠️ 写法必须与 1598 同格**：`[ "$ASSUME_YES" = "yes" ] || confirm "仍然继续？"`

**⚠️ 环境警告**：本机实测**没有 `ss`**。`ci.yml` 的 ubuntu **自带** `iproute2`；`alpine-openrc.yml` 的 `alpine:3.20` **不带**。
⇒ **B1.1 改写后的断言绝不能依赖 `ss` 存在**，否则"ubuntu 绿、Alpine 红"。一律走沙箱桩。

**需新增**：
1. 结构断言：`fn_code do_check` 的端口 `*)` 分支**必须含 `problems=`**。
2. 行为断言（**桩掉 `ss`，确定性**）：沙箱里让 `need_cmd ss` 失败 → `problems ≥ 1` → `--check` 非 0。

---

## 验收（跑完贴原始输出）

```bash
cd naiveproxy
bash -n deploy-naive-caddy.sh && echo "语法 OK"

# ① A2：有问题必须退 1（现状退 0）
bash ./deploy-naive-caddy.sh --check --domain a.example.com --email ops@mail.test </dev/null >/tmp/o 2>&1
echo "A2 exit=$?（期望 1）"; grep -o '有 .* 项需要先处理' /tmp/o

# ② G：do_check 的端口 *) 分支必须计入 problems
lib=$(mktemp); grep -vxF 'main "$@"' deploy-naive-caddy.sh > "$lib"
bash -c 'source "$1"; fn_code do_check' deploy-naive-caddy.sh "$lib" \
  | sed -n '/^[[:space:]]*\*)/,/;;/p' | grep -c 'problems='
# 期望 >=1（现状 0）

# ③ 全量自检必须全绿
bash ./deploy-naive-caddy.sh --self-test; echo "rc=$?"
```

## 完成后报告

1. `do_check` 的返回值怎么传的（贴改动片段）
2. 6 条断言**各自改成了什么**（逐条）
3. G 两处分别改成了什么
4. 新增了哪几条断言（名字 + 内容）
5. 验收 ①②③ 的**原始输出**
6. `git status --short`

## 红线复述（违反即失败）

1. **只做 A2 + G**
2. **不加 `--strict` 开关**
3. **不动 `run_stage` / `print_summary` 位置 / 3082**
4. **不碰生产服务器**
5. **`--self-test` 失败数必须为 0**
