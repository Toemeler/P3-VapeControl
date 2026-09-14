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
    "Independent tool, not affiliated with or endorsed by PAX Labs."
)


def main(out_dir):
    repo = os.environ["GITHUB_REPOSITORY"]
    owner, name = repo.split("/")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    version = os.environ["VERSION"]
    tag = os.environ["TAG"]
    size = int(os.environ["SIZE"])
    sha256 = os.environ["SHA256"]

    # Pages serves the default branch, and that is where the workflow commits
    # the feed and the screenshots, so every asset URL hangs off it.
    branch = os.environ.get("DEFAULT_BRANCH") or "main"
    # PAGES_URL is set by the workflow only when Pages is actually serving.
    # Without it the short URL would 404, so the raw one becomes the feed URL.
    pages_site = os.environ.get("PAGES_URL", "").strip().rstrip("/")
    pages_base = pages_site or f"https://{owner.lower()}.github.io/{name}"
    raw_base = f"https://raw.githubusercontent.com/{repo}/{branch}"
    # Assets are referenced over raw.githubusercontent.com so the feed works
    # before GitHub Pages is switched on for the repository.
    icon_url = f"{raw_base}/icon.png"
    download_url = f"{server}/{repo}/releases/download/{tag}/PaxController.ipa"
    date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # The simulator workflow commits screenshots; surface them in the listing
    # when they exist so the source shows more than an icon.
    shots = []
    if os.path.isdir("screenshots"):
        for filename in sorted(os.listdir("screenshots")):
            if filename.endswith(".png"):
                shots.append(f"{raw_base}/screenshots/{filename}")

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
        "iconURL": icon_url,
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
        "subtitle": "Bluetooth control for the PAX 3",
        # Shown as "About" in SideStore, so it describes the app rather than
        # how the builds are produced.
        "description": DESCRIPTION,
        "iconURL": icon_url,
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

    raw_url = f"{raw_base}/s.json"
    source_url = f"{pages_base}/s.json" if pages_site else raw_url
    with open(os.path.join(out_dir, "index.html"), "w") as fh:
        fh.write(
            LANDING.format(
                source_url=f"{pages_base}/s.json",
                raw_url=raw_url,
                version=version,
                repo=repo,
                server=server,
            )
        )

    print(f"source URL: {source_url}")
    print(f"raw URL:    {raw_url}")
    print("Pages: " + (pages_site or "not enabled - the notes use the raw URL"))

    # Single source of truth for the URL: the release notes read it back here
    # instead of rebuilding it from the repository name a second time.
    step_output = os.environ.get("GITHUB_OUTPUT")
    if step_output:
        with open(step_output, "a") as fh:
            fh.write(f"source_url={source_url}\n")
            fh.write(f"raw_url={raw_url}\n")
            fh.write(f"pages_url={pages_site}\n")


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
<p>Works without GitHub Pages too:</p>
<p><code>{raw_url}</code></p>
<p><a href="{server}/{repo}">Source code and releases</a></p>
</body>
</html>
"""


if __name__ == "__main__":
    main(sys.argv[1])
