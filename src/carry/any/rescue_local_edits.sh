#!/bin/bash
# INSIDE (both boxes). A refresh (mirror or install) dies because a checkout was EDITED here.
#
# Symptom this exists for: the VM was set up, the code was used, and now a refresh
# stops. Nobody has to type a git command for this to happen: a notebook tool that
# SAVES as you drive it (marimo, Jupyter with autosave), or anything that writes a
# tracked file, is enough to modify the working tree.
#
# It surfaces in one of two places, and NEITHER message says "you have local edits":
#
#   mirror_to_gitlab.sh --refresh, in ~/DSH_import/<repo> (GitLab mode only):
#       error: Your local changes to the following files would be overwritten by
#       checkout: ...
#     ...from the `git checkout "$branch"` that follows the detach. That script is
#     set -e, so it stops there, having mirrored the repos before this one and not
#     the ones after.
#
#   install_packages.sh, in <workspace>/src/<repo>:
#       <pkg>: pull --ff-only FAILED - this clone is NOT being updated
#     (GitLab mode), or "has local edits to tracked files" / "cannot fast-forward
#     to the payload's <branch>" (bundle mode), then "RESULT: FAIL - what is
#     checked out is not what this payload carries". Its last suggestion, "delete
#     <repo> and re-run", DESTROYS the edits.
#
# That last point is why this script exists rather than a `git checkout -- .`:
# nothing edited on this VM can be recovered from outside it. So the edits are
# COMMITTED to a local rescue branch first, and only then is the tracked branch put
# back to what the payload carries. Nothing is deleted and nothing is pushed - the
# rescue branch stays on this VM, in this clone, and `git log dsh-local/<stamp>`
# has it whenever you want it back.
#
# Untracked files are NOT touched, and gitignored ones (Configuration_files/, .env,
# Results/) are not affected at all - they are why a rebuild does not lose config.
#
# MIRROR REPOS ONLY. MANIFEST.txt's fourth column says what each repo is for, and a
# repo marked `working` (KIT_WORKING_REPOS - the one you edit inside) is reported
# and then left completely alone. Its edits are the point of it, and nothing asserts
# its HEAD, so it cannot be what blocked you. A refresh handles that repo itself: if
# the payload carries it, install_packages.sh parks the edits on dsh-local/<stamp> and
# overwrites; if it does not, they are simply left where they are.
#
#   ./rescue_local_edits.sh                  # report only; changes nothing
#   ./rescue_local_edits.sh --rescue         # park the edits, restore the branches
#   ./rescue_local_edits.sh --repo <repo> --rescue
#
# Report first. It names every checkout it can see, both copies of each repo, and
# says which one is actually blocking - run it with --rescue once you have read it.
#
# Log: Logs/rescue_local_edits.log beside this script.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/dsh_log.sh
. "${SELF_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

PAYLOAD_DIR="$SELF_DIR"
WORKSPACE=""
CONFIG="${DSH_KIT_ENV:-${HOME}/dsh-kit.env}"
ONLY_REPO=""
RESCUE=0

usage() {
    cat <<'USAGE'
Usage: ./rescue_local_edits.sh [options]

  --rescue          park local edits on a branch and restore the tracked branch.
                    Without it, this script only reports.
  --repo NAME       just this repo, instead of every one in MANIFEST.txt
  --workspace DIR   workspace root, instead of KIT_WORKSPACE_DIR from ~/dsh-kit.env
  --payload DIR     payload directory (default: this script's own directory)
  --config FILE     read per-machine settings from FILE instead of ~/dsh-kit.env
USAGE
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rescue)    RESCUE=1; shift ;;
        --repo)      ONLY_REPO="$2"; shift 2 ;;
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --payload)   PAYLOAD_DIR="$2"; shift 2 ;;
        --config)    CONFIG="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# shellcheck source=lib/dsh_platform.sh
. "${SELF_DIR}/lib/dsh_platform.sh"
# Every check below is a git command, and on this VM they all fail as "permission
# denied" until the ceiling is set - which would read here as "not a git repo".
dsh_git_guard || exit 1

if [ -z "$WORKSPACE" ]; then
    KIT_WORKSPACE_DIR=""
    dsh_load_machine_env "$CONFIG"
    WORKSPACE="${KIT_WORKSPACE_DIR:-}"
fi

[ -d "$PAYLOAD_DIR" ] && PAYLOAD_DIR="$(cd "$PAYLOAD_DIR" && pwd)"

