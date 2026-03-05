#!/usr/bin/env bash
# Download and extract Base mainnet pruned Reth snapshot into base-reth-data.
# Run once from the project root (same dir as docker-compose.yml) before first
# "docker compose up -d" for base-reth. Requires: curl, wget, tar, zstd (for .tar.zst).
set -e

DATA_DIR="${1:-base-reth-data}"
mkdir -p "$DATA_DIR"

echo "Fetching latest snapshot filename..."
SNAPSHOT_URL="https://mainnet-reth-pruned-snapshots.base.org"
LATEST=$(curl -sSf "$SNAPSHOT_URL/latest" | tr -d '\n\r')
echo "Latest: $LATEST"

ARCHIVE="$LATEST"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading (resumable with wget -c)..."
  wget -c "$SNAPSHOT_URL/$LATEST"
else
  echo "Using existing file: $ARCHIVE"
fi

echo "Extracting..."
if [[ "$ARCHIVE" == *.tar.zst ]]; then
  tar -I zstd -xvf "$ARCHIVE"
elif [[ "$ARCHIVE" == *.tar.gz ]]; then
  tar -xzvf "$ARCHIVE"
else
  echo "Unknown archive format: $ARCHIVE" >&2
  exit 1
fi

# Move contents into data dir (extract often creates a single folder, e.g. reth/)
for dir in reth mainnet base chaindata 2>/dev/null; do
  if [[ -d "$dir" ]] && [[ ! -d "$DATA_DIR/chaindata" ]]; then
    echo "Moving $dir/* into $DATA_DIR/"
    mv "$dir"/* "$DATA_DIR/"
    rmdir "$dir" 2>/dev/null || true
    break
  fi
done
# If archive extracted flat (chaindata at top level), move only if target empty
if [[ -d "chaindata" ]] && [[ ! -d "$DATA_DIR/chaindata" ]]; then
  mv chaindata nodes segments 2>/dev/null "$DATA_DIR/" || true
fi

echo "Done. Snapshot data is in $DATA_DIR/. You can start with: docker compose up -d"
echo "Optional: remove the archive to free space: rm -f $ARCHIVE"
