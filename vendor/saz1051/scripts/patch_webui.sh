#!/bin/sh
# Defensive WebUI fix (2026-09-23, SAZ1051 v6).
#
# Some majestic builds busy-loop on `-v` (never exit). The WebUI's common.cgi
# probes the version via $(majestic -v); with a broken binary this hangs the CGI
# at 100% CPU and OOM-kills the box, which (before v6) also rebooted the board.
# Replace the version-probe command substitution with a static string so the
# WebUI always renders without ever invoking the binary.
#
# Runs at build time on the OpenIPC builder; $1 = TARGET_DIR.
set -e
TARGET="$1"
[ -n "$TARGET" ] || exit 0
for f in \
    "$TARGET/var/www/cgi-bin/p/common.cgi" \
    "$TARGET/var/www/cgi-bin/common.cgi" \
    "$TARGET/usr/sbin/extutils" ; do
    [ -f "$f" ] || continue
    sed -i -E 's/\$\([^)]*-v[^)]*\)/"SAZ1051-openipc"/g' "$f"
done
echo "patch_webui: neutralized majestic -v version probes"
