#!/bin/bash
# INSIDE. mirror_to_gitlab.sh follow-up - the mirror push said NON-FAST-FORWARD.
#
# Symptom this exists for: mirror_to_gitlab.sh --refresh fetches the new bundle
# fine, then
#
#   ! [rejected]        master -> master (non-fast-forward)
#   error: failed to push some refs to https://gitlab.../<repo>.git
#
# That is not a policy refusal (that would say "pre-receive hook declined") and
# not credentials. It means GitLab's branch holds commits that are NOT in the
# bundle. The bundle's history only ever moves forward - the refresh fetch is
# not forced, so a rewrite outside would have failed there instead - so those
# commits were MADE INSIDE: a web-UI edit, a push from the workspace clone, or an
# import-from-outside merge request merged as a squash or a merge commit.
#
# diagnose_push_rejection.sh lists the commits WE are pushing. This lists the
# ones GITLAB has and we do not, and says whether their content is already in
# the bundle (safe to overwrite) or is real inside work (rescue it first).
#
# READ-ONLY on GitLab. It fetches into the payload-side clone's origin/* refs
# and changes nothing else - no push, no checkout, no reset.
#
#   ./diagnose/diagnose_gitlab_divergence.sh        # host and group from dsh-kit.conf
#   ./diagnose/diagnose_gitlab_divergence.sh --repo <repo>
#
# With no --repo it checks every repo in MANIFEST.txt, because the mirror stops
# at the first failure and the ones after it were never tried.
#
# Log: Logs/diagnose_gitlab_divergence.log at the payload root.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

# The payload ROOT: this script lands in DSH_import/diagnose/.
PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

# shellcheck source=../../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"
dsh_git_guard || exit 1

dsh_kit_settings "$PAYLOAD_DIR" || exit 1
dsh_gitlab_only "$(basename "$0")" || exit 0
GITLAB_HOST="$KIT_GITLAB_HOST"
GROUP="$KIT_GITLAB_GROUP"
# Working repos may live in another namespace - see dsh_repo_namespace in
# dsh_platform.sh. Empty means "same as the group".
WORKING_NAMESPACE="$KIT_WORKING_NAMESPACE"
REPO=""
DEST="$PAYLOAD_DIR"

usage() {
    sed -n '2,30p' "$0"
    echo
    echo "Usage: $0 --gitlab HOST --group GROUP [--repo NAME] [--dest DIR]"
    echo "          [--working-namespace NS]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab) GITLAB_HOST="$2"; shift 2 ;;
        --group)  GROUP="$2";       shift 2 ;;
        --repo)   REPO="$2";        shift 2 ;;
        --dest)   DEST="$2";        shift 2 ;;
        --working-namespace) WORKING_NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$GROUP" ] || { echo "Error: no GitLab group - set KIT_GITLAB_GROUP or pass --group" >&2; usage; }

dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
NS_ARG="$(dsh_working_ns_arg)"

MANIFEST="${PAYLOAD_DIR}/MANIFEST.txt"
[ -f "$MANIFEST" ] || { echo "Error: $MANIFEST not found" >&2; exit 1; }

DIVERGED=""
OVERWRITABLE=""

