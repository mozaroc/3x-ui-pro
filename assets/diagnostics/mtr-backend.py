#!/usr/bin/env python3
"""
MTR diagnostics backend — serves on 127.0.0.1:PORT only.
Accepts POST /mtr with packet_count parameter.
Client IP is taken from X-Real-IP header (set by nginx).
Never runs mtr to arbitrary hosts.
"""

import argparse
import ipaddress
import json
import logging
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlparse

# ── Constants ──────────────────────────────────────────────────────────────────
MAX_PACKET_COUNT = 100
MIN_PACKET_COUNT = 1
DEFAULT_PACKET_COUNT = 5
MTR_TIMEOUT = 360        # seconds: mtr max run time (100 packets × ~3s margin)
RATE_LIMIT_WINDOW = 60   # seconds
RATE_LIMIT_MAX = 3       # requests per window per IP
MTR_BIN = "/usr/bin/mtr"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("mtr-backend")

# ── Rate limiter ───────────────────────────────────────────────────────────────
_rate_lock = Lock()
_rate_store: dict[str, list[float]] = {}


def rate_check(client_ip: str) -> bool:
    """Returns True if request is allowed, False if rate-limited."""
    now = time.monotonic()
    with _rate_lock:
        times = _rate_store.get(client_ip, [])
        times = [t for t in times if now - t < RATE_LIMIT_WINDOW]
        if len(times) >= RATE_LIMIT_MAX:
            return False
        times.append(now)
        _rate_store[client_ip] = times
    return True


# ── IP validation ──────────────────────────────────────────────────────────────

def validate_ip(raw: str) -> str:
    """
    Strict IP validation. Rejects private/loopback/link-local/multicast ranges
    to prevent SSRF and abuse.
    Returns the normalized IP string or raises ValueError.
    """
    raw = raw.strip()
    # Strip IPv6 brackets
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    # Strip IPv4-mapped IPv6 prefix
    if raw.startswith("::ffff:"):
        raw = raw[7:]

    try:
        addr = ipaddress.ip_address(raw)
    except ValueError as e:
        raise ValueError(f"Invalid IP address: {raw!r}") from e

    if addr.is_private:
        raise ValueError(f"Private IP not allowed: {raw}")
    if addr.is_loopback:
        raise ValueError(f"Loopback IP not allowed: {raw}")
    if addr.is_link_local:
        raise ValueError(f"Link-local IP not allowed: {raw}")
    if addr.is_multicast:
        raise ValueError(f"Multicast IP not allowed: {raw}")
    if addr.is_reserved:
        raise ValueError(f"Reserved IP not allowed: {raw}")

    return str(addr)


def validate_packet_count(raw: str) -> int:
    """Parse and validate packet count. Returns int or raises ValueError."""
    if not re.fullmatch(r"[0-9]{1,2}", raw.strip()):
        raise ValueError("Packet count must be a 1-2 digit integer")
    n = int(raw.strip())
    if not (MIN_PACKET_COUNT <= n <= MAX_PACKET_COUNT):
        raise ValueError(f"Packet count must be between {MIN_PACKET_COUNT} and {MAX_PACKET_COUNT}")
    return n


# ── MTR runner ─────────────────────────────────────────────────────────────────

def run_mtr(target_ip: str, count: int) -> dict:
    """
    Run mtr against target_ip with exactly `count` cycles.
    Returns a dict with keys: success, output, error.
    """
    if not os.path.isfile(MTR_BIN):
        return {"success": False, "error": "mtr not installed", "output": ""}

    # Build command — note: NO shell=True, all args as list
    cmd = [
        MTR_BIN,
        "--report",
        "--report-wide",
        "--no-dns",
        "--max-ttl", "30",
        "--report-cycles", str(count),
        "--",           # explicit end of options: prevents injection via IP
        target_ip,
    ]

    log.info("Running mtr: %s cycles → %s", count, target_ip)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=MTR_TIMEOUT,
            # Safety: drop stdin, clean environment
            stdin=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin", "HOME": "/tmp"},
        )
        output = result.stdout or ""
        error = result.stderr or ""
        if result.returncode != 0:
            return {"success": False, "error": f"mtr exited {result.returncode}: {error[:500]}", "output": output}
        return {"success": True, "output": output, "error": ""}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "mtr timed out", "output": ""}
    except FileNotFoundError:
        return {"success": False, "error": "mtr binary not found", "output": ""}
    except Exception as exc:  # noqa: BLE001
        log.error("mtr exception: %s", exc)
        return {"success": False, "error": "internal error", "output": ""}


