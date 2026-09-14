#!/usr/bin/env python3
"""Download the auto-refresh Shortcut from its iCloud link into the repo.

iCloud share links are not permanent - the owner can revoke or replace one -
so the file itself is kept next to the app. Apple serves the signed shortcut
behind a small JSON record API keyed by the share id.

Usage: fetch_shortcut.py <icloud share url> <output path>
"""
import json
import os
import re
import sys
import urllib.request

RECORD_API = "https://www.icloud.com/shortcuts/api/records/{share_id}"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def main(share_url, out_path):
    match = re.search(r"/shortcuts/([0-9a-fA-F]{8,})", share_url)
    if not match:
        sys.exit(f"::error::not an iCloud Shortcuts share link: {share_url}")

    record = json.loads(get(RECORD_API.format(share_id=match.group(1))))
    fields = record.get("fields", {})
    try:
        download_url = fields["shortcut"]["value"]["downloadURL"]
    except (KeyError, TypeError):
        sys.exit(
            "::error::no downloadURL in the iCloud record - the link may be revoked "
            f"or the API shape changed. Fields seen: {sorted(fields)}"
        )

    payload = get(download_url)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "wb") as fh:
        fh.write(payload)

    name = fields.get("name", {}).get("value", "")
    print(f"shortcut name: {name or '(unnamed)'}")
    print(f"wrote {out_path} ({len(payload)} bytes)")

    step_output = os.environ.get("GITHUB_OUTPUT")
    if step_output:
        with open(step_output, "a") as fh:
            fh.write(f"shortcut_name={name}\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
