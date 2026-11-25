#!/usr/bin/env python3
"""Encrypted DNS covers every download path.

Folio's encrypted DNS is set on the app's own network privacy context, so it
applies to every URLSession and Network connection made inside the app. It
does not reach work handed to another process: background URLSessions (run by
nsurlsessiond) and WebKit pages (resolved by WebKit's networking process).
This check fails when such a path appears in the download code without being
routed through FolioEncryptedDNSWebProxy.
"""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "app"
sources = [p for p in root.rglob("*.swift") if "/checks/" not in str(p) and ".build" not in p.parts]
fails = []
for path in sources:
    text = path.read_text(encoding="utf-8", errors="ignore")
    rel = path.relative_to(root)
    if re.search(r"URLSessionConfiguration\.background|\.background\(withIdentifier", text):
        fails.append(f"{rel}: background URLSession runs outside Folio and skips encrypted DNS")

browser = (root / "Sources/Folio/ExtensionBrowser.swift").read_text()
if "FolioEncryptedDNSWebProxy.shared.proxyConfigurations()" not in browser:
    fails.append("ExtensionBrowser.swift: source pages no longer go through the encrypted DNS proxy")

downloads = (root / "Sources/Folio/Extensions.swift").read_text()
if "e.runtime.session.download(" not in downloads:
    fails.append("Extensions.swift: file downloads no longer use the extension's in-app URLSession")

if fails:
    print("\n".join("FAIL " + f for f in fails)); sys.exit(1)
print(f"PASS encrypted DNS: {len(sources)} Swift files, no out-of-process downloads; "
      "source pages use the DNS proxy; files download in-app")
