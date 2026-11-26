#!/data/data/com.termux/files/usr/bin/env python3
"""反向隧道：电脑 -> 手机的本地端口（手机侧）。

Android 不允许热点客户端连接手机上的普通应用，但手机可以主动连电脑。
所以由手机发起隧道连接，电脑在本地开一个端口，把流量经隧道送到手机。

用法：
    python3 tunnel-phone.py <电脑IP> [--tunnel-port 9000] [--target-port 58627]

协议（每条连接都是手机主动连电脑）：
    控制连接：手机连上后先发 "CONTROL\\n"，之后电脑在其上发 "OPEN <targetPort> <seq>\\n"
    数据连接：手机为每个 seq 新连一条，先发 "STREAM <seq>\\n"，随后是原始字节
"""

import socket
import sys
import threading

TIMEOUT = 15


def log(*a):
    print("[tunnel-phone]", *a, flush=True)


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


def open_stream(host, tunnel_port, target_port, seq):
    """开一条数据连接，桥接到手机的 127.0.0.1:target_port。"""
    up = socket.create_connection((host, tunnel_port), timeout=TIMEOUT)
    up.sendall(("STREAM %d\n" % seq).encode())
    down = socket.create_connection(("127.0.0.1", target_port), timeout=TIMEOUT)
    t1 = threading.Thread(target=pipe, args=(up, down), daemon=True)
    t2 = threading.Thread(target=pipe, args=(down, up), daemon=True)
    t1.start()
    t2.start()


def handle_control(host, tunnel_port, target_port, conn):
    buf = b""
    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                parts = line.decode(errors="replace").split()
                if len(parts) == 3 and parts[0] == "OPEN":
                    port, seq = int(parts[1]), int(parts[2])
                    log("电脑请求 -> 127.0.0.1:%d (seq=%d)" % (port, seq))
                    threading.Thread(
                        target=open_stream, args=(host, tunnel_port, port, seq), daemon=True
                    ).start()
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    host = sys.argv[1]
    tunnel_port = 9000
    target_port = 58627
    args = sys.argv[2:]
    for i, a in enumerate(args):
        if a == "--tunnel-port" and i + 1 < len(args):
            tunnel_port = int(args[i + 1])
        if a == "--target-port" and i + 1 < len(args):
            target_port = int(args[i + 1])

    log("连接电脑 %s:%d …" % (host, tunnel_port))
    while True:
        try:
            conn = socket.create_connection((host, tunnel_port), timeout=TIMEOUT)
        except OSError as e:
            log("连不上电脑：%r，5 秒后重试" % (e,))
            threading.Event().wait(5)
            continue
        conn.sendall(b"CONTROL\n")
        log("控制连接已建立")
        handle_control(host, tunnel_port, target_port, conn)


if __name__ == "__main__":
    main()
