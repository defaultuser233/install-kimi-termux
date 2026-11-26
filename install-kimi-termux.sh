#!/data/data/com.termux/files/usr/bin/bash
#
# Kimi Code CLI —— Termux / Android 一键安装
#
#   bash install-kimi-termux.sh                   # 标准安装
#   bash install-kimi-termux.sh --config my.toml # 安装后套用自定义 provider/model 配置
#   bash install-kimi-termux.sh --no-hardlink     # 不打硬链接补丁
#   bash install-kimi-termux.sh --no-ifaddrs      # 不打 getifaddrs 补丁（kimi web 会崩）
#   bash install-kimi-termux.sh --dry-run         # 只打印将要执行的命令，不真跑
#
# 为什么需要这个脚本：
#   官方安装器 (code.kimi.com/kimi-code/install.sh) 只发 glibc 的二进制，
#   在 Android 上没有 /lib/ld-linux-aarch64.so.1，装完直接跑不起来。
#   这个脚本补上 termux-glibc，生成用 glibc loader 直启的启动器，
#   再打两个 Android 特有的补丁：
#     nolink.so  —— link() 降级成 rename()：Android 禁止应用创建硬链接，
#                   而 Kimi Code 用它做会话锁和索引镜像的原子发布，
#                   不补的话锁拿不到、索引写不进、日志每秒刷十条。
#     ifaddrs.so —— 替换 getifaddrs()：glibc 的实现要用 CAP_NET_ADMIN 做
#                   NETLINK_ROUTE 汇总、还要读被封的 /proc/net/if_inet6，
#                   在 Android 上一律 EACCES，Node 的 os.networkInterfaces()
#                   会抛 "uv_interface_addresses ... error 13"，
#                   `kimi web` 启动时直接崩。
#
set -euo pipefail

GLIBC_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}/glibc"
KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
LAUNCHER="$HOME/.local/bin/kimi"
SHIM_SRC="$HOME/.local/share/nolink.c"
SHIM_SO="$HOME/.local/lib/nolink.so"
IFADDRRS_SRC="$HOME/.local/share/ifaddrs.c"
IFADDRRS_SO="$HOME/.local/lib/ifaddrs.so"
HIJACK_JS="$KIMI_HOME/hijack.js"

DO_OFFICIAL=1
DO_HARDLINK=1
DO_IFADDRRS=1
DO_DRYRUN=0
CONFIG_TEMPLATE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--no-official)   DO_OFFICIAL=0 ;;
		--fix-hardlink)  DO_HARDLINK=1 ;;
		--no-hardlink)   DO_HARDLINK=0 ;;
		--no-ifaddrs)    DO_IFADDRRS=0 ;;
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

# ---------- 5. getifaddrs 补丁 ----------
if [ "$DO_IFADDRRS" = 1 ]; then
	say "打 getifaddrs 补丁（glibc 的实现在这台机上返回 EACCES，kimi web 会崩）"
	ensure_gcc
	cat > "$IFADDRRS_SRC" <<'EOF'
/* getifaddrs 替代实现（给 glibc 程序在 Android/Termux 上用）
 *
 * 背景：glibc 的 getifaddrs() 在 Android 上返回 EACCES，两个原因：
 *   1) 它发 NETLINK_ROUTE 的 RTM_GETLINK 汇总，内核要求 CAP_NET_ADMIN，普通应用没有；
 *   2) 它还要读 /proc/net/if_inet6 拿 IPv6，Android 对普通应用封了 /proc/net。
 *
 * bionic 的 getifaddrs() 绕开了这两点：它发 RTM_GETADDR（地址表，内核不要求
 * CAP_NET_ADMIN），并且用 sendto() 而不是 send()/sendmsg()——Android 的 SELinux
 * 放行 sendto、拒绝 send/sendmsg。
 *
 * 这里照 bionic 的做法实现：
 *   - socket(AF_NETLINK, SOCK_RAW, 0) + sendto(RTM_GETADDR dump) + recvfrom()
 *   - 从 RTM_NEWADDR 里取地址、接口名(IFA_LABEL)、接口标志(IFA_FLAGS)、前缀长度
 *
 * 注意：IFA_* 的编号在不同内核头里不一致（Android 新头文件给 enum 加了
 * IFA_UNSPEC，整体错位 1），所以运行时探测——消息里出现 rta_type==1 就是经典编号，
 * 否则是带 IFA_UNSPEC 的编号。
 *
 * 同时自己实现 freeifaddrs，避免和 glibc 版的释放逻辑不一致。
 *
 * 编译：
 *   $PREFIX/glibc/bin/aarch64-linux-gnu-gcc -O2 -mno-fix-cortex-a53-835769 \
 *       -shared -fPIC -o ~/.local/lib/ifaddrs.so ifaddrs.c
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <linux/if_addr.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_ENTRIES 64
#define MAX_ATTRS 24

/* 经典内核的 IFA_* 编号 */
#define K_IFA_ADDRESS 1
#define K_IFA_LOCAL   2
#define K_IFA_LABEL   3
#define K_IFA_CACHEINFO 6
#define K_IFA_FLAGS   8

