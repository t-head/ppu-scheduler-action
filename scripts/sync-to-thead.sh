#!/usr/bin/env bash
# Sync ppu-distributed-action to t-head/ppu-scheduler-action
# Usage: ./scripts/sync-to-thead.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

REMOTE_NAME="thead"
REMOTE_URL="https://github.com/t-head/ppu-scheduler-action.git"

# Ensure remote exists
if ! git remote get-url "$REMOTE_NAME" &>/dev/null; then
    echo "Adding remote '$REMOTE_NAME' -> $REMOTE_URL"
    git remote add "$REMOTE_NAME" "$REMOTE_URL"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Pushing branch '$BRANCH' to $REMOTE_NAME..."
git push "$REMOTE_NAME" "$BRANCH"

echo "Pushing tags to $REMOTE_NAME..."
git push "$REMOTE_NAME" --tags

echo "Sync complete."
