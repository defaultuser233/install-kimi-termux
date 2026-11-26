#!/data/data/com.termux/files/usr/bin/bash
#
# Kimi Code CLI —— Termux / Android 一键安装
#
#   bash install-kimi-termux.sh                   # 标准安装
#   bash install-kimi-termux.sh --config my.toml # 安装后套用自定义 provider/model 配置
#   bash install-kimi-termux.sh --no-hardlink     # 不打硬链接补丁
#   bash install-kimi-termux.sh --dry-run         # 只打印将要执行的命令，不真跑
#
# 为什么需要这个脚本：
#   官方安装器 (code.kimi.com/kimi-code/install.sh) 只发 glibc 的二进制，
#   在 Android 上没有 /lib/ld-linux-aarch64.so.1，装完直接跑不起来。
#   这个脚本补上 termux-glibc，生成用 glibc loader 直启的启动器，
#   再处理两个 Android 特有的问题：
#     nolink.so  —— link() 降级成 rename()：Android 禁止应用创建硬链接，
#                   而 Kimi Code 用它做会话锁和索引镜像的原子发布，
#                   不补的话锁拿不到、索引写不进、日志每秒刷十条。
#     hijack.js  —— 兜住 os.networkInterfaces() 的异常：Android 上 glibc 的
#                   getifaddrs() 返回 EACCES（要用 CAP_NET_ADMIN 做
#                   NETLINK_ROUTE 汇总，还要读被封的 /proc/net/if_inet6），
#                   Node 会抛 "uv_interface_addresses ... error 13"，
#                   而 kimi web 在 'listening' 事件回调里调它，
#                   异常逃逸出去会让整个进程崩掉。
#
set -euo pipefail

GLIBC_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}/glibc"
KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
LAUNCHER="$HOME/.local/bin/kimi"
SHIM_SRC="$HOME/.local/share/nolink.c"
SHIM_SO="$HOME/.local/lib/nolink.so"
HIJACK_JS="$KIMI_HOME/hijack.js"

DO_OFFICIAL=1
DO_HARDLINK=1
DO_DRYRUN=0
CONFIG_TEMPLATE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--no-official)   DO_OFFICIAL=0 ;;
		--fix-hardlink)  DO_HARDLINK=1 ;;
		--no-hardlink)   DO_HARDLINK=0 ;;
		--dry-run)       DO_DRYRUN=1 ;;
		--config)        CONFIG_TEMPLATE="${2:-}"; shift ;;
		-h|--help)       sed -n '2,24p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
	shift
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DO_DRYRUN" = 1 ]; then printf '    %s\n' "$*"; else "$@"; fi; }

# 编译两个 shim 都要 glibc 的 gcc；已经装了就别再去联网装一遍
GLIBC_CC=""
ensure_gcc() {
	[ -n "$GLIBC_CC" ] && return 0
	for c in "$GLIBC_PREFIX/bin/gcc" "$GLIBC_PREFIX/bin/aarch64-linux-gnu-gcc"; do
		if [ -x "$c" ]; then GLIBC_CC="$c"; return 0; fi
	done
	say "安装 gcc-glibc（要编译 Android 兼容补丁）"
	run pkg install -y gcc-glibc
	for c in "$GLIBC_PREFIX/bin/gcc" "$GLIBC_PREFIX/bin/aarch64-linux-gnu-gcc"; do
		if [ -x "$c" ]; then GLIBC_CC="$c"; return 0; fi
	done
	die "找不到可用的 glibc gcc（$GLIBC_PREFIX/bin/gcc）"
}

# ---------- 0. 环境检查 ----------
[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/bash" ] || die "这脚本只能在 Termux 里跑（没找到 \$PREFIX）"
case "$(uname -m)" in
	aarch64|arm64) ;;
	*) warn "当前架构是 $(uname -m)，termux-glibc 源目前只有 aarch64，后面可能会失败" ;;
esac
say "Termux 环境 OK, 架构 $(uname -m)"

# ---------- 1. glibc 运行时 ----------
if [ ! -f "$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1" ]; then
	say "安装 termux-glibc 运行时（官方二进制是 glibc 的，Android 必须补这个）"
	run pkg install -y glibc-repo
	run pkg update -y
	run pkg install -y glibc glibc-runner
else
	say "glibc 已就绪: $GLIBC_PREFIX"
fi
[ -f "$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1" ] || die "glibc 没装上（$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1 不存在）"

# ---------- 2. 官方安装器 ----------
if [ "$DO_OFFICIAL" = 1 ]; then
	say "跑官方安装器（会做 sha256 校验）"
	# KIMI_NO_MODIFY_PATH=1：别让它把 ~/.kimi-code/bin 加进 PATH——
	# 那个目录里是裸的 glibc 二进制，PATH 里排在我们启动器前面的话 kimi 就废了
	run sh -c 'curl -fsSL https://code.kimi.com/kimi-code/install.sh | KIMI_NO_MODIFY_PATH=1 bash'
else
	say "跳过官方安装器（--no-official）"
