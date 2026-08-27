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
#   SMOKE_SELFTEST  1/true/yes/on to run the negative control instead: a blank frame that must be
#                   rejected, proved by reading the app's own report and never by an exit code.
#                   Anything this script does not recognise is a hard stop, never a quiet "off".

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

# This used to read [ "${SMOKE_SELFTEST:-0}" = "1" ], so every value except the exact string 1 -
# including the "true" GitHub hands over from the natural YAML "SMOKE_SELFTEST: true" - skipped the
# negative control entirely and fell through to the ordinary positive run below, which passes. The
# step named "Prove the smoke test can fail" then printed a green run indistinguishable from the
# ordinary smoke step: no error, no self-test line, nothing saying the control had not run. Five
# call sites pass this flag, so one unquoted true in one workflow disarmed all five at once. So the
# spellings a human would reasonably write are honoured here, and anything else stops the job.
# Guessing "off" for an unrecognised value is the one answer that must never be given, because it
# turns the only check that proves the pixel assertions still assert into a second positive test.
selftest_given="${SMOKE_SELFTEST+given}"
# No colon in ${SMOKE_SELFTEST-0}, and that is the whole point: ":-" substitutes for unset OR
# empty, which quietly turned a set-but-empty value into "0" - the guessed "off" this file
# forbids two comments up. Empty is not unset; it is an unrecognised value and belongs in the
# hard stop below. It arrives the way every other value here arrives: an unset ${{ }} input or
# a $GITHUB_ENV line whose shell variable was empty, exactly as SMOKE_LAUNCHER already is on
# the Windows and macOS legs. Unset still means "off"; empty now means "say so and stop".
selftest=$(printf '%s' "${SMOKE_SELFTEST-0}" | tr '[:upper:]' '[:lower:]')
case "$selftest" in
    1 | true | yes | on)
        selftest=1
        ;;
    0 | false | no | off)
        selftest=0
        ;;
    *)
        echo "::error::SMOKE_SELFTEST='${SMOKE_SELFTEST:-}' is not a value this script understands. Use 1, true, yes or on to run the negative control; 0, false, no, off or leaving it unset for an ordinary run. Refusing to guess: reading an unrecognised value as 'off' would silently replace the negative control with a second positive test that passes."
        exit 1
        ;;
esac

