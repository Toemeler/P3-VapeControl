# AutoRefreshApps

Archived copy of the Shortcut that refreshes sideloaded apps before their
7-day signature expires. It calls SideStore's own "refresh all" action.

Downloaded from the author's iCloud share link by the `Build` workflow
(`refresh_shortcut` input) and kept here so it survives that link being
revoked - Apple has invalidated old Shortcut links before.

It is the **signed** copy: iOS refuses to import unsigned shortcut files.

**Requires iOS 27 or later.** On earlier versions it will not work; refresh
manually in SideStore instead.

To add it, open the file on the device. If the import is refused, turn on
*Settings → Shortcuts → Allow Untrusted Shortcuts* once and try again.

The name shown inside the Shortcuts app comes from the signed metadata, not
from this filename, so it may still read as the author named it. Rename it
in the Shortcuts app if you want it to match.
