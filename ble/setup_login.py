"""Loopback-only one-time setup. Never logs or saves account passwords/tokens."""
import base64
import html
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from secure_store import save_user_id

ROOT = Path(__file__).resolve().parent
HOST = "127.0.0.1"
PORT = 18766
ORIGIN = f"http://{HOST}:{PORT}"
previous_url = ROOT / "setup-url.txt"
TOKEN = (previous_url.read_text().strip().rsplit("/", 1)[-1]
         if previous_url.exists() else secrets.token_urlsafe(32))
ROUTE = "/setup/" + TOKEN
SECRET = ROOT / "user-id.dpapi"


def page(message="", success=False):
    content = "<p>Account ID saved. You can close this tab.</p>" if success else f"""
    <p>Connect this PC to your EcoFlow over Bluetooth. Your password is sent to
    EcoFlow's HTTPS login API and is never saved. Only your account ID is saved,
    encrypted for your Windows account.</p>
    <form method="post" action="{ROUTE}">
      <input type="hidden" name="csrf" value="{TOKEN}">
      <label>EcoFlow email<input name="email" type="email" autocomplete="username"></label>
      <label>EcoFlow password<input name="password" type="password" autocomplete="current-password"></label>
      <label>Account region<select name="region"><option value="api">Default / US</option>
      <option value="api-e">Europe</option><option value="api-a">Asia</option>
      <option value="api-j">Japan</option></select></label>
      <p>Already know your numeric EcoFlow user ID? Enter it below instead of signing in.</p>
      <label>User ID (optional)<input name="user_id" inputmode="numeric" autocomplete="off"></label>
      <button type="submit">Set up Bluetooth access</button>
    </form>"""
    return f"""<!doctype html><html lang="en"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>EcoFlow Bluetooth setup</title><style>
    body{{font:17px system-ui;background:#101820;color:#e8eef2;max-width:580px;margin:50px auto;padding:24px}}
    label{{display:block;margin:20px 0}}input,select,button{{display:block;box-sizing:border-box;width:100%;padding:12px;margin-top:7px;font:inherit}}
    button{{background:#72d2bd;border:0;border-radius:5px;cursor:pointer}}
    .message{{color:#ffca7b}}</style><h1>EcoFlow Bluetooth setup</h1>
    <p class="message">{html.escape(message)}</p>{content}</html>""".encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, content, status=200, mime="text/html; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        if self.headers.get("Host") != f"{HOST}:{PORT}" or self.path != ROUTE:
            self.reply(b"Not found", 404, "text/plain")
            return
        self.reply(page(success=SECRET.exists()))

    def do_POST(self):
        if (self.headers.get("Host") not in {f"{HOST}:{PORT}", f"localhost:{PORT}"}
                or self.path != ROUTE or SECRET.exists()):
            self.reply(b"Invalid request", 403, "text/plain")
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 16384:
                raise ValueError("Invalid form size.")
            values = urllib.parse.parse_qs(self.rfile.read(size).decode())
            field = lambda name: values.get(name, [""])[0]
            if not secrets.compare_digest(field("csrf"), TOKEN):
                raise ValueError("This setup page is out of date. Reload it, then submit again.")
            user_id = field("user_id").strip()
            if user_id:
                if not user_id.isascii() or not user_id.isdigit():
                    raise ValueError("The user ID must contain only digits.")
            else:
                if not field("email") or not field("password"):
                    raise ValueError("Enter your EcoFlow email and password, or your numeric user ID.")
                region = field("region")
                if region not in {"api", "api-e", "api-a", "api-j"}:
                    raise ValueError("Invalid region.")
                payload = {
                    "scene": "IOT_APP", "appVersion": "1.0.0", "userType": "ECOFLOW",
                    "oauth": {"bundleId": "com.ef.EcoFlow"},
                    "email": field("email").strip(),
                    "password": base64.b64encode(field("password").encode()).decode(),
                }
                request = urllib.request.Request(
                    f"https://{region}.ecoflow.com/auth/login",
                    data=json.dumps(payload).encode(),
                    headers={"Content-Type": "application/json", "Accept": "application/json"})
                with urllib.request.urlopen(request, timeout=20) as response:
                    result = json.load(response)
                if str(result.get("code")) != "0":
                    raise ValueError("EcoFlow rejected the login. Check your password and account region.")
                user_id = str(result["data"]["user"]["userId"])
            save_user_id(SECRET, user_id)
            self.reply(page(success=True))
            print("EcoFlow account ID saved securely. No password or session token retained.", flush=True)
        except ValueError as error:
            self.reply(page(str(error)), 400)
        except Exception:
            self.reply(page("Could not complete setup. Check your connection and try again."), 502)


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    server.timeout = 1
    url = ORIGIN + ROUTE
    (ROOT / "setup-url.txt").write_text(url)
    print(f"Open this address in a browser on this PC: {url}", flush=True)
    print("(It is also in setup-url.txt; keep it private.) The page closes after setup or 30 minutes.", flush=True)
    expires = time.monotonic() + 1800
    saved_at = None
    while time.monotonic() < expires:
        server.handle_request()
        if SECRET.exists():
            saved_at = saved_at or time.monotonic()
            if time.monotonic() - saved_at > 15:
                break
    server.server_close()
