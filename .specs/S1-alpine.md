# 任务：给脚本加 Alpine/OpenRC 真机 CI 覆盖

## 绝对不要做（红线）

1. **禁止碰生产服务器** `root@82.139.194.92` —— 上面跑着线上代理，且有明天 16:14 待触发的证书签发 timer。一切测试只在 CI 跑。
2. **禁止并行跑自检** —— 单轮 78 秒 × N 并发会打满 CPU。一次只跑一个。
3. **禁止修改现有 393 条断言的任何一行** —— 只能新增。
4. **禁止生成整份脚本副本做实验** —— 要试改用 `git stash` 或临时目录。
5. **禁止提交、禁止 push** —— 收尾统一做。
6. **禁止为了"让测试变绿"去改脚本行为** —— 如果 Alpine 上某条断言真的失败，**如实报告**，那可能正是要发现的 bug。

## 背景（≤5 行）

脚本有 OpenRC 分支（`render_openrc_script()`、`rc-service` 调用），但**从没在真 Alpine 上跑过**，只有断言覆盖。
现在要加一条 CI，在真 Alpine 容器里跑脚本，看它到底行不行。
仓库是 public，GitHub Actions 免费。

## 要做（编号）

1. 新建 `.github/workflows/alpine-openrc.yml`：
   - 用 `container: alpine:3.20`（真 Alpine 用户态）
   - 装依赖：`bash curl tar xz shellcheck openrc`
   - 跑 `bash -n deploy-naive-caddy.sh`
   - 跑 `bash deploy-naive-caddy.sh --self-test`，**报告完整结果**
2. 如果自检在 Alpine 上有失败，**逐条列出失败断言 + 原因**。不要掩盖。
3. 验证 `render_openrc_script()` 的产出可用：
   - 取出它渲染的 openrc 脚本，用 `sh -n` 验语法
   - 断言产出里有 `reload()`（脚本第 1327 行注释说：不定义它 `--reload` 在 Alpine 上必然失败）
4. 在 README 的"已验证/未验证"表格里更新 Alpine 一行（**据实填写，不许美化**）。

## 验收（必须贴实际输出）

```bash
# CI 跑完，贴出：
#   1. workflow 文件内容
#   2. Alpine 上的完整自检输出（通过/失败数）
#   3. 失败断言的逐条说明（如果有）
#   4. render_openrc_script 产出的 sh -n 结果
#   5. README 改动
```

- 判据 1：workflow 文件存在且语法合法
- 判据 2：Alpine 上的自检结果**有明确数字**（通过 N / 失败 M）
- 判据 3：若有失败，每条都有原因分析
- 判据 4：**不许说"应该能行"** —— 必须是实跑结果

## 止损

- **10 分钟无可测量进展 → 立刻停下报告，不要继续试。**
- CI 单次运行超过 15 分钟无结果 → 停下报告。
- 最多迭代 workflow 5 次；5 次还不行就报告卡点。

## 环境

- Git Bash on Windows；`/tmp` 实为 `~/.config/alma/scratch`
- GitHub CLI 在 `/tmp/ghx/bin/gh.exe`（已登录 olst57）
- 仓库：`olst57/naiveproxy-deploy`（public）
- shellcheck 本地在 `/tmp/sc11/shellcheck.exe`（0.11.0）

## 红线复述（与开头一字不差）

1. **禁止碰生产服务器** `root@82.139.194.92`。
2. **禁止并行跑自检**。一次只跑一个。
3. **禁止修改现有 393 条断言的任何一行**。
4. **禁止生成整份脚本副本做实验**。
5. **禁止提交、禁止 push**。
6. **禁止为了"让测试变绿"去改脚本行为** —— 失败要如实报告。
