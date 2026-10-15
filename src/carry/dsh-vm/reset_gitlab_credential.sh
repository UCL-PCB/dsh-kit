#!/bin/bash
# INSIDE. Make git ask for GitLab credentials again - before mirroring, or whenever
# GitLab refuses without asking.
#
# Symptom this exists for: `git ls-remote https://gitlab.idhs.ucl.ac.uk/...`
# denies instantly and NEVER PROMPTS, on an account that is Owner of the project
# and can sign into the GitLab web UI. Nothing is wrong with rights or with the
# URL - the credential helper is replaying a stored password that is no longer
# valid.
#
# Why it goes stale: the DSH password expires every 90 days. The stored entry
# does not expire with it, so the first git operation after a password change
# fails with the old one and, because a helper "answered", git sees no reason to
# ask you. This is also why the Artifactory "Set Me Up" snippet has to be
# regenerated after every password change - same cause, different service.
#
# The Windows Credential Manager UI is the usual way to clear it, and is often
# blocked on a locked-down DSH Desktop. git can do it itself, which is what this
# does.
#
# MILDLY STATE-CHANGING, and only on this machine: it deletes the stored
# credential for the GitLab host. Nothing on GitLab changes, nothing is pushed.
# The cost of being wrong is typing your password once.
#
#   ./reset_gitlab_credential.sh                  # host and group from dsh-kit.conf
#   ./reset_gitlab_credential.sh --no-test        (erase only)
#   ./reset_gitlab_credential.sh --group <group>  # override the conf
#
# The test at the end IS interactive - it is meant to prompt you. Give your DSH
# username and your CURRENT DSH password; this GitLab is AD-backed, so no
# personal access token is needed.
#
# Everything lands in Logs/reset_gitlab_credential.log beside this script, except
# what you type, which is never echoed and never written.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

# shellcheck source=../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"
# Before blaming a host or a credential, make sure git can run in this
# directory at all - an unstattable ancestor fails every git command identically.
dsh_git_guard || exit 1
dsh_kit_settings "$PAYLOAD_DIR" || exit 1

GITLAB_HOST="$KIT_GITLAB_HOST"
GROUP="$KIT_GITLAB_GROUP"
# Working repos may live in another namespace - see dsh_repo_namespace in
# dsh_platform.sh. Empty means "same as the group".
WORKING_NAMESPACE="$KIT_WORKING_NAMESPACE"
# The repo the test reads. The base of the chain, because it is in every payload.
PROBE_REPO="${KIT_REPOS%% *}"
RUN_TEST="yes"

usage() {
    sed -n '2,34p' "$0"
    echo
    echo "Usage: $0 [--gitlab HOST] [--group GROUP] [--repo NAME] [--no-test]"
    echo "          [--working-namespace NS]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab)  GITLAB_HOST="$2"; shift 2 ;;
        --group)   GROUP="$2";       shift 2 ;;
        --repo)    PROBE_REPO="$2";  shift 2 ;;
        --no-test) RUN_TEST="no";    shift 1 ;;
        --working-namespace) WORKING_NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

dsh_no_placeholder KIT_GITLAB_GROUP "$GROUP" || exit 1

# Publish --gitlab / --group / --working-namespace for dsh_repo_remote, which
# reads them from the environment so that one function assembles every URL in
# every carried script. NS_ARG is the flag to repeat on the commands this script
# suggests running next; empty when both namespaces are the same.
dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
NS_ARG="$(dsh_working_ns_arg)"

have() { command -v "$1" >/dev/null 2>&1; }
hr()   { echo; echo "=== $* ==="; }

echo "reset_gitlab_credential - host ${GITLAB_HOST}"
if [ -n "$GROUP" ] && [ -n "$NS_ARG" ]; then
    echo "  namespaces: ${GROUP} (mirrors) and ${WORKING_NAMESPACE} (${KIT_WORKING_REPOS})"
fi

hr "1. What is answering for credentials"
# If no helper is configured at all, a stale stored password cannot be the
# cause and the diagnosis needs to go elsewhere - so this is worth seeing.
helper="$(git config --get-all credential.helper 2>/dev/null)"
if [ -n "$helper" ]; then
    echo "$helper" | sed 's/^/  helper: /'
else
    echo "  helper: (none configured - nothing should be stored, so a denial"
    echo "           without a prompt is NOT a stale credential)"
fi
echo "  sslBackend: $(git config --global --get http.sslBackend || echo '(unset)')"
have git-credential-manager && echo "  GCM: $(git-credential-manager --version 2>/dev/null | head -1)"

