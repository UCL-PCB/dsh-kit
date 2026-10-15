#!/bin/bash
# INSIDE. mirror_to_gitlab.sh follow-up - GitLab said "pre-receive hook declined".
#
# Symptom this exists for: mirror_to_gitlab.sh clones and fetches fine, then
#
#   remote: GitLab: <a reason>
#   ! [remote rejected] master -> master (pre-receive hook declined)
#   error: failed to push some refs to https://gitlab.../<repo>.git
#
# "pre-receive hook declined" is GitLab refusing on policy, NOT a network,
# credential or TLS problem - the push authenticated and arrived. The reason is
# always on the `remote:` line above, and there are four families of it:
#
#   A. PROTECTED BRANCH. The default branch is protected and this account is not
#      in "Allowed to push". Being project Owner does not help if the setting
#      says Maintainers-or-no-one. Fix in the UI, or push a side branch and
#      merge - both below.
#   B. PUSH RULE ON THE COMMITS. Commit author not a GitLab user, commit message
#      pattern, unsigned commits. These inspect the NEW commits, which is why
#      a repo with no new history can push clean beside one that is declined. Cannot be
#      fixed by rewriting history here: those SHAs are what MANIFEST.txt pins.
#   C. PUSH RULE ON THE CONTENT. File size cap, forbidden filename, secret
#      detection. Names the offending file.
#   D. A custom server-side hook (LFS, a DSH-local policy). The reason is
#      whatever the hook prints.
#
# READ-ONLY except that it RE-ATTEMPTS THE PUSH THAT ALREADY FAILED. That push
# was declined, so nothing on GitLab changed and nothing will; if it now
# succeeds, that is the fix confirming itself.
#
#   ./diagnose_push_rejection.sh        # host and group from dsh-kit.conf
#   ./diagnose_push_rejection.sh --repo <repo>
#
# Log: Logs/diagnose_push_rejection.log beside this script. The remote's exact words
# are captured there verbatim - that wording IS the diagnosis.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

# The payload ROOT: this script lands in DSH_import/diagnose/, and everything
# it reaches for - lib/, the workspace, the other scripts - is named from there.
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
REPO="${KIT_REPOS%% *}"
DEST="$PAYLOAD_DIR"

