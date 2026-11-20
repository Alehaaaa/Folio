#!/usr/bin/env python3
"""Read-only DNS/TLS/HTTPS probes for Folio iOS Anna source failures.

Only resolves hostnames and sends TLS handshakes and HTTP HEAD to site roots.
No book searches, download URLs, credentials, cookies or user files are used.
Does not change the host's DNS, VPN, certificates or application settings.
"""

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
HOSTS = (
    "annas-archive.gl",
    "annas-archive.gd",
    "annas-archive.pk",
    "www.gutenberg.org",
    "www.apple.com",
    "raw.githubusercontent.com",
)


def run(command, timeout=9):
    try:
        result = subprocess.run(
            command, capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=timeout, check=False,
        )
        return {"exit": result.returncode,
                "stdout": result.stdout[-1800:].strip(),
                "stderr": result.stderr[-1200:].strip()}
    except subprocess.TimeoutExpired:
        return {"exit": "timeout", "stdout": "", "stderr": f"probe exceeded {timeout} s"}
    except OSError as exc:
        return {"exit": "cannot_run", "stdout": "", "stderr": str(exc)}


def simctl_path(kind):
    result = run(["xcrun", "simctl", "get_app_container", "booted", "app.folio.reader.ios", kind], 5)
    if result["exit"] == 0:
        return Path(result["stdout"])
    return None


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path and path.is_file() else None


def probe(host, kind):
    if kind == "system_dns":
        return run(["dscacheutil", "-q", "host", "-a", "name", host], 7)
    if kind == "public_dns":
        return run(["dig", "+time=2", "+tries=1", "+short", "@1.1.1.1", host, "A"], 6)
    if kind in ("curl_default", "curl_ipv4", "curl_ipv6"):
        command = [
            "curl", "--silent", "--show-error", "--head", "--connect-timeout", "4",
            "--max-time", "8", "--output", "/dev/null",
            "--write-out", "http=%{http_code}; remote_ip=%{remote_ip}; ssl_verify=%{ssl_verify_result}; connect_s=%{time_connect}; tls_s=%{time_appconnect}",
        ]
        if kind == "curl_ipv4":
            command.append("--ipv4")
        elif kind == "curl_ipv6":
            command.append("--ipv6")
        command.append(f"https://{host}/")
        return run(command, 10)
    if kind == "openssl_tls":
        return run([
            "openssl", "s_client", "-brief", "-verify_return_error",
            "-servername", host, "-connect", f"{host}:443",
        ], 8)
    raise ValueError(kind)


def main():
    started = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"Folio read-only network diagnostics, captured {started}", flush=True)
    print("Method: DNS queries, certificate handshakes, HTTP HEAD / only (no book requests)", flush=True)
    source = ROOT / "extensions/annas-archive.js"
    built = ROOT / "app/iOS/.build/Build/Products/Debug-iphonesimulator/Folio.app/annas-archive.js"
    app = simctl_path("app")
    data = simctl_path("data")
    installed = app / "annas-archive.js" if app else None
    runtime = data / "Library/Application Support/Folio/Extensions/annas-archive-free.js" if data else None
    for label, path in (("repo JS", source), ("debug bundle JS", built),
                        ("simulator app JS", installed), ("simulator runtime JS", runtime)):
        print(f"{label}: {sha256(path) or 'unavailable'}", flush=True)

    kinds = ("system_dns", "public_dns", "curl_default", "curl_ipv4", "curl_ipv6", "openssl_tls")
    jobs = [(h, kind) for h in HOSTS for kind in kinds]
    results = {}
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(probe, host, kind): (host, kind) for host, kind in jobs}
        for future in as_completed(futures):
            host, kind = futures[future]
            try:
                results[(host, kind)] = future.result()
            except Exception as exc:
                results[(host, kind)] = {"exit": "exception", "stdout": "", "stderr": str(exc)}
    for host in HOSTS:
        print(f"\n[{host}]", flush=True)
        for kind in kinds:
            result = results[(host, kind)]
            output = (result["stdout"] + " " + result["stderr"]).strip().replace("\n", " | ")
            print(f"  {kind}: exit={result['exit']} {output[:550]}", flush=True)
    print("\nReminder: simulator inherits host routing; a physical iPhone can use different DNS, VPN and carrier paths.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
