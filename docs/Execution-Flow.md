# 执行路径与运行逻辑

> 本文回答一个问题：**用户敲下命令之后，这台机器上依次发生了什么。**
>
> 所有内容都读自 `deploy-naive-caddy.sh` 源码并标注行号（对应 `SCRIPT_VERSION = 2.6.1`）。
> 行号会随改动漂移，**语义不会** —— 以函数名与阶段名为准，行号仅作定位参考。
>
> 本文只描述**现状**。梳理过程中发现的问题记录在文末「梳理中记录的问题」，
> 那是**待评估清单，不是待办**。

---

## 一、整体形态

`deploy-naive-caddy.sh` 是**纯编排脚本** —— 自身不含任何上游源码。
它做的事是：下载并校验 `klzgrad/forwardproxy` 的 `caddy-forwardproxy-naive` 二进制，
渲染配置、起服务，然后**验证自己刚才做的事**。

```
naive 客户端 ──TLS:443──▶ Caddy 站点 ──▶ forward_proxy ──▶ 外网
浏览器 / 探测者 ──HTTPS──▶ 同一个站点 ──basic_auth 不过──▶ file_server（伪装页）
```

**关键设计（决定了阶段 7 的行为）**：

| 设计 | 原因 |
| --- | --- |
| 站点地址写 `:443, domain` 而非裸域名 | 带 `:port` 才生成**无 host matcher** 的路由，`forward_proxy` 才收得住任意 Host 的客户端请求 |
| `probe_resistance` | 决定「未认证访问」长什么样：**认证失败不报 407，而是看到一个正常网页** |
| 证书三层降级 | 显式文件 → acme.sh → Caddy 自签（`resolve_cert_mode`） |
| 续期钩子必须用 `caddy reload --force` | `systemctl reload` 返回 0 但握手里还是旧证书，是**静默失效** |

---

## 二、全局入口与分流

`main()` 的入口顺序是**刻意设计的**，不是随手排的：

```
main()
 │
 ├─ 无参数              → print_guide（引导页）→ return 0     ← 不报错
 ├─ parse_args
 ├─ --self-test         → self_test → return 0
 ├─ --check             → do_check → return 0                 ← 刻意放在 root 检查之前
 ├─ validate_cert_options || exit 1
 ├─ validate_inputs                                           ← 参数合法性
 ├─ require_root                                              ← 要 root
 ├─ detect_os + detect_arch                                   ← 兜底探测（见下）
 │
 ├─ --rotate-password   → do_rotate_password → return 0
 ├─ --reload            → do_reload → return 0
 ├─ --uninstall         → do_uninstall → return 0
 ├─ --upgrade           → do_upgrade → return 0
 │
 ├─ preflight || exit 1                                       ← ★ 预检
 │
 ├─ run_stage 1 install_deps
 ├─ run_stage 2 install_caddy_binary
 ├─ run_stage 3 setup_user_and_dirs
 ├─ run_stage 4 write_config
 ├─ run_stage 5 write_camouflage_site
 ├─ run_stage 6 install_service
 ├─ run_stage 7 verify_deployment
 │
 ├─ print_summary                                             ← 打印凭据与客户端配置
 └─ 退出码判定（0 / 2）
```

**三处顺序上的讲究：**

1. **`--check` 在 `require_root` 之前** —— 它是只读体检，不该要求 root。
2. **`validate_inputs` 先于 `require_root`** —— 否则「缺 `--domain`」会被显示成「没权限」。
3. **`detect_arch` 在分流前单独调了一次** —— 因为 `--upgrade` / `--reload` / `--rotate-password`
   **都不走预检**。漏了它 `ARCH` 就是空串，`install_caddy_binary` 会把空串判成
   「非 x86_64」，于是本该下载预编译包的机器跑去源码编译。

---

## 三、预检 `preflight()`

**它不是阶段**（不进 `run_stage`，编号是 `—` 而不是 `1`），所以失败时
**没有阶段横幅、没有「第 N 步」编号**，直接 `exit 1`。

```
preflight()
 │
 ├─ section "预检"
 ├─ detect_os; detect_arch               ← 认系统、认架构
 ├─ info 系统 / 架构 / init / 包管理器
 │
 ├─ INIT 为空？                          ← ★ 唯一的硬失败
 │    是 → err "没找到 systemd 或 openrc"
 │         return 1
 │
 ├─ check_domain_dns                     ← 域名 A 记录
 ├─ check_probe_secret_dns               ← 秘密域名 A 记录（未提供则跳过）
 ├─ check_ports_free                    ← 80 / 443 / 自定义端口
 ├─ /proc/sys/net 不存在 → warn          ← 非 Linux 警告，不拦
 └─ ok "预检完成"
```