fi
[ -x "$KIMI_HOME/bin/kimi" ] || die "官方二进制没到位: $KIMI_HOME/bin/kimi"

# ---------- 3. 目录准备 ----------
# 启动器要等补丁编译完再生成（它按实际产物决定 LD_PRELOAD），见第 5 节
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.local/share"

# 官方安装器可能已经把 ~/.kimi-code/bin 写进过 rc 文件，PATH 里它排前面会盖掉启动器
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
	[ -f "$rc" ] || continue
	if grep -q 'kimi-code/bin' "$rc" 2>/dev/null; then
		say "清理 $rc 里的 kimi-code/bin PATH 行（避免盖掉启动器）"
		if [ "$DO_DRYRUN" = 1 ]; then
			printf '    %s\n' "sed -i '/kimi-code\\/bin/d' $rc"
		else
			cp "$rc" "$rc.bak-kimi" 2>/dev/null || true
			sed -i '/kimi-code\/bin/d' "$rc"
		fi
	fi
done

# ~/.local/bin 要在 PATH 里，否则 `kimi` 还是找不到启动器
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
	[ -f "$rc" ] || continue
	grep -q 'HOME/.local/bin' "$rc" 2>/dev/null && continue
	say "把 ~/.local/bin 加进 PATH（$rc）"
	if [ "$DO_DRYRUN" = 1 ]; then
		printf '    %s\n' "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $rc"
	else
		printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
	fi
done

# ---------- 4. 硬链接补丁 ----------
if [ "$DO_HARDLINK" = 1 ]; then
	say "打硬链接补丁（Kimi Code 的会话锁和索引都靠 link()，在 Android 上恒失败）"
	ensure_gcc
	cat > "$SHIM_SRC" <<'EOF'
/*
 * Android 禁止应用创建硬链接（link/linkat 返回 EACCES）。
 * Kimi Code 用 link() 做会话锁和索引镜像的原子发布，在这台机器上全部失败，
 * 于是锁拿不到、索引写不进去、日志每秒刷十条。
 *
 * 这个 shim 把 link() 降级为 rename()：同样是一次原子替换，语义足够接近。
 * 只有在真实 link() 返回 EPERM/EACCES 时才降级，其他错误照常返回。
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/*
 * 这个 .so 是给 glibc 进程用的。Kimi Code / Claude Code 会用 bionic 的 /bin/sh
 * 跑命令，而 Android 的链接器加载 glibc 的 .so 会直接失败（CANNOT LINK EXECUTABLE）。
 * 加载器在启动时已经读过 LD_PRELOAD，所以这里把它从环境里清掉，
 * 只影响之后派生的子进程，避免 bionic 程序被牵连。
 */
__attribute__((constructor)) static void nolink_init(void)
{
	unsetenv("LD_PRELOAD");
}

typedef int (*link_fn)(const char *, const char *);
typedef int (*linkat_fn)(int, const char *, int, const char *, int);

static link_fn real_link;
static linkat_fn real_linkat;

static int denied(int err)
{
	return err == EPERM || err == EACCES;
}

int link(const char *oldpath, const char *newpath)
{
	if (!real_link)
		real_link = (link_fn)dlsym(RTLD_NEXT, "link");
	if (real_link) {
		int r = real_link(oldpath, newpath);
		if (r == 0 || !denied(errno))
			return r;
	}
	return rename(oldpath, newpath);
}

int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags)
{
	if (!real_linkat)
		real_linkat = (linkat_fn)dlsym(RTLD_NEXT, "linkat");
	if (real_linkat && !(flags & AT_SYMLINK_FOLLOW)) {
		int r = real_linkat(olddirfd, oldpath, newdirfd, newpath, flags);
		if (r == 0 || !denied(errno))
			return r;
	}
	if (flags & AT_SYMLINK_FOLLOW) {
		errno = ENOSYS;
		return -1;
	}
	return renameat(olddirfd, oldpath, newdirfd, newpath);
}
EOF
	# -mno-fix-cortex-a53-835769：termux-pacman 的 gcc 默认会给链接器塞
	# --fix-cortex-a53-835769，那是 LLVM 的 flag，GNU ld 不认会直接报错
	run "$GLIBC_CC" -shared -fPIC -O2 -mno-fix-cortex-a53-835769 \
		-o "$SHIM_SO" "$SHIM_SRC" -ldl
	[ "$DO_DRYRUN" = 1 ] || [ -f "$SHIM_SO" ] || die "硬链接补丁编译失败"
else
	say "跳过硬链接补丁（--no-hardlink）"
	rm -f "$SHIM_SO"
fi

# ---------- 5. hijack.js ----------
# 给 os.networkInterfaces() 兜一层异常：Android 上它可能抛 EACCES，
# 而 kimi web 在 'listening' 事件回调里调它，异常逃逸出去会带走整个进程。
# 它只在真的抛错时才返回空对象，正常情况返回真实网卡列表。
say "写入 $HIJACK_JS"
if [ "$DO_DRYRUN" = 1 ]; then
	printf '    %s\n' "写入 $HIJACK_JS"
