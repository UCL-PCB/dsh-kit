#!/bin/bash
# INSIDE. Can this box install the first-party packages by CLONING them from
# GitLab-inside, instead of unpacking the bundles the payload carries?
#
# That is the question behind install_git_route.sh and docs/git_install_route.md:
# if the cluster can reach GitLab-inside the way the Desktop VM can, the cluster
# can install pinned git sources straight from it, with no clones to keep in step.
#
# The clone route (install_packages.sh) works and is not being replaced. This
# probe exists so that decision is made on a measurement rather than on "both
# boxes are inside the DSH, so presumably". Run it on the box you mean to use the
# git route on - usually the cluster.
#
# ENTIRELY READ-ONLY. It clones into a temporary directory and deletes it, writes
# no git config, pushes nothing, and touches neither the payload nor any venv.
#
#   ./probe_gitlab_install_route.sh                 # host and group from dsh-kit.conf
#   ./probe_gitlab_install_route.sh --no-lock
#   ./probe_gitlab_install_route.sh --group <group> --gitlab <host>
#
# Everything lands in Logs/probe_gitlab_install_route.log beside this script, so the
# result is reviewable here without relaying it anywhere.

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
# Every interesting command here is git, and on the Desktop VM an unstattable
# ancestor of $HOME fails all of them identically as "permission denied" - which
# reads exactly like GitLab refusing the connection.
dsh_git_guard || exit 1
dsh_kit_settings "$PAYLOAD_DIR" || exit 1
dsh_gitlab_only "$(basename "$0")" || exit 0

GITLAB_HOST="$KIT_GITLAB_HOST"
GROUP="$KIT_GITLAB_GROUP"
WORKING_NAMESPACE="$KIT_WORKING_NAMESPACE"
DO_LOCK="auto"
CLONE_REPO=""

usage() {
    sed -n '2,24p' "$0"
    echo
    echo "Usage: $0 [--group GROUP] [--gitlab HOST] [--repo NAME] [--no-lock]"
    echo "          [--working-namespace NS]"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gitlab)  GITLAB_HOST="$2"; shift 2 ;;
        --group)   GROUP="$2";       shift 2 ;;
        --repo)    CLONE_REPO="$2";  shift 2 ;;
        --no-lock) DO_LOCK="no";     shift ;;
        --working-namespace) WORKING_NAMESPACE="$2"; shift 2 ;;
        --lock)    DO_LOCK="yes";    shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$GROUP" ] || { echo "Error: no GitLab group - set KIT_GITLAB_GROUP or pass --group" >&2; usage; }
dsh_no_placeholder KIT_GITLAB_GROUP "$GROUP" || exit 1

# Publish --gitlab / --group / --working-namespace for dsh_repo_remote, which
# reads them from the environment so that one function assembles every URL in
# every carried script. NS_ARG is the flag to repeat on the commands this script
# suggests running next; empty when both namespaces are the same.
dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
NS_ARG="$(dsh_working_ns_arg)"

have() { command -v "$1" >/dev/null 2>&1; }
hr()   { echo; echo "=== $* ==="; }
report() { printf '  %-26s %s\n' "$1" "$2"; }

REACH="no"
LS_OK=0
LS_FAIL=0
CLONE_RESULT="skipped"
LOCK_RESULT="skipped"

echo "probe_gitlab_install_route - https://${GITLAB_HOST}/${GROUP}/"
if [ -n "$NS_ARG" ]; then
    echo "  working repos (${KIT_WORKING_REPOS}): https://${GITLAB_HOST}/${WORKING_NAMESPACE}/"
fi
echo "read-only: clones to a temp dir and removes it, changes no configuration"
report "platform" "$DSH_OS"
report "hostname" "$(hostname 2>/dev/null)"

# ---------------------------------------------------------------------------
hr "1. Toolchain"
for c in git curl uv; do
    if have "$c"; then
        report "$c" "$(command -v "$c") - $("$c" --version 2>&1 | head -1)"
    else
        report "$c" "NOT on PATH"
    fi
done
if ! have git; then
    echo
    echo "  No git here, so there is no route to probe. Nothing else below can run."
    exit 1
fi

