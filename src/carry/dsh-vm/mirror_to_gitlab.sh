#!/bin/bash
# INSIDE. Clone the bundles and push them to GitLab-inside.
#
# Run from the directory the airlock payload landed in (the one holding the
# .bundle files and MANIFEST.txt).
#
#   ./mirror_to_gitlab.sh                       # host and group from dsh-kit.conf
#   ./mirror_to_gitlab.sh --refresh             # every trip after the first
#   ./mirror_to_gitlab.sh --gitlab <host> --group <group>   # override the conf
#
# FIRST TIME: create the projects in GitLab first, and create them EMPTY - no
# README, no initial commit. An initial commit makes the first push a
# non-fast-forward and you will be fighting it.
#
# REFRESHING an existing mirror: pass --refresh. Existing clones are then
# fetched forward from the new bundles and re-pushed, instead of being skipped.
# Without it, an existing clone directory is left alone and the checkpoint below
# will flag it as a mismatch against the new manifest - which is the point: a
# silent skip is how a stale mirror survives a "successful" run.
#
# Afterwards, protect the default branch in GitLab and restrict push to
# yourself. Otherwise someone commits inside, it never reaches the outside, and
# "this SHA means the same thing on both sides" is quietly dead.

set -euo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    echo "(sourcing it makes its 'exit' close your terminal)" >&2
    return 1 2>/dev/null || exit 1
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log to a file as well as the terminal. A push that GitLab declines explains
# itself on `remote:` lines, and those are the whole diagnosis - they should not
# live only in a scrollback buffer.
# shellcheck source=../any/lib/dsh_log.sh
. "${SELF_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

PAYLOAD_DIR="$SELF_DIR"
# shellcheck source=../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"
dsh_kit_settings "$PAYLOAD_DIR" || exit 1

# Defaults from dsh-kit.conf / ~/dsh-kit.env; the flags below override them.
GITLAB_HOST="$KIT_GITLAB_HOST"
GROUP="$KIT_GITLAB_GROUP"
WORKING_NAMESPACE="$KIT_WORKING_NAMESPACE"
DEST="."
REFRESH="no"

usage() {
    echo "Usage: $0 [--refresh] [--gitlab HOST] [--group GROUP] [--dest DIR]"
    echo
    echo "  --gitlab HOST   internal GitLab host (default from the conf: ${KIT_GITLAB_HOST})"
    echo "  --group  GROUP  the group the projects live under (default: ${KIT_GITLAB_GROUP})"
    echo "  --dest   DIR    where to put the clones (default: current directory)"
    echo "  --refresh       fetch existing clones forward from the new bundles"
    echo "                  and re-push, rather than skipping them"
    echo "  --working-namespace NS  the namespace the working repos live in"
    echo "                  (default: KIT_WORKING_NAMESPACE, or the group)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab) GITLAB_HOST="$2"; shift 2 ;;
        --group)  GROUP="$2";       shift 2 ;;
        --dest)   DEST="$2";        shift 2 ;;
        --refresh) REFRESH="yes";   shift 1 ;;
        --working-namespace) WORKING_NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$GITLAB_HOST" ] || { echo "Error: no GitLab host - set KIT_GITLAB_HOST or pass --gitlab" >&2; usage; }
[ -n "$GROUP" ]       || { echo "Error: no GitLab group - set KIT_GITLAB_GROUP or pass --group" >&2; usage; }
dsh_no_placeholder KIT_GITLAB_GROUP "$GROUP" || exit 1

# Every command below is git. If git cannot walk out of this directory, all of
# them fail as "permission denied" and none of them ever reach GitLab.
dsh_git_guard || exit 1

# Publish --gitlab / --group / --working-namespace for dsh_repo_remote, which
# reads them from the environment so that one function assembles every URL in
# every carried script. NS_ARG is the flag to repeat on the commands this script
# suggests running next; empty when both namespaces are the same.
dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
NS_ARG="$(dsh_working_ns_arg)"

MANIFEST="${PAYLOAD_DIR}/MANIFEST.txt"
[ -f "$MANIFEST" ] || { echo "Error: $MANIFEST not found - run this from the payload directory" >&2; exit 1; }

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

echo "Mirroring to https://${GITLAB_HOST}/${GROUP}/  ->  clones in ${DEST}"
if [ -n "$NS_ARG" ] && [ -n "$KIT_WORKING_REPOS" ]; then
    echo "  working repos (${KIT_WORKING_REPOS}) go to https://${GITLAB_HOST}/${WORKING_NAMESPACE}/ instead"
fi
echo

