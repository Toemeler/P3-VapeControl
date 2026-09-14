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


def block():
    if not os.path.isdir("screenshots"):
        return ""
    shots = []
    for name in sorted(os.listdir("screenshots")):
        match = re.match(r"(\d+)-([a-z]+)\.png$", name)
        if match:
            shots.append((name, match.group(2)))
    if not shots:
        return ""

    headers = "".join(
        f'<td align="center"><b>{TITLES.get(tab, tab.title())}</b></td>' for _, tab in shots
    )
    images = "".join(
        f'<td align="center"><img src="screenshots/{name}" width="{WIDTH}" alt="{tab} screen"></td>'
        for name, tab in shots
    )
    return (
        '<div align="center">\n\n'
        f"<table>\n<tr>{headers}</tr>\n<tr>{images}</tr>\n</table>\n\n"
        "</div>"
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
