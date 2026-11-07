#!/usr/bin/env python3
"""Creates the hosted PRHub GitHub App on the signed-in GitHub account, through GitHub's manifest flow.

Run it on a Mac where Jai is signed in to github.com in the default browser:

    python3 -I deploy/github-app/create.py [--worker https://<custom domain>]

It opens a page that posts manifest.json to github.com/settings/apps/new. After Jai clicks Create, GitHub returns
to this script, which trades the one-time code for the App's credentials and writes them, mode 0600, to
tmp/github-app/prhub-app.json. It prints no secret. Steps after that: docs/plans/github-app.md, "Creating the App".
"""

import argparse
import html
import json
import os
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The hosted Worker the manifest names; --worker swaps in another origin (a custom domain).
PLACEHOLDER = "https://prhub.jai-f89.workers.dev"
NEW_APP_URL = "https://github.com/settings/apps/new"


def manifest_for(worker: str, redirect: str) -> dict:
    text = (HERE / "manifest.json").read_text().replace(PLACEHOLDER, worker)
    manifest = json.loads(text)
    manifest["redirect_url"] = redirect
    return manifest


def convert(code: str) -> dict:
    """The manifest flow's last step. GitHub needs no token for it, and the code works once, within one hour."""
    request = urllib.request.Request(
        f"https://api.github.com/app-manifests/{urllib.parse.quote(code)}/conversions",
        method="POST",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "prhub-app-setup"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--worker", default=PLACEHOLDER,
                        help="the hosted Worker's origin, https://host with no path")
    parser.add_argument("--port", type=int, default=53682, help="local port for GitHub's redirect")
    parser.add_argument("--dry-run", action="store_true", help="print the manifest and exit")
    args = parser.parse_args()

    worker = args.worker.rstrip("/")
    if not worker.startswith("https://") or urllib.parse.urlparse(worker).path:
        parser.error("--worker must be https://<host>, with no path")
    redirect = f"http://127.0.0.1:{args.port}/created"
    manifest = manifest_for(worker, redirect)
    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    repo = HERE.parent.parent
    out_dir = repo / "tmp" / "github-app"
    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o700)
    out_file = out_dir / "prhub-app.json"
    state = secrets.token_urlsafe(24)
    result: dict = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args) -> None:
            pass

        def reply(self, status: int, body: str) -> None:
            data = f"<!doctype html><meta name='viewport' content='width=device-width'>{body}".encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path == "/":
                action = html.escape(f"{NEW_APP_URL}?state={state}", quote=True)
                value = html.escape(json.dumps(manifest), quote=True)
                self.reply(200, f"<form id=f method=post action='{action}'>"
                                f"<input type=hidden name=manifest value='{value}'>"
                                f"<button>Create {html.escape(manifest['name'])} on GitHub</button></form>"
                                "<script>document.getElementById('f').submit()</script>")
                return
            if url.path != "/created":
                self.reply(404, "Not found")
                return
            code = query.get("code", [""])[0]
            if query.get("state", [""])[0] != state or not code.isalnum():
                self.reply(400, "This is not the answer to this script's request. Nothing was saved.")
                return
            try:
                app = convert(code)
            except urllib.error.HTTPError as error:
                result["error"] = f"GitHub answered {error.code} to the code exchange"
                self.reply(502, html.escape(result["error"]))
                threading.Thread(target=server.shutdown).start()
                return
            fd = os.open(out_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as handle:
                json.dump(app, handle, indent=2)
            result["app"] = app
            self.reply(200, f"<p>Created <a href='{html.escape(app['html_url'])}'>{html.escape(app['slug'])}</a>. "
                            "Back to the terminal for the next steps.</p>")
            threading.Thread(target=server.shutdown).start()

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    start = f"http://127.0.0.1:{args.port}/"
    print(f"Opening {start}; if no browser opens, open it yourself. Waiting for GitHub (Ctrl-C to stop).")
    webbrowser.open(start)
    server.serve_forever()

    if "error" in result:
        print(result["error"], file=sys.stderr)
        return 1
    app = result["app"]
    fields = ["id", "slug", "client_id", "client_secret", "webhook_secret", "pem"]
    missing = [name for name in fields if not app.get(name)]
    print(f"Created {app['slug']} (App ID {app['id']}): {app['html_url']}")
    print(f"Credentials in {out_file} (mode 0600). Fields present: "
          f"{', '.join(name for name in fields if name not in missing)}.")
    if missing:
        print(f"Missing from GitHub's answer: {', '.join(missing)}", file=sys.stderr)
        return 1
    print("Next: store them in your password manager and delete the file (docs/plans/github-app.md, 'Creating the App').")
    return 0


if __name__ == "__main__":
    sys.exit(main())