# $1 pkg  $2 branch  $3 manifest sha
check_repo() {
    local pkg="$1" branch="$2" sha="$3"
    local target="${DEST}/${pkg}"

    echo
    echo "=== ${pkg} (${branch}) ==="
    if [ ! -d "${target}/.git" ]; then
        echo "  no clone at ${target} - mirror never reached it; nothing to compare"
        return
    fi

    local remote
    remote="$(dsh_repo_remote "$pkg")" || return
    if ! git -C "$target" fetch -q "$remote" "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>"${PAYLOAD_DIR}/.fetch.err"; then
        echo "  fetch from GitLab FAILED - not a divergence problem:"
        sed 's/^/    /' "${PAYLOAD_DIR}/.fetch.err"
        rm -f "${PAYLOAD_DIR}/.fetch.err"
        return
    fi
    rm -f "${PAYLOAD_DIR}/.fetch.err"

    local theirs ours
    theirs="$(git -C "$target" rev-parse "refs/remotes/origin/${branch}" 2>/dev/null || echo NONE)"
    ours="$(git -C "$target" rev-parse "refs/heads/${branch}")"
    echo "  manifest:   ${sha}"
    echo "  local:      ${ours}"
    echo "  GitLab:     ${theirs}"

    if [ "$theirs" = "NONE" ]; then
        echo "  GitLab has no ${branch} - first push, cannot be non-fast-forward"
        return
    fi
    if git -C "$target" merge-base --is-ancestor "$theirs" "$ours"; then
        echo "  OK - fast-forward, GitLab is behind us and the push will go through"
        return
    fi

    DIVERGED="${DIVERGED} ${pkg}"
    local base
    base="$(git -C "$target" merge-base "$theirs" "$ours" || echo NONE)"
    if [ "$base" = "NONE" ]; then
        # No shared history at all: the GitLab project was created with its own
        # root commit (a README or licence from the "new project" form).
        echo "  UNRELATED HISTORIES - GitLab's ${branch} shares no commit with the bundle."
        echo "  The project was almost certainly created non-empty. What it holds:"
        git -C "$target" log --format='    %h  %ad  %an  %s' --date=short "$theirs" | head -10
        DIVERGED="${DIVERGED} ${pkg}"
        OVERWRITABLE="${OVERWRITABLE} ${pkg}"
        return
    fi
    echo "  DIVERGED - common ancestor ${base:0:12}"
    echo
    echo "  Commits on GitLab and NOT in the bundle (made inside):"
    git -C "$target" log --format='    %h  %ad  %an <%ae>%n          %s' --date=short \
        "${ours}..${theirs}"
    echo
    echo "  Files they touch:"
    git -C "$target" diff --stat=100 "${base}" "${theirs}" | sed 's/^/    /'

    # Does the bundle already hold what those commits changed? Compare GitLab's
    # tip against ours on exactly the files the inside commits touched. Empty
    # means the inside commits carry nothing the bundle lacks - typically a
    # squash/merge commit from an import-from-outside MR.
    local files leftover
    files="$(git -C "$target" diff --name-only "${base}" "${theirs}")"
    if [ -z "$files" ]; then
        leftover=""
    else
        # shellcheck disable=SC2086
        leftover="$(git -C "$target" diff --stat=100 "${ours}" "${theirs}" -- $files)"
    fi
    echo
    if [ -z "$leftover" ]; then
        echo "  CONTENT CHECK: every file those commits touched is IDENTICAL in the"
        echo "  bundle. The inside commits add nothing - overwriting loses no work."
        OVERWRITABLE="${OVERWRITABLE} ${pkg}"
    else
        echo "  CONTENT CHECK: these files DIFFER between GitLab and the bundle -"
        echo "  this is inside work the bundle does not have:"
        echo "$leftover" | sed 's/^/    /'
        echo "  Full diff (GitLab -> bundle) for those files:"
        # shellcheck disable=SC2086
        git -C "$target" diff "${theirs}" "${ours}" -- $files | head -200 | sed 's/^/    /'
    fi
}

while read -r pkg branch sha _role <&3; do
    case "$pkg" in ''|'#'*) continue ;; esac
    [ -n "$REPO" ] && [ "$pkg" != "$REPO" ] && continue
    check_repo "$pkg" "$branch" "$sha"
done 3< "$MANIFEST"

echo
echo "=== Verdict ==="
if [ -z "$DIVERGED" ]; then
    echo "  Nothing diverged. Re-run the mirror:"
    echo "      ./mirror_to_gitlab.sh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG} --refresh"
    exit 0
fi

for pkg in $DIVERGED; do
    branch="$(awk -v p="$pkg" '$1==p {print $2}' "$MANIFEST")"
    theirs="$(git -C "${DEST}/${pkg}" rev-parse "refs/remotes/origin/${branch}")"
    echo
    case " $OVERWRITABLE " in
        *" $pkg "*)
            echo "  ${pkg}: SAFE TO OVERWRITE - the inside commits hold nothing new."
            echo "    1. GitLab > ${pkg} > Settings > Repository > Protected branches >"
            echo "       ${branch}: turn 'Allowed to force push' ON."
            echo "    2. From ${PAYLOAD_DIR}:"
            echo "       git -C ${pkg} push --force-with-lease=${branch}:${theirs} origin ${branch}"
            echo "       (the lease pins GitLab's current tip, so it refuses if anything"
            echo "        else landed on GitLab since this check)"
            echo "    3. Turn 'Allowed to force push' back OFF."
            ;;
        *)
            echo "  ${pkg}: REAL INSIDE WORK - do NOT overwrite."
            echo "    The diff above is work that exists only on GitLab. It has to go"
            echo "    out through the airlock (outgoing review), be committed on GitHub,"
            echo "    and come back in the next payload. Until then, keep it safe on a"
            echo "    branch so a later force push cannot lose it:"
            echo "       git -C ${PAYLOAD_DIR}/${pkg} push origin ${theirs}:refs/heads/inside-work-${theirs:0:8}"
            echo "    Then overwrite ${branch} as in the SAFE case, or wait for the work"
            echo "    to come back round from GitHub."
            ;;
    esac
done
echo
echo "  Then finish the mirror:"
echo "      ./mirror_to_gitlab.sh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG} --refresh"
exit 1
