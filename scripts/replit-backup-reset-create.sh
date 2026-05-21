#!/usr/bin/env bash
set -euo pipefail

echo "== Backup Replit working tree =="
git status --short
mkdir -p backups
git diff > backups/replit-before-reset.patch || true
git diff --staged > backups/replit-before-reset-staged.patch || true
git status --short > backups/replit-before-reset-status.txt || true

if [ -s backups/replit-before-reset-status.txt ]; then
  echo "HAS_LOCAL_CHANGES=YES"
else
  echo "HAS_LOCAL_CHANGES=NO"
fi

echo "BACKUP_FILES=backups/replit-before-reset.patch backups/replit-before-reset-staged.patch backups/replit-before-reset-status.txt"

echo "== Sync GitHub main =="
git fetch origin main
git reset --hard origin/main

echo "== Current commit =="
git rev-parse HEAD
git log --oneline -3

echo "== Run one-shot create runner =="
bash scripts/replit-create-flap-token-once.sh
