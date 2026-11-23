#!/usr/bin/env python3
"""Verify the hosted extension manifest matches the checked-in scripts."""

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = ROOT / "extensions"
manifest = json.loads((EXTENSIONS / "versions.json").read_text())
entries = {entry["id"]: entry for entry in manifest["extensions"]}

scripts = list(sorted(EXTENSIONS.glob("*.js")))
assert len(entries) == len(scripts), "manifest must list every extension exactly once"
for script in scripts:
    text = script.read_text()
    extension_id = re.search(r'\bid\s*:\s*["\']([A-Za-z0-9_-]+)["\']', text).group(1)
    version = re.search(r'\bversion\s*:\s*["\']([^"\']+)["\']', text).group(1)
    entry = entries[extension_id]
    assert entry["version"] == version, f"{extension_id}: version mismatch"
    assert entry["sha256"] == hashlib.sha256(script.read_bytes()).hexdigest(), \
        f"{extension_id}: SHA-256 mismatch"
    assert entry["url"].endswith("/extensions/" + script.name), \
        f"{extension_id}: URL does not point to {script.name}"

print(f"PASS: versions.json matches {len(scripts)} extension scripts")