**拦截力实测（这是预检最值得注意的地方）：**

| 检查 | 真的会拦住吗 |
| --- | --- |
| `INIT` 为空 | ✅ **唯一硬失败**，`return 1` |
| 域名指向别的 IP | ⚠️ 问 `y/N` |
| 域名查不到 A 记录 | ⚠️ 只 warn，**不问** |
| 秘密域名未解析 | ⚠️ 问 `y/N` |
| 端口被占 | ⚠️ 问 `y/N` |
| 非 Linux | ⚠️ 只 warn |

**三处警告汇聚到同一个 `confirm()`**，而它有两条绕过路径：

```
警告 → confirm()
        ├─ --assume-yes 给了？    → 直接放行，不问
        ├─ 没有终端（非 TTY）？   → 自动按「继续」   ← 默认方向是「前进」
        └─ 有终端                 → 读 y/N，非 y 则 exit 0
```

> ⚠️ **非 TTY 时默认「继续」而不是「停」**。`echo | ./deploy.sh`、Ansible、CI
> 这类场景下，预检的警告全部变成**静默放行** —— 看起来像检查过了，实际没有拦截力。

---

## 四、七个部署阶段

阶段名与编号的**唯一事实源是 `STAGE_NAMES`** —— 所以不会出现「屏幕显示第 4 步、
报错说第 5 步」。

| # | 阶段名 | 函数 | 做什么 | 提示语 |
| --- | --- | --- | --- | --- |
| 1 | 安装系统依赖 | `install_deps` | 只装**确实缺**的 curl/tar/xz，包名按发行版映射 | 约 30 秒，看网络 |
| 2 | 安装 Caddy 二进制 | `install_caddy_binary` | 下载 → **sha256 校验** → 装；非 x86_64 自动源码编译 | 从 GitHub 下载 |
| 3 | 创建运行用户与目录 | `setup_user_and_dirs` | `caddy` 系统用户 + `/etc/caddy`、`/var/log/caddy`、`/var/lib/caddy`、web_root | 建系统用户与目录 |
| 4 | 写入 Caddyfile | `write_config` | acme 先签证书 → 渲染 → 按需 fmt → `caddy validate` → 写状态文件 | 渲染配置并校验语法 |
| 5 | 布置伪装站点 | `write_camouflage_site` | 生成 `index.html`；**目录里有别人的东西就拒绝接管** | 生成一个正常网站作为伪装 |
| 6 | 安装并启动服务 | `install_service` | systemd unit 或 openrc；启动前**再修日志属主**；acme 模式装续期 timer | 安装服务并启动 |
| 7 | 验证部署 | `verify_deployment` | 实测握手 / 证书 / 转发 / 公网 | 实测握手、证书、转发（最长约 80 秒） |

### 失败的形态由 `run_stage` 统一包裹

```
run_stage <序号> <函数>
 │
 ├─ stage_banner                   ← 「第 N 步 / 共 7 步」
 ├─ 调用阶段函数
 │    成功 → return 0
 │    失败 → 记下退出码
 ├─ gather_state                   ← 收集现场
 ├─ fail_stage                     ← 阶段专属建议 + 状态快照
 └─ exit 1
```

**注意这里没有 `else` 是刻意的**：没有 `else` 的 `if` 在条件为假时整个语句返回 0，
放在 `fi` 之后的 `$?` 永远捕到 0 —— 退出码就会一直是假信息。

### 阶段 7 的 5 项检查 —— 只有 1 项影响退出码

| # | 检查 | 失败时 |
| --- | --- | --- |
| ① | 服务 `systemctl is-active` | **`return 1`** ✅ 唯一影响退出码 |
| ② | 本机 HTTPS 握手 | `verify_warn`（只累计） |
| ③ | 证书信息（从握手读，不看盘上文件） | `verify_warn` |
| ④ | 代理转发实测（真穿一个请求） | `verify_warn` |
| ⑤ | 公网可达（外网回连） | `verify_warn` |

**为什么 ②③④⑤ 是警告而不是失败**（源码注释有据）：

- ④ 失败可能是凭据错（真问题），也可能是 `probe_resistance` 让错密码
  **返回 200 伪装页**（需人工判）