if [ "$selftest" = "1" ]; then
    # A smoke test nobody has watched fail is not evidence. This draws nothing - the blank window in
    # its usual form - through the cheapest backend the tier carries, and has to come back non-zero.
    #
    # One variable carries the mode into both the run and the assertion below, so a respelling can
    # never arm one without the other.
    selftest_mode=blank
    backend=$(printf '%s\n' $SMOKE_BACKENDS | tail -n 1)
    report="$SMOKE_LOG_DIR/selftest-$backend.txt"
    echo "== self-test: $label, $backend backend, drawing nothing on purpose"

    # Cleared first, so that a report standing there afterwards is demonstrably this run's. On the
    # musl leg the control and the real run happen back to back in one container, and a report left
    # behind by an earlier invocation would otherwise answer for a run that never happened at all.
    rm -f "$report" 2>/dev/null || true
    if [ -e "$report" ]; then
        echo "::error::$label: $report is left over from an earlier run and could not be removed, so nothing found there can be trusted as evidence about this one."
        exit 1
    fi

    OPTRIS_SMOKE_TIER="$SMOKE_TIER" \
    OPTRIS_SMOKE_BACKEND="$backend" \
    OPTRIS_SMOKE_SELFTEST="$selftest_mode" \
    OPTRIS_SMOKE_TIMEOUT_SECONDS="$watchdog" \
    OPTRIS_SMOKE_REPORT="$report" \
        $guard $launcher "$app"
    code=$?

    if [ "$code" -eq 0 ]; then
        echo "::error::$label: a blank frame passed every check. The assertions have stopped asserting."
        exit 1
    fi

    # Exit 1 - and only exit 1 - can mean the app reached a frame and rejected it. Every other
    # non-zero code says the control never got that far: 2 no frame reached the probe or the watchdog
    # fired, 3 the run was refused at option parsing, 4 the backend would not start, 124 the guard
    # above killed it, 126/127 the app would not launch. This step is the only thing that proves the
    # pixel assertions still assert, so "any non-zero is proof of rejection" made it certify itself in
    # exactly the runs where nothing was ever asserted. OPTRIS_SMOKE_SELFTEST is the one variable
    # the real run below never sets, which makes exit 3 reachable here and nowhere else: respell it
    # (it takes 'blank' or 'uniform', not the 1/true the shell flag uses) and every workflow goes
    # green on a blank scene that was never even constructed.
    if [ "$code" -ne 1 ]; then
        echo "::error::$label: the self-test exited $code. Only 1 means a frame was inspected and rejected; $code means the blank run never reached the assertions, so this proves nothing about them. See $report."
        exit 1
    fi

    # Passing that is necessary and nowhere near sufficient, because the code just read is the
    # OUTERMOST process's, and on every Linux leg the outermost process is xvfb-run, not the app.
    # Debian's and Ubuntu's xvfb-run exits 1 - the single code accepted above - from its own
    # "Xvfb failed to start" path, so a display that never came up was indistinguishable from a blank
    # frame that had been inspected and rejected: the step went green, $SMOKE_LOG_DIR was left empty
    # and the app had never started. "xvfb-run -a" picks its display by scanning for a free
    # /tmp/.X<n>-lock, and on the musl leg the guard above can SIGTERM the preceding run before its
    # cleanup trap clears that lock, so this is a per-invocation failure that the preceding real run
    # would not have caught either.
    #
    # The evidence that settles it already existed and was simply never read: the app writes its own
    # report to $report. From here down the verdict comes out of that file. No report means no run,
    # and no run means no verdict - which is a failure, not a pass.
    if [ ! -s "$report" ]; then
        echo "::error::$label: the self-test wrote no report to $report, so the app never ran far enough to write one and whatever exited $code was not a run that inspected anything. On Linux this is what xvfb-run exiting 1 because Xvfb would not start looks like. Nothing here says the pixel assertions still assert."
        ls -la "$SMOKE_LOG_DIR" || true
        exit 1
    fi

    # DescribeRun prints this line only once OPTRIS_SMOKE_SELFTEST has parsed into a self-test mode,
    # so its absence means the blank scene was never constructed and whatever did run was an ordinary
    # positive test wearing the negative control's name.
    if ! grep -qi "^self-test *: $selftest_mode" "$report"; then
        echo "::error::$label: $report carries no 'self-test: $selftest_mode' line, so the app never entered the blank-scene mode and drew the real scene instead. OPTRIS_SMOKE_SELFTEST takes 'blank' or 'uniform'; anything else parses as no self-test at all."
        exit 1
    fi

    # The app's own closing verdict, which is the only statement of the exit code that comes from the
    # app rather than from whatever wrapped it. A 1 forged by a launcher that died before exec cannot
    # put this line in the file.
    if ! grep -q "^FAIL .*exit=1[^0-9]*$" "$report"; then
        echo "::error::$label: $report does not carry the app's own 'FAIL ... exit=1' verdict, so the 1 seen here came from something other than the app - the launcher, the guard or the shell. A wrapper's exit code says nothing about a frame."
        exit 1
    fi

    # And this is the assertion itself. SmokeReport prefixes every failure in its summary with the
    # section that produced it, so a "[window render, ...] frame is not one flat colour" line is
    # FrameAnalysis.Inspect's verdict on the frame the window backend actually produced - the exact
    # check that catches the blank window this fork exists for. Exit 1 alone does not imply it:
    # SmokeRunner returns Failed for any accumulated failure, and its window path returns the frame
    # WITHOUT calling Inspect when the readback itself failed, so a run that inspected nothing exits
    # 1 too. If FrameAnalysis ever renames that check this fails closed, and the name here is what
    # needs updating - do not delete the assertion to get the step green again.
    if ! grep -qi "^ *- \[window render[^]]*\] frame is not one flat colour" "$report"; then
        echo "::error::$label: $report never records FrameAnalysis rejecting the window's frame as one flat colour. The app failed for some other reason - a readback error, a backend mismatch - and the pixel assertions were never run against a frame, so this run proves nothing about them. Read $report."
        exit 1
    fi

    echo "== the blank frame was inspected and rejected, as it must be. From $report:"
    grep -i "^ *- \[window render" "$report" || true
    exit 0
fi

if [ "$selftest_given" = "given" ]; then
    # Said out loud, because the failure this whole pipeline is against is a check that cannot tell
    # "I looked and it was fine" from "I never looked". A step that meant to run the negative control
    # and wrote SMOKE_SELFTEST: 0 gets an ordinary positive run, and this line is the only thing in
    # its log that admits it.
    echo "== SMOKE_SELFTEST is off: this is an ordinary run, not the negative control"
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
