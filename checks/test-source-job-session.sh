#!/bin/sh
# Compile the actual shared Folio extension layer against safe, temporary
# fixture models. This is NOT a full app build and does not access the user's
# installed library, WebKit browser, or network.
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d /tmp/folio-job-session-check.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library \
    app/Core/Extensions.swift app/Core/ExtensionBrowser.swift \
    app/Core/EncryptedDNS.swift app/Core/EncryptedDNSWebProxy.swift app/Core/WebText.swift \
    checks/test-source-job-session.swift \
    -o "$tmp/test-source-job-session"
"$tmp/test-source-job-session"
