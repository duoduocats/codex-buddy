#!/bin/bash
# Runs only after the app verifies the downloaded DMG and copied bundle.
set -eu
WORK="$1"
TARGET="$2"
OLD_PID="$3"
MODE="${4:-foreground}"
case "$MODE" in foreground|background) ;; *) exit 1;; esac
open_target() {
    if [[ "$MODE" == background ]]; then
        /usr/bin/open -g "$TARGET"
    else
        /usr/bin/open "$TARGET"
    fi
}
case "$WORK" in */.codex-buddy-update-*.noindex) ;; *) exit 1;; esac
[[ "$(dirname "$WORK")" == "$(dirname "$TARGET")" ]] || exit 1
[[ "$TARGET" == */Codex\ Buddy.app ]] || exit 1
[[ "$OLD_PID" =~ ^[0-9]+$ ]] || exit 1
NEW="$WORK/Codex Buddy.app"
BACKUP="$WORK/previous.app"
[[ -d "$NEW" && -d "$TARGET" && ! -e "$BACKUP" ]] || exit 1
for ((n=0;n<150;n++)); do
    kill -0 "$OLD_PID" 2>/dev/null || break
    /bin/sleep 0.2
done
if kill -0 "$OLD_PID" 2>/dev/null; then exit 1; fi
rollback() {
    if [[ ! -e "$TARGET" && -d "$BACKUP" ]]; then /bin/mv "$BACKUP" "$TARGET"; fi
    open_target || true
}
trap rollback ERR
/bin/mv "$TARGET" "$BACKUP"
/bin/mv "$NEW" "$TARGET"
if ! open_target; then
    /bin/mv "$TARGET" "$WORK/failed.app"
    /bin/mv "$BACKUP" "$TARGET"
    open_target || true
    exit 1
fi
trap - ERR
# Keep the previous version in this hidden .noindex directory for manual recovery.
printf '%s\n' 'Update installed successfully' > "$WORK/result.txt"
