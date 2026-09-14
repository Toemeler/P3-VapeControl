#!/usr/bin/env python3
"""Refresh the screenshot block in README.md.

The block sits between two HTML comment markers so the rest of the README is
never touched. Images are referenced by relative path rather than a pinned
URL: the README should always show the current screenshots, and GitHub
resolves relative paths against the branch being viewed.

Usage: update_readme.py
"""
import os
import re

START = "<!-- screenshots:start -->"
END = "<!-- screenshots:end -->"
TITLES = {"scan": "Scan", "device": "Device"}
WIDTH = 230


def picture(index, name, width):
    """Pair the light and dark shots so GitHub serves the matching one.

    <picture> with a prefers-color-scheme source is the only way to switch
    images on GitHub - release notes and READMEs run no scripts, so a real
    toggle button is not possible.
    """
    light = f"screenshots/{index:02d}-{name}.png"
    dark = f"screenshots/{index:02d}-{name}-dark.png"
    return (
        "<picture>"
        f'<source media="(prefers-color-scheme: dark)" srcset="{dark}">'
        f'<img src="{light}" width="{width}" alt="{name} screen">'
        "</picture>"
    )


def block():
    if not os.path.isdir("screenshots"):
        return ""
    shots = []
    for name in sorted(os.listdir("screenshots")):
        match = re.match(r"(\d+)-([a-z]+)\.png$", name)
        if match:
            shots.append((int(match.group(1)), match.group(2)))
    if not shots:
        return ""

    headers = "".join(
        f'<td align="center"><b>{TITLES.get(tab, tab.title())}</b></td>' for _, tab in shots
    )
    images = "".join(
        f'<td align="center">{picture(index, tab, WIDTH)}</td>'
        for index, tab in shots
    )
    # Inverted pairing: whichever appearance the reader is not already seeing.
    other_images = "".join(
        f'<td align="center">'
        f"<picture>"
        f'<source media="(prefers-color-scheme: dark)" '
        f'srcset="screenshots/{index:02d}-{tab}.png">'
        f'<img src="screenshots/{index:02d}-{tab}-dark.png" '
        f'width="{WIDTH}" alt="{tab} screen, other appearance">'
        f"</picture></td>"
        for index, tab in shots
    )

    return (
        '<div align="center">\n\n'
        f"<table>\n<tr>{headers}</tr>\n<tr>{images}</tr>\n</table>\n\n"
        "</div>\n\n"
        # The <picture> above follows the reader's theme; this keeps the dark
        # shots reachable from a light-themed page too.
        "<details>\n<summary align=\"center\"><b>The other appearance</b></summary>\n\n"
        '<div align="center">\n\n'
        f"<table>\n<tr>{headers}</tr>\n<tr>{other_images}</tr>\n</table>\n\n"
        "</div>\n\n</details>"
    )


def main():
    with open("README.md") as fh:
        readme = fh.read()

    if START not in readme or END not in readme:
        print("::warning::README has no screenshot markers; leaving it alone")
        return

    before = readme.split(START)[0]
    after = readme.split(END, 1)[1]
    updated = f"{before}{START}\n\n{block()}\n\n{END}{after}"

    if updated == readme:
        print("README screenshots unchanged")
        return
    with open("README.md", "w") as fh:
        fh.write(updated)
    print("README screenshots updated")


if __name__ == "__main__":
    main()
