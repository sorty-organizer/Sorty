#!/usr/bin/env python3
"""Generate deterministic Markdown and HTML release notes for Sparkle."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
from pathlib import Path


REQUIRED_SECTIONS = ("New", "Improved", "Fixed")


def git_lines(args: list[str]) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def commit_sections(from_tag: str, fallback_count: int) -> dict[str, list[str]]:
    range_spec = f"{from_tag}..HEAD" if from_tag else f"HEAD~{fallback_count}..HEAD"
    subjects = git_lines(["log", range_spec, "--pretty=format:%s", "--no-merges"])
    sections: dict[str, list[str]] = {heading: [] for heading in REQUIRED_SECTIONS}
    for subject in subjects:
        lower = subject.lower()
        cleaned = re.sub(
            r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore)(\(.+\))?:\s*",
            "",
            subject,
            flags=re.IGNORECASE,
        )
        if lower.startswith(("feat", "add", "introduce")):
            sections["New"].append(cleaned)
        elif lower.startswith(("fix", "repair", "restore")):
            sections["Fixed"].append(cleaned)
        else:
            sections["Improved"].append(cleaned)

    for heading in REQUIRED_SECTIONS:
        if not sections[heading]:
            sections[heading].append(f"No {heading.lower()} items in this build.")
    return sections


def changelog_sections(path: Path, version: str) -> dict[str, list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    start_pattern = re.compile(rf"^## \[{re.escape(version)}\](?:\s+-\s+.+)?$")
    start = next((index for index, line in enumerate(lines) if start_pattern.match(line)), None)
    if start is None:
        raise SystemExit(f"CHANGELOG entry for {version} was not found in {path}.")

    sections: dict[str, list[str]] = {heading: [] for heading in REQUIRED_SECTIONS}
    current: str | None = None
    for line in lines[start + 1 :]:
        if line.startswith("## ["):
            break
        if line.startswith("### "):
            heading = line.removeprefix("### ").strip()
            current = heading if heading in sections else None
            continue
        if current and line.startswith("- "):
            sections[current].append(line.removeprefix("- ").strip())

    missing = [heading for heading, items in sections.items() if not items]
    if missing:
        raise SystemExit(
            f"CHANGELOG {version} must contain non-empty sections in this order: "
            + ", ".join(REQUIRED_SECTIONS)
            + f". Missing: {', '.join(missing)}."
        )

    encountered = [
        line.removeprefix("### ").strip()
        for line in lines[start + 1 :]
        if line.startswith("### ")
    ]
    if encountered[: len(REQUIRED_SECTIONS)] != list(REQUIRED_SECTIONS):
        raise SystemExit(
            f"CHANGELOG {version} section order must be: "
            + " -> ".join(REQUIRED_SECTIONS)
        )
    return sections


def markdown_document(title: str, summary: str, sections: dict[str, list[str]]) -> str:
    lines = [f"## {title}", "", summary, ""]
    for heading in REQUIRED_SECTIONS:
        lines.append(f"### {heading}")
        lines.extend(f"- {item}" for item in sections[heading])
        lines.append("")
    return "\n".join(lines)


def inline_html(markdown_text: str) -> str:
    escaped = html.escape(markdown_text)
    escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", escaped)


def performance_chart(version: str) -> str:
    path = Path(f"docs/release-metrics/{version}.json")
    if not path.exists():
        return ""

    data = json.loads(path.read_text(encoding="utf-8"))
    rows = []
    for metric in data["metrics"]:
        before = metric["before"]
        after = metric["after"]
        width = max(0, min(100, after / before * 100))
        color = metric["color"] if metric["color"] in ("blue", "green") else "blue"
        name = html.escape(metric["name"])
        unit = html.escape(metric["unit"])
        suffix = f" {unit}" if unit != "%" else unit
        improvement = html.escape(metric["improvement"])
        rows.append(f"""<div class="metric {color}">
          <div class="metric-heading"><strong>{name}</strong><strong>{improvement}</strong></div>
          <div class="bar-row"><span>1.2.0</span><div class="track"><div class="bar before"></div></div><span>{before:,g}{suffix}</span></div>
          <div class="bar-row"><span>Preview</span><div class="track"><div class="bar after" style="width: {width:.1f}%"></div></div><span>{after:,g}{suffix}</span></div>
        </div>""")
    method = html.escape(data["method"])
    source = html.escape(data["source"], quote=True)
    return f"""<section class="performance" aria-label="Pre-release performance comparison">
      <h2>Measured against 1.2.0</h2>
      {''.join(rows)}
      <p>{method} <a href="{source}">Method and results</a></p>
    </section>"""


def html_document(
    title: str,
    summary: str,
    release_tag: str,
    sections: dict[str, list[str]],
    version: str,
) -> str:
    repository = os.environ.get("GITHUB_REPOSITORY", "sorty-organizer/Sorty")
    release_url = f"https://github.com/{repository}/releases/tag/{release_tag}"
    rendered_sections = []
    chart = performance_chart(version)
    for heading in REQUIRED_SECTIONS:
        items = "".join(f"<li>{inline_html(item)}</li>" for item in sections[heading])
        rendered_sections.append(f"<section><h2>{heading}</h2><ul>{items}</ul></section>")

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{ color-scheme: light dark; }}
    body {{ margin: 0; padding: 28px; font: -apple-system-body; color: CanvasText; background: Canvas; }}
    main {{ max-width: 720px; margin: 0 auto; }}
    h1 {{ margin: 0 0 8px; font: -apple-system-title1; }}
    h2 {{ margin: 28px 0 10px; font: -apple-system-headline; }}
    p {{ line-height: 1.5; }}
    ul {{ margin: 0; padding-left: 22px; }}
    li {{ margin: 9px 0; line-height: 1.45; }}
    .summary {{ color: color-mix(in srgb, CanvasText 78%, transparent); }}
    .callout {{ margin: 22px 0 8px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 14px; padding: 14px 16px; background: color-mix(in srgb, CanvasText 7%, Canvas); }}
    code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }}
    a {{ color: LinkText; }}
    .performance {{ margin: 24px 0; padding: 18px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 16px; background: color-mix(in srgb, CanvasText 5%, Canvas); }}
    .performance h2 {{ margin: 0 0 20px; font-size: 1em; }}
    .performance p {{ margin: 18px 0 0; font-size: 0.85em; }}
    .metric + .metric {{ margin-top: 20px; }}
    .metric-heading, .bar-row {{ display: flex; align-items: center; justify-content: space-between; gap: 10px; }}
    .metric-heading {{ margin-bottom: 10px; }}
    .metric-heading strong:last-child {{ color: #3997e8; }}
    .green .metric-heading strong:last-child {{ color: #238f6a; }}
    .bar-row {{ margin-top: 8px; font-size: 0.85em; font-variant-numeric: tabular-nums; }}
    .bar-row span:first-child {{ width: 55px; color: color-mix(in srgb, CanvasText 70%, transparent); }}
    .bar-row span:last-child {{ width: 72px; text-align: right; }}
    .track {{ flex: 1; height: 10px; border-radius: 10px; background: color-mix(in srgb, CanvasText 12%, Canvas); }}
    .bar {{ height: 100%; border-radius: 10px; }}
    .before {{ width: 100%; background: #8794a8; }}
    .blue .after {{ background: #3997e8; }}
    .green .after {{ background: #29a77a; min-width: 2px; }}
  </style>
</head>
<body>
  <main>
    <h1>{html.escape(title)}</h1>
    <p class="summary">{html.escape(summary)}</p>
    <div class="callout"><strong>Update:</strong> Install this release in Sorty with <strong>Check for Updates</strong>, or download <code>Sorty.zip</code> for a new installation.</div>
    {chart}
    {''.join(rendered_sections)}
    <p><a href="{html.escape(release_url)}">View this release on GitHub</a></p>
  </main>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="")
    parser.add_argument("--title", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--changelog", default="CHANGELOG.md")
    parser.add_argument("--from-tag", default="")
    parser.add_argument("--fallback-count", type=int, default=25)
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--html", required=True)
    args = parser.parse_args()

    if args.version:
        sections = changelog_sections(Path(args.changelog), args.version)
        release_tag = f"v{args.version}"
    else:
        sections = commit_sections(args.from_tag, args.fallback_count)
        release_tag = "nightly"
    Path(args.markdown).write_text(
        markdown_document(args.title, args.summary, sections),
        encoding="utf-8",
    )
    Path(args.html).write_text(
        html_document(args.title, args.summary, release_tag, sections, args.version),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