# GitLab or bundle mode, from the payload's dsh-kit.conf. Only decides which copies
# exist and what the advice at the end says; the rescue itself is the same. With
# no readable conf, both kinds of copy are looked at.
USE_GITLAB="unknown"
KIT_GITLAB=""
if [ -f "${PAYLOAD_DIR}/dsh-kit.conf" ]; then
    _ws="$WORKSPACE"
    if dsh_kit_settings "$PAYLOAD_DIR" >/dev/null 2>&1; then
        if dsh_uses_gitlab; then USE_GITLAB="yes"; else USE_GITLAB="no"; fi
    fi
    WORKSPACE="$_ws"
    # The same default install_packages.sh uses on Linux, so the cluster's
    # workspace is checked without --workspace.
    if [ -z "$WORKSPACE" ] && [ "$DSH_OS" = "linux" ] && [ -n "${KIT_PROJECT:-}" ]; then
        WORKSPACE="${HOME}/Scratch/${KIT_PROJECT}"
    fi
fi

# One stamp for the whole run, so every branch this parks work on is named for the
# same rescue and they can be found together.
STAMP="$(date '+%Y%m%d-%H%M%S')"
RESCUE_BRANCH="dsh-local/${STAMP}"

MANIFEST="${PAYLOAD_DIR}/MANIFEST.txt"
if [ ! -f "$MANIFEST" ]; then
    echo "Error: ${MANIFEST} not found." >&2
    echo "  Run this from the payload directory, or pass --payload DIR." >&2
    exit 1
fi

echo "=== rescue_local_edits.sh ==="
printf '  %-14s %s\n' "payload"   "$PAYLOAD_DIR"
printf '  %-14s %s\n' "workspace" "${WORKSPACE:-<not set - workspace clones NOT checked>}"
if [ "$RESCUE" -eq 1 ]; then
    printf '  %-14s %s\n' "mode"   "RESCUE (this run writes)"
    printf '  %-14s %s\n' "branch" "$RESCUE_BRANCH"
else
    printf '  %-14s %s\n' "mode"   "report only (nothing will be changed)"
fi
echo

BLOCKED=0
PARKED=0

