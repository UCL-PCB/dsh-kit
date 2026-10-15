#!/bin/bash
# INSIDE, CLUSTER ONLY. The cluster's counterpart to update_dsh_vm.sh: bring this
# box's install up to the payload it was given, in one command, with nothing typed
# at a prompt. What the project is comes from the payload's dsh-kit.conf; where it
# goes on this box from ~/dsh-kit.env (see dsh_platform.sh for the keys).
#
#   bash ./update_dsh_cluster.sh              # unpack (if a zip is here) -> install
#   bash ./update_dsh_cluster.sh --check      # change nothing, report drift
#   bash ./update_dsh_cluster.sh --dry-run    # print the commands, run nothing
#
# THERE IS NO MIRROR STEP, and that is the difference from the VM. Where the
# clones come from is KIT_GITLAB in the payload's dsh-kit.conf:
#
#   no   (bundle mode) install_packages.sh clones and refreshes straight from the
#        .bundle files in the payload folder, exactly as on the VM. Nothing here
#        depends on the VM having done anything first.
#   yes  bundles are pushed to GitLab-inside from the Desktop VM, which is the only
#        box the airlock delivers to; the cluster is a READER of that mirror. So the
#        order across the two boxes is: update_dsh_vm.bat on the VM first, this
#        second. Running this before the VM has mirrored gets you a clean
#        fast-forward to yesterday's commit and a MANIFEST mismatch, which
#        install_packages.sh reports as a FAIL rather than installing it.
#
# THE PAYLOAD FOLDER HAS TO TRAVEL VM -> CLUSTER for this to work, because the
# arrow between those boxes is a person with WinSCP, not an scp. The load-bearing
# files in it:
#
#   MANIFEST.txt          the new one. install_packages.sh asserts every mirror
#                         clone's HEAD against it, so a stale manifest fails a run
#                         that was otherwise correct.
#   dsh-kit.conf          what to install.
#   install_packages.sh   the step this wraps.
#   lib/                  sourced by all of them.
#
#   <repo>.bundle         in bundle mode, the ONLY source of the code. In GitLab
#                         mode needed only to refresh a WORKING repo. Copying the
#                         whole payload folder is simplest either way.
#
# --check is the pre-flight. It compares three things per repo - what is checked
# out here, what the manifest says, and where the code comes from (GitLab's branch
# tip, or the bundle's) - and names which of the three is behind. Run it before
# submitting a job rather than discovering a stale install partway into one.
#
# Writes Logs/update_dsh_cluster.log beside itself, so the result is reviewable on
# the cluster without relaying it anywhere.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   bash ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log to a file AND the terminal, via a re-run through a plain pipe rather than
# `exec > >(tee f)` - that form loses the tail when the script exits before tee
# flushes, which is precisely the output you came for.
# shellcheck source=../any/lib/dsh_log.sh
. "${HERE}/lib/dsh_log.sh"
dsh_start_log "$@"

SKIP=""
DRY=0
CHECK=0
CONFIG="${DSH_KIT_ENV:-${HOME}/dsh-kit.env}"