hr "2. Erase the stored credential"
# `git credential reject` is the plumbing the helper protocol is built on: it
# tells whichever helper is configured to forget this host. The bare host AND
# one path per namespace are erased - helpers can store either, depending on
# credential.useHttpPath.
erase_one() {
    local desc="$1"; shift
    printf '%s\n' "$@" '' | git credential reject 2>&1 | sed 's/^/    /'
    echo "  erased: ${desc}"
}
erase_one "https://${GITLAB_HOST}" \
    "protocol=https" "host=${GITLAB_HOST}"
# One path per namespace in play, not just the group's. git's credential store
# keys by path once a path is recorded, so an entry left behind for one
# namespace is exactly the stale credential this script exists to clear - and it
# would go on silently answering for the other one. The repos that leave the
# group come from dsh_namespaced_repos, so this does not name any of them.
if [ -n "$GROUP" ]; then
    for repo in "$PROBE_REPO" $(dsh_namespaced_repos); do
        ns="$(dsh_repo_namespace "$repo")" || continue
        erase_one "https://${GITLAB_HOST}/${ns}/${repo}.git" \
            "protocol=https" "host=${GITLAB_HOST}" "path=${ns}/${repo}.git"
    done
fi
echo "  (no error above means it either erased or had nothing to erase - both fine)"

hr "3. Confirm nothing is stored now"
# A helper with nothing stored returns no username/password lines. If one still
# comes back, something else is answering - a second helper, or a URL-embedded
# credential in a remote.
stored="$(printf 'protocol=https\nhost=%s\n\n' "$GITLAB_HOST" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | grep -c '^password=' || true)"
if [ "${stored:-0}" -eq 0 ]; then
    echo "  nothing stored - git will have to ask you"
else
    echo "  SOMETHING IS STILL STORED for ${GITLAB_HOST}."
    echo "  A second helper is configured, or a remote URL embeds a credential."
    echo "  Section 1 lists the helpers; check those before continuing."
fi

if [ "$RUN_TEST" != "yes" ]; then
    hr "Done (test skipped)"
    exit 0
fi

if [ -z "$GROUP" ]; then
    hr "Done"
    echo "  --group not given, so there is no URL to test against."
    echo "  Re-run with --group <group>, or test by hand:"
    echo "      git ls-remote https://${GITLAB_HOST}/<group>/${PROBE_REPO}.git"
    exit 0
fi

hr "4. Test - THIS SHOULD PROMPT YOU"
REMOTE="$(dsh_repo_remote "$PROBE_REPO")"
echo "  git ls-remote ${REMOTE}"
echo "  Username: your DSH username.  Password: your CURRENT DSH password."
echo "  (AD-backed GitLab - no personal access token needed.)"
echo
# Prompts deliberately ENABLED here - the whole point is to be asked. Nothing
# typed is echoed or written to the log.
if git ls-remote "$REMOTE" > "${PAYLOAD_DIR}/.ls_remote.out" 2>"${PAYLOAD_DIR}/.ls_remote.err"; then
    refs="$(wc -l < "${PAYLOAD_DIR}/.ls_remote.out" | tr -d ' ')"
    echo "  OK - ${refs} refs on the remote. Heads:"
    grep 'refs/heads/' "${PAYLOAD_DIR}/.ls_remote.out" | sed 's/^/    /'
    rm -f "${PAYLOAD_DIR}/.ls_remote.out" "${PAYLOAD_DIR}/.ls_remote.err"
    hr "Verdict"
    echo "  Credentials work and GitLab is readable. This is what the mirror needs."
    echo "  The SHAs above are what GitLab holds now - the mirror fast-forwards from them."
    echo "  Next: ./mirror_to_gitlab.sh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG} --refresh"
    exit 0
fi

sed 's/^/    /' "${PAYLOAD_DIR}/.ls_remote.err"
rm -f "${PAYLOAD_DIR}/.ls_remote.out" "${PAYLOAD_DIR}/.ls_remote.err"
hr "Verdict"
echo "  Still failing. What the message says decides what is next:"
echo
echo "    'Authentication failed' / 'Access denied' AFTER a prompt"
echo "        - the password is wrong or expired. Reset it at"
echo "          registration.idhs.ucl.ac.uk/drp, then re-run this."
echo "          Remember it invalidates the Artifactory Set Me Up snippet too."
echo "    no prompt at all"
echo "        - something is still answering. See section 3."
echo "    'could not read Username'"
echo "        - prompts are disabled in this shell (GIT_TERMINAL_PROMPT=0)."
echo "          Open a fresh Git Bash and re-run."
echo "    certificate / SSL"
echo "        - unrelated to credentials: git config --global http.sslBackend schannel"
exit 1