# ---------------------------------------------------------------------------
# One checkout.
#   $1 label   $2 directory   $3 the branch MANIFEST.txt says this repo is on
#   $4 role    mirror (default) or working
# ---------------------------------------------------------------------------
examine() {
    local label="$1" dir="$2" branch="$3" role="${4:-mirror}"
    local head_desc dirty untracked ahead target unpushed upstream

    if [ ! -d "$dir" ]; then
        printf '  %-38s -\n' "$label"
        return 0
    fi
    if [ ! -d "${dir}/.git" ]; then
        printf '  %-38s NOT A GIT REPO\n' "$label"
        return 0
    fi

    # --detach leaves no branch name, and a mirror run that died at its checkout
    # leaves exactly that. Say so: a detached HEAD here is itself a finding.
    if head_desc="$(git -C "$dir" symbolic-ref --quiet --short HEAD)"; then
        :
    else
        head_desc="DETACHED at $(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    fi

    dirty="$(git -C "$dir" status --porcelain --untracked-files=no)"
    untracked="$(git -C "$dir" status --porcelain --untracked-files=normal | grep -c '^??' || true)"
    # What the payload last delivered for this branch: origin/<branch> in a GitLab
    # clone, refs/outside/<branch> in a clone fed from bundles (install_packages.sh
    # fetches there, and a bundle clone keeps no origin).
    ahead=0
    upstream=""
    if git -C "$dir" rev-parse --quiet --verify "refs/remotes/origin/${branch}" > /dev/null 2>&1; then
        upstream="origin/${branch}"
    elif git -C "$dir" rev-parse --quiet --verify "refs/outside/${branch}" > /dev/null 2>&1; then
        upstream="refs/outside/${branch}"
    fi
    if [ -n "$upstream" ]; then
        ahead="$(git -C "$dir" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
    fi

    if [ -z "$dirty" ] && [ "$ahead" = "0" ] && [ "$head_desc" = "$branch" ]; then
        printf '  %-38s clean, on %s\n' "$label" "$branch"
        if [ "$untracked" -gt 0 ]; then
            printf '  %-38s   (%s untracked file(s), left alone)\n' "" "$untracked"
        fi
        return 0
    fi

    # A working repo is SUPPOSED to look like this. Its working tree is never
    # touched by a refresh, nothing is asserted about its HEAD, and parking its
    # edits would take away the very thing it exists to hold. Report and move on.
    if [ "$role" = "working" ]; then
        printf '  %-38s working repo - edits expected, left alone\n' "$label"
        printf '      %-18s %s\n' "HEAD" "$head_desc"
        if [ -n "$dirty" ]; then
            echo "      modified tracked files:"
            printf '%s\n' "$dirty" | sed 's/^/        /'
        fi
        # NOT `ahead of origin/<manifest branch>`: work here lives on its own branch,
        # so measuring it against the mirror branch counts the wrong thing. What
        # matters is commits that exist on this disk and nowhere else - HEAD minus
        # everything origin already has, whichever branch holds it.
        if [ "$upstream" = "origin/${branch}" ]; then
            unpushed="$(git -C "$dir" rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo 0)"
        else
            unpushed="$(git -C "$dir" rev-list --count HEAD --not --glob='refs/outside/*' 2>/dev/null || echo 0)"
        fi
        if [ "$unpushed" != "0" ]; then
            printf '      %-18s %s commit(s) exist only on this VM\n' "not from outside" "$unpushed"
            printf '      %s\n' "and only on this disk - nothing pushes them anywhere by design."
        fi
        echo
        return 0
    fi

    BLOCKED=$((BLOCKED + 1))
    printf '  %-38s BLOCKS THE REFRESH\n' "$label"
    printf '      %-18s %s\n' "HEAD" "$head_desc"
    printf '      %-18s %s\n' "payload wants" "$branch"
    printf '      %-18s %s commit(s)\n' "ahead of payload" "$ahead"
    if [ -n "$dirty" ]; then
        echo "      modified tracked files:"
        printf '%s\n' "$dirty" | sed 's/^/        /'
    else
        echo "      modified tracked files: none"
    fi
    if [ "$untracked" -gt 0 ]; then
        printf '      %-18s %s (left alone)\n' "untracked" "$untracked"
    fi

    if [ "$RESCUE" -eq 0 ]; then
        echo "      -> re-run with --rescue to park this and restore ${branch}"
        echo
        return 0
    fi

    # -----------------------------------------------------------------------
    # Park. Order matters: commit BEFORE anything that can discard.
    # -----------------------------------------------------------------------
    echo "      parking on ${RESCUE_BRANCH}"
    # -B from wherever HEAD is, so this works detached, and works when an earlier
    # rescue in the same second already took the name.
    if ! git -C "$dir" checkout -q -B "$RESCUE_BRANCH"; then
        echo "      ERROR: could not create ${RESCUE_BRANCH}. Nothing changed here." >&2
        echo
        return 1
    fi
    if [ -n "$dirty" ]; then
        # -u only: tracked modifications and deletions. Untracked files are not
        # swept in, because that is how a multi-gigabyte Results/ database ends up
        # in a commit, and they do not block a fast-forward anyway.
        git -C "$dir" add -u
        # A fresh account inside has no user.name / user.email and git refuses to
        # commit without them. Supply one only if none is configured.
        ident=()
        git -C "$dir" config user.name  >/dev/null 2>&1 || ident+=(-c "user.name=dsh-kit")
        git -C "$dir" config user.email >/dev/null 2>&1 || ident+=(-c "user.email=dsh-kit@localhost")
        if ! git ${ident[@]+"${ident[@]}"} -C "$dir" commit -q -F - <<COMMITMSG
Local edits made on the DSH VM, parked by rescue_local_edits.sh

Made in ${dir} between payload refreshes - often by a notebook that saves itself
as it is driven. Parked here so the tracked branch could be put back to the
commit MANIFEST.txt pins; nothing was discarded.

Recover with:  git -C '${dir}' checkout ${RESCUE_BRANCH}
COMMITMSG
        then
            echo "      ERROR: commit failed. Nothing discarded; you are on ${RESCUE_BRANCH}." >&2
            echo
            return 1
        fi
    fi

    # Assert the park worked before anything destructive runs. A clean tree on the
    # rescue branch is the proof; without it, stop and leave the edits alone.
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
        echo "      ERROR: still dirty after committing. Stopping BEFORE restoring ${branch}." >&2
        echo "      The edits are intact in the working tree. Nothing was discarded." >&2
        echo
        return 1
    fi
    printf '      parked as %s\n' "$(git -C "$dir" rev-parse --short HEAD)"
    PARKED=$((PARKED + 1))

    # -----------------------------------------------------------------------
    # Restore the tracked branch to what the payload carries.
    # -----------------------------------------------------------------------
    if [ -n "$upstream" ]; then
        target="$upstream"
    elif git -C "$dir" rev-parse --quiet --verify "refs/heads/${branch}" > /dev/null 2>&1; then
        # The payload-directory mirror clone has no useful origin - it is fed from
        # the bundle, not fetched. Its own branch ref is the right target;
        # mirror_to_gitlab.sh --refresh moves it forward from the new bundle
        # immediately after this.
        target="refs/heads/${branch}"
    else
        echo "      ERROR: no ${branch} here, local or remote. Left on ${RESCUE_BRANCH}." >&2
        echo
        return 1
    fi
    if ! git -C "$dir" checkout -q -B "$branch" "$target"; then
        echo "      ERROR: could not restore ${branch} from ${target}." >&2
        echo "      The edits are safe on ${RESCUE_BRANCH}." >&2
        echo
        return 1
    fi
    printf '      %s restored to %s (%s)\n' "$branch" "$target" "$(git -C "$dir" rev-parse --short HEAD)"
    echo
    return 0
}

