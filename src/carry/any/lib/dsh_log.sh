#!/bin/bash
# ANY. Sourced by every script in this repo. Not run directly.
#
# One log per script, all of them in one Logs/ directory, and that directory is
# never inside this repository.
#
# Thirty scripts used to carry their own copy of an eight-line `tee` re-exec
# block, and each dropped <name>.log beside itself - which on the far side of the
# airlock meant into DSH_import/, mixed in among the payload it was diagnosing.
# build_payload.sh then had to `rm ./*.log` and verify_payload.sh had to call the
# survivors "harmless extras". This replaces all of it:
#
#     source "<...>/dsh_log.sh"
#     dsh_start_log "$@"
#
# Everything printed after that lands on the terminal AND in the log. The call
# re-executes the script through tee and does not return in the parent, so put it
# near the top - but AFTER anything that decides where the log should go.
#
# WHERE THE LOG GOES, in order:
#   1. $DSH_LOG_DIR            - set it to put the logs anywhere you like
#   2. $DSH_LOG_BASE_DIR/Logs  - what a script sets once it knows its payload or
#                                workspace directory. build_payload.sh sets it to
#                                the DSH_import/ it is building.
#   3. <the payload root>/Logs
#
# (3) is what the carried scripts get for free: they run from inside DSH_import/
# on the far side, so their logs land in DSH_import/Logs/ with no configuration.
# The payload ROOT, not the script's own directory, because the payload is not one
# flat pile: a diagnosis script runs from DSH_import/diagnose/ and its log still
# belongs in the one Logs/ with every other script's. A workstation script must
# NOT fall through to (3) - its own directory is this repository - so every one of
# them sets DSH_LOG_BASE_DIR first.
#
# TRUNCATED, not appended. The file is this run and nothing else: reading it never
# means scrolling past an older run to find where the current output began, and a
# log half an hour old cannot be mistaken for the result of what just happened.
# The previous run is gone - copy a log elsewhere before re-running if two runs are
# to be compared. Each run still opens with a header naming the time, the arguments
# and the working directory, and closes with the exit status.
#
# THE PATH IS ALWAYS PRINTED. Once the script has finished - however it finished -
# the wrapper prints "Log: <path>" on the terminal. It used to be each script's job
# to call a footer at the end, so a script that died early (dsh_die, set -e) never
# said where its log was, which is exactly when the log is wanted.

# The directory a carried script's logs belong in: the payload root when the script
# sits in a subdirectory of one, else its own directory. PAYLOAD_CONTENTS.txt is
# written into every payload by build_payload.sh, and is what identifies one.
dsh_log_payload_root() {
    local here="$1"
    if [ ! -f "${here}/PAYLOAD_CONTENTS.txt" ] && [ -f "${here}/../PAYLOAD_CONTENTS.txt" ]; then
        (cd "${here}/.." && pwd)
        return 0
    fi
    printf '%s\n' "$here"
}

# Where this run's logs belong. Prints an absolute path; creates nothing.
dsh_log_dir() {
    if [ -n "${DSH_LOG_DIR:-}" ]; then
        printf '%s\n' "$DSH_LOG_DIR"
        return 0
    fi
    if [ -n "${DSH_LOG_BASE_DIR:-}" ]; then
        printf '%s/Logs\n' "$DSH_LOG_BASE_DIR"
        return 0
    fi
    printf '%s/Logs\n' \
        "$(dsh_log_payload_root "$(cd "$(dirname "${DSH_LOG_SCRIPT:-$0}")" && pwd)")"
}

# dsh_start_log "$@"
#
# In the parent: re-executes the script with its stdout and stderr joined and
# teed into the log, then exits with the script's own status. In the child (which
# is where the script's actual work happens) it returns immediately, having set
# DSH_LOG_FILE so the script can tell the user where to read the result.
dsh_start_log() {
    local script name dir log rc
    script="${DSH_LOG_SCRIPT:-$0}"
    name="$(basename "$script")"
    name="${name%.sh}"

    # Already inside this script's own tee - this is the child. Do the work.
    case ":${DSH_LOG_WRAPPED:-}:" in
        *":${name}:"*) return 0 ;;
    esac

    dir="$(dsh_log_dir)"
    if ! mkdir -p "$dir" 2>/dev/null; then
        # A read-only or unwritable location must not stop the script running -
        # the log is a record of the work, not a precondition for it.
        echo "Warning: cannot create ${dir}; running without a log" >&2
        export DSH_LOG_WRAPPED="${DSH_LOG_WRAPPED:-}:${name}"
        export DSH_LOG_FILE=""
        return 0
    fi
    log="${dir}/${name}.log"

    # Truncating write: the header STARTS the file, and the tee below appends this
    # run's output to it. Nothing from an earlier run survives into it.
    {
        echo "=============================================================================="
        echo "=== ${name}  $(date -u '+%Y-%m-%dT%H:%M:%SZ')  pid $$"
        echo "===   cwd   ${PWD}"
        echo "===   args  $*"
        echo "=============================================================================="
    } > "$log" 2>/dev/null

    export DSH_LOG_WRAPPED="${DSH_LOG_WRAPPED:-}:${name}"
    export DSH_LOG_FILE="$log"
    # `set -e` is off for the pipeline itself. Under it, a script that exits
    # non-zero takes this wrapper down with it before PIPESTATUS can be read, and
    # the caller gets tee's status - 0 - instead of the script's. Four of the
    # cluster scripts run under `set -e`, and reporting a failed qsub as success is
    # exactly the class of thing this log exists to catch.
    local had_errexit=0
    case "$-" in *e*) had_errexit=1; set +e ;; esac
    bash "$script" "$@" 2>&1 | tee -a "$log"
    rc="${PIPESTATUS[0]}"
    [ "$had_errexit" -eq 1 ] && set -e
    echo "=== ${name} exited ${rc} at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log" 2>/dev/null
    # On the terminal only - the log already records the exit status above.
    if [ "$rc" -eq 0 ]; then
        echo "Log: ${log}" >&2
    else
        echo "Log: ${log}  (exited ${rc})" >&2
    fi
    exit "$rc"
}