usage() {
    cat <<'USAGE'
Usage: bash ./update_dsh_cluster.sh [options]

  --check         report drift only: clone HEAD vs MANIFEST vs GitLab (or vs the
                  bundle, when KIT_GITLAB=no). Changes nothing, clones nothing,
                  exits 1 if anything is behind.
  --skip LIST     comma-separated steps not to run: unpack, install
  --dry-run       print the commands that would run, then stop
  --config FILE   read per-machine settings from FILE instead of ~/dsh-kit.env
USAGE
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK=1; shift ;;
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
if [ ! -f "${HERE}/lib/dsh_platform.sh" ]; then
    echo "Not found: ${HERE}/lib/dsh_platform.sh" >&2
    echo "Copy the whole payload folder over from the VM, lib/ included." >&2
    exit 1
fi
# shellcheck source=../any/lib/dsh_platform.sh
. "${HERE}/lib/dsh_platform.sh"

# ~/dsh-kit.env is optional here: on Linux install_packages.sh defaults the
# workspace to ~/Scratch/<KIT_PROJECT>, and the conf says everything else. The
# payload directory has to be known before the conf can be read, so it is read
# from the machine file first.
export DSH_KIT_ENV="$CONFIG"
KIT_PAYLOAD_DIR=""
dsh_load_machine_env "$CONFIG"
PAYLOAD_DIR="${KIT_PAYLOAD_DIR:-$HERE}"
MANIFEST="${PAYLOAD_DIR}/MANIFEST.txt"

echo "=== Settings ==="
if [ -f "$CONFIG" ]; then
    printf '  %-16s %s\n' "machine file" "$CONFIG"
else
    printf '  %-16s %s\n' "machine file" "${CONFIG} (absent - defaults)"
fi
printf '  %-16s %s\n' "payload"   "$PAYLOAD_DIR"
[ -n "$SKIP" ] && printf '  %-16s %s\n' "skipping" "$SKIP"
if [ -f "$MANIFEST" ]; then
    # The export stamp is the one line that says WHICH payload this is, and it is
    # the thing a stale copy gets wrong. Print it before anything runs.
    printf '  %-16s %s\n' "manifest" "$(head -1 "$MANIFEST" | sed 's/^# *//')"
else
    printf '  %-16s %s\n' "manifest" "MISSING - ${MANIFEST}"
fi

# ---------------------------------------------------------------------------
# --check: the pre-flight
# ---------------------------------------------------------------------------
# Three-way, because the two failure modes are different and have different
# fixes. GitLab behind the manifest means the VM has not mirrored this payload;
# the clone behind GitLab means this script has not been run. Reporting only
# "mismatch" would leave the operator to work out which, on the box where that is
# hardest to find out.
if [ "$CHECK" -eq 1 ]; then
    if [ ! -f "$MANIFEST" ]; then
        echo "Cannot check: ${MANIFEST} does not exist." >&2
        echo "Copy the payload folder over from the VM first." >&2
        exit 1
    fi
    dsh_kit_settings "$PAYLOAD_DIR" || exit 1
    WORKSPACE="${KIT_WORKSPACE_DIR:-${HOME}/Scratch/${KIT_PROJECT}}"
    if dsh_uses_gitlab; then
        SOURCE="gitlab"
        dsh_no_placeholder KIT_GITLAB_GROUP "$KIT_GITLAB_GROUP" || exit 1
        dsh_gitlab_env "$KIT_GITLAB_HOST" "$KIT_GITLAB_GROUP" "$KIT_WORKING_NAMESPACE"
    else
        SOURCE="bundle"
    fi
    printf '  %-16s %s\n' "workspace" "$WORKSPACE"
    printf '  %-16s %s\n' "source"    "$SOURCE  (KIT_GITLAB=${KIT_GITLAB})"
    echo

    echo "=== Drift: clone HEAD vs MANIFEST vs ${SOURCE} ==="
    printf '  %-26s %-10s %-10s %-10s %s\n' "repo" "here" "manifest" "$SOURCE" "verdict"
    DRIFT=0
    while read -r pkg branch want role _; do
        case "$pkg" in
            ""|"#"*) continue ;;
        esac
        [ "${role:-mirror}" = "working" ] && continue

        dir="${WORKSPACE}/src/${pkg}"
        if [ -d "${dir}/.git" ]; then
            here_sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
        else
            here_sha=""
        fi
        if [ "$SOURCE" = "gitlab" ]; then
            # GIT_TERMINAL_PROMPT=0 so a missing credential is an ANSWER rather than
            # a prompt that hangs a login shell nobody is watching.
            remote_sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$(dsh_repo_remote "$pkg")" \
                          "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')"
        elif [ -f "${PAYLOAD_DIR}/${pkg}.bundle" ]; then
            remote_sha="$(git bundle list-heads "${PAYLOAD_DIR}/${pkg}.bundle" \
                          "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')"
        else
            remote_sha=""
        fi

        if [ -z "$here_sha" ]; then
            verdict="NOT CLONED - run this script without --check"; DRIFT=1
        elif [ -z "$remote_sha" ] && [ "$SOURCE" = "gitlab" ]; then
            verdict="GitLab unreachable or no credential"; DRIFT=1
        elif [ -z "$remote_sha" ]; then
            verdict="no ${pkg}.bundle (or no ${branch} in it) - copy the payload over"; DRIFT=1
        elif [ "$remote_sha" != "$want" ] && [ "$SOURCE" = "gitlab" ]; then
            verdict="GitLab BEHIND - mirror from the VM first"; DRIFT=1
        elif [ "$remote_sha" != "$want" ]; then
            verdict="bundle does not match MANIFEST - payload is inconsistent"; DRIFT=1
        elif [ "$here_sha" != "$want" ]; then
            verdict="clone BEHIND - run this script without --check"; DRIFT=1
        else
            verdict="up to date"
        fi
        printf '  %-26s %-10s %-10s %-10s %s\n' \
               "$pkg" "${here_sha:0:8}" "${want:0:8}" "${remote_sha:0:8}" "$verdict"
    done < "$MANIFEST"
    echo
    if [ "$DRIFT" -eq 0 ]; then
        echo "RESULT: PASS - every mirror repo here is at the commit this payload carries."
        exit 0
    fi
    if [ "$SOURCE" = "gitlab" ]; then
    cat >&2 <<'EOF'
