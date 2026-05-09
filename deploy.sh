#!/usr/bin/env bash
# Deploy EdgeField to norns
# Usage:
#   ./deploy.sh        — sync everything (code + audio + data)
#   ./deploy.sh code   — sync code only (fast, skips audio)

NORNS="we@192.168.0.215"
SRC="/mnt/g/Documents/GitHub/edgefield/.claude/worktrees/cool-jackson-54502c/dust/"
DEST="$NORNS:/home/we/dust/"

if [ "$1" = "code" ]; then
  echo "Deploying code only..."
  rsync -avz --progress \
    --include="code/***" \
    --include="data/***" \
    --exclude="audio/**" \
    --exclude="*" \
    "$SRC" "$DEST"
else
  echo "Deploying everything..."
  rsync -avz --progress "$SRC" "$DEST"
fi

echo "Done."
