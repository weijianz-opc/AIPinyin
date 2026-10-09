#!/bin/sh
# Waits until the screen is unlocked, then runs the real-app test (`make realtest-run`) once and
# reports the result. Started as a temporary launchd job by `make realtest-when-unlocked`, which
# builds the harness first (a plain background process would not survive the shell that started
# it). The job removes itself when done. Cancel with: make realtest-cancel
LABEL=com.aipinyin.realtest-watch
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="$HOME/Library/Logs/AllInOneIME"
OUT="$LOGS/realtest"
HARNESS="$REPO/build/RealTest.app/Contents/MacOS/RealTest"
MAX_WAIT=${MAX_WAIT:-259200}  # give up after 3 days
deadline=$(( $(date +%s) + MAX_WAIT ))

mkdir -p "$LOGS"
exec >>"$LOGS/realtest-watch.log" 2>&1
echo "[$(date)] watcher started (repo $REPO)"

# The harness asks CoreGraphics about *this* login session; anything but "false" counts as locked.
locked() { [ "$("$HARNESS" --is-locked 2>/dev/null)" != "false" ]; }

finish() {
    echo "[$(date)] done: $1"
    rm -f "$LOGS/realtest-watch.plist"
    # Unloading the job also ends this script, so it comes last.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    exit 0
}

[ -x "$HARNESS" ] || finish "harness not built ($HARNESS)"

while :; do
    echo "[$(date)] waiting for the screen to be unlocked"
    while locked; do
        [ "$(date +%s)" -ge "$deadline" ] && finish "still locked after ${MAX_WAIT}s"
        sleep 10
    done
    echo "[$(date)] unlocked; the real-app test starts in 20s"
    osascript -e 'display notification "测试窗口会占用前台约 1 分钟，期间请勿打字" with title "AllInOneIME 将在 20 秒后自动测试"' || true
    sleep 20
    if locked; then echo "[$(date)] locked again before the test started"; continue; fi

    start=$(date '+%Y-%m-%d %H:%M:%S')
    (cd "$REPO" && /usr/bin/make realtest-run)
    rc=$?
    if grep -q '^REALTEST BLOCKED' "$OUT/output.txt" 2>/dev/null; then
        echo "[$(date)] the screen locked during the test; waiting again"
        continue
    fi
    echo "[$(date)] make realtest-run exit $rc"
    echo "--- input method log during the test ---"
    log show --start "$start" --style compact --info --predicate 'subsystem == "com.aipinyin.inputmethod.AIPinyin"' 2>/dev/null \
        | cut -c1-200 | tail -60
    if [ "$rc" -eq 0 ]; then
        osascript -e 'display notification "真实 App 打字测试全部通过" with title "AllInOneIME 测试通过"' || true
    else
        osascript -e 'display notification "详情见 ~/Library/Logs/AllInOneIME/realtest/output.txt" with title "AllInOneIME 测试未通过"' || true
    fi
    finish "make realtest-run exit $rc"
done