RESULT: DRIFT - the verdict column says which end is behind.

  GitLab BEHIND   run update_dsh_vm.bat on the Desktop VM. Only that box can
                  push the bundles to GitLab-inside; this one only reads it.
  clone BEHIND    bash ./update_dsh_cluster.sh
EOF
    else
    cat >&2 <<'EOF'
RESULT: DRIFT - the verdict column says which end is behind.

  no bundle /     the payload folder here is incomplete or mixed from two
  bundle does     trips. Copy the whole folder over again from the VM, then
  not match       bash ./update_dsh_cluster.sh
  clone BEHIND    bash ./update_dsh_cluster.sh
EOF
    fi
    exit 1
fi
echo

# ---------------------------------------------------------------------------
# The steps
# ---------------------------------------------------------------------------
# Each is echoed before it runs, in a form that can be pasted to run it alone, so
# a failure leaves the operator with a single command to retry rather than a
# wrapper to reverse-engineer.
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

# Only if a zip actually landed here. The usual cluster route is a WinSCP copy of
# the payload FOLDER, which needs no unpacking, so a missing zip is the normal
# case and not a fault.
if skipped unpack; then
    echo "=== 1. Unpack (skipped) ==="
    echo
elif [ -f "${HERE}/DSH_import.zip" ] && [ -f "${HERE}/unpack_payload.sh" ]; then
    run_step "1. Unpack + verify" "$HERE" ./unpack_payload.sh --dest "$PAYLOAD_DIR" --force
else
    echo "=== 1. Unpack (nothing to unpack) ==="
    echo "  No DSH_import.zip beside this script - taking ${PAYLOAD_DIR} as already unpacked."
    echo
fi

if [ ! -f "$MANIFEST" ]; then
    echo "Not found: ${MANIFEST}" >&2
    echo "install_packages.sh asserts every clone against it, so it cannot run without" >&2
    echo "it - and an OLD one fails a run that was otherwise correct. Copy the new" >&2
    echo "MANIFEST.txt over from the VM's payload folder." >&2
    exit 1
fi

# Re-running is the supported update path: existing clones are fetched and
# fast-forwarded rather than re-cloned. Workspace and python come from
# ~/dsh-kit.env, which install_packages.sh reads itself; neither is passed here,
# so a python named once is not re-named on every refresh.
if skipped install; then
    echo "=== 2. Install (skipped) ==="
    echo
else
    run_step "2. Install" "$PAYLOAD_DIR" ./install_packages.sh
fi

if [ "$DRY" -eq 1 ]; then
    echo "Dry run - nothing was executed."
    exit 0
fi

cat <<EOF
=== Done ===

  Logs:
    ${HERE}/Logs/update_dsh_cluster.log
    ${PAYLOAD_DIR}/Logs/install_packages.log

  The step above printed a SHA per mirror repo against MANIFEST.txt and stopped
  if any of them disagreed, so there is nothing further to check by hand. To
  confirm the same thing before a later submission, without changing anything:

    bash ./update_dsh_cluster.sh --check

  Do NOT smoke-test with 'uv run'. In a uv workspace it performs an exact sync
  and uninstalls the optional extras this environment is built with: a check
  that damages what it is checking. Use the venv python directly.
EOF
