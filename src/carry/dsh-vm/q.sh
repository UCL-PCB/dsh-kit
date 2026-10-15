#!/bin/bash
# INSIDE. Import scripts that arrived on Q: and run one, without typing a long
# command line.
#
# Everything else in this payload arrives once, in the zip. This is for the
# scripts written mid-session, in response to something the VM did - they arrive
# one at a time on Q:, and the copy-then-fix-line-endings-then-chmod-then-run
# incantation is long enough to be worth not typing.
#
#   ./q.sh                      import from Q:, run the one that arrived
#   ./q.sh <name> [args...]     import from Q:, run that one with those args
#   ./q.sh --list               import from Q:, run nothing
#   ./q.sh --set-group <group>  remember --group, then behave as above
#   ./q.sh --qdir /r            look somewhere other than Q: for arrivals
#
# <name> may be given with or without the .sh. Anything after it is passed
# straight to the script.
#
# Every carried script already reads the group from dsh-kit.conf, so --set-group
# matters only for a script written mid-session that does not. It records the
# GitLab group as KIT_GITLAB_GROUP in ~/dsh-kit.env ($DSH_KIT_ENV overrides) - the
# same per-machine file every carried script reads - and supplies
# --group automatically to any script whose --help mentions --group and that was
# not given one on the command line. Nothing else is inferred.
#
# CRLF is stripped on import: these files are written on a workstation, cross
# the airlock through a portal, and land on Windows. A stray CR makes bash fail
# with `$'\r': command not found`, which reads like a corrupt script.
#
# Log: Logs/q.log beside this script. The imported script keeps its own log too.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

ENV_FILE="${DSH_KIT_ENV:-${HOME}/dsh-kit.env}"

# Note: only the import half is logged. The script that gets run keeps its own
# log, and wrapping it here would put a tee between it and the terminal - which
# is exactly what breaks an interactive credential prompt.
LIST_ONLY="no"
TARGET=""
QDIR=""
declare -a TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST_ONLY="yes"; shift ;;
        --qdir) QDIR="$2"; shift 2 ;;
        --set-group)
            [ -n "${2:-}" ] || { echo "Error: --set-group needs a value" >&2; exit 1; }
            # Replace the one key, keep every other line of the machine file.
            { [ -f "$ENV_FILE" ] && grep -v '^KIT_GITLAB_GROUP=' "$ENV_FILE"
              printf 'KIT_GITLAB_GROUP="%s"\n' "$2"; } > "${ENV_FILE}.$$" \
                && mv "${ENV_FILE}.$$" "$ENV_FILE"
            echo "Remembered: group ${2}  (KIT_GITLAB_GROUP in ${ENV_FILE})"
            shift 2 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *)  TARGET="$1"; shift; TARGET_ARGS=("$@"); break ;;
    esac
done

# The conf's group, overridden by the machine file - parsed, never sourced.
KIT_GITLAB_GROUP=""
# shellcheck source=../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"
if [ -f "${PAYLOAD_DIR}/dsh-kit.conf" ]; then
    dsh_kit_settings "$PAYLOAD_DIR" >/dev/null || true
else
    DSH_KIT_ENV="$ENV_FILE" dsh_load_machine_env >/dev/null
fi
case "${KIT_GITLAB_GROUP:-}" in '<'*'>') KIT_GITLAB_GROUP="" ;; esac
DSH_GROUP="${KIT_GITLAB_GROUP:-}"

echo "=== 1. Find Q: ==="
# say() used to write to the terminal and to a second descriptor on q.log.
# Everything this script prints now goes to Logs/q.log through dsh_start_log,
# like every other script's output, so one echo does both jobs. Kept as a name
# because the calls below read as "say this to the operator and to the record",
# which is still what happens.
say() { echo "$@"; }

if [ -z "$QDIR" ]; then
    for c in /q /Q; do
        [ -d "$c" ] && { QDIR="$c"; break; }
    done
