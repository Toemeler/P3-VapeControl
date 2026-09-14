#!/usr/bin/env python3
"""Render the release notes, including an inline screenshot gallery.

The screenshots are embedded in the release body rather than attached as
assets, so the release reads as a preview instead of a file list. Image URLs
are pinned to the commit the screenshots were pushed in, so an old release
keeps showing the screens it actually shipped with.

Usage: render_notes.py <output path>

Environment:
  VERSION, SOURCE_URL       required
  SCREENSHOT_SHA            commit to pin image URLs to (default: main)
  GITHUB_REPOSITORY         owner/name, for building raw URLs
  IPA_SIZE                  human-readable size, shown in the header
"""
import os
import re
import sys

TAB_TITLES = {"scan": "Scan", "device": "Device"}

THUMB_WIDTH = 230


def picture(base_url, index, name, width):
    """Pair the light and dark shots so GitHub serves the matching one.

    <picture> with a prefers-color-scheme source is the only way to switch
    images on GitHub - release notes and READMEs run no scripts, so a real
    toggle button is not possible.
    """
    light = f"{base_url}/{index:02d}-{name}.png"
    dark = f"{base_url}/{index:02d}-{name}-dark.png"
    return (
        "<picture>"
        f'<source media="(prefers-color-scheme: dark)" srcset="{dark}">'
        f'<img src="{light}" width="{width}" alt="{name} screen">'
        "</picture>"
    )


def parse(filename):
    """01-scan.png -> (1, 'scan')"""
    match = re.match(r"(\d+)-([a-z]+)\.png$", filename)
    if not match:
        return None
    return int(match.group(1)), match.group(2)


def gallery(base_url, shots_dir):
    if not os.path.isdir(shots_dir):
        return "_No screenshots for this build._"

    shots = sorted(filter(None, (parse(f) for f in os.listdir(shots_dir))))
    if not shots:
        return "_No screenshots for this build._"

    headers = "".join(
        f'<td align="center"><b>{TAB_TITLES.get(name, name.title())}</b></td>'
        for _, name in shots
    )
    images = "".join(
        f'<td align="center">{picture(base_url, index, name, THUMB_WIDTH)}</td>'
        for index, name in shots
    )
    table = f"<table>\n<tr>{headers}</tr>\n<tr>{images}</tr>\n</table>"

    # The <picture> above follows the reader's theme; this keeps the dark shots
    # reachable from a light-themed page too.
    # Inverted pairing: whichever theme the reader is not already seeing.
    other_images = "".join(
        f'<td align="center">'
        f"<picture>"
        f'<source media="(prefers-color-scheme: dark)" '
        f'srcset="{base_url}/{index:02d}-{name}.png">'
        f'<img src="{base_url}/{index:02d}-{name}-dark.png" '
        f'width="{THUMB_WIDTH}" alt="{name} screen, other theme">'
        f"</picture></td>"
        for index, name in shots
    )
    other_table = f"<table>\n<tr>{headers}</tr>\n<tr>{other_images}</tr>\n</table>"

    return "\n".join([
        '<div align="center">', "", table, "", "</div>", "",
        "<details>",
        "<summary align=\"center\"><b>Light / dark</b></summary>", "",
        '<div align="center">', "", other_table, "", "</div>", "",
        "</details>",
    ])


def main(out_path):
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("SCREENSHOT_SHA") or "main"
    base = f"https://raw.githubusercontent.com/{repo}/{sha}"
    source_url = os.environ["SOURCE_URL"]

    with open(os.path.join(".github", "release-notes-template.md")) as fh:
        template = fh.read()

    # The one-tap button lives on the Pages landing page - GitHub strips the
    # sidestore:// link it wraps, so it cannot go in the notes directly. With
    # Pages off there is no page to link to, and the URL is spelled out instead.
    pages_url = os.environ.get("PAGES_URL", "").strip().rstrip("/")
    if pages_url:
        add_source = f"**[Add to SideStore]({pages_url}/)**"
    else:
        add_source = f"Add this source in SideStore:\n\n`{source_url}`"

    notes = template.format(
        version=os.environ["VERSION"],
        size=os.environ.get("IPA_SIZE", ""),
        source_url=source_url,
        add_source=add_source,
        icon_url=f"{base}/icon.png",
        gallery=gallery(f"{base}/screenshots", "screenshots"),
    )
    with open(out_path, "w") as fh:
        fh.write(notes)
    print(notes)


if __name__ == "__main__":
    main(sys.argv[1])
