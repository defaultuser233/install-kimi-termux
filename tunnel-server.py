#!/usr/bin/env python3
"""反向隧道：电脑 -> 手机的本地端口（电脑侧）。

Android 不允许热点客户端连接手机上的普通应用，但手机可以主动连电脑。
所以由手机发起隧道连接，电脑在本地开一个端口，把流量经隧道送到手机。

用法（电脑上）：
    python tunnel-server.py [--host-port 58628] [--tunnel-port 9000] [--target-port 58627]

    --host-port   浏览器访问这个端口（默认 58628，只监听 127.0.0.1）
    --tunnel-port 隧道端口，手机端要连到这个（默认 9000）
    --target-port 手机上要转发的目标端口（默认 58627，kimi web 的端口）

协议（每条连接都是手机主动连电脑）：
    控制连接：手机连上后先发 "CONTROL\\n"，之后电脑在其上发 "OPEN <targetPort> <seq>\\n"
    数据连接：手机为每个 seq 新连一条，先发 "STREAM <seq>\\n"，随后是原始字节
"""

import socket
import sys
import threading

TIMEOUT = 30


def log(*a):
    print("[tunnel-server]", *a, flush=True)


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main():
    host_port, tunnel_port, target_port = 58628, 9000, 58627
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--host-port" and i + 1 < len(args):
            host_port = int(args[i + 1])
        if a == "--tunnel-port" and i + 1 < len(args):
            tunnel_port = int(args[i + 1])
        if a == "--target-port" and i + 1 < len(args):
            target_port = int(args[i + 1])

    lock = threading.Lock()
    pending = {}          # seq -> 浏览器连接
    next_seq = [0]
    control = []          # 控制连接

    tunnel_listener = socket.socket()
    tunnel_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tunnel_listener.bind(("0.0.0.0", tunnel_port))
    tunnel_listener.listen(16)

    host_listener = socket.socket()
    host_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    host_listener.bind(("127.0.0.1", host_port))
    host_listener.listen(16)

    def send_open(seq):
        with lock:
            conns = list(control)
        if not conns:
            return False
        try:
            conns[0].sendall(("OPEN %d %d\n" % (target_port, seq)).encode())
            return True
        except OSError:
            return False

    def serve_browser(client):
        with lock:
            seq = next_seq[0]
            next_seq[0] += 1
            pending[seq] = client
        if not send_open(seq):
            log("没有可用的控制连接，关闭")
            with lock:
                pending.pop(seq, None)
            client.close()

    def handle_tunnel(conn, addr):
        conn.settimeout(TIMEOUT)
        try:
            first = conn.recv(64)
        except OSError:
            conn.close()
            return
        if not first:
            conn.close()
            return
        if b"\n" in first:
            line, _ = first.split(b"\n", 1)
        else:
            line = first
        kind = line.decode(errors="replace").strip()

        if kind == "CONTROL":
            log("手机已连接：%s（控制通道）" % (addr,))
            with lock:
                control.append(conn)
            buf = b""
            try:
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    buf += data
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        parts = raw.decode(errors="replace").split()
                        if len(parts) == 3 and parts[0] == "OPEN":
                            port, seq = int(parts[1]), int(parts[2])
                            log("手机请求 -> 127.0.0.1:%d (seq=%d)" % (port, seq))
            except OSError:
                pass
            finally:
                with lock:
                    if conn in control:
                        control.remove(conn)
                conn.close()
            return

        if kind.startswith("STREAM"):
            seq = int(kind.split()[1])
            with lock:
                browser = pending.pop(seq, None)
            if browser is None:
                conn.close()
                return
            log("数据通道 seq=%d 已配对" % seq)
            threading.Thread(target=pipe, args=(browser, conn), daemon=True).start()
            threading.Thread(target=pipe, args=(conn, browser), daemon=True).start()
            return

        conn.close()

    def accept_tunnel():
        while True:
            conn, addr = tunnel_listener.accept()
            threading.Thread(target=handle_tunnel, args=(conn, addr), daemon=True).start()

    def accept_host():
        while True:
            client, _ = host_listener.accept()
            threading.Thread(target=serve_browser, args=(client,), daemon=True).start()

    threading.Thread(target=accept_tunnel, daemon=True).start()
    threading.Thread(target=accept_host, daemon=True).start()

    log("隧道端口 %d 已监听，等待手机连接" % tunnel_port)
    log("浏览器请访问 http://127.0.0.1:%d/" % host_port)
    try:
        while True:
            threading.Event().wait(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
