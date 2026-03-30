#!/usr/bin/env bash
# Extract Base mainnet pruned Reth snapshot into base-reth-data.
# Usage: ./extract-base-pruned-snapshot.sh [path-to-archive]
#   If no path given, prints download URL and usage.
# Run from repo root (parent of scripts/). Needs: tar, and for .tar.zst: zstd.

set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$REPO_ROOT/base-reth-data"
ARCHIVE="${1:-}"

if [ -z "$ARCHIVE" ]; then
  echo "Usage: $0 <path-to-snapshot-archive>"
  echo ""
  echo "Pruned snapshot (mainnet):"
  echo "  wget -c https://mainnet-reth-pruned-snapshots.base.org/\$(curl -sS https://mainnet-reth-pruned-snapshots.base.org/latest)"
  echo ""
  echo "Then run: $0 ./<downloaded-filename.tar.zst>"
  exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "Error: archive not found: $ARCHIVE"
  exit 1
fi

mkdir -p "$DATA_DIR"
cd "$REPO_ROOT"

case "$ARCHIVE" in
  *.tar.zst)
    echo "Extracting .tar.zst (requires zstd)..."
    tar -I zstd -xvf "$ARCHIVE"
    ;;
  *.tar.gz|*.tgz)
    echo "Extracting .tar.gz..."
    tar -xzvf "$ARCHIVE"
    ;;
  *)
    echo "Error: unknown format. Use .tar.zst or .tar.gz"
    exit 1
    ;;
esac

# Snapshot archives usually extract to a single dir (e.g. reth/). Move its contents into base-reth-data.
MOVED=
for dir in reth base reth-data; do
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "Moving $dir/* into base-reth-data/ ..."
    shopt -s dotglob 2>/dev/null || true
    mv "$dir"/* "$DATA_DIR/" 2>/dev/null || true
    rmdir "$dir" 2>/dev/null || true
    MOVED=1
    break
  fi
done

# If no subdir, archive may have extracted chaindata/nodes/segments into current dir
if [ -z "$MOVED" ] && [ -d "chaindata" ] && [ ! -d "$DATA_DIR/chaindata" ]; then
  echo "Moving chain data into base-reth-data/ ..."
  for x in chaindata nodes segments static_files; do
    [ -e "$x" ] && mv "$x" "$DATA_DIR/"
  done
fi

echo "Done. Contents of base-reth-data:"
ls -la "$DATA_DIR"
echo ""
echo "Start L2 stack (and monitoring):"
echo "  docker compose up -d"
echo "Or only base-reth + rollup-client (L1 must already be up):"
echo "  docker compose up -d base-reth rollup-client"