else
	mkdir -p "$(dirname "$HIJACK_JS")"
	cat > "$HIJACK_JS" <<'EOF'
// os.networkInterfaces() 在 Android 上可能抛异常：
// glibc 的 getifaddrs() 要 CAP_NET_ADMIN 才能做 NETLINK_ROUTE 汇总，
// 而且还要读被封的 /proc/net/if_inet6，于是返回 EACCES，
// Node 抛 "uv_interface_addresses returned Unknown system error 13"。
// kimi web 在 'listening' 事件回调里调它，异常逃逸出去会直接带走整个进程。
//
// 这里不替换实现，只兜住异常：
//   - 正常情况返回真实网卡列表；
//   - 枚举失败时返回空对象，进程照常启动，只是横幅里没有 Network 行。
//
// 用法：NODE_OPTIONS="--require ~/.kimi-code/hijack.js" kimi web --host 0.0.0.0
const os = require('os');

const real = os.networkInterfaces;

os.networkInterfaces = function networkInterfaces () {
  try {
    return real.call(os);
  } catch {
    return {};
  }
};
EOF
fi

# ---------- 6. 启动器 ----------
# 放到补丁之后：LD_PRELOAD 要按实际编出来的 .so 来定，
# 路径悬空会让 bionic 的子进程（kimi 跑命令用的 /bin/sh）直接炸
say "生成启动器 $LAUNCHER"
PRELOAD=""
if [ "$DO_HARDLINK" = 1 ] && { [ "$DO_DRYRUN" = 1 ] || [ -f "$SHIM_SO" ]; }; then
	PRELOAD="$SHIM_SO"
fi
[ -n "$PRELOAD" ] || warn "没有可用的补丁，启动器里不设 LD_PRELOAD"

if [ "$DO_DRYRUN" = 1 ]; then
	printf '    %s\n' "写入 $LAUNCHER（LD_PRELOAD=$PRELOAD）"
else
	cat > "$LAUNCHER" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# 用 glibc 的 loader 直启 Kimi Code。
# 不要用 glibc-runner 转发参数：它会把带空格的参数拆开，
# 于是 kimi -p "reply with exactly: ok" 里的整句只剩第一个词。
# nolink.so：link() 降级成 rename()（Android 禁硬链接）
unset LD_LIBRARY_PATH LD_AUDIT
GLIBC=$GLIBC_PREFIX
EOF
	if [ -f "$HIJACK_JS" ]; then
		cat >> "$LAUNCHER" <<EOF
# hijack.js：兜住 os.networkInterfaces() 的异常。它只在真的抛错时才返回空对象，
# 正常情况返回真实网卡列表（横幅里的 Network 行）。
export NODE_OPTIONS="--require $HIJACK_JS\${NODE_OPTIONS:+ \$NODE_OPTIONS}"
EOF
	fi
	if [ -n "$PRELOAD" ]; then
		printf 'export LD_PRELOAD=%s\n' "$PRELOAD" >> "$LAUNCHER"
	fi
	cat >> "$LAUNCHER" <<EOF
exec "\$GLIBC/lib/ld-linux-aarch64.so.1" --library-path "\$GLIBC/lib" \\
	$KIMI_HOME/bin/kimi "\$@"
EOF
	chmod +x "$LAUNCHER"
fi

# ---------- 7. 自定义配置 ----------
if [ -n "$CONFIG_TEMPLATE" ] && [ -f "$CONFIG_TEMPLATE" ]; then
	say "套用配置模板 $CONFIG_TEMPLATE"
	if [ "$DO_DRYRUN" = 1 ]; then
		printf '    %s\n' "cp $CONFIG_TEMPLATE $KIMI_HOME/config.toml"
	else
		[ -f "$KIMI_HOME/config.toml" ] && cp "$KIMI_HOME/config.toml" "$KIMI_HOME/config.toml.bak"
		cp "$CONFIG_TEMPLATE" "$KIMI_HOME/config.toml"
	fi
else
	[ -n "$CONFIG_TEMPLATE" ] && warn "配置模板不存在: $CONFIG_TEMPLATE"
fi

# ---------- 8. 验证 ----------
say "验证"
if [ "$DO_DRYRUN" = 1 ]; then
	printf '    %s\n' "$LAUNCHER --version"
else
	"$LAUNCHER" --version || die "启动器跑不起来：$LAUNCHER --version 失败"
fi

cat <<EOF

安装完成。

  启动器 : $LAUNCHER
  二进制 : $KIMI_HOME/bin/kimi
  glibc  : $GLIBC_PREFIX
  补丁   : nolink=$DO_HARDLINK  hijack.js（已装）

接下来：
  1. 开一个新终端或者source你的shell的启动配置文件（让 PATH 生效），然后跑 \`kimi\`
  2. 确认 \`which kimi\` 指向 $LAUNCHER 而不是 $KIMI_HOME/bin/kimi
EOF