# ── HTTP handler ───────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # suppress default access log to stdout
        log.debug("http: " + fmt, *args)

    def _send_json(self, code: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def _client_ip(self) -> str:
        """Extract real client IP. nginx sets X-Real-IP via proxy_protocol chain."""
        # X-Real-IP: set by nginx real_ip module from proxy_protocol header
        ip = self.headers.get("X-Real-IP", "").strip()
        if ip:
            log.debug("IP from X-Real-IP: %s", ip)
            return ip
        # X-Forwarded-For: fallback, take first (leftmost) address in chain
        xff = self.headers.get("X-Forwarded-For", "").strip()
        if xff:
            ip = xff.split(",")[0].strip()
            log.debug("IP from X-Forwarded-For: %s (full: %s)", ip, xff)
            return ip
        # Direct connection — will be 127.0.0.1 when proxied through nginx
        ip = self.client_address[0]
        log.debug("IP from direct connection: %s", ip)
        return ip

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._send_json(200, {"ok": True})
            return

        # ── Clash subscription generator ───────────────────────────────────────
        if parsed.path == "/api/clash" or parsed.path.endswith("/api/clash"):
            tpl_path = "/var/www/subpage/clash.yaml.tpl"
            if not os.path.isfile(tpl_path):
                self._send_json(404, {"error": "clash template not found"})
                return
            params = parse_qs(parsed.query)
            sub_id = params.get("sub_id", [""])[0].strip()
            try:
                with open(tpl_path, "r", encoding="utf-8") as f:
                    content = f.read()
                content = content.replace("${SUB_ID}", sub_id)
                payload = content.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/yaml; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Content-Disposition", "attachment; filename=clash.yaml")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(payload)
            except Exception as exc:
                log.error("clash template error: %s", exc)
                self._send_json(500, {"error": "internal error"})
            return

        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)

        # ── Upload speed test receiver ─────────────────────────────────────
        # Reads the entire body before responding so the client timer is accurate
        if parsed.path == "/api/upload" or parsed.path.endswith("/api/upload"):
            content_length = int(self.headers.get("Content-Length", "0"))
            to_read = min(content_length, 600 * 1024 * 1024)  # cap at 600 MB
            received = 0
            buf = 65536
            while received < to_read:
                chunk = self.rfile.read(min(buf, to_read - received))
                if not chunk:
                    break
                received += len(chunk)
            self._send_json(200, {"received": received, "ok": True})
            return

        if not (parsed.path in ("/mtr", "/api/mtr") or parsed.path.endswith("/api/mtr")):
            self._send_json(404, {"error": "not found"})
            return

        raw_ip = self._client_ip()
        log.info("MTR request from %s", raw_ip)

        # ── Rate limit ────────────────────────────────────────────────────
        if not rate_check(raw_ip):
            self._send_json(429, {"error": "Rate limit exceeded. Please wait 60 seconds."})
            return

        # ── Validate client IP ────────────────────────────────────────────
        try:
            target_ip = validate_ip(raw_ip)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
            return

        # ── Parse body ────────────────────────────────────────────────────
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length > 200:
            self._send_json(400, {"error": "Request body too large"})
            return

        body_raw = self.rfile.read(content_length).decode(errors="replace")

        # Support both form-encoded and JSON body
        packet_count = DEFAULT_PACKET_COUNT
        try:
            if self.headers.get("Content-Type", "").startswith("application/json"):
                data = json.loads(body_raw) if body_raw else {}
                raw_count = str(data.get("count", DEFAULT_PACKET_COUNT))
            else:
                params = parse_qs(body_raw)
                raw_count = params.get("count", [str(DEFAULT_PACKET_COUNT)])[0]
            packet_count = validate_packet_count(raw_count)
        except (ValueError, json.JSONDecodeError) as e:
            self._send_json(400, {"error": f"Invalid parameters: {e}"})
            return

        # ── Run mtr ───────────────────────────────────────────────────────
        result = run_mtr(target_ip, packet_count)
        code = 200 if result["success"] else 500
        result["target"] = target_ip
        result["count"] = packet_count
        self._send_json(code, result)


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="MTR diagnostics backend")
    parser.add_argument("--port", type=int, default=18080, help="Listen port (127.0.0.1 only)")
    args = parser.parse_args()

    if not (1024 <= args.port <= 65535):
        sys.exit("Port must be between 1024 and 65535")

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    log.info("MTR backend listening on 127.0.0.1:%d", args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
