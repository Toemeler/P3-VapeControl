#!/usr/bin/env python3
"""Describe the currently published release, read back from the source feed.

Used when a run skips the build: s.json already records the version, the IPA
size and the tag the assets hang off, so the release notes can be re-rendered
without rebuilding anything.

Writes version, size, human_size, tag and source_url to GITHUB_OUTPUT.
"""
import json
import os


def main():
    with open("s.json") as fh:
        feed = json.load(fh)
    app = feed["apps"][0]

    version = app["version"]
    size = int(app["size"])
    tag = app["downloadURL"].split("/download/", 1)[1].split("/", 1)[0]

    # Same rule as make_source.py: the short URL is only advertised once Pages
    # is serving it, otherwise the raw one, which needs nothing switched on.
    repo = os.environ["GITHUB_REPOSITORY"]
    branch = os.environ.get("DEFAULT_BRANCH") or "main"
    pages_site = os.environ.get("PAGES_URL", "").strip().rstrip("/")
    source_url = (
        f"{pages_site}/s.json"
        if pages_site
        else f"https://raw.githubusercontent.com/{repo}/{branch}/s.json"
    )

    facts = {
        "version": version,
        "size": size,
        "human_size": f"{round(size / 1024)}K",
        "tag": tag,
        "source_url": source_url,
        "pages_url": pages_site,
    }
    with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
        for key, value in facts.items():
            fh.write(f"{key}={value}\n")
    for key, value in facts.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
