#!/bin/sh
# Runs the smoke app once per backend the tier promises and lets its exit code decide.
#
# Upstream launched the app under a fifteen second timeout and treated "still running" as a pass.
# A window that never paints is also still running, which is exactly how the defect this fork
# exists for shipped. Nothing here interprets liveness: 0 is the only pass, and a run that has to
# be killed is a failure like any other.
#
# POSIX sh on purpose - the same script runs under bash on Linux and macOS, Git Bash on Windows and
# busybox ash inside the Alpine container, so all four platforms are held to one check.
#
#   SMOKE_TIER      Vulkan | OpenGL | Software - the tier the package under test was built for
#   SMOKE_BACKENDS  space separated backends to force, richest first
#   SMOKE_DIR       directory holding the published app (default: the working directory)
#   SMOKE_LOG_DIR   where the frame BMPs and the reports are written
#   SMOKE_LABEL     what to call this run in the log (default: the tier)
#   SMOKE_LAUNCHER  command prefix, "xvfb-run -a" where there is no display
#   SMOKE_TIMEOUT   watchdog seconds handed to the app, default 60
#   SMOKE_SELFTEST  1 to run the negative control instead: a blank frame that must be rejected

set -u

: "${SMOKE_TIER:?SMOKE_TIER is required}"
: "${SMOKE_BACKENDS:?SMOKE_BACKENDS is required}"
: "${SMOKE_LOG_DIR:?SMOKE_LOG_DIR is required}"

directory="${SMOKE_DIR:-.}"
launcher="${SMOKE_LAUNCHER:-}"
watchdog="${SMOKE_TIMEOUT:-60}"
label="${SMOKE_LABEL:-$SMOKE_TIER}"

app="$directory/OptrisStaticGraphicsSmoke"
[ -f "$app" ] || app="$directory/OptrisStaticGraphicsSmoke.exe"
if [ ! -f "$app" ]; then
    echo "::error::No smoke app under '$directory'."
    ls -la "$directory" || true
    exit 1
fi

chmod +x "$app" 2>/dev/null || true
mkdir -p "$SMOKE_LOG_DIR"

# A belt over the app's own watchdog, which is itself there because a wedged GPU driver is one of
# the outcomes under test. Where timeout is missing the watchdog and the job timeout are the
# backstop; either way the run ending by force is a failure and never a pass.
guard=""
if command -v timeout > /dev/null 2>&1; then
    guard="timeout $((watchdog + 60))"
fi

if [ "${SMOKE_SELFTEST:-0}" = "1" ]; then
    # A smoke test nobody has watched fail is not evidence. This draws nothing - the blank window in
    # its usual form - through the cheapest backend the tier carries, and has to come back non-zero.
    backend=$(printf '%s\n' $SMOKE_BACKENDS | tail -n 1)
    echo "== self-test: $label, $backend backend, drawing nothing on purpose"

    OPTRIS_SMOKE_TIER="$SMOKE_TIER" \
    OPTRIS_SMOKE_BACKEND="$backend" \
    OPTRIS_SMOKE_SELFTEST=blank \
    OPTRIS_SMOKE_TIMEOUT_SECONDS="$watchdog" \
    OPTRIS_SMOKE_REPORT="$SMOKE_LOG_DIR/selftest-$backend.txt" \
        $guard $launcher "$app"
    code=$?

    if [ "$code" -eq 0 ]; then
        echo "::error::$label: a blank frame passed every check. The assertions have stopped asserting."
        exit 1
    fi

    echo "== the blank frame was rejected with exit $code, as it must be"
    exit 0
fi

status=0
for backend in $SMOKE_BACKENDS; do
    echo "== $label: forcing the $backend backend"

    OPTRIS_SMOKE_TIER="$SMOKE_TIER" \
    OPTRIS_SMOKE_BACKEND="$backend" \
    OPTRIS_SMOKE_TIMEOUT_SECONDS="$watchdog" \
    OPTRIS_SMOKE_FRAME="$SMOKE_LOG_DIR/frame-$backend.bmp" \
    OPTRIS_SMOKE_REPORT="$SMOKE_LOG_DIR/report-$backend.txt" \
        $guard $launcher "$app"
    code=$?

    if [ "$code" -ne 0 ]; then
        echo "::error::$label: the $backend run exited $code. Zero is the only pass; see the report and the frame BMP."
        status=1
    fi
done

exit $status
