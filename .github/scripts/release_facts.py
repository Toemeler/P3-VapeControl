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

    owner, name = os.environ["GITHUB_REPOSITORY"].split("/")
    source_url = f"https://{owner.lower()}.github.io/{name}/s.json"

    facts = {
        "version": version,
        "size": size,
        "human_size": f"{round(size / 1024)}K",
        "tag": tag,
        "source_url": source_url,
    }
    with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
        for key, value in facts.items():
            fh.write(f"{key}={value}\n")
    for key, value in facts.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