struct namemap {
    unsigned index;
    char name[IFNAMSIZ + 1];
};

static void nm_set(struct namemap *map, int *count, unsigned index, const char *name)
{
    if (!name || !*name)
        return;
    for (int i = 0; i < *count; i++) {
        if (map[i].index == index) {
            strncpy(map[i].name, name, IFNAMSIZ);
            map[i].name[IFNAMSIZ] = '\0';
            return;
        }
    }
    if (*count >= MAX_ENTRIES)
        return;
    map[*count].index = index;
    strncpy(map[*count].name, name, IFNAMSIZ);
    map[*count].name[IFNAMSIZ] = '\0';
    (*count)++;
}

static const char *nm_get(struct namemap *map, int count, unsigned index)
{
    for (int i = 0; i < count; i++)
        if (map[i].index == index)
            return map[i].name;
    return NULL;
}

static void mask_from_prefix(int family, int prefix, struct sockaddr_storage *out)
{
    memset(out, 0, sizeof(*out));
    if (family == AF_INET) {
        struct sockaddr_in *m = (struct sockaddr_in *)out;
        m->sin_family = AF_INET;
        if (prefix <= 0)
            m->sin_addr.s_addr = 0;
        else if (prefix >= 32)
            m->sin_addr.s_addr = 0xffffffffu;
        else
            m->sin_addr.s_addr = htonl(0xffffffffu << (32 - prefix));
    } else {
        struct sockaddr_in6 *m = (struct sockaddr_in6 *)out;
        m->sin6_family = AF_INET6;
        if (prefix > 0) {
            int full = prefix / 8, rem = prefix % 8;
            for (int i = 0; i < full && i < 16; i++)
                m->sin6_addr.s6_addr[i] = 0xff;
            if (rem && full < 16)
                m->sin6_addr.s6_addr[full] = (unsigned char)(0xff << (8 - rem));
        }
    }
}

static void append_entry(struct ifaddrs **head, struct ifaddrs **tail,
                         const char *name, unsigned flags,
                         struct sockaddr *addr, struct sockaddr *mask)
{
    struct ifaddrs *e = calloc(1, sizeof(*e));
    if (!e) {
        free(addr);
        free(mask);
        return;
    }
    e->ifa_name = strdup(name ? name : "");
    e->ifa_flags = flags;
    e->ifa_addr = addr;
    e->ifa_netmask = mask;
    if (*tail)
        (*tail)->ifa_next = e;
    else
        *head = e;
    *tail = e;
}

/* 取接口的真实标志（IFF_*）。
 * 注意不能用地址消息里的 IFA_FLAGS——那是 IFA_F_* 地址标志（0x80 之类），
 * 不是接口标志。libuv 的 uv__ifaddr_exclude() 要求 ifa_flags 同时带
 * IFF_UP 和 IFF_RUNNING，否则整条被丢掉，os.networkInterfaces() 就返回 {};
 * is_internal 也是靠 IFF_LOOPBACK 判的。
 * RTM_GETLINK 汇总在 Android 上被拒，所以这里用 ioctl(SIOCGIFFLAGS) 逐个问。 */
static unsigned interface_flags(int sock, const char *name)
{
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) == 0)
        return (unsigned)ifr.ifr_flags;
    /* 兜底：拿不到就按"已启用"算，否则 libuv 会把这条丢掉 */
    return IFF_UP | IFF_RUNNING;
}