fi
if [ -z "$QDIR" ]; then
    say "  Q: is not mapped in this shell."
    say "  A Git Bash opened before the drive was mapped has no /q - open a fresh"
    say "  one, or point this at the right place with --qdir <dir>."
    exit 1
fi
say "  $QDIR"

say ""
say "=== 2. Import *.sh ==="
# Q: holds a per-user folder; depth 2 covers both that and a file dropped at the
# root. -newer keeps an unchanged file from being reported as an import every
# time, so "what arrived" stays meaningful.
imported=()
while IFS= read -r src; do
    [ -n "$src" ] || continue
    base="$(basename "$src")"
    dest="${PAYLOAD_DIR}/${base}"
    if [ -f "$dest" ] && [ ! "$src" -nt "$dest" ]; then
        say "  unchanged  ${base}"
        continue
    fi
    tr -d '\r' < "$src" > "$dest" && chmod +x "$dest"
    say "  imported   ${base}"
    imported+=("$base")
done < <(find "$QDIR" -maxdepth 2 -name '*.sh' -type f 2>/dev/null | sort)

if [ "${#imported[@]}" -eq 0 ]; then
    say "  nothing new"
fi

if [ "$LIST_ONLY" = "yes" ]; then
    say ""
    say "=== Done (--list) ==="
    exit 0
fi

# With no name given, run the new arrival - but only when there is exactly one,
# because guessing between two is how the wrong thing gets run.
if [ -z "$TARGET" ]; then
    if [ "${#imported[@]}" -eq 1 ]; then
        TARGET="${imported[0]}"
        say ""
        say "  running the one that arrived: ${TARGET}"
    elif [ "${#imported[@]}" -eq 0 ]; then
        say ""
        say "  Nothing arrived, so there is nothing to run."
        say "  Name one to run it:   ./q.sh <name> [args...]"
        exit 0
    else
        say ""
        say "  ${#imported[@]} scripts arrived - name the one to run:"
        for b in "${imported[@]}"; do say "      ./q.sh ${b%.sh}"; done
        exit 1
    fi
fi

case "$TARGET" in *.sh) ;; *) TARGET="${TARGET}.sh" ;; esac
# A name, not a path: an arriving script lands here at the top level, but one that
# came in the payload may be in diagnose/. Which directory a script is in is the
# payload's business, not something to have to remember at the prompt.
SCRIPT=""
for dir in "$PAYLOAD_DIR" "${PAYLOAD_DIR}/diagnose"; do
    if [ -f "${dir}/${TARGET}" ]; then SCRIPT="${dir}/${TARGET}"; break; fi
done
if [ -z "$SCRIPT" ]; then
    say ""
    say "  No such script here: ${TARGET}"
    say "  It has to be on Q: (upload it) or already in $(basename "$PAYLOAD_DIR")"
    say "  or its diagnose/ subdirectory."
    exit 1
fi

# Supply --group only where it is accepted and was not given. Reading --help is
# how that is established; assuming it would break every script without the flag.
if [ -n "$DSH_GROUP" ]; then
    case " ${TARGET_ARGS[*]:-} " in
        *" --group "*) ;;
        *)  # Captured, not piped: a --help that exits non-zero (most of them do)
            # would fail the pipeline under `set -o pipefail` even when grep
            # matched, and the flag would silently never be added.
            help_text="$(bash "$SCRIPT" --help 2>&1 || true)"
            case "$help_text" in
                *--group*)
                    TARGET_ARGS+=(--group "$DSH_GROUP")
                    say "  adding --group ${DSH_GROUP} (remembered)" ;;
            esac ;;
    esac
fi

say ""
say "=== 3. Run ${TARGET} ${TARGET_ARGS[*]:-} ==="
say "  (its own output goes to Logs/${TARGET%.sh}.log)"
echo
exec 3>&-
# exec, not a subshell: the script inherits this terminal directly, so an
# interactive credential prompt still works and its exit code is ours.
exec bash "$SCRIPT" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}