# ---------------------------------------------------------------------------
hr "2. Does the host answer at all"
# Separates "wrong or blocked name" from "TLS" from "auth". A TLS failure still
# resolves; an auth failure answers with a 401 rather than with nothing.
if have getent && getent hosts "$GITLAB_HOST"; then
    report "resolves" "yes"
elif have nslookup && nslookup "$GITLAB_HOST" >/dev/null 2>&1; then
    report "resolves" "yes"
else
    report "resolves" "NO - with the tools available here"
fi
if have curl; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${GITLAB_HOST}" 2>/dev/null)
    report "curl https" "HTTP ${code:-000}   (000 = no response, usually the TLS handshake)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then REACH="yes"; fi
    # The insecure retry is the one that tells TLS apart from unreachable. One
    # request, to a UCL host, inside the walled garden.
    codek=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${GITLAB_HOST}" 2>/dev/null)
    report "curl, cert check off" "HTTP ${codek:-000}"
    if [ -n "$codek" ] && [ "$codek" != "000" ]; then REACH="yes"; fi
    if [ "${code:-000}" = "000" ] && [ "${codek:-000}" != "000" ]; then
        echo "  -> reachable, but the certificate chain is rejected. See"
        echo "     diagnose/diagnose_gitlab_reachability.sh; on Linux the fix is a CA bundle"
        echo "     or http.sslCAInfo, not the schannel backend it recommends on Windows."
    fi
else
    report "curl" "absent - relying on git below"
fi

# ---------------------------------------------------------------------------
hr "3. Can git read each repo (the load-bearing check)"
# ls-remote is exactly what uv does first when resolving a git source: it asks the
# host for the refs. If this works for every repo, the git route works.
#
# Driven off MANIFEST.txt when it is here, for the same reason mirror_to_gitlab.sh
# is: the manifest is the definition of which repos exist on the other side.
if [ -f "${PAYLOAD_DIR}/MANIFEST.txt" ]; then
    REPOS="$(awk '!/^#/ && NF {print $1}' "${PAYLOAD_DIR}/MANIFEST.txt")"
    report "repo list from" "MANIFEST.txt"
else
    REPOS="$KIT_REPOS"
    report "repo list from" "dsh-kit.conf (no MANIFEST.txt beside this script)"
fi
for pkg in $REPOS; do
    remote="$(dsh_repo_remote "$pkg")"
    # GIT_TERMINAL_PROMPT=0 so a missing credential is a result rather than a hung
    # script waiting on a username nobody is there to type.
    if GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$remote" >/dev/null 2>"${PAYLOAD_DIR}/.ls.err"; then
        report "$pkg" "ok"
        LS_OK=$((LS_OK + 1))
        if [ -z "$CLONE_REPO" ]; then CLONE_REPO="$pkg"; fi
    else
        report "$pkg" "FAILED"
        sed 's/^/      /' "${PAYLOAD_DIR}/.ls.err"
        LS_FAIL=$((LS_FAIL + 1))
    fi
    rm -f "${PAYLOAD_DIR}/.ls.err"
done

# ---------------------------------------------------------------------------
hr "4. Can git actually clone one"
# Reading refs is not fetching objects. A host can answer ls-remote and then fail
# the pack transfer - on a proxy, a size limit, or a smart-HTTP restriction - so
# the clone is a separate question from the one section 3 answers.
if [ "$LS_OK" -eq 0 ]; then
    echo "  nothing readable to clone - skipping"
else
    TMP="$(mktemp -d 2>/dev/null)"
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        remote="$(dsh_repo_remote "$CLONE_REPO")"
        echo "  git clone --depth 1 ${remote}"
        if GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$remote" "${TMP}/probe" 2>&1 | sed 's/^/    /'; then
            if [ -f "${TMP}/probe/pyproject.toml" ]; then
                CLONE_RESULT="ok"
                report "working tree" "populated, pyproject.toml present"
            else
                # The same trap mirror_to_gitlab.sh documents: history arrives, no
                # files, because nothing was checked out.
                CLONE_RESULT="empty"
                report "working tree" "EMPTY - clone succeeded but checked out nothing"
            fi
        else
            CLONE_RESULT="failed"
        fi
        rm -rf "$TMP"
    else
        echo "  could not make a temp directory - skipping"
    fi
fi

