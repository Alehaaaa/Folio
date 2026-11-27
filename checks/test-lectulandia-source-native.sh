#!/bin/sh
# Compile production Folio extension runtime against minimal test stubs, then
# run a live read-only public-domain catalogue search without changing the app.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d /tmp/folio-lectulandia-native.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library \
    app/Core/Extensions.swift app/Core/ExtensionBrowser.swift \
    app/Core/EncryptedDNS.swift app/Core/EncryptedDNSWebProxy.swift app/Core/WebText.swift \
    checks/test-lectulandia-source-native.swift \
    -o "$scratch/test-lectulandia-native"
"$scratch/test-lectulandia-native" "$PWD/extensions/lectulandia.js"