# ---------------------------------------------------------------------------
# Both copies of every repo. There are two of each on this VM and they fail at
# different steps, so checking one and declaring victory is how the second one is
# met an hour later.
# ---------------------------------------------------------------------------
# In bundle mode (KIT_GITLAB=no) there are no payload-directory clones - nothing
# mirrors to GitLab - so only the workspace copy is looked at.
if [ "$USE_GITLAB" != "no" ]; then
echo "=== Mirror clones, beside the payload (mirror_to_gitlab.sh reads these) ==="
while read -r pkg branch sha role; do
    case "$pkg" in ''|'#'*) continue ;; esac
    if [ -n "$ONLY_REPO" ] && [ "$ONLY_REPO" != "$pkg" ]; then continue; fi
    # The payload-directory clones are mirrors whatever the repo is FOR: nothing
    # edits them, so a working repo mirrors here exactly like the others.
    examine "$pkg" "${PAYLOAD_DIR}/${pkg}" "$branch" mirror
done < "$MANIFEST"
echo
fi

if [ -n "$WORKSPACE" ]; then
    echo "=== Workspace clones, in ${WORKSPACE}/src (install_packages.sh reads these) ==="
    while read -r pkg branch sha role; do
        case "$pkg" in ''|'#'*) continue ;; esac
        if [ -n "$ONLY_REPO" ] && [ "$ONLY_REPO" != "$pkg" ]; then continue; fi
        examine "$pkg" "${WORKSPACE}/src/${pkg}" "$branch" "${role:-mirror}"
    done < "$MANIFEST"
    echo
else
    echo "=== Workspace clones: NOT CHECKED ==="
    echo "  KIT_WORKSPACE_DIR is not set in ${CONFIG} and --workspace was not given,"
    echo "  so the clones install_packages.sh actually installs from were not looked"
    echo "  at. That is where work happens, so it is the likely one. Re-run with --workspace."
    echo
fi

# ---------------------------------------------------------------------------
echo "=== Result ==="
if [ "$BLOCKED" -eq 0 ]; then
    echo "  PASS - nothing found here blocks a refresh."
    echo
    echo "  So the failure is something else. Take install_packages.log's own"
    if [ "$USE_GITLAB" = "no" ]; then
        echo "  causes in its order: a bundle missing from this payload (./verify_payload.sh),"
        echo "  or a repo that was never carried in at all."
    else
        echo "  causes in its order: GitLab not refreshed from THIS payload, the GitLab"
        echo "  project missing, or a clone that has genuinely diverged."
    fi
    exit 0
fi

if [ "$RESCUE" -eq 0 ]; then
    echo "  ${BLOCKED} checkout(s) would block the refresh. NOTHING WAS CHANGED."
    echo
    echo "  Park them and restore the tracked branches:"
    echo "    ./rescue_local_edits.sh --rescue"
    exit 1
fi

echo "  ${PARKED} of ${BLOCKED} checkout(s) parked on ${RESCUE_BRANCH}."
echo
if [ "$PARKED" -lt "$BLOCKED" ]; then
    echo "  Some did not complete - see the ERROR lines above. Do not re-run the" >&2
    echo "  refresh until they do; nothing was discarded either way." >&2
    exit 1
fi
echo "  Nothing was discarded and nothing was pushed. To see the parked work:"
echo "    git -C <the checkout> log --stat ${RESCUE_BRANCH}"
echo "    git -C <the checkout> show ${RESCUE_BRANCH}"
echo
echo "  Now re-run the refresh:"
echo "    bash ./update_dsh_vm.sh"
echo
echo "  If those edits were meant to last, they have to be made in the repo OUTSIDE"
echo "  and come back in the next payload. A commit made here never reaches the outside, so"
echo "  the next refresh will park it again."
