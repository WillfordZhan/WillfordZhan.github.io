#!/usr/bin/env bash
set -euo pipefail

REPO="${BLOG_REPO:-$HOME/Desktop/Project/blog}"
MSG=""
SKIP_BUILD=0

usage() {
  cat <<USAGE
Usage: publish.sh [-r repo_path] [-m message] [--skip-build]

Publishes Hexo source to origin/hexo-src, triggering GitHub Actions deploy to master.

Examples:
  bash scripts/publish.sh -m "post: add new article"
  BLOG_REPO=~/Desktop/Project/blog bash scripts/publish.sh -m "chore: update"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo) REPO="$2"; shift 2;;
    -m|--message) MSG="$2"; shift 2;;
    --skip-build) SKIP_BUILD=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

cd "$REPO"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repo: $REPO" >&2
  exit 1
fi

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$branch" != "hexo-src" ]]; then
  git checkout hexo-src
fi

# Basic sanity
if ! test -f _config.yml; then
  echo "Missing _config.yml; this doesn't look like the Hexo source branch." >&2
  exit 1
fi

# Install + build
if [[ $SKIP_BUILD -eq 0 ]]; then
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build
fi

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit."
  exit 0
fi

git add -A

if [[ -z "$MSG" ]]; then
  # Default message
  MSG="chore: publish $(date +%Y-%m-%d)"
fi

git commit -m "$MSG" || {
  echo "Commit failed (maybe nothing staged)." >&2
  exit 1
}

git push origin hexo-src

echo "Pushed to hexo-src. Check GitHub Actions for deploy status."
