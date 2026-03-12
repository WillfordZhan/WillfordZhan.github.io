#!/usr/bin/env bash
set -euo pipefail

# 同步 blog skill 镜像副本，约定全局 skill 为唯一主版本，repo 内仅保留可审阅、可归档的镜像文件。

REPO="${BLOG_REPO:-$HOME/Desktop/Project/blog}"
SKILL_NAME="hexo-blog-publish"
GLOBAL_SKILL_PATH="${CODEX_HOME:-$HOME/.codex}/skills/${SKILL_NAME}/SKILL.md"
REPO_SKILL_DIR="${REPO}/skills/${SKILL_NAME}"
REPO_SKILL_PATH="${REPO_SKILL_DIR}/SKILL.md"

usage() {
  cat <<USAGE
Usage: sync_skill.sh [--repo /path/to/blog]

Synchronize the mirrored hexo blog skill from the global Codex skill directory
into the blog repository.

Examples:
  bash bin/sync_skill.sh
  BLOG_REPO=~/Desktop/Project/blog bash bin/sync_skill.sh
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)
      REPO="$2"
      REPO_SKILL_DIR="${REPO}/skills/${SKILL_NAME}"
      REPO_SKILL_PATH="${REPO_SKILL_DIR}/SKILL.md"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$GLOBAL_SKILL_PATH" ]]; then
  echo "Global skill not found: $GLOBAL_SKILL_PATH" >&2
  exit 1
fi

if [[ ! -d "$REPO" ]]; then
  echo "Blog repo not found: $REPO" >&2
  exit 1
fi

# repo 内 skill 目录按需创建，镜像文件始终以全局 skill 为准做覆盖同步。
mkdir -p "$REPO_SKILL_DIR"
cp "$GLOBAL_SKILL_PATH" "$REPO_SKILL_PATH"

echo "Synced skill:"
echo "  from: $GLOBAL_SKILL_PATH"
echo "  to:   $REPO_SKILL_PATH"
