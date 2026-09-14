#!/usr/bin/env python3
"""Emit the SideStore/AltStore source feed and a small landing page.

Reads the build facts from the environment so the workflow stays the single
source of truth for version, size and download URL.
"""
import datetime as dt
import json
import os
import sys

DESCRIPTION = (
    "Monitor and control a PAX 3 vaporizer over Bluetooth: battery level, "
    "heating state, live temperature readout and four oven presets "
    "(180/193/204/215 C).\n\n"
    "Independent tool, not affiliated with or endorsed by PAX Labs. "
    "Based on P3-VapeControl by selfmeister."
)


def main(out_dir):
    repo = os.environ["GITHUB_REPOSITORY"]
    owner, name = repo.split("/")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    version = os.environ["VERSION"]
    tag = os.environ["TAG"]
    size = int(os.environ["SIZE"])
    sha256 = os.environ["SHA256"]

    pages_base = f"https://{owner.lower()}.github.io/{name}"
    download_url = f"{server}/{repo}/releases/download/{tag}/PaxController.ipa"
    date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # The simulator workflow commits screenshots; surface them in the listing
    # when they exist so the source shows more than an icon.
    shots = []
    if os.path.isdir("screenshots"):
        for filename in sorted(os.listdir("screenshots")):
            if filename.endswith(".png"):
                shots.append(
                    f"https://raw.githubusercontent.com/{repo}/main/screenshots/{filename}"
                )

    version_entry = {
        "version": version,
        "buildVersion": version.rsplit(".", 1)[-1],
        "date": date,
        "localizedDescription": f"Automated build {tag}.",
        "downloadURL": download_url,
        "size": size,
        "sha256": sha256,
        "minOSVersion": "16.0",
    }

    app = {
        "name": "PAX Controller",
        "bundleIdentifier": "de.marcomeissner.PaxController",
        "developerName": owner,
        "subtitle": "Bluetooth control for the PAX 3",
        "localizedDescription": DESCRIPTION,
        "iconURL": f"{pages_base}/icon.png",
        "tintColor": "FF7A1A",
        "category": "utilities",
        "screenshots": shots,
        "versions": [version_entry],
        # Legacy top-level keys, for clients that predate the versions array.
        "version": version,
        "versionDate": date,
        "versionDescription": f"Automated build {tag}.",
        "downloadURL": download_url,
        "size": size,
    }

    source = {
        "name": "P3 VapeControl",
        "identifier": f"io.github.{owner.lower()}.p3vapecontrol",
        "subtitle": "Unsigned builds of PAX Controller",
        "description": "Automated unsigned builds of the P3-VapeControl PAX 3 app.",
        "iconURL": f"{pages_base}/icon.png",
        "website": f"{server}/{repo}",
        "tintColor": "FF7A1A",
        "apps": [app],
        "news": [],
    }

    os.makedirs(out_dir, exist_ok=True)
    payload = json.dumps(source, indent=2)
    # s.json is the short path people type; apps.json is the conventional name.
    for filename in ("s.json", "apps.json"):
        with open(os.path.join(out_dir, filename), "w") as fh:
            fh.write(payload + "\n")

    source_url = f"{pages_base}/s.json"
    with open(os.path.join(out_dir, "index.html"), "w") as fh:
        fh.write(LANDING.format(source_url=source_url, version=version, repo=repo, server=server))

    print(f"source URL: {source_url}")


LANDING = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>P3 VapeControl source</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 34rem;
         margin: 0 auto; padding: 3rem 1.25rem; }}
  code {{ background: rgba(128,128,128,.18); padding: .15em .4em; border-radius: .3em;
          word-break: break-all; }}
  a.btn {{ display: inline-block; background: #FF7A1A; color: #fff; text-decoration: none;
           padding: .7em 1.2em; border-radius: .6em; font-weight: 600; }}
</style>
</head>
<body>
<h1>P3 VapeControl</h1>
<p>SideStore / AltStore source for unsigned PAX Controller builds. Current version
   <strong>{version}</strong>.</p>
<p><a class="btn" href="sidestore://source?url={source_url}">Add to SideStore</a></p>
<p>Or paste this URL into SideStore &rarr; Sources &rarr; +:</p>
<p><code>{source_url}</code></p>
<p><a href="{server}/{repo}">Source code and releases</a></p>
</body>
</html>
"""


if __name__ == "__main__":
    main(sys.argv[1])