/* 从 netlink 的地址表里取接口 */
static int query_netlink(struct ifaddrs **head, struct ifaddrs **tail)
{
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;

    /* 取接口标志用的 socket */
    int ifsock = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);

    /* 和 bionic 一致：20 字节请求，payload 的 ifa_family 留 0(AF_UNSPEC) */
    unsigned char req[20];
    memset(req, 0, sizeof(req));
    struct nlmsghdr *nh = (struct nlmsghdr *)req;
    nh->nlmsg_len = sizeof(req);
    nh->nlmsg_type = RTM_GETADDR;           /* 22：地址表，不需要 CAP_NET_ADMIN */
    nh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    nh->nlmsg_seq = 0;
    nh->nlmsg_pid = 0;

    if (sendto(fd, req, sizeof(req), 0, NULL, 0) < 0) {
        close(fd);
        return -1;
    }

    struct namemap map[MAX_ENTRIES];
    int mapcount = 0;

    char buf[16384];
    for (;;) {
        int n = recvfrom(fd, buf, sizeof(buf), 0, NULL, NULL);
        if (n <= 0)
            break;

        for (struct nlmsghdr *h = (struct nlmsghdr *)buf; NLMSG_OK(h, (unsigned)n);
             h = NLMSG_NEXT(h, n)) {
            if (h->nlmsg_type == NLMSG_DONE)
                goto done;
            if (h->nlmsg_type == NLMSG_ERROR)
                goto done;
            if (h->nlmsg_type != RTM_NEWADDR)
                continue;

            struct ifaddrmsg *am = NLMSG_DATA(h);
            int family = am->ifa_family;
            int prefix = am->ifa_prefixlen;
            unsigned flags = 0;
            char label[IFNAMSIZ + 1] = {0};
            unsigned char addrbuf[16];
            int addrlen = 0;

            size_t rlen = h->nlmsg_len - NLMSG_LENGTH(sizeof(struct ifaddrmsg));

            /* 先探测本条消息用的编号方案（RTA_NEXT 会递减 len，所以用副本） */
            int classic = 0;
            {
                size_t scan = rlen;
                for (struct rtattr *t = IFA_RTA(am); RTA_OK(t, scan); t = RTA_NEXT(t, scan))
                    if (t->rta_type == K_IFA_ADDRESS)
                        classic = 1;
            }
            unsigned T_ADDR  = classic ? K_IFA_ADDRESS : K_IFA_ADDRESS + 1;
            unsigned T_LOCAL = classic ? K_IFA_LOCAL   : K_IFA_LOCAL + 1;
            unsigned T_LABEL = classic ? K_IFA_LABEL   : K_IFA_LABEL + 1;
            unsigned T_CACHE = classic ? K_IFA_CACHEINFO : K_IFA_CACHEINFO + 1;
            unsigned T_FLAGS = classic ? K_IFA_FLAGS   : K_IFA_FLAGS + 1;

            for (struct rtattr *rta = IFA_RTA(am); RTA_OK(rta, rlen); rta = RTA_NEXT(rta, rlen)) {
                unsigned type = rta->rta_type;
                unsigned plen = RTA_PAYLOAD(rta);
                if (type == T_LABEL) {
                    if (plen > 0 && plen <= IFNAMSIZ) {
                        memcpy(label, RTA_DATA(rta), plen);
                        label[IFNAMSIZ] = '\0';
                    }
                } else if (type == T_FLAGS) {
                    if (plen >= sizeof(unsigned int))
                        flags = *(const unsigned int *)RTA_DATA(rta);
                } else if (type == T_ADDR || type == T_LOCAL) {
                    if (!addrlen && (plen == 4 || plen == 16) && plen <= sizeof(addrbuf)) {
                        memcpy(addrbuf, RTA_DATA(rta), plen);
                        addrlen = (int)plen;
                    }
                } else if (type == T_CACHE && family == AF_INET6) {
                    /* struct ifa_cacheinfo 最后一个字节是 IPv6 前缀长度 */
                    if (plen >= 16)
                        prefix = ((const unsigned char *)RTA_DATA(rta))[15];
                }
            }

            if (!addrlen)
                continue;

            if (label[0])
                nm_set(map, &mapcount, am->ifa_index, label);

            const char *name = label[0] ? label : nm_get(map, mapcount, am->ifa_index);
            if (!name || !name[0])
                continue;   /* IPv6 条目常常没有 IFA_LABEL，对不上名字就跳过 */

            /* 接口标志要真实的 IFF_*，地址消息里的 IFA_FLAGS 是地址标志，用不了 */
            flags = interface_flags(ifsock, name);

            struct sockaddr_storage sa;
            memset(&sa, 0, sizeof(sa));
            if (family == AF_INET && addrlen == 4) {
                struct sockaddr_in *sin = (struct sockaddr_in *)&sa;
                sin->sin_family = AF_INET;
                memcpy(&sin->sin_addr, addrbuf, 4);
            } else if (family == AF_INET6 && addrlen == 16) {
                struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&sa;
                sin6->sin6_family = AF_INET6;
                memcpy(&sin6->sin6_addr, addrbuf, 16);
            } else {
                continue;
            }

            struct sockaddr_storage ms;
            mask_from_prefix(family, prefix, &ms);

            struct sockaddr *pa = malloc(sizeof(sa));
            struct sockaddr *pm = malloc(sizeof(ms));
            if (!pa || !pm) { free(pa); free(pm); continue; }
            memcpy(pa, &sa, sizeof(sa));
            memcpy(pm, &ms, sizeof(ms));
            append_entry(head, tail, name, flags, pa, pm);
        }
    }
