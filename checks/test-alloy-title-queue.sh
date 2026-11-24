#!/bin/zsh
# Metadata-only translated-title queue regression. No real source or EPUB download.
set -euo pipefail
here="${0:A:h}"
cd "$here/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-alloy-title.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/data"
swiftc -swift-version 5 -parse-as-library app/Sources/Folio/DownloadQueue.swift checks/test-alloy-title-queue.swift -o "$scratch/alloy"
for scenario in valid outage unsafe-bilingual compilation-only wrong-bilingual; do
  echo "TEST ALLOY TITLE scenario=$scenario"
  FOLIO_DATA_DIR="$scratch/data-$scenario" "$scratch/alloy" "$scenario"
done
