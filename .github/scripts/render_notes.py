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
  SHORTCUT_URL              optional override; defaults to the committed file
"""
import os
import re
import sys

TAB_TITLES = {
    "scan": "Scan",
    "device": "Device",
    # The log console is compiled out of release builds, so say so where it shows.
    "log": "Log<br><sub>debug build only</sub>",
}

# The Shortcut that refreshes sideloaded apps before their 7-day signature
# expires. It is committed to the repo rather than only linked, so it keeps
# working if the iCloud share link is revoked.
SHORTCUT_PATH = "shortcut/RefreshApps.shortcut"
THUMB_WIDTH = 230

SHORTCUT_SECTION = """
**8.** Open [**RefreshApps.shortcut**]({url}) on the device to add it, then let
it run daily via *Shortcuts → Automation*. It calls SideStore's refresh before
the 7 days run out, so the app does not stop working.
"""


def parse(filename):
    """01-scan-light.png -> (1, 'scan', 'light')"""
    match = re.match(r"(\d+)-([a-z]+)-(light|dark)\.png$", filename)
    if not match:
        return None
    return int(match.group(1)), match.group(2), match.group(3)


def gallery(base_url, shots_dir):
    if not os.path.isdir(shots_dir):
        return "_No screenshots for this build._"

    shots = sorted(filter(None, (parse(f) for f in os.listdir(shots_dir))))
    if not shots:
        return "_No screenshots for this build._"

    def table(appearance):
        row = [s for s in shots if s[2] == appearance]
        if not row:
            return ""
        headers = "".join(
            f"<td align=\"center\"><b>{TAB_TITLES.get(tab, tab.title())}</b></td>"
            for _, tab, _ in row
        )
        images = "".join(
            f'<td align="center">'
            f'<img src="{base_url}/{index:02d}-{tab}-{appearance}.png" '
            f'width="{THUMB_WIDTH}" alt="{tab} screen"></td>'
            for index, tab, _ in row
        )
        return f"<table>\n<tr>{headers}</tr>\n<tr>{images}</tr>\n</table>"

    light = table("light")
    dark = table("dark")

    parts = ['<div align="center">', "", light, "", "</div>"]
    if dark:
        parts += [
            "",
            "<details>",
            "<summary align=\"center\"><b>Dark mode</b></summary>",
            "",
            '<div align="center">',
            "",
            dark,
            "",
            "</div>",
            "",
            "</details>",
        ]
    return "\n".join(parts)


def main(out_path):
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("SCREENSHOT_SHA") or "main"
    base = f"https://raw.githubusercontent.com/{repo}/{sha}"
    shortcut_url = os.environ.get("SHORTCUT_URL", "").strip() or f"{base}/{SHORTCUT_PATH}"

    with open(os.path.join(".github", "release-notes-template.md")) as fh:
        template = fh.read()

    notes = template.format(
        version=os.environ["VERSION"],
        size=os.environ.get("IPA_SIZE", ""),
        source_url=os.environ["SOURCE_URL"],
        icon_url=f"{base}/icon.png",
        gallery=gallery(f"{base}/screenshots", "screenshots"),
        # Omitted rather than left as a dead placeholder when there is no link.
        shortcut_section=SHORTCUT_SECTION.format(url=shortcut_url) if shortcut_url else "",
    )
    with open(out_path, "w") as fh:
        fh.write(notes)
    print(notes)


if __name__ == "__main__":
    main(sys.argv[1])