- ⑤ 失败可能只是 **NAT 回流受限**（环境限制，不是部署问题）
- ② 失败在首次部署时**必然发生** —— 证书还在签发中

**`verify_warn()` 只累计计数器，不改退出码** —— 这两者的关系就是退出码 2 的由来。

### ★ 已知缺陷：非 systemd 机器上阶段 7 的失败路径是空的

阶段 7 里**唯一的 `return 1`** 被 `if [ "$INIT" = "systemd" ]` 包住。
所以在 openrc / Alpine，或 `INIT` 为空的机器上，阶段 7 只会走到「退出码 2」，
**永远走不到「致命失败 1」**。

---

## 五、退出码

| 码 | 含义 | 触发条件 |
| --- | --- | --- |
| **0** | 成功 / 用户取消 / 显式跳过验证 | 验证全过，或 `--skip-verify`，或回**车取消** |
| **1** | 致命失败 | `die`，或任一阶段失败（`run_stage` 路径） |
| **2** | **部署完成但验证未确认** | 没跳过验证且有 warning |

**判定位置是硬约束**：必须在 `print_summary` **之后**。

```
run_stage 7 ...
print_summary              ← 打印密码与 client-config.json
        ↓
if 没跳过验证 且 有 warning → return 2
else                       → return 0
```

**为什么不能放进 `verify_deployment`**：在阶段函数里 `return` 非 0 会走
`run_stage` 的 `exit 1`，**跳过 `print_summary`** —— 用户拿不到密码和客户端配置。
那比原来的 bug 更伤用户。

**为什么退出码 2 而不是把警告当失败**：`grep` 与 `diff` 都是三档
（0 = 正常 / 1 = 合法的非干净结果 / 2 = 出错）。「未确认」既不是失败也不是成功，
它需要自己的码 —— 否则自动化要么误入成功分支，要么把好好的部署当坏的重试。

---

## 六、各入口的执行路径

| 入口 | 函数 | 做什么 | 关键约束 |
| --- | --- | --- | --- |
| `--check` | `do_check` | 5 项判定 + 证书方案预演 + 配置预览 | **零写入**，不需 root |
| `--reload` | `do_reload` | 校验配置后 `caddy reload --force` | validate 不过就不 reload |
| `--upgrade` | `do_upgrade` | 只换二进制 | 配置不动 |
| `--rotate-password` | `do_rotate_password` | 换密码 + reload | **先写临时文件 validate 再落盘** |
| `--uninstall` | `do_uninstall` | 先拆 timer 再停服务 | `--purge` 二次确认，**不删 acme.sh** |
| `--collect-diagnostics` | `do_collect_diagnostics` | 收集诊断信息 | **密码打码**，不强制 root |
| `--self-test` | `self_test` | 离线自检 | 不需 root，不改系统 |

`--check` 覆盖的 5 项判据：域名 A 记录指向 / 端口占用（80 + 443）/ GitHub 可达 /
根分区剩余 / 证书方案预演；外加配置预览。

---

## 七、关键文件落点

| 路径 | 内容 | 权限 |
| --- | --- | --- |
| `/etc/caddy/Caddyfile` | 服务端配置 | — |
| `/etc/caddy/.naive-deploy-state` | 账号密码状态 | 0600 |
| `/etc/caddy/client-config.json` | 客户端配置 | 0600 |
| `/etc/ssl/naiveproxy/` | acme 模式证书落点 | 750 root:caddy |
| `/var/log/caddy/access.log` | 访问日志 | 属主 caddy |
| `/var/lib/caddy` | caddy 数据目录 | — |
| `/var/www/naive-camouflage` | 伪装站点根 | — |
| `/usr/bin/caddy` | 二进制 | — |

**状态文件绝不 `source`** —— 按行取值、校验属主权限、再逐项重校验
（注入抵抗设计）。

---

## 八、自检与门禁

### 自检：406 条断言，两类

- **结构断言**：每条交互设计一条（如「帮助里不许出现 `--cf-token`」）
- **行为级断言**：**真起子进程跑 `main` 读退出码** —— 因为「源码里写了 `return 2`」
  **不等于真这么退**

### `--self-test <模式>` 双层过滤

| 层 | 作用 |
| --- | --- |
| 区段级 `st_want` | 连**段内准备代码**一起省掉 |
| 断言级 `st_match` | 用包装器拦住子进程 |

**零命中就报错非零** —— 防「跑 0 条还报全过」。
实测：`密码生成` 0.8 秒 vs 全量 78 秒。

### 证伪实验

