#!/usr/bin/env python3
"""The Mac end-to-end run's helper, on the loopback interface only.

The app under test is sandboxed: it can make network connections but write nowhere outside
its container, and it cannot run docker. So it asks this helper:

  GET  /stop, /start      stop and start the server container named on the command line
  GET  /share?url=<url>   share a web address through the Share menu's "TwoNote" service,
                          from a process of its own (tools/e2e-mac-share.swift, built by
                          e2e-mac.sh): the app cannot use its own share extension itself
  POST /log               a line of progress (printed with an [e2e] prefix)
  POST /shot/<name>.png   a screenshot of one of its windows (saved into the shots folder)
  POST /result            "passed" or "failed: ..." (written to <shots>/../.build/e2e-result)

    python3 e2e-mac-control.py <container-name> <port> <shots folder> <result file> [<share helper>]
"""
import os
import re
import subprocess
import sys
from urllib.parse import parse_qs, urlparse
from http.server import BaseHTTPRequestHandler, HTTPServer

container = sys.argv[1]
port = int(sys.argv[2])
shots = sys.argv[3]
result_file = sys.argv[4]
share_helper = sys.argv[5] if len(sys.argv) > 5 else ""


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        action = self.path.split("?")[0].strip("/")
        if action in ("stop", "start"):
            result = subprocess.run(["docker", action, container], capture_output=True, text=True)
            self.reply(200 if result.returncode == 0 else 500, (result.stdout + result.stderr).encode())
        elif action == "share":
            url = parse_qs(urlparse(self.path).query).get("url", [""])[0]
            if not share_helper or not url.startswith("https://"):
                self.reply(400)
                return
            try:
                result = subprocess.run([share_helper, url], capture_output=True, text=True, timeout=80)
                status = {0: 200, 3: 409}.get(result.returncode, 500)
                self.reply(status, (result.stdout + result.stderr).encode())
            except subprocess.TimeoutExpired:
                self.reply(504, b"timed out")
        else:
            self.reply(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        path = self.path.split("?")[0].strip("/")
        if path == "log":
            print("[e2e] " + body.decode("utf-8", "replace"), flush=True)
            self.reply(200)
        elif path.startswith("shot/"):
            name = path[len("shot/"):]
            if not re.fullmatch(r"[A-Za-z0-9_.-]+\.png", name) or not shots:
                self.reply(400)
                return
            with open(os.path.join(shots, name), "wb") as f:
                f.write(body)
            self.reply(200)
        elif path == "result":
            with open(result_file, "wb") as f:
                f.write(body)
            self.reply(200)
        else:
            self.reply(404)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
