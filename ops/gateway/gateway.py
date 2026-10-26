#!/usr/bin/env python
"""dsv41 轻量 API 网关：鉴权 + 最闲路由 + 统计。纯标准库，零依赖。
监听 0.0.0.0:8012，后端 127.0.0.1:8011 / 8013（环境变量可覆盖）。
  /health  免鉴权存活探针
  /stats   带 key 查看每后端请求数/在途/错误/时延
"""
import http.client
import http.server
import json
import os
import threading
import time

KEY = os.environ.get("DSV41_GW_KEY", "changeme")
BACKENDS = [b.strip() for b in os.environ.get(
    "DSV41_GW_BACKENDS", "127.0.0.1:8011,127.0.0.1:8013").split(",") if b.strip()]
PORT = int(os.environ.get("DSV41_GW_PORT", "8012"))
LOG = os.path.expanduser("~/dsv41_deploy/logs/gateway.log")

lock = threading.Lock()
stats = {"started": time.strftime("%F %T")}


def bstat(addr):
    with lock:
        return stats.setdefault(addr, {"requests": 0, "inflight": 0,
                                       "errors": 0, "ms_total": 0})


def logline(*a):
    with open(LOG, "a") as f:
        f.write(" ".join(str(x) for x in a) + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _authed(self):
        h = self.headers.get("Authorization", "") or self.headers.get("x-api-key", "")
        if KEY in h:
            return True
        msg = b'{"error":{"message":"invalid api key","type":"auth_error"}}'
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)
        return False

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if not self._authed():
            return
        if self.path == "/stats":
            with lock:
                body = json.dumps(stats, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._proxy("GET")

    def do_POST(self):
        if not self._authed():
            return
        self._proxy("POST")

    def _pick(self):
        best, best_n = BACKENDS[0], 10 ** 9
        for a in BACKENDS:
            n = bstat(a)["inflight"]
            if n < best_n:
                best, best_n = a, n
        return best

    def _proxy(self, method):
        addr = self._pick()
        t0 = time.time()
        s = bstat(addr)
        s["requests"] += 1
        s["inflight"] += 1
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            host, port = addr.split(":")
            conn = http.client.HTTPConnection(host, int(port), timeout=1800)
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in ("host", "transfer-encoding",
                                            "connection", "content-length")}
            if body is not None:
                headers["Content-Length"] = str(len(body))
            # 后端 SSE 发完 [DONE] 后连接仍保持打开；带 Connection:close 令其响应完即关，
            # 网关才能收到 EOF 并正确终结客户端的 close-delimited 流
            headers["Connection"] = "close"
            conn.request(method, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            chunked = "chunked" in (resp.getheader("Transfer-Encoding") or "").lower()
            clen = resp.getheader("Content-Length")
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in ("transfer-encoding", "connection", "content-length"):
                    continue
                self.send_header(k, v)
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            elif clen is not None:
                n = int(clen)
                self.send_header("Content-Length", str(n))
                self.end_headers()
                if n:
                    self.wfile.write(resp.read(n))
            else:
                # 连接关闭定界的流式响应：转发到 EOF，本侧也用关闭定界
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                tail = b""
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    # 后端发完 [DONE] 后连接保持打开（无视 Connection:close），
                    # 网关自行检测 SSE 终止标记并收尾，否则客户端流永不终结
                    tail = (tail + chunk)[-64:]
                    if b"[DONE]" in tail:
                        break
                self.wfile.flush()
            conn.close()
            s["ms_total"] += int((time.time() - t0) * 1000)
            logline(time.strftime("%T"), method, self.path, addr,
                    resp.status, f"{(time.time() - t0) * 1000:.0f}ms")
        except Exception as e:
            s["errors"] += 1
            logline(time.strftime("%T"), "ERR", self.path, addr, repr(e))
            try:
                msg = json.dumps({"error": {
                    "message": f"backend {addr} failed: {e}",
                    "type": "gateway_error"}}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)
            except Exception:
                pass
        finally:
            s["inflight"] -= 1

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    print(f"gateway on 0.0.0.0:{PORT} backends={BACKENDS}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
