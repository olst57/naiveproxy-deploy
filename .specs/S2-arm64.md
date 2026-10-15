# 任务：验证 arm64 架构（源码构建路径）

## 绝对不要做（红线）

1. **禁止碰生产服务器** `root@82.139.194.92` —— 上面跑着线上代理，且有明天 16:14 待触发的证书签发 timer。一切测试只在 CI 跑。
2. **禁止并行跑自检** —— 单轮 78 秒 × N 并发会打满 CPU。一次只跑一个。
3. **禁止修改现有 393 条断言的任何一行** —— 只能新增。
4. **禁止生成整份脚本副本做实验**。
5. **禁止提交、禁止 push**。
6. **禁止假装验证过** —— 没跑过的就写"未验证"。这个项目最恨的就是"跑了但报绿"。

## 背景（≤5 行）

脚本第 1834 行：`ARCH` 不是 x86_64 时强制走 `build_from_source()`。
上游只发布一个资产 `caddy-forwardproxy-naive.tar.xz`（x86_64），所以 **arm64 必须源码构建**。
**这条路径从没在真 arm64 上验证过。**
仓库是 public → GitHub 免费提供 `ubuntu-24.04-arm` runner。

## 要做（编号）

1. 新建 `.github/workflows/arm64.yml`，`runs-on: ubuntu-24.04-arm`：
   - 跑 `bash -n`、`shellcheck -x -S style`、`bash deploy-naive-caddy.sh --self-test`
   - **报告实测数字**
2. **核心**：在真 arm64 上跑脚本实际用的构建命令（照抄 `build_from_source()` 里的）：
   ```bash
   xcaddy build --output caddy \
     --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
   ```
   - Go 需要 1.26+（脚本注释里写了；runner 上装最新版）
3. 验证产出的二进制真的能用：
   - `./caddy version`
   - `./caddy list-modules | grep -i forwardproxy`（确认 naive 模块在里面）
   - **跑一次 `caddy validate` 校验一个含 `forward_proxy` 的最小 Caddyfile**
4. 在 README 的"已验证/未验证"表格里更新 arm64 一行（**据实填写**）。

## 验收（必须贴实际输出）

```bash
# CI 跑完，贴出：
#   1. uname -m 的实际输出（证明真是 arm64）
#   2. workflow 文件内容
#   3. 源码构建的完整结果（成功/失败 + 耗时）
#   4. ./caddy version 与 list-modules 的 grep 结果
#   5. caddy validate 对最小 Caddyfile 的结果
#   6. README 改动
```

- 判据 1：`uname -m` 输出 `aarch64`
- 判据 2：源码构建**真的跑完**（不是"跳过了"）
- 判据 3：`list-modules` 里能查到 forward_proxy 模块
- 判据 4：构建失败也要如实报告失败原因，**不许写成成功**

## 止损

- **10 分钟无可测量进展 → 立刻停下报告。**
- 源码构建超过 25 分钟未完成 → 停下报告（arm runner 上 go build 可能较慢）。
- 最多迭代 workflow 5 次。

## 环境

- Git Bash on Windows；`/tmp` 实为 `~/.config/alma/scratch`
- GitHub CLI 在 `/tmp/ghx/bin/gh.exe`（已登录 olst57）
- 仓库：`olst57/naiveproxy-deploy`（public）

## 红线复述（与开头一字不差）

1. **禁止碰生产服务器** `root@82.139.194.92`。
2. **禁止并行跑自检**。
3. **禁止修改现有 393 条断言的任何一行**。
4. **禁止生成整份脚本副本做实验**。
5. **禁止提交、禁止 push**。
6. **禁止假装验证过** —— 没跑过的就写"未验证"。
