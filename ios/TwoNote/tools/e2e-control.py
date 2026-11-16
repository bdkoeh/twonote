#!/usr/bin/env python3
"""Lets the UI test take the server away and bring it back.

The UI test runs inside the simulator and cannot run docker itself, so it asks this little
server on the Mac's loopback interface:  GET /stop  and  GET /start  stop and start the one
container named on the command line;  GET /reset  replaces it with a fresh one (a server
without an account), when the server's port and image were given.

GET /article  is a small web page with a title, for sharing from Safari to TwoNote.

    python3 e2e-control.py <container-name> [port] [server-port image]
"""
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

container = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18091
server_port = sys.argv[3] if len(sys.argv) > 4 else None
image = sys.argv[4] if len(sys.argv) > 4 else None

ARTICLE = b"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Marsh Birds Weekly</title></head>
<body style="font: 17px -apple-system; margin: 24px">
<h1>Marsh Birds Weekly</h1>
<p id="quote">A bittern was heard booming at dawn near the reedbed.</p>
<p>Second paragraph of the article.</p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        action = self.path.split("?")[0].strip("/")
        if action == "article":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(ARTICLE)))
            self.end_headers()
            self.wfile.write(ARTICLE)
            return
        if action == "reset" and image:
            subprocess.run(["docker", "rm", "-f", container], capture_output=True, text=True)
            result = subprocess.run(
                ["docker", "run", "-d", "--name", container, "-p", server_port + ":8080", image], capture_output=True, text=True)
        elif action in ("stop", "start"):
            result = subprocess.run(["docker", action, container], capture_output=True, text=True)
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200 if result.returncode == 0 else 500)
        self.end_headers()
        self.wfile.write((result.stdout + result.stderr).encode())

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
