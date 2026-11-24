#!/bin/zsh
# Expected RED until sparse Open Library fallback uses canonical work editions.json.
# Compiles real DownloadQueue.swift and intercepts all Open Library HTTP requests.
set -euo pipefail
here="${0:A:h}"
cd "$here/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-language-sparse.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/data"
swiftc -swift-version 5 -parse-as-library app/Sources/Folio/DownloadQueue.swift checks/test-language-sparse-queue.swift -o "$scratch/sparse"
FOLIO_DATA_DIR="$scratch/data" "$scratch/sparse" --fixture-contract
FOLIO_DATA_DIR="$scratch/data" "$scratch/sparse"
