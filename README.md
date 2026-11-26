# install-kimi-termux

在 **Termux / Android** 上一键装好 [Kimi Code CLI](https://github.com/MoonshotAI/kimi-code)。

官方安装器只发一个 glibc 动态链接的二进制，而 Android 上没有
`/lib/ld-linux-aarch64.so.1`，装完直接跑不起来。这个脚本补上 termux-glibc，
生成用 loader 直启的启动器，再打两个 Android 特有的补丁。

## 安装

```sh
bash install-kimi-termux.sh
```

装完开一个新终端（或 `source` 你的 shell 启动配置），然后：

```sh
which kimi      # 应该指向 ~/.local/bin/kimi，而不是 ~/.kimi-code/bin/kimi
kimi
```

### 参数

| 参数 | 作用 |
|---|---|
| （无） | 标准安装：装 glibc 运行时 → 跑官方安装器 → 打补丁 → 生成启动器 |
| `--config my.toml` | 安装后把 `my.toml` 套用成 `~/.kimi-code/config.toml`（原文件备份成 `.bak`） |
| `--no-hardlink` | 不打 `nolink` 补丁 |
| `--no-ifaddrs` | 不打 `getifaddrs` 补丁（**`kimi web` 会崩**） |
| `--no-official` | 不跑官方安装器，只做 glibc + 补丁 + 启动器 |
| `--dry-run` | 只打印将要执行的命令，不真跑 |
| `--help` | 用法 |

## 为什么需要这两个补丁

### `nolink.so` —— 硬链接

Android 禁止应用创建硬链接（`link()` 恒返回 `EACCES`）。而 Kimi Code 用 `link()`
做会话锁和索引镜像的原子发布，不补的话：锁拿不到、索引写不进去、日志每秒刷十条。

补丁把 `link()` 降级成 `rename()`——同样是一次原子替换，语义足够接近。

### `ifaddrs.so` —— 网卡枚举

glibc 的 `getifaddrs()` 在 Android 上必然失败（`EACCES`），原因有两个：

1. 它发 NETLINK_ROUTE 的 **RTM_GETLINK** 汇总，内核要求 `CAP_NET_ADMIN`，普通应用没有；
2. 它还要读 `/proc/net/if_inet6` 拿 IPv6，而 Android 对普通应用封了整个 `/proc/net`。

Node 的 `os.networkInterfaces()` 底层就是 `getifaddrs()`，于是会抛：

```
SystemError [ERR_SYSTEM_ERROR]: uv_interface_addresses returned Unknown system error 13
    at Object.networkInterfaces (node:os:218:16)
    at getAddresses (...main.cjs:379195:62)
    at Object.logServerAddress (...main.cjs:379208:66)
```

`kimi web` 启动 HTTP 服务后要打印服务器地址，正好走到这里，进程直接崩。

补丁换成了 bionic 那套能用的做法：发 **RTM_GETADDR**（地址表，内核不要求
`CAP_NET_ADMIN`）并且用 `sendto()` 而不是 `send()`/`sendmsg()`——Android 的 SELinux
放行 `sendto`、拒绝另外两个。

> 附带说明：这台机器上的内核头文件和 Termux 头文件在 `IFA_*` 编号上差 1
> （Android 新头文件给 enum 加了 `IFA_UNSPEC`），所以补丁在运行时探测用哪套编号。

## 安装完的自检

脚本会跑一个只调 `getifaddrs()` 的小程序，对比打补丁前后的结果：

```
==> getifaddrs: 不打补丁=FAIL getifaddrs: 1 FAIL, 打补丁=OK
```

`OK` 说明补丁生效，`kimi web` 能正常启动。

## 几个容易踩的坑

- **不要用 `glibc-runner` 转发参数**：它会把带空格的参数拆开，于是
  `kimi -p "reply with exactly: ok"` 里的整句只剩第一个词。脚本生成的启动器是
  直接调 loader 的。
- **补丁只对 glibc 进程生效**：Kimi Code 会用 bionic 的 `/bin/sh` 跑命令，而 Android 的
  链接器加载 glibc 的 `.so` 会直接失败（`CANNOT LINK EXECUTABLE`）。所以补丁在加载时
  把 `LD_PRELOAD` 从环境里清掉，只影响之后派生的子进程。
- **PATH 里 `~/.kimi-code/bin` 要清掉**：那里是裸的 glibc 二进制，排在启动器前面的话
  `kimi` 就废了。脚本会自动清理 `.zshrc`/`.bashrc`/`.profile` 里对应的行。
- **别删 `LD_PRELOAD` 那行**：路径悬空的话，bionic 的子进程会跟着炸。

## 从电脑访问手机上的 `kimi web`

Android 不允许热点客户端连接手机上的普通应用（系统栈可以，普通 App 不行），
所以电脑直接访问 `http://<手机热点IP>:58627/` 会超时。

绕过办法是**反向隧道**：手机主动连电脑（这方向是通的），电脑在本地开一个端口，
把流量经隧道送回手机。两个脚本：

| 文件 | 跑在哪 | 作用 |
|---|---|---|
| `tunnel-server.py` | 电脑（需 Python） | 监听隧道端口，并在 `127.0.0.1:58628` 开一个入口端口 |
| `tunnel-phone.py` | 手机（Termux） | 主动连电脑，把隧道流量转到手机的 `127.0.0.1:58627` |

```sh
# 电脑
python tunnel-server.py
# 手机（把 <电脑IP> 换成电脑在热点里的地址）
python3 tunnel-phone.py <电脑IP>
# 电脑浏览器
#   http://127.0.0.1:58628/#token=<kimi web 横幅里的 token>
```

参数（两边通用）：`--host-port`（电脑入口，默认 58628）、`--tunnel-port`（默认 9000）、
`--target-port`（手机上的目标端口，默认 58627）。

> 电脑首次运行要允许防火墙放行隧道端口（9000），否则手机连不上。
> 更省事的替代方案：直接 `adb reverse tcp:58627 tcp:58627`（需 USB 调试）。

## 环境要求

- Termux（Android）
- aarch64（termux-glibc 目前只提供 aarch64）
- 脚本需要联网：装 glibc 运行时、跑官方安装器

## License

[Unlicense](LICENSE)