done:
    close(fd);
    if (ifsock >= 0)
        close(ifsock);
    return (*head ? 0 : -1);
}

int getifaddrs(struct ifaddrs **ifap)
{
    if (!ifap)
        return -1;
    *ifap = NULL;

    struct ifaddrs *head = NULL, *tail = NULL;

    if (query_netlink(&head, &tail) != 0) {
        /* 拿不到就返回空列表而不是失败，调用方不会因此崩溃 */
        freeifaddrs(head);
        head = NULL;
        tail = NULL;
    }

    if (!head) {
        /* 至少给一个 lo 占位，保证调用方拿到非 NULL */
        struct ifaddrs *e = calloc(1, sizeof(*e));
        if (!e) {
            errno = ENOMEM;
            return -1;
        }
        e->ifa_name = strdup("lo");
        e->ifa_flags = IFF_UP | IFF_RUNNING | IFF_LOOPBACK;
        struct sockaddr_in *a = calloc(1, sizeof(*a));
        struct sockaddr_in *m = calloc(1, sizeof(*m));
        if (a) { a->sin_family = AF_INET; a->sin_addr.s_addr = htonl(0x7f000001); }
        if (m) { m->sin_family = AF_INET; }
        e->ifa_addr = (struct sockaddr *)a;
        e->ifa_netmask = (struct sockaddr *)m;
        head = e;
    }

    *ifap = head;
    if (getenv("IFADDRRS_DEBUG") != NULL) {
        int n = 0;
        for (struct ifaddrs *e = head; e; e = e->ifa_next) {
            char ip[64] = "?";
            if (e->ifa_addr && e->ifa_addr->sa_family == AF_INET)
                inet_ntop(AF_INET, &((struct sockaddr_in *)e->ifa_addr)->sin_addr, ip, sizeof(ip));
            else if (e->ifa_addr && e->ifa_addr->sa_family == AF_INET6)
                inet_ntop(AF_INET6, &((struct sockaddr_in6 *)e->ifa_addr)->sin6_addr, ip, sizeof(ip));
            fprintf(stderr, "[ifaddrs] %-10s family=%d %s flags=0x%x\n",
                    e->ifa_name ? e->ifa_name : "?", e->ifa_addr ? e->ifa_addr->sa_family : -1,
                    ip, e->ifa_flags);
            n++;
        }
        fprintf(stderr, "[ifaddrs] 共 %d 条\n", n);
    }
    return 0;
}

void freeifaddrs(struct ifaddrs *ifa)
{
    while (ifa) {
        struct ifaddrs *next = ifa->ifa_next;
        free(ifa->ifa_name);
        free(ifa->ifa_addr);
        free(ifa->ifa_netmask);
        free(ifa->ifa_broadaddr);
        free(ifa->ifa_data);
        free(ifa);
        ifa = next;
    }
}
EOF
	run "$GLIBC_CC" -shared -fPIC -O2 -mno-fix-cortex-a53-835769 \
		-o "$IFADDRRS_SO" "$IFADDRRS_SRC"
	[ "$DO_DRYRUN" = 1 ] || [ -f "$IFADDRRS_SO" ] || die "getifaddrs 补丁编译失败"