把 bug 放回去，看断言变不变红。**不做这步，断言就是假的。**
v2.6.0 的 5 个变异全部被抓红，其中「把交握项改成 `return 1`」
**反而暴露出写过的一条假绿断言**。

### 四个 CI 门禁 + 一个巡检

| workflow | 守什么 |
| --- | --- |
| `ci.yml` | 静态：`bash -n`、锁 0.11.0 的 shellcheck、自检、可执行位、LF、版本一致性 |
| `alpine-openrc.yml` | 真 `alpine:3.20`：392/0/1 + 渲染产物 `sh -n` |
| `arm64.yml` | 真 arm64：源码构建 47 秒 + 模块名核对 |
| `failure-injection.yml` | 7 阶段逐个注入、串行、一次性容器，**要求注入自证生效才认读数** |
| `upstream-drift.yml` | 每天查上游资产名与 digest 还在不在 |

**四者都不碰生产机。**

---

## 九、已知边界（照实说）

| 项 | 状态 |
| --- | --- |
| `hide_ip` / `ports` 的**运行行为** | 只做过**语法核对**，未实测 |
| 阶段 7 在**非 systemd** 上的失败路径 | **空**（见第四节） |
| Alpine/openrc **端到端**（真起 caddy、真签证书） | **从未跑过** —— CI 只证明脚本跑得动、产物合法 |
| 真机验证是**回环自测** | 证明服务端能工作，**不证明**在受限网络里不被识别 |

> **最该记住的一条分界**：406 条断言 + shellcheck 全绿的情况下，
> **第一次上真机仍抓出 3 个 bug**（apt 包名、root 建出属主错误的日志文件
> 导致崩溃重启 29 次、用 IP 做 SNI 导致假失败）。
>
> **静态全绿 ≠ 能跑。**

---

## 十、梳理中记录的问题（待评估，不是待办）

### A. 预检的警告在非 TTY 下全部失效

`confirm()` 在非 TTY 时**默认「继续」而不是「停」**。这让预检在
Ansible / CI / 管道场景下失去拦截力 —— 警告照打，但没人拦。

**考虑方向**（未定）：非 TTY 时的默认方向是否该反过来？或至少在非 TTY 时
把「警告」升级成明确的退出？

### B. `check_domain_dns` 两个失败分支行为不对称

| 情况 | 行为 |
| --- | --- |
| 解析到了，但指向**别的 IP** | warn **+ confirm 问继续** |
| **查不到 A 记录** | warn，**不问** |

**第二种其实更常见也更致命** —— 新买的域名还没配 A 记录就来装机，
证书到阶段 4 必然签发失败，但它反而不问。

**推测原意**：`get_public_ip` 失败（本机没网）时判定不可靠，问了是噪音。
但代码没有区分「本机 IP 拿不到」和「域名查不到」这两种情况，混在同一个 `else` 里。

### C. 文档滞后（两处，同一件事）

`docs/VERIFICATION.md` 与 `README.md` 仍写着失败注入矩阵「阶段 7 的注入本身失效
—— 待修」，而 **v2.6.1 已修完**，修复后的矩阵里阶段 7 读数是 2。

### D. 向导路线的设计约束（产品方向，用户已拍板「两条路都要」）

- 路 A：面向普通用户的**向导**（交互式）
- 路 B：面向 AI / 运维的**一条命令**（`-y` / `--assume-yes` 已存在）

**硬约束**：向导**绝不能绕过任何东西** —— 必须收集完参数后拼成与手工完全相同的
参数，走同一条 `main` 路径（预检 + 7 阶段）。否则向导会成为一条只在新手路径上跑、
且**没有 406 条断言覆盖**的代码路径。

**已知难点**：向导的交互输入天然是测试盲区 —— 现有 19 处断言靠
`bash "$0" --check` 起真子进程读退出码，交互式输入无法这样测；
设计时需让输入可注入（stdin 或环境变量）。

---

## 附：阅读源码的建议顺序

想快速建立整体印象，按这个顺序读：

1. `STAGE_NAMES` / `STAGE_HINT` —— 先知道有哪 7 步
2. `main()` —— 看分流与顺序
3. `preflight()` —— 开工前的体检
4. `run_stage()` —— 失败如何传递（这里定义了整个失败语义）
5. `verify_deployment()` —— 最后一步的 5 项检查
6. `main()` 末尾的退出码判定 —— 0/1/2 从哪来
7. `print_guide()` / `usage()` —— 用户实际看到什么
