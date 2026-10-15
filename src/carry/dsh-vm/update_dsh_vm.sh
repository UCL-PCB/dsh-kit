#!/bin/bash
# INSIDE. Unpack, mirror --refresh and install in one pass, for a REFRESH of a VM
# that is already set up - a new payload carrying newer bundles, nothing else
# changed.
#
# Driven by ~/dsh-kit.env (where things go on this machine) and by the payload's
# own dsh-kit.conf (what the project is), so the same command works every trip and
# no environment-specific path is ever typed at a prompt. update_dsh_vm.bat is the
# double-clickable wrapper; this is where the logic lives.
#
#   bash ./update_dsh_vm.sh                 # unpack -> mirror --refresh -> install
#   bash ./update_dsh_vm.sh --skip unpack   # the zip is already unpacked
#   bash ./update_dsh_vm.sh --dry-run       # print the three commands, run nothing
#
# This travels BESIDE the zip, like unpack_payload.sh, because it runs the
# unpacker: the copy inside the payload cannot unpack the payload it is in. The
# copy in the payload directory is the reference copy and is never the one
# running, so unpacking over it is safe.
#
# It is a refresh, not a first build. It never installs uv, never probes and
# never picks a venv location; those are one-time and stay done. For a first
# import, follow the dsh-setup skill (or docs) step by step instead.
#
# Writes Logs/update_dsh_vm.log beside itself, so the result is reviewable on the
# VM without relaying it anywhere.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   bash ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log to a file AND the terminal, through dsh_log.sh like every other script.
#
# This one logs beside ITSELF rather than beside the payload, and that is not an
# oversight: this script travels outside the zip and runs before there is an
# unpacked payload to log into. The scripts it then drives each log into the
# payload, where they belong.
#
# So it needs lib/ BESIDE it too, not just inside the zip: build_payload.sh stages
# DSH_upload/lib/ for exactly this. Checked rather than assumed, because the
# failure otherwise is a bare "No such file" from a `.` line.
if [ ! -f "${HERE}/lib/dsh_log.sh" ] || [ ! -f "${HERE}/lib/dsh_platform.sh" ]; then
    echo "Not found: ${HERE}/lib/dsh_log.sh and lib/dsh_platform.sh" >&2
    echo "  They travel in DSH_upload/lib/, beside this script and the zip. Upload" >&2
    echo "  the whole DSH_upload folder, lib/ included." >&2
    exit 1
fi
# shellcheck source=../any/lib/dsh_log.sh
. "${HERE}/lib/dsh_log.sh"
# shellcheck source=../any/lib/dsh_platform.sh
. "${HERE}/lib/dsh_platform.sh"
dsh_start_log "$@"

SKIP=""
DRY=0
CONFIG="${DSH_KIT_ENV:-${HOME}/dsh-kit.env}"

usage() {
    cat <<'USAGE'
Usage: bash ./update_dsh_vm.sh [options]

  --skip LIST     comma-separated steps not to run: unpack, mirror, install
  --dry-run       print the commands that would run, then stop
  --config FILE   read per-machine settings from FILE instead of ~/dsh-kit.env
USAGE
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip)    SKIP="$2"; shift 2 ;;
        --config)  CONFIG="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        *)         echo "Unknown argument: $1" >&2; usage ;;
    esac
done

