#!/bin/bash
# Poke the running app without touching the keyboard. Needs the debug hooks enabled once:
#   defaults write com.gabe.annotation-station debugHooks -bool true   (then relaunch)
#
#   Scripts/debug.sh capture            # same as ⌘⇧A
#   Scripts/debug.sh demo               # add three demo marks to the open overlay
#   Scripts/debug.sh snapshot out.png   # app captures its own display (overlay included) to out.png
#   Scripts/debug.sh next | send | discard
set -euo pipefail
ACTION="${1:?action}"
TARGET="${2:-}"
[[ -n "$TARGET" ]] && TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
osascript -l JavaScript - "$ACTION" "$TARGET" <<'JS' >/dev/null
ObjC.import('Foundation');
function run(argv) {
  const center = $.NSDistributedNotificationCenter.defaultCenter;
  center.postNotificationNameObjectUserInfoDeliverImmediately(
    'com.gabe.annotation-station.debug', $(), $({action: argv[0], path: argv[1]}), true);
  return '';
}
JS
