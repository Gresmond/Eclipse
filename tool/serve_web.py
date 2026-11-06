#!/usr/bin/env python3
"""Serves build/web on http://localhost:8765 (or a port you name) with the
headers the site has in web/_headers. Only for trying the web build locally;
build it with `bash tool/build_web.sh --local`, as there's no sign-in here."""
import functools
import http.server
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
headers = [
    line.strip().split(": ", 1)
    for line in (root / "web" / "_headers").read_text().splitlines()
    if ": " in line
]


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


http.server.ThreadingHTTPServer(
    ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765),
    functools.partial(Handler, directory=str(root / "build" / "web")),
).serve_forever()
