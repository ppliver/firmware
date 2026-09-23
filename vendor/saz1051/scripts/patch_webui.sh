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

# --- IR-cut 误报 (2026-09-23, SAZ1051 v7) ---------------------------------
# majestic-webui's a/ircut-check.js decides whether to nag from the TRI-STATE
# field nightMode.irCut ("off"/"manual"/"auto"), treating a boolean false as
# "off" too. This board's majestic binary predates that rename: it only knows
# nightMode.irCutEnabled (bool). So l.irCut is undefined -> the WebUI reads
# "auto" -> and because irCutPin1 is unset it always pushes the danger item
#   "Majestic cannot move the IR-cut filter" / "Nothing is connected to the
#    filter, so nothing moves it ... set IR-cut filter to off"
# The claim itself is TRUE on this board -- the factory板级定义
# YHTX_HS_IPC_SAZ1051_gpio.json has IrCutOpen = IrCutClose = -1 (no coil pad),
# confirmed independently by the factory swapp log in the data partition:
#   "... parse ... 441] ircut_open:-1, ..., led:9, white:10, red:6, oth:7 ..."
# -- so the warning is describing the hardware accurately. We have therefore
# set irCutEnabled:false (see vendor/saz1051/majestic.yaml, which also carries
# an explicit `irCut: off`). This fixup makes the WebUI honour that boolean
# directly, so the notice stays away even if the extra `irCut` key is dropped
# the next time something rewrites /etc/majestic.yaml from the WebUI.
#
# Widen the condition rather than deleting the check: if a coil pad is ever
# assigned and irCutEnabled flipped to true, the real diagnosis still runs.
for f in "$TARGET/var/www/a/ircut-check.js"; do
    [ -f "$f" ] || continue
    # NB: the minified source reads `,k="off"===i(l.irCut);` -- the variable is
    # declared inside a comma list, so the pattern must NOT be anchored on
    # `const`. An earlier revision of this fixup used `const k=` and silently
    # matched nothing, which is why the grep guard below is worth keeping.
    if grep -q 'k="off"===i(l\.irCut);' "$f"; then
        sed -i 's/k="off"===i(l\.irCut);/k="off"===i(l.irCut)||!1===l.irCutEnabled||"false"===l.irCutEnabled;/' "$f"
        echo "patch_webui: ircut-check.js accepts irCutEnabled=false as \"off\""
    else
        echo "patch_webui: WARN ircut-check.js pattern changed upstream -- the" \
             "IR-cut notice may reappear; re-check nightMode.irCut vs irCutEnabled"
    fi
done
