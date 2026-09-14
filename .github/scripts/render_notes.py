#!/usr/bin/env python3
"""Render the release notes from the template.

Kept as a template file so the wording - and the auto-refresh shortcut link -
can be changed without touching workflow YAML.

Usage: render_notes.py <output path>
Reads VERSION, SOURCE_URL and the optional SHORTCUT_URL from the environment.
"""
import os
import sys

SHORTCUT_SECTION = """
8. **Automatic refresh (recommended):** add [this shortcut]({url}) and let it run
   daily. It refreshes your apps before the 7 days run out, so the app does not
   stop working.
"""


def main(out_path):
    shortcut_url = os.environ.get("SHORTCUT_URL", "").strip()
    with open(os.path.join(".github", "release-notes-template.md")) as fh:
        template = fh.read()

    notes = template.format(
        version=os.environ["VERSION"],
        source_url=os.environ["SOURCE_URL"],
        # Omitted entirely rather than left as a dead placeholder when unset.
        shortcut_section=SHORTCUT_SECTION.format(url=shortcut_url) if shortcut_url else "",
    )
    with open(out_path, "w") as fh:
        fh.write(notes)
    print(notes)


if __name__ == "__main__":
    main(sys.argv[1])