skipped() { case ",${SKIP}," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# Printed rather than shipped as a second file: a template that travels is a
# template that goes stale against the keys read below.
template() {
    cat <<'TEMPLATE'
# ~/dsh-kit.env on the DSH analysis VM. Per-machine and never carried - what the
# PROJECT is lives in the payload's dsh-kit.conf, not here.
#
# Parsed, not sourced: one KEY="value" per line, no $variables, no spaces around =.
# Paths are POSIX, as Git Bash sees them: S:\x becomes /s/x.

# Required by this script.
KIT_WORKSPACE_DIR="/s/<share>/<workspace-dir>"

# Optional. Delete any line you do not need.
#KIT_PAYLOAD_DIR="/c/Users/<you>/DSH_import"   # where the zip unpacks to; default ~/DSH_import
#KIT_ZIP="/q/<username>/DSH_import.zip"        # unset = search Q:, $HOME, here, ~/Downloads
#KIT_CLEAN_PATH="no"                           # yes if Anaconda shadows the venv's DLLs
#KIT_PYTHON=""                                 # only needed on a first build
#KIT_GITLAB_GROUP=""                           # override the conf's group on this machine
#KIT_WORKING_NAMESPACE=""                      # override where working repos live
TEMPLATE
}

if [ ! -f "$CONFIG" ]; then
    echo "Not found: ${CONFIG}"
    echo
    echo "Create it with this, filling in the placeholders:"
    echo "---------------------------------------------------------------"
    template
    echo "---------------------------------------------------------------"
    exit 1
fi
KIT_WORKSPACE_DIR="" KIT_PAYLOAD_DIR="" KIT_ZIP=""
dsh_load_machine_env "$CONFIG"

WORKSPACE="${KIT_WORKSPACE_DIR:-}"
PAYLOAD_DIR="${KIT_PAYLOAD_DIR:-${HOME}/DSH_import}"
ZIP="${KIT_ZIP:-}"

if [ -z "$WORKSPACE" ]; then
    echo "  ${CONFIG} does not set KIT_WORKSPACE_DIR" >&2
    echo >&2
    template >&2
    exit 1
fi
dsh_no_placeholder KIT_WORKSPACE_DIR "$WORKSPACE" || exit 1

echo "=== Settings (${CONFIG}) ==="
printf '  %-16s %s\n' "workspace" "$WORKSPACE"
printf '  %-16s %s\n' "payload"   "$PAYLOAD_DIR"
[ -n "$ZIP" ]  && printf '  %-16s %s\n' "zip"      "$ZIP"
[ -n "$SKIP" ] && printf '  %-16s %s\n' "skipping" "$SKIP"
echo "  (repos, GitLab group and install mode come from the payload's dsh-kit.conf)"
echo

# Git walks up from the cwd statting every ancestor, and on this VM one of them
# can be unstattable by the account - which kills every git command, including the
# ones that touch no network, with a message that reads like GitLab refusing the
# account. ~/.bashrc should set this; set it here too so the .bat route does not
# depend on which shell flags started us.
export GIT_CEILING_DIRECTORIES="${GIT_CEILING_DIRECTORIES:-$HOME}"
# The children read ~/dsh-kit.env themselves; make sure they read THIS one.
export DSH_KIT_ENV="$CONFIG"

# ---------------------------------------------------------------------------
# The three steps
# ---------------------------------------------------------------------------
# Each is echoed before it runs, in a form that can be pasted to run it alone -
# so a failure here leaves the operator with the single command to retry rather
# than a wrapper to reverse-engineer.
run_step() {
    local name="$1" dir="$2" rc
    shift 2

    echo "=== ${name} ==="
    printf '  cd %s\n  bash' "$dir"
    printf ' %q' "$@"
    printf '\n\n'
    if [ "$DRY" -eq 1 ]; then
        return 0
    fi

    ( cd "$dir" && bash "$@" )
    rc=$?
    echo
    if [ "$rc" -ne 0 ]; then
        echo "!!! ${name} failed (exit ${rc}). Stopping: the later steps assume it worked." >&2
        echo "    Its own log is in ${dir}/Logs." >&2
        exit "$rc"
    fi
    echo "--- ${name} OK"
    echo
}

# 1. Run from HERE, not from the payload directory: this is the copy that
# travelled beside the zip, and the payload directory is what it writes.
if skipped unpack; then
    echo "=== 1. Unpack + verify (skipped) ==="
    echo
else
    if [ ! -f "${HERE}/unpack_payload.sh" ]; then
        echo "Not found: ${HERE}/unpack_payload.sh" >&2
        echo "It travels beside the zip, and so does this script. Upload it too," >&2
        echo "or re-run with --skip unpack if the payload is already unpacked." >&2
        exit 1
    fi
    # --force because a refresh unpacks over the previous payload, which is not
    # empty. Without it unpack_payload.sh stops rather than mix two payloads.
    unpack_args=(./unpack_payload.sh --dest "$PAYLOAD_DIR" --force)
    [ -n "$ZIP" ] && unpack_args+=(--zip "$ZIP")
    run_step "1. Unpack + verify" "$HERE" "${unpack_args[@]}"
fi

# 2. --refresh, always: without it an existing clone is silently skipped, which is
# exactly how a stale mirror survives a run that reports success. A repo whose SHA
# did not move pushes nothing and never reaches a protected-branch hook, so an
# unchanged repo cannot be declined.
if skipped mirror; then
    echo "=== 2. Mirror refresh (skipped) ==="
    echo
else
    run_step "2. Mirror refresh" "$PAYLOAD_DIR" ./mirror_to_gitlab.sh --refresh
fi

# 3. Re-running is the supported update path: existing clones are fetched and
# fast-forwarded rather than re-cloned. The python is not passed unless
# ~/dsh-kit.env sets one - uv recorded the interpreter in .venv on the first build.
if skipped install; then
    echo "=== 3. Install (skipped) ==="
    echo
else
    run_step "3. Install" "$PAYLOAD_DIR" ./install_packages.sh --workspace "$WORKSPACE"
fi

if [ "$DRY" -eq 1 ]; then
    echo "Dry run - nothing was executed."
    exit 0
fi

cat <<EOF
=== Done ===

  Logs - this one beside this script, the rest in the payload's own Logs/:
    ${HERE}/Logs/update_dsh_vm.log
    ${PAYLOAD_DIR}/Logs/unpack_payload.log
    ${PAYLOAD_DIR}/Logs/verify_payload.log
    ${PAYLOAD_DIR}/Logs/mirror_to_gitlab.log
    ${PAYLOAD_DIR}/Logs/install_packages.log

  The mirror checkpoint above prints a SHA per repo. They must match
  ${PAYLOAD_DIR}/MANIFEST.txt exactly, or a commit id does not mean the same
  thing on both sides of the airlock - which is the whole point of the bundles.

  Do NOT smoke-test with 'uv run'. In a uv workspace it performs an exact sync
  and uninstalls the optional extras this environment is built with: a check
  that damages what it is checking. Use the venv python directly.

  The console-script wrappers need regenerating only if an entry point was added
  or renamed. If one was: make_console_wrappers.sh --workspace '${WORKSPACE}'
EOF
