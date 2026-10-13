# 在 Windows 上校验配置的坑（重要）

这个项目的验证过程踩过一个反复出现的坑，值得单独写下来。
开发机是 Windows，而配置里的路径是 Linux 风格的 —— 两者相遇时会产生**宿主机上凭空多出目录**的副作用。

## 坑一：Git Bash 把 `/var/...` 解析到当前盘符

配置里有 `output file /var/log/caddy/access.log`。在 Windows 上用官方 caddy 跑
`validate` 或 `fmt` 时，**caddy 会真的去创建那个日志文件** —— 而 Git Bash 把 `/var/...`
解析成「当前盘符下的 `\var\...`」，于是宿主机上会凭空多出 `D:\var\log\caddy\access.log`。

**两个一起用能避免**：

```bash
# 先拿一个官方 caddy（跟 naive fork 同基线：2.11.7）
curl -sL -o /tmp/caddy.zip \
  https://github.com/caddyserver/caddy/releases/download/v2.11.7/caddy_2.11.7_windows_amd64.zip
python -c "import zipfile;zipfile.ZipFile('/tmp/caddy.zip').extractall('/tmp')"

# 用这个工具校验，它只在自己的临时目录里工作
CADDY=/tmp/caddy.exe ./validate-caddyfile.sh
```

它接受 `CADDY` 环境变量，也会去 PATH 和脚本同目录找。
**用完记得删掉 caddy** —— 它会在 `/tmp`（实为 `~/.config/alma/scratch`）里占 50 MB。

`validate-caddyfile.sh` 做了三件事：

1. **整块**把 `output file … { roll_size … }` 换成 `output discard`
   （只换 `output` 那一行不够：`roll_size` 等是 file writer 的子指令，`discard` 不认它们，
   会直接校验失败；而留着 file 输出就会在宿主机上建目录）
2. 剥掉只存在于 naive 构建里的指令（`order forward_proxy` / `forward_proxy` 块），
   否则官方 caddy 会报「不是已注册的指令」
3. 全程在 `mktemp -d` 里操作，结束时删掉

已验证：用它跑校验，`D:\var` 不会出现；不用它直接跑，`D:\var` 会出现。

## 坑二：Python 在 Windows 上 stdout 默认走 GBK

Python 在 Windows 上 `stdout` 默认走控制台代码页（GBK），
脚本里如果用 `sys.stdout.write()` 往管道写中文，下游按 UTF-8 读会直接 `UnicodeDecodeError`。
所以要写 `sys.stdout.buffer.write(s.encode('utf-8'))`，或设 `PYTHONIOENCODING=utf-8`。

`validate-caddyfile.sh` 里的两个内嵌 Python 脚本（`sanitize.py` / `strip.py`）
都按这个方式写字节输出。