else
	say "跳过 getifaddrs 补丁（--no-ifaddrs，kimi web 会崩）"
	rm -f "$IFADDRRS_SO"
fi

# ---------- 5b. hijack.js ----------
# 给 os.networkInterfaces() 兜一层异常：Android 上它可能抛 EACCES，
# 而 kimi web 在 'listening' 事件回调里调它，异常逃逸出去会带走整个进程。
# 它只在真的抛错时才返回空对象，正常情况仍走 ifaddrs.so 的真实网卡列表。
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
//   - 正常情况（配合 ~/.local/lib/ifaddrs.so 时）返回真实网卡列表；
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
if [ "$DO_IFADDRRS" = 1 ] && { [ "$DO_DRYRUN" = 1 ] || [ -f "$IFADDRRS_SO" ]; }; then
	if [ -n "$PRELOAD" ]; then PRELOAD="$PRELOAD:$IFADDRRS_SO"; else PRELOAD="$IFADDRRS_SO"; fi
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
# ifaddrs.so：替换 getifaddrs()（glibc 的实现在这台机上返回 EACCES）
unset LD_LIBRARY_PATH LD_AUDIT
GLIBC=$GLIBC_PREFIX
EOF
	if [ -f "$HIJACK_JS" ]; then
		cat >> "$LAUNCHER" <<EOF
# hijack.js：兜住 os.networkInterfaces() 的异常。它只在真的抛错时才返回空对象，
# 正常情况仍走 ifaddrs.so 给出的真实网卡列表（横幅里的 Network 行）。
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

	# getifaddrs 补丁自检：跑一个只调 getifaddrs() 的小程序，
	# 看它能不能拿到网卡（拿不到就是补丁没生效）
	if [ "$DO_IFADDRRS" = 1 ] && [ -f "$IFADDRRS_SO" ]; then
		TMPD="$(mktemp -d)"
		cat > "$TMPD/t.c" <<'EOF'
#include <stdio.h>
#include <ifaddrs.h>
int main(void) {
    struct ifaddrs *ifa = NULL, *p;
    int n = 0;
    if (getifaddrs(&ifa) != 0) { printf("FAIL getifaddrs: %d\n", 1); return 1; }
    for (p = ifa; p; p = p->ifa_next) n++;
    freeifaddrs(ifa);
    printf("%s\n", n > 0 ? "OK" : "EMPTY");
    return n > 0 ? 0 : 1;
}
EOF
		ensure_gcc
		if "$GLIBC_CC" -O2 -mno-fix-cortex-a53-835769 -o "$TMPD/t" "$TMPD/t.c" 2>/dev/null; then
			R="$("$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1" --library-path "$GLIBC_PREFIX/lib" \
				"$TMPD/t" 2>/dev/null || echo FAIL)"
			R2="$(LD_PRELOAD="$IFADDRRS_SO" "$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1" \
				--library-path "$GLIBC_PREFIX/lib" "$TMPD/t" 2>/dev/null || echo FAIL)"
			say "getifaddrs: 不打补丁=$R, 打补丁=$R2"
			[ "$R2" = "OK" ] || warn "getifaddrs 补丁似乎没生效，kimi web 可能会崩"
		fi
		rm -rf "$TMPD"
	fi
fi

cat <<EOF

安装完成。

  启动器 : $LAUNCHER
  二进制 : $KIMI_HOME/bin/kimi
  glibc  : $GLIBC_PREFIX
  补丁   : nolink=$DO_HARDLINK ifaddrs=$DO_IFADDRRS

接下来：
  1. 开一个新终端或者source你的shell的启动配置文件（让 PATH 生效），然后跑 \`kimi\`
  2. 确认 \`which kimi\` 指向 $LAUNCHER 而不是 $KIMI_HOME/bin/kimi
  3. \`kimi web\` 需要 ifaddrs 补丁，别用 --no-ifaddrs
EOF