# Driven off MANIFEST.txt so each repo is cloned at its own default branch.
#
# The -b "$branch" is essential. `git bundle create --branches --tags` does not
# record HEAD, so a plain `git clone x.bundle` warns "remote HEAD refers to
# nonexistent ref, unable to checkout" and leaves an EMPTY working tree - the
# history is all there, but no files. Repos do not agree on master vs main,
# which is why we read the branch rather than assume it.
#
# `role` is read but not acted on HERE, and that is deliberate. These clones live
# beside the payload and nothing ever edits them, so a working repo mirrors exactly
# like the others and its default branch on GitLab stays what the bundle carried.
# The role matters one directory later, in the WORKSPACE clone, which is the one
# that gets edited - install_packages.sh is where it is honoured.
#
# It is read rather than ignored because `read -r pkg branch sha` would otherwise
# swallow the fourth column into `sha` and every checkpoint below would mismatch.
while read -r pkg branch sha role <&3; do
    case "$pkg" in ''|'#'*) continue ;; esac

    bundle="${PAYLOAD_DIR}/${pkg}.bundle"
    [ -f "$bundle" ] || { echo "Error: $bundle not found" >&2; exit 1; }

    target="${DEST}/${pkg}"
    remote="$(dsh_repo_remote "$pkg")"

    if [ -e "$target" ]; then
        if [ "$REFRESH" != "yes" ]; then
            echo "Skipping ${pkg}: ${target} already exists (pass --refresh to update it)"
            continue
        fi
        [ -d "${target}/.git" ] || { echo "Error: ${target} exists but is not a git repo" >&2; exit 1; }
        echo "Refreshing ${pkg} from the new bundle"
        # A bundle is a valid remote. Fetching refs/heads/* out of it moves the
        # existing clone forward to the exported commit without re-cloning, and
        # fails loudly rather than silently if the new history is not a
        # fast-forward of the old one.
        #
        # DETACH FIRST. git refuses to fetch straight into a branch that is
        # checked out - "refusing to fetch into branch refs/heads/master,
        # checked out at ..." - so a refresh of an existing clone dies here
        # while the very same command works on a fresh one. Detaching HEAD
        # means no branch is checked out and the refspec updates cleanly; the
        # checkout below puts it back. Deliberately NOT forced: a non-fast-
        # forward still has to fail loudly, which is the point of the fetch.
        git -C "$target" checkout -q --detach
        git -C "$target" fetch "$bundle" 'refs/heads/*:refs/heads/*' --tags
        git -C "$target" checkout -q "$branch"
        git -C "$target" reset -q --hard "$branch"
    else
        git clone -b "$branch" "$bundle" "$target"
    fi

    git -C "$target" remote remove origin 2>/dev/null || true
    git -C "$target" remote add origin "$remote"
    if ! git -C "$target" push --all origin; then
        echo
        echo "Push of ${pkg} was refused. If the lines above say 'pre-receive hook" >&2
        echo "declined', GitLab refused on POLICY - the push authenticated and" >&2
        echo "arrived, so this is not credentials or TLS. The commonest cause is a" >&2
        echo "protected default branch, which must let the mirror through before" >&2
        echo "this can run. Sort that out and re-run; repos after this one have not" >&2
        echo "been mirrored," >&2
        echo "because this stops at the first failure." >&2
        echo "  ./diagnose/diagnose_push_rejection.sh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG} --repo ${pkg}" >&2
        exit 1
    fi
    git -C "$target" push --tags origin

    echo "Mirrored ${pkg} (${branch})"
    echo
done 3< "$MANIFEST"

# Checkpoint - the mirror is faithful. If the SHAs match, a commit SHA means
# the same thing on both sides of the airlock, which is the entire point of
# using bundles rather than copying files.
echo "=== Checkpoint: cloned HEAD vs manifest ==="
fail=0
while read -r pkg branch sha role; do
    case "$pkg" in ''|'#'*) continue ;; esac
    actual="$(git -C "${DEST}/${pkg}" rev-parse HEAD 2>/dev/null || echo MISSING)"
    if [ "$actual" = "$sha" ]; then
        printf '  %-26s %s  OK\n' "$pkg" "${sha:0:8}"
    else
        printf '  %-26s expected %s got %s  MISMATCH\n' "$pkg" "${sha:0:8}" "${actual:0:8}"
        fail=1
    fi
done < "$MANIFEST"

echo
if [ "$fail" -eq 0 ]; then
    echo "All repos match the manifest."
    echo
    echo "Now in GitLab: protect the default branch on each project and restrict"
    echo "push to yourself, so the inside stays a read-only mirror."
    echo
    echo "Next, first trip: ./install_uv.sh, then ./check_venv_location.sh,"
    echo "      then ./install_packages.sh --workspace <workspace-dir>"
    echo "Next, a refresh:  ./install_packages.sh   (workspace from ~/dsh-kit.env)"
else
    echo "MISMATCH - do not continue. The clone does not match what was exported." >&2
    exit 1
fi
