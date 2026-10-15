# 任务：给部署脚本加退出码 2（部署完成但验证未确认）

## 绝对不要做（红线）

1. **禁止在 `verify_deployment()` 里写 `exit` 或 `die`** —— 会走 `run_stage`(行427-434) → `exit 1`，跳过 `print_summary`(行3050)，**用户拿不到密码和 config.json**。这比原 bug 更伤用户。判定逻辑只能放 `main` 末尾。
2. **禁止把 ②③④⑤ 改成 `return 1`** —— 首次部署时证书还在签发（`sleep 2` 后握手必然失败），会误报失败。
3. **禁止修改现有 393 条断言的任何一行** —— 只能新增。
4. **禁止生成整份脚本副本做实验** —— 用 `git stash` 或临时目录。
5. **禁止并行跑自检** —— 单轮 78 秒 × N 并发会打满 CPU。
6. **禁止碰生产服务器** `root@82.139.194.92`。
7. **禁止提交、禁止 push** —— 我来推。

## 背景（≤6 行）

阶段 7 `verify_deployment()`（行 2180-2277）检查 5 件事，但只有「服务 is-active」会 `return 1`；
另外 4 项（本机 HTTPS 握手 / 证书信息 / 代理转发实测 / 公网可达）用 `verify_warn()`（行 2175），
**只累加计数器、不改退出码**。结果这 4 项全失败时退出码仍是 0 ——
`if sudo ./deploy.sh; then` 会走进"成功"分支。横幅本身是诚实的（"有 N 项需要你确认"）。

## 要做（编号）

**1. 核心改动 —— 唯一控制流改动点**

`main()` 行 3050 `print_summary` **之后**追加：

| 退出码 | 条件 |
| --- | --- |
| `0` | `VERIFY_WARNINGS = 0`（全部通过） |
| `0` | `VERIFY_SKIPPED = yes`（用户显式 `--skip-verify`） |
| `1` | 致命失败（现有 die / run_stage 路径，**不动**） |
| `2` | `VERIFY_SKIPPED = no` 且 `VERIFY_WARNINGS > 0` |

**2. 横幅配套**（行 2388 附近，"有 N 项需要确认"分支）
文案补「（退出码 2）」—— 否则人看到进程码 2 会以为"参数写错了"。

**3. usage() / help**（行 517 附近）
新增退出码说明（0/1/2 三段 + `--skip-verify` 记 0）。**必须写明语义**，不能让下一个人猜。

**4. 加行为断言**（不是字符串匹配，起真子进程）
照 `stage_rc_propagates`（行 3240-3257）的模板，加一条"有警告时 main 退出 2"的行为断言。

**5. 文档**
README 选项表 + 新增「退出码」小节；CHANGELOG `[Unreleased]` 标为**可观察行为变更**；
`docs/VERIFICATION.md` 更新。**版本号升 minor**（当前 2.5.0 → 2.6.0）。

## 验收（必须贴实际输出）

```bash
bash -n deploy-naive-caddy.sh                                  # exit 0
/tmp/sc11/shellcheck.exe -x -S style deploy-naive-caddy.sh     # 零告警
bash deploy-naive-caddy.sh --self-test                         # ≥393 通过 / 0 失败
# 行为验证（起真子进程，这是关键）：
#   有警告时退出码必须是 2，不是 0
```

- 判据 1：`verify_deployment` 体内**没有**新增 `exit`/`die`
- 判据 2：新逻辑在 `print_summary` 之后
- 判据 3：`--skip-verify` 时退出码 0
- 判据 4：有 warning 时退出码 **2**（贴实测）
- 判据 5：原 393 条断言零改动

## 止损

- **10 分钟无可测量进展 → 立刻停下报告。**
- 全量自检单次超 3 分钟 → 用 `--self-test <模式>` 定位，别反复全量跑。
- 改动若超过 3 个文件 → 停下报告，先确认范围。

## 环境

- Git Bash on Windows；`/tmp` 实为 `~/.config/alma/scratch`
- shellcheck 在 `/tmp/sc11/shellcheck.exe`（0.11.0）
- **别直接跑 `caddy validate`** 校验生成的 Caddyfile（会建出 `D:\var`）；用 `validate-caddyfile.sh`
- 工作区：`D:\AiWork\AMIA\naiveproxy`（main 分支，当前 4e6653a）

## 红线复述（与开头一字不差）

1. **禁止在 `verify_deployment()` 里写 `exit` 或 `die`**。
2. **禁止把 ②③④⑤ 改成 `return 1`**。
3. **禁止修改现有 393 条断言的任何一行**。
4. **禁止生成整份脚本副本做实验**。
5. **禁止并行跑自检**。
6. **禁止碰生产服务器** `root@82.139.194.92`。
7. **禁止提交、禁止 push**。
