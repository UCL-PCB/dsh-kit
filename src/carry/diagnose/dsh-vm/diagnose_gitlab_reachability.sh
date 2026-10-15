#!/bin/bash
# INSIDE. probe_secure_env.sh follow-up - why did the probe get no HTTP response from
# GitLab, when Artifactory answered?
#
# probe_secure_env.sh reports `gitlab ... -> HTTP 000`, which is curl's way of
# saying it never got a response at all. That has two causes with opposite
# consequences for the mirror (mirror_to_gitlab.sh):
#
#   A. TLS. The DSH intercepts TLS, and curl/git in Git Bash validate against
#      their own bundled CA store rather than the Windows one, so the handshake
#      fails before any HTTP happens. The host is fine; the client is wrong.
#      This is the same root cause as the documented
#      `git config --global http.sslBackend schannel` fix.
#   B. The host really is unreachable from this VM - wrong name, blocked, or
#      not routed. The mirror cannot run and there is nothing to configure.
#
# The difference is visible in about a minute: if the name resolves and an
# insecure request or a schannel-backed git succeeds where the default fails,
# it is A.
#
# ENTIRELY READ-ONLY. It does not write git config, does not push, and does not
# touch the bundles. `-c http.sslBackend=schannel` sets the backend for one
# command only; nothing persists. Fixing it for real is one line, printed at
# the end, and is yours to run.
#
#   ./diagnose_gitlab_reachability.sh        # host and group from dsh-kit.conf
#   ./diagnose_gitlab_reachability.sh --gitlab <host> --group <group>
#
# Everything lands in Logs/diagnose_gitlab_reachability.log beside this script.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

# The payload ROOT: this script lands in DSH_import/diagnose/, and everything
# it reaches for - lib/, the workspace, the other scripts - is named from there.
PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same logging idiom as the other inside scripts: re-run self with a plain pipe
# so tee cannot lose the tail, and keep the real exit code out of PIPESTATUS.
# shellcheck source=../../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

# shellcheck source=../../any/lib/dsh_platform.sh
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
PROBE_REPO="${KIT_REPOS%% *}"

usage() {
    sed -n '2,29p' "$0"
    echo
    echo "Usage: $0 [--gitlab HOST] [--group GROUP] [--repo NAME] [--working-namespace NS]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab) GITLAB_HOST="$2"; shift 2 ;;
        --group)  GROUP="$2";       shift 2 ;;
        --repo)   PROBE_REPO="$2";  shift 2 ;;
        --working-namespace) WORKING_NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# Publish --gitlab / --group / --working-namespace for dsh_repo_remote, which
# reads them from the environment so that one function assembles every URL in
# every carried script. NS_ARG is the flag to repeat on the commands this script
# suggests running next; empty when both namespaces are the same.
dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
NS_ARG="$(dsh_working_ns_arg)"

have() { command -v "$1" >/dev/null 2>&1; }
hr()   { echo; echo "=== $* ==="; }

DNS_OK="no"
CURL_DEFAULT=""
CURL_INSECURE=""
GIT_DEFAULT="skipped"
GIT_SCHANNEL="skipped"

echo "diagnose_gitlab_reachability - host ${GITLAB_HOST}"
if [ -n "$GROUP" ] && [ -n "$NS_ARG" ]; then
    echo "  namespaces: ${GROUP} (mirrors) and ${WORKING_NAMESPACE} (${KIT_WORKING_REPOS})"
fi
echo "read-only: no git config is written, nothing is pushed"

hr "1. Does the name resolve"
# Resolution alone separates "wrong/blocked name" from "TLS problem" - a TLS
# failure still resolves.
if have getent && getent hosts "$GITLAB_HOST"; then
    DNS_OK="yes"
elif have nslookup && { lookup="$(nslookup "$GITLAB_HOST" 2>&1 || true)"; echo "$lookup" | tail -n +3 | grep -qi 'address'; }; then
    echo "$lookup" | tail -n +3 | sed 's/^/  /'
    DNS_OK="yes"
elif have ping && ping -n 1 -w 3000 "$GITLAB_HOST" 2>&1 | head -3 | grep -qiE '\[|bytes=|Reply from'; then
    ping -n 1 -w 3000 "$GITLAB_HOST" 2>&1 | head -3
    DNS_OK="yes"
else
    echo "  does not resolve with the tools available here"
fi
echo "  resolves: ${DNS_OK}"

hr "2. curl, default CA bundle"
if have curl; then
    CURL_DEFAULT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${GITLAB_HOST}" 2>&1)
    echo "  HTTP ${CURL_DEFAULT:-none}   (000 = no response, usually the TLS handshake)"
    echo "  --- curl's own words ---"
    # -v is where the certificate error actually names itself.
    curl -sS -o /dev/null --max-time 10 "https://${GITLAB_HOST}" 2>&1 | sed 's/^/    /'
