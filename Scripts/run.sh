#!/bin/bash
# Bundle, (re)launch the .app, and stream its log output until Ctrl-C.
# Ctrl-C only stops the log stream; the app keeps running in the menu bar.
# (/usr/bin/log is spelled out because zsh has a `log` builtin that shadows it.)
#
#   Scripts/run.sh            # build + launch + follow logs
#   Scripts/run.sh --no-logs  # build + launch only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AnnotationStation.app"
SUBSYSTEM="com.gabe.annotation-station"

"$ROOT/Scripts/bundle.sh"

# Replace any running instance so the new build (and its signature) is what gets tested.
if pgrep -xq AnnotationStation; then
    echo "▸ stopping running instance"
    pkill -x AnnotationStation || true
    sleep 0.5
fi

echo "▸ open $APP"
open "$APP"

if [[ "${1:-}" == "--no-logs" ]]; then
    exit 0
fi

echo "▸ streaming logs for $SUBSYSTEM (Ctrl-C to stop; app keeps running)"
exec /usr/bin/log stream --level info --style compact --predicate "subsystem == \"$SUBSYSTEM\""
