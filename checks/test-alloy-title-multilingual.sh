#!/bin/zsh
# Metadata-only translated-title queue regression. No real source or EPUB download.
set -euo pipefail
here="${0:A:h}"
cd "$here/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-alloy-title.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/data"
swiftc -swift-version 5 -parse-as-library app/Sources/Folio/DownloadQueue.swift checks/test-alloy-title-multilingual.swift -o "$scratch/alloy"
FOLIO_DATA_DIR="$scratch/data" "$scratch/alloy"
FOLIO_DATA_DIR="$scratch/data-sparse" "$scratch/alloy" --sparse-metadata