else
    echo "  no curl here"
fi

hr "3. curl, certificate check off"
# Deliberately insecure, for one request, to a UCL host inside the walled
# garden. If this answers where section 2 did not, the network is fine and the
# certificate chain is the whole problem.
if have curl; then
    CURL_INSECURE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${GITLAB_HOST}" 2>&1)
    echo "  HTTP ${CURL_INSECURE:-none}"
else
    echo "  no curl here"
fi

hr "4. git, as configured now"
echo "  http.sslBackend currently: $(git config --global --get http.sslBackend || echo '(unset - openssl default)')"
# Whether the project can be probed is whether its URL RESOLVES, not whether
# --group was given: a working repo resolves from --working-namespace alone.
if REMOTE="$(dsh_repo_remote "$PROBE_REPO" 2>/dev/null)"; then
    echo "  git ls-remote ${REMOTE}"
    # ls-remote is the read-only half of what the mirror does. GIT_TERMINAL_PROMPT=0
    # keeps a credential prompt from hanging the script - an auth failure is a
    # result, not something to sit and wait on.
    if GIT_TERMINAL_PROMPT=0 git ls-remote "$REMOTE" >/dev/null 2>"${PAYLOAD_DIR}/.git_default.err"; then
        GIT_DEFAULT="ok"
    else
        GIT_DEFAULT="failed"
        sed 's/^/    /' "${PAYLOAD_DIR}/.git_default.err"
    fi
    echo "  result: ${GIT_DEFAULT}"

    hr "5. git, forced onto the Windows certificate store"
    echo "  git -c http.sslBackend=schannel ls-remote ... (this command only)"
    if GIT_TERMINAL_PROMPT=0 git -c http.sslBackend=schannel ls-remote "$REMOTE" >/dev/null 2>"${PAYLOAD_DIR}/.git_schannel.err"; then
        GIT_SCHANNEL="ok"
    else
        GIT_SCHANNEL="failed"
        sed 's/^/    /' "${PAYLOAD_DIR}/.git_schannel.err"
    fi
    echo "  result: ${GIT_SCHANNEL}"
    rm -f "${PAYLOAD_DIR}/.git_default.err" "${PAYLOAD_DIR}/.git_schannel.err"
else
    echo "  No namespace for ${PROBE_REPO}, so there is no project URL to test."
    echo "  Re-run with --group <group> to test the URL the mirror pushes to"
    echo "  (or --working-namespace <ns> --repo <working-repo>)."
fi

hr "Verdict"
printf '  %-22s %s\n' "resolves"           "$DNS_OK"
printf '  %-22s %s\n' "curl default"       "HTTP ${CURL_DEFAULT:-none}"
printf '  %-22s %s\n' "curl insecure"      "HTTP ${CURL_INSECURE:-none}"
printf '  %-22s %s\n' "git default"        "$GIT_DEFAULT"
printf '  %-22s %s\n' "git schannel"       "$GIT_SCHANNEL"
echo

if [ "$GIT_SCHANNEL" = "ok" ]; then
    echo "  CAUSE A - TLS. GitLab is reachable; git's default CA store is not"
    echo "  what this network needs. Make it permanent, then the mirror works:"
    echo
    echo "      git config --global http.sslBackend schannel"
    echo
    echo "  The HTTP 000 from the probe was curl hitting the same wall, not an outage."
    exit 0
elif [ "$DNS_OK" = "yes" ] && [ -n "${CURL_INSECURE}" ] && [ "${CURL_INSECURE}" != "000" ]; then
    echo "  CAUSE A, probably - the name resolves and the host answers once the"
    echo "  certificate check is off, so the network path exists."
    if [ "$GIT_DEFAULT" = "skipped" ]; then
        echo "  Re-run with --group <group> to confirm git itself gets through."
    else
        echo "  git still failed with schannel - read section 4 and 5 above for"
        echo "  what it said; an auth prompt or a 403 is a different problem from"
        echo "  a certificate one, and means the host is fine."
    fi
    exit 0
elif [ "$DNS_OK" = "no" ]; then
    echo "  CAUSE B - the name does not resolve from this VM. Nothing client-side"
    echo "  fixes that. Check the host name against the DSH documentation, and"
    echo "  whether GitLab is enabled for this project's environment at all."
    echo "  The mirror cannot run until it resolves; install_uv.sh and"
    echo "  check_venv_location.sh are unaffected because they only need Artifactory."
    exit 1
else
    echo "  UNCLEAR - the name resolves but nothing answered, secure or not."
    echo "  Read sections 2-5 above. Treat as CAUSE B for now: the mirror is blocked,"
    echo "  Artifactory-only steps are not."
    exit 1
fi
