#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import os
import re
from pathlib import Path


def slugify_filename(title: str) -> str:
    # ASCII-ish, safe for git and shells
    s = title.strip().lower()
    s = re.sub(r"\s+", "-", s)
    s = re.sub(r"[^a-z0-9._-]", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s or "post"


def parse_tags(tags: str | None) -> list[str]:
    if not tags:
        return []
    parts = re.split(r"[,，]\s*", tags.strip())
    return [p for p in (x.strip() for x in parts) if p]


def append_unique(items: list[str], value: str) -> list[str]:
    if value not in items:
        items.append(value)
    return items


def yaml_quote(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


@dataclass
class Post:
    title: str
    date: str
    categories: list[str]
    tags: list[str]
    permalink: str | None


def main() -> int:
    ap = argparse.ArgumentParser(description="Create a Hexo post under source/_posts")
    ap.add_argument("--repo", default=os.path.expanduser("~/Desktop/Project/blog"))
    ap.add_argument("--title", required=True)
    ap.add_argument("--categories", default="")
    ap.add_argument("--tags", default="")
    ap.add_argument("--ai-log", action="store_true", help="Auto classify post into AI tab")
    ap.add_argument("--permalink", default="")
    ap.add_argument("--filename", default="")
    args = ap.parse_args()

    repo = Path(args.repo).expanduser().resolve()
    posts_dir = repo / "source" / "_posts"
    posts_dir.mkdir(parents=True, exist_ok=True)

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    categories = parse_tags(args.categories)
    tags = parse_tags(args.tags)
    if args.ai_log:
        append_unique(categories, "AI")
        append_unique(tags, "AI工作日志")

    post = Post(
        title=args.title.strip(),
        date=now,
        categories=categories,
        tags=tags,
        permalink=(args.permalink.strip() or None),
    )

    filename = args.filename.strip() or f"{slugify_filename(post.title)}.md"
    if not filename.endswith(".md"):
        filename += ".md"

    out = posts_dir / filename
    if out.exists():
        raise SystemExit(f"Refusing to overwrite existing file: {out}")

    fm: list[str] = [
        "---",
        f"title: {yaml_quote(post.title)}",
        f"date: {post.date}",
    ]
    if post.permalink:
        fm.append(f"permalink: {post.permalink}")
    if post.categories:
        fm.append("categories:")
        for c in post.categories:
            fm.append(f"  - {yaml_quote(c)}")
    if post.tags:
        fm.append("tags:")
        for t in post.tags:
            fm.append(f"  - {yaml_quote(t)}")
    fm.append("---")

    body = "\n\n".join(
        [
            "## TODO",
            "\n".join(
                [
                    "- 写正文",
                    "- 本地预览：`npm run server`",
                    "- 发布：`bash scripts/publish.sh -m \"post: ...\"`",
                ]
            ),
        ]
    )

    out.write_text("\n".join(fm) + "\n\n" + body + "\n", encoding="utf-8")
    print(str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
