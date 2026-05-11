#!/usr/bin/env bash
# Deploy EdgeField to norns (edgefield directories only)
# Usage:
#   ./deploy.sh        — sync everything (code + audio + data)
#   ./deploy.sh code   — sync code only (fast, skips audio)

NORNS="we@192.168.0.215"
NORNS2="we@192.168.0.49"

BASE="/mnt/g/Documents/GitHub/edgefield/dust"
DEST_BASE="$NORNS:/home/we/dust"

if [ "$1" = "code" ]; then
  echo "Deploying code + data..."
  rsync -avz --progress "$BASE/code/edgefield/"  "$DEST_BASE/code/edgefield/"
  rsync -avz --progress "$BASE/data/edgefield/"  "$DEST_BASE/data/edgefield/"
else
  echo "Deploying everything..."
  rsync -avz --progress "$BASE/code/edgefield/"  "$DEST_BASE/code/edgefield/"
  rsync -avz --progress "$BASE/data/edgefield/"  "$DEST_BASE/data/edgefield/"
  rsync -avz --progress "$BASE/audio/edgefield/" "$DEST_BASE/audio/edgefield/"
fi

echo "Done."