# ---------------------------------------------------------------------------
hr "5. Can uv resolve a git source"
# The end-to-end question, and the only one that proves the route rather than its
# parts: uv has its own git client and its own CA store, and either can fail where
# the system git succeeds.
#
# Deliberately ONE package - the first in KIT_REPOS, which being the base of the
# chain has no first-party dependencies. This asks "does the git source mechanism
# work here", not "does the whole set resolve" - the second needs Artifactory for
# every third-party dependency, and would report an index problem as though it
# were a git one.
BASE_REPO="${KIT_REPOS%% *}"
if [ "$DO_LOCK" = "no" ]; then
    echo "  skipped (--no-lock)"
    LOCK_RESULT="skipped"
elif ! have uv; then
    echo "  no uv on PATH yet - run install_uv.sh first, then re-run this"
    LOCK_RESULT="no-uv"
elif [ "$LS_OK" -eq 0 ]; then
    echo "  git cannot read the repos, so there is no point asking uv - skipping"
else
    TMP="$(mktemp -d 2>/dev/null)"
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        {
            echo '[project]'
            echo 'name = "probe-git-route"'
            echo 'version = "0.0.0"'
            [ -n "$KIT_PYTHON_SPEC" ] && echo "requires-python = \"${KIT_PYTHON_SPEC}\""
            echo "dependencies = [\"${BASE_REPO}\"]"
            echo
            echo '[tool.uv]'
            echo 'package = false'
            echo
            echo '[tool.uv.sources]'
            echo "${BASE_REPO} = { git = \"$(dsh_repo_remote "$BASE_REPO")\" }"
        } > "${TMP}/pyproject.toml"
        echo "  uv lock, in ${TMP}"
        if ( cd "$TMP" && GIT_TERMINAL_PROMPT=0 uv lock >"${TMP}/lock.out" 2>&1 ); then
            LOCK_RESULT="ok"
            sed 's/^/    /' "${TMP}/lock.out"
            grep -n "$BASE_REPO" "${TMP}/uv.lock" 2>/dev/null | head -5 | sed 's/^/    /'
        else
            LOCK_RESULT="failed"
            sed 's/^/    /' "${TMP}/lock.out"
            echo "    (a failure naming an INDEX or Artifactory is a third-party problem,"
            echo "     not a git one - the git source is what this section tests)"
        fi
        rm -rf "$TMP"
    else
        echo "  could not make a temp directory - skipping"
    fi
fi

# ---------------------------------------------------------------------------
hr "Verdict"
report "host answers" "$REACH"
report "repos readable" "${LS_OK} ok, ${LS_FAIL} failed"
report "clone" "$CLONE_RESULT"
report "uv lock over git" "$LOCK_RESULT"
echo

if [ "$LS_FAIL" -eq 0 ] && [ "$LS_OK" -gt 0 ] && [ "$CLONE_RESULT" = "ok" ] && [ "$LOCK_RESULT" = "ok" ]; then
    echo "  THE GIT ROUTE WORKS from this box. ./install_git_route.sh can install"
    echo "  pinned git sources straight from this GitLab - see docs/git_install_route.md,"
    echo "  which also lists what that costs (no editable installs; new code arrives"
    echo "  only as a new payload)."
    exit 0
elif [ "$LS_FAIL" -eq 0 ] && [ "$LS_OK" -gt 0 ] && [ "$CLONE_RESULT" = "ok" ]; then
    echo "  GIT WORKS, UV UNPROVEN. Cloning is fine, so the repos are reachable and the"
    echo "  credential is good. Re-run once install_uv.sh has run; uv brings its own git"
    echo "  client and its own CA store and can fail on its own."
    exit 0
elif [ "$LS_OK" -gt 0 ]; then
    echo "  PARTIAL. Some repos answer and some do not, which is a per-project permission"
    echo "  or a repo the mirror never pushed - not a network fault. Check the mirror covered"
    echo "  every repo and that this account can read each project."
    exit 1
else
    echo "  NO ROUTE from this box. Nothing readable over git, so the clone route stays"
    echo "  the only way code reaches here. If section 2 says the host answers but"
    echo "  section 3 does not, it is credentials or per-project permissions rather than"
    echo "  reachability: diagnose/diagnose_gitlab_reachability.sh separates those."
    exit 1
fi