usage() {
    sed -n '2,35p' "$0"
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
# A working repo can resolve from --working-namespace alone, so the requirement
# is that the URL resolves, not that the group is set.
if [ -z "$GROUP" ] && [ -z "$WORKING_NAMESPACE" ]; then
    echo "Error: no GitLab group - set KIT_GITLAB_GROUP or pass --group" >&2
    usage
fi

# Publish --gitlab / --group / --working-namespace for dsh_repo_remote, which
# reads them from the environment so that one function assembles every URL in
# every carried script. NS_ARG is the flag to repeat on the commands this script
# suggests running next; empty when both namespaces are the same.
dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
NS_ARG="$(dsh_working_ns_arg)"

hr() { echo; echo "=== $* ==="; }

TARGET="${DEST}/${REPO}"
# Exits rather than carrying an empty namespace into the push: --repo names a
# mirror while only --working-namespace was given, say.
REMOTE_URL="$(dsh_repo_remote "$REPO")" || exit 1
if [ ! -d "${TARGET}/.git" ]; then
    echo "No clone at ${TARGET} - run mirror_to_gitlab.sh first, or pass --dest." >&2
    exit 1
fi

BRANCH="$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "diagnose_push_rejection - ${REPO} (${BRANCH}) -> ${REMOTE_URL}"
echo "the push below already failed once; re-attempting it changes nothing on GitLab"

hr "1. What GitLab has, and what we are asking it to take"
# If the remote refs cannot be read, the problem is upstream of the push and
# everything below is noise.
if git -C "$TARGET" fetch -q origin 2>"${PAYLOAD_DIR}/.fetch.err"; then
    echo "  fetch: OK - credentials and TLS are fine, so this is a policy refusal"
    REMOTE_SHA="$(git -C "$TARGET" rev-parse "origin/${BRANCH}" 2>/dev/null || echo NONE)"
else
    echo "  fetch: FAILED - so this is not a pre-receive problem after all:"
    sed 's/^/    /' "${PAYLOAD_DIR}/.fetch.err"
    REMOTE_SHA="NONE"
fi
rm -f "${PAYLOAD_DIR}/.fetch.err"
echo "  GitLab has:  ${REMOTE_SHA}"
echo "  we are at:   $(git -C "$TARGET" rev-parse HEAD)"

RANGE=""
if [ "$REMOTE_SHA" != "NONE" ]; then
    if git -C "$TARGET" merge-base --is-ancestor "$REMOTE_SHA" HEAD 2>/dev/null; then
        echo "  relationship: fast-forward - GitLab's tip is an ancestor of ours"
    else
        echo "  relationship: NOT A FAST-FORWARD. Someone committed inside GitLab."
        echo "  Reconcile that by hand; do not force."
    fi
    RANGE="${REMOTE_SHA}..HEAD"
fi

hr "2. The commits being pushed"
# Family B inspects exactly these. Author identity is the one that bites a
# mirror: the commits were authored outside, under an identity this GitLab has
# never seen.
if [ -n "$RANGE" ]; then
    count="$(git -C "$TARGET" rev-list --count "$RANGE" 2>/dev/null || echo '?')"
    echo "  ${count} commit(s)"
    git -C "$TARGET" log --format='    %h  %an <%ae>  %s' "$RANGE" 2>/dev/null | head -20
    echo "  distinct author emails:"
    git -C "$TARGET" log --format='%ae' "$RANGE" 2>/dev/null | sort -u | sed 's/^/    /'
    echo "  signature status (N = unsigned; a 'reject unsigned' rule kills every N):"
    git -C "$TARGET" log --format='    %h %G?' "$RANGE" 2>/dev/null | head -20
else
    echo "  cannot determine the range without the remote ref"
fi

hr "3. The largest files in the tree"
# Family C. A size cap declines and names the file; seeing the top of this list
# says whether that is even plausible before you go looking in the UI.
git -C "$TARGET" ls-tree -r -l HEAD 2>/dev/null | sort -k4 -n -r | head -5 \
    | awk '{ printf "    %8.1f KB  %s\n", $4/1024, $5 }'

hr "4. The push, with the remote's exact words"
git -C "$TARGET" push origin "$BRANCH" > "${PAYLOAD_DIR}/.push.out" 2>"${PAYLOAD_DIR}/.push.err"
PUSH_RC=$?
PUSH_MSG="$(cat "${PAYLOAD_DIR}/.push.out" "${PAYLOAD_DIR}/.push.err" 2>/dev/null)"
rm -f "${PAYLOAD_DIR}/.push.out" "${PAYLOAD_DIR}/.push.err"
echo "$PUSH_MSG" | sed 's/^/    /'

hr "Verdict"
if [ "$PUSH_RC" -eq 0 ]; then
    echo "  The push SUCCEEDED this time, so whatever declined it has changed."
    echo "  Finish the other three:"
    echo "      ./mirror_to_gitlab.sh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG} --refresh"
    exit 0
fi

# GitLab's reason strings are stable enough to match on.
case "$PUSH_MSG" in
    *"not allowed to push code to protected branches"*|*"protected branch"*|*"You are not allowed to push"*)
        echo "  CAUSE A - the branch is PROTECTED and this account may not push to it."
        echo "  Two ways out, and the first is one click:"
        echo
        echo "    GitLab > Settings > Repository > Protected branches > ${BRANCH}"
        echo "      set 'Allowed to push and merge' to include you, run the mirror,"
        echo "      then set it back. Protecting it is still right - it just has to"
        echo "      let the mirror through."
        echo
        echo "    Or, if that setting is not yours to change, push a side branch and"
        echo "    merge it in the UI, which protection does allow:"
        echo "      git -C ${TARGET} push origin ${BRANCH}:import-from-outside"
        echo "    then open a merge request into ${BRANCH}. Merge it as a FAST-FORWARD"
        echo "    or a merge commit - do NOT let GitLab squash, which rewrites the"
        echo "    SHAs and breaks the manifest check."
        ;;
    *"not a GitLab user"*|*"not a member"*|*"Author"*"rejected"*|*"Committer"*)
        echo "  CAUSE B - a push rule rejects the COMMIT AUTHOR. These commits were"
        echo "  authored outside, under an identity this GitLab does not know."
        echo "  Section 2 lists the emails it is objecting to."
        echo
        echo "  Do NOT rewrite the commits to satisfy it. Their SHAs are what"
        echo "  MANIFEST.txt pins, and rewriting them makes one SHA mean two"
        echo "  different things either side of the airlock - the exact failure the"
        echo "  bundle route exists to prevent."
        echo
        echo "  Fix: Settings > Repository > Push rules, clear 'Check whether the"
        echo "  author is a GitLab user' and any committer restriction. If those are"
        echo "  set at group or instance level and out of your reach, that is a DSH"
        echo "  support request, not something to work around."
        ;;
    *"unsigned"*|*"signature"*|*"signed"*)
        echo "  CAUSE B - a push rule requires SIGNED commits and these are not"
        echo "  signed (the N column in section 2). Same argument: re-signing"
        echo "  rewrites every SHA. Clear the rule under Settings > Repository >"
        echo "  Push rules."
        ;;
    *"commit message"*|*"does not follow"*|*"regex"*)
        echo "  CAUSE B - a push rule enforces a COMMIT MESSAGE pattern, often an IG"
        echo "  case reference. Section 2 shows the subjects it rejected. They were"
        echo "  written outside and cannot be changed without rewriting the SHAs."
        echo "  Clear the rule, or ask for mirrored projects to be exempted."
        ;;
    *"exceeds"*|*"file size"*|*"too large"*|*"file name"*|*"filename"*|*"secret"*|*"blocked"*)
        echo "  CAUSE C - a push rule rejects the CONTENT, and the message above"
        echo "  names the file. Section 3 lists the biggest ones in the tree."
        echo "  If it is a size cap: the file is in HISTORY, so deleting it now does"
        echo "  not help. The rule has to be raised or the project exempted."
        ;;
    *"pre-receive hook declined"*)
        echo "  CAUSE D - declined, with no reason this script recognises. Section 4"
        echo "  has the remote's exact words and they are the answer; they are also"
        echo "  in diagnose_push_rejection.log. If GitLab printed no reason at all,"
        echo "  it is a custom server-side hook and only DSH support can say what it"
        echo "  enforces."
        ;;
    *)
        echo "  Not a pre-receive decline this time - the push failed for some other"
        echo "  reason. Section 4 has it verbatim."
        ;;
esac
echo
echo "  The mirror stops on the first failure, so every repo after ${REPO} in"
echo "  MANIFEST.txt is still exactly as it was on GitLab. Once this is settled:"
echo "      ./mirror_to_gitlab.sh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG} --refresh"
exit 1
