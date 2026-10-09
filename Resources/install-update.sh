#!/bin/bash
# The app verifies the package before invoking this helper. Installation succeeds
# only when the replacement process acknowledges native startup and stays alive.
set -eu
WORK="$1"
TARGET="$2"
OLD_PID="$3"
MODE="${4:-foreground}"
TOKEN="${5:-}"
case "$MODE" in foreground|background) ;; *) exit 1;; esac
case "$WORK" in */.codex-buddy-update-*.noindex) ;; *) exit 1;; esac
[[ "$(dirname "$WORK")" == "$(dirname "$TARGET")" ]] || exit 1
[[ "$TARGET" == */Codex\ Buddy.app ]] || exit 1
[[ "$OLD_PID" =~ ^[0-9]+$ ]] || exit 1
[[ "$TOKEN" =~ ^[A-Fa-f0-9-]{36}$ ]] || exit 1
[[ -f "$WORK/health-request.json" && ! -L "$WORK" && ! -e "$WORK/ready" ]] || exit 1
NEW="$WORK/Codex Buddy.app"
BACKUP="$WORK/previous.app"
[[ -d "$NEW" && -d "$TARGET" && ! -e "$BACKUP" ]] || exit 1
for ((n=0;n<150;n++)); do
    kill -0 "$OLD_PID" 2>/dev/null || break
    /bin/sleep 0.2
done
if kill -0 "$OLD_PID" 2>/dev/null; then exit 1; fi
NEW_PID=""
rollback() {
    trap - ERR
    if [[ -n "$NEW_PID" ]] && kill -0 "$NEW_PID" 2>/dev/null; then
        kill "$NEW_PID" 2>/dev/null || true
        for ((r=0;r<25;r++)); do
            kill -0 "$NEW_PID" 2>/dev/null || break
            /bin/sleep 0.2
        done
        if kill -0 "$NEW_PID" 2>/dev/null; then kill -KILL "$NEW_PID" 2>/dev/null || true; fi
    fi
    if [[ -d "$BACKUP" ]]; then
        if [[ -e "$TARGET" ]]; then /bin/mv "$TARGET" "$WORK/failed.app"; fi
        /bin/mv "$BACKUP" "$TARGET"
    fi
    printf '%s\n' 'Update failed; previous version restored' > "$WORK/result.txt"
    if [[ "$MODE" == background ]]; then
        /usr/bin/open -g "$TARGET" --args --update-restored "$WORK" --update-token "$TOKEN" || true
    else
        /usr/bin/open "$TARGET" --args --update-restored "$WORK" --update-token "$TOKEN" || true
    fi
}
trap rollback ERR
/bin/mv "$TARGET" "$BACKUP"
/bin/mv "$NEW" "$TARGET"
# Launch the verified executable directly so the helper owns its exact PID.
# The app's normal accessory activation policy keeps silent launches in the background.
"$TARGET/Contents/MacOS/CodexBuddy" --update-work "$WORK" --update-token "$TOKEN" >/dev/null 2>&1 &
NEW_PID=$!
READY=false
for ((n=0;n<150;n++)); do
    if ! kill -0 "$NEW_PID" 2>/dev/null; then break; fi
    if [[ -f "$WORK/ready" && ! -L "$WORK/ready" ]]; then
        IFS=' ' read -r READY_TOKEN READY_PID < "$WORK/ready" || true
        if [[ "${READY_TOKEN:-}" == "$TOKEN" && "${READY_PID:-}" == "$NEW_PID" ]]; then READY=true;break; fi
    fi
    /bin/sleep 0.2
done
if [[ "$READY" != true ]]; then rollback;exit 1; fi
# A receipt followed immediately by a crash still requires restoration.
/bin/sleep 1
if ! kill -0 "$NEW_PID" 2>/dev/null; then rollback;exit 1; fi
trap - ERR
if [[ "$MODE" == foreground ]]; then /usr/bin/open "$TARGET" || true; fi
printf '%s\n' 'Update installed and startup confirmed' > "$WORK/result.txt"
