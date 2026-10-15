#!/bin/bash
# INSIDE. Sourced by the other carried scripts. Not run directly.
#
# The DSH has two boxes and they are not the same operating system:
#   * the Desktop analysis VM  - Windows, reached over Citrix, driven from Git Bash
#   * the cluster login node   - Linux, reached over SSH from the Desktop
#
# Every path that differs between them is resolved here, once, so the install
# scripts stay one file rather than two that drift apart. So is every setting:
# what the project is (dsh-kit.conf), what this machine is (~/dsh-kit.env), and
# the GitLab URL each repo is cloned from.

# DSH_OS            -> "windows" | "linux"
# DSH_VENV_PYTHON   -> path fragment: Scripts/python.exe | bin/python
# DSH_UV_CONFIG     -> the uv.toml uv actually reads on this platform
# DSH_UV_ASSET      -> the uv release asset this platform needs
# DSH_UV_EXE        -> "uv.exe" | "uv"

case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) DSH_OS="windows" ;;
    *)                    DSH_OS="linux"   ;;
esac

if [ "$DSH_OS" = "windows" ]; then
    DSH_VENV_PYTHON="Scripts/python.exe"
    DSH_UV_ASSET="uv-x86_64-pc-windows-msvc.zip"
    DSH_UV_EXE="uv.exe"
    # uv reads %APPDATA%\uv\uv.toml on Windows, NOT ~/.config/uv/uv.toml.
    # Writing the Linux path on Windows produces a config uv silently ignores,
    # which then looks like "Artifactory is unreachable" at the first download.
    if [ -n "${APPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
        DSH_UV_CONFIG="$(cygpath -u "$APPDATA")/uv/uv.toml"
    else
        DSH_UV_CONFIG="${HOME}/AppData/Roaming/uv/uv.toml"
    fi
else
    DSH_VENV_PYTHON="bin/python"
    DSH_UV_ASSET="uv-x86_64-unknown-linux-gnu.tar.gz"
    DSH_UV_EXE="uv"
    DSH_UV_CONFIG="${HOME}/.config/uv/uv.toml"
fi

# Make git usable from wherever this script is standing.
#
# git runs "gently": before doing anything at all - even `git config --list`,
# which touches no repository - it walks UP from the current directory looking
# for a .git, statting every ancestor on the way. On the DSH Desktop an ancestor
# of the home directory is not stattable by the account, so git dies with
#
#     fatal: failed to stat '<dir>': Permission denied
#
# before it has looked at a config file, a credential or a host. That is
# indistinguishable, from the outside, from GitLab refusing the account: it
# never prompts, it fails identically on both TLS backends, and being Owner of
# the project changes nothing. It is easy to lose a whole session to that.
#
# GIT_CEILING_DIRECTORIES stops the upward walk. Exported, so every git in every
# child process inherits it.
dsh_git_guard() {
    command -v git >/dev/null 2>&1 || return 0
    # The test is whether git can RUN here, not what it found: outside a repo
    # `git rev-parse --git-dir` fails normally, and `git config --list` exits
    # non-zero on a merely empty config. Only the stat error means broken.
    local err
    err="$(git rev-parse --git-dir 2>&1 >/dev/null)"
    case "$err" in
        *"failed to stat"*) ;;
        *) return 0 ;;
    esac
    export GIT_CEILING_DIRECTORIES="${GIT_CEILING_DIRECTORIES:-$HOME}"
    err="$(git rev-parse --git-dir 2>&1 >/dev/null)"
    if [ "${err#*failed to stat}" != "$err" ]; then
        echo "  WARNING: git cannot stat this directory's ancestors, and" >&2
        echo "  GIT_CEILING_DIRECTORIES=${GIT_CEILING_DIRECTORIES} did not help." >&2
        echo "  Run diagnose/diagnose_git_permissions.sh - no git command will work here." >&2
        return 1
    fi
    echo "  note: set GIT_CEILING_DIRECTORIES=${GIT_CEILING_DIRECTORIES} so git can run here"
    echo "        (an ancestor of this directory is not stattable by this account)"
    return 0
}

# Unpack either asset without assuming a tool that is not there. Git Bash ships
# no unzip; Windows 10 ships bsdtar as tar.exe and PowerShell has Expand-Archive.
dsh_unpack() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"
    case "$archive" in
        *.tar.gz) tar -xzf "$archive" -C "$dest" ;;
        *.zip)
            if [ -n "${SYSTEMROOT:-}" ] && [ -x "$(cygpath -u "${SYSTEMROOT}" 2>/dev/null)/System32/tar.exe" ]; then
                "$(cygpath -u "${SYSTEMROOT}")/System32/tar.exe" -xf "$(cygpath -w "$archive")" -C "$(cygpath -w "$dest")"
            elif command -v unzip >/dev/null 2>&1; then
                unzip -q -o "$archive" -d "$dest"
            else
                powershell -NoProfile -NonInteractive -Command \
                    "Expand-Archive -Force -Path '$(cygpath -w "$archive")' -DestinationPath '$(cygpath -w "$dest")'"
            fi
            ;;
        *) echo "dsh_unpack: unknown archive type: $archive" >&2; return 1 ;;
    esac
}

# dsh_py_satisfies <python> [spec]  - true if that interpreter runs and its version
# is inside the spec (default KIT_PYTHON_SPEC; empty means any Python 3). Handles
# the specifier forms a requires-python actually uses - >=, <=, >, <, ==, !=, ~=,
# and == with a trailing .* - without the `packaging` module, which a bare system
# Python on the DSH may not have.
dsh_py_satisfies() {
    local py="$1" spec="${2-${KIT_PYTHON_SPEC:-}}"
    DSH_SPEC="$spec" "$py" -c '
import os, re, sys
v = sys.version_info[:3]
def tup(s):
    return tuple(int(x) for x in s.split(".") if x != "*")
def pad(t):
    return (t + (0, 0, 0))[:3]
ok = sys.version_info[0] == 3
for c in [c.strip() for c in os.environ.get("DSH_SPEC", "").split(",") if c.strip()]:
    m = re.match(r"(>=|<=|==|!=|~=|<|>)\s*([0-9][0-9.*]*)$", c)
    if not m:
        continue
    op, ver = m.groups()
    w = tup(ver)
    if op == ">=": ok &= v >= pad(w)
    elif op == "<=": ok &= v <= pad(w)
    elif op == ">": ok &= v > pad(w)
    elif op == "<": ok &= v < pad(w)
    elif op == "==": ok &= v[:len(w)] == w
    elif op == "!=": ok &= v[:len(w)] != w
    elif op == "~=": ok &= v >= pad(w) and v[:len(w) - 1] == w[:-1]
raise SystemExit(0 if ok else 1)
' 2>/dev/null
}

# The interpreter names worth trying, newest first. The first name that happens
# to be on PATH is often a shim or an old install, so the probes try them all and
# keep the newest inside the spec rather than the first hit.
DSH_PY_CANDIDATES="python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3 python"

# ---------------------------------------------------------------------------
# Settings: dsh-kit.conf, then ~/dsh-kit.env, then the script's own flags
# ---------------------------------------------------------------------------
# Two files, because they answer different questions:
#
#   dsh-kit.conf     what the PROJECT is - its repos, install mode, extras, GitLab
#                    group. Written outside, carried in the payload, identical for
#                    everyone who installs this project.
#   ~/dsh-kit.env    what THIS MACHINE is - where the workspace goes, which python,
#                    where the zip arrives. Written once on each box by hand, never
#                    carried, never synced.
#
# ~/dsh-kit.env keys, all optional, all KEY="value" (parsed, never sourced):
#
#   KIT_WORKSPACE_DIR      where the clones and the .venv go. Required on Windows by
#                          install_packages.sh unless --workspace is given.
#   KIT_PYTHON             full path to the interpreter. Only needed on a first
#                          build; uv records it in .venv after that.
#   KIT_PAYLOAD_DIR        where the zip unpacks to (default ~/DSH_import)
#   KIT_ZIP                the payload zip (default: search Q:, $HOME, here, ~/Downloads)
#   KIT_CLEAN_PATH         yes to strip Anaconda and the rest out of PATH for the build
#   KIT_GITLAB_HOST        } override the conf on this machine only - e.g. your
#   KIT_GITLAB_GROUP       } personal namespace while the project's group does
#   KIT_WORKING_NAMESPACE  } not exist yet
#
# $DSH_KIT_ENV names a different file. Precedence, highest first: a flag on the
# command line, ~/dsh-kit.env, dsh-kit.conf.
DSH_MACHINE_KEYS="KIT_WORKSPACE_DIR KIT_PYTHON KIT_PAYLOAD_DIR KIT_ZIP KIT_CLEAN_PATH
KIT_GITLAB_HOST KIT_GITLAB_GROUP KIT_WORKING_NAMESPACE"

# dsh_load_machine_env [file]. A missing file is not an error: every key in it is
# also a flag.
dsh_load_machine_env() {
    local f="${1:-${DSH_KIT_ENV:-${HOME}/dsh-kit.env}}" line key val
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        if [[ "$line" =~ ^(KIT_[A-Z_]+)=\"([^\"]*)\"[[:space:]]*(#.*)?$ ]] \
           || [[ "$line" =~ ^(KIT_[A-Z_]+)=([^[:space:]\"]*)[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            # shellcheck disable=SC2086
            case " $(echo $DSH_MACHINE_KEYS) " in
                *" ${key} "*) printf -v "$key" '%s' "$val" ;;
                *) echo "  ${f}: ${key} is not a per-machine key - ignored (it belongs in dsh-kit.conf)" >&2 ;;
            esac
        else
            echo "  ${f}: not KEY=\"value\" - ignored: ${line}" >&2
        fi
    done < "$f"
    DSH_MACHINE_ENV_FILE="$f"
}

# dsh_kit_settings <dir>  - load <dir>/dsh-kit.conf, then ~/dsh-kit.env.
#
# Every carried script that needs to know the project calls this once, with the
# payload directory, BEFORE parsing its flags - so a flag then simply overwrites
# the variable it names. A missing conf is fatal: build_payload.sh puts one in
# every payload, so its absence means this directory is not one.
dsh_kit_settings() {
    local dir="$1" conf
    # dsh_conf.sh sits beside this file, in lib/ on the far side.
    # shellcheck source=dsh_conf.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dsh_conf.sh" || return 1
    conf="$(dsh_find_conf "$dir")" || {
        echo "Error: no dsh-kit.conf in ${dir}." >&2
        echo "  Every payload carries one at its top level. If it is missing, this" >&2
        echo "  is not an unpacked payload." >&2
        return 1
    }
    dsh_load_conf "$conf" || { echo "Error: ${conf} is not valid - see above." >&2; return 1; }
    dsh_load_machine_env
    : "${KIT_WORKSPACE_DIR:=}" "${KIT_PYTHON:=}" "${KIT_PAYLOAD_DIR:=}" "${KIT_ZIP:=}"
    : "${KIT_CLEAN_PATH:=no}"
}

# dsh_gitlab_only <script name>  - for a script that only means anything when the
# repos go through GitLab. Call it right after dsh_kit_settings:
#
#   dsh_gitlab_only "$(basename "$0")" || exit 0
#
# In bundle mode (KIT_GITLAB=no) it says so in one line and returns 1, and the
# script exits 0: nothing is wrong, there is just nothing for it to do. The
# GitLab-only scripts are still carried in bundle mode - one payload layout for
# both modes is simpler than a conditional one, and a project can switch.
dsh_gitlab_only() {
    dsh_uses_gitlab && return 0
    echo "KIT_GITLAB=no in dsh-kit.conf - $1 is not used; repos install from the bundles."
    return 1
}

# dsh_no_placeholder <name> <value>. A value still holding a <placeholder> is not
# a value: left in, it reaches GitLab as a real group name and fails several
# clones later, by which point the cause is buried.
dsh_no_placeholder() {
    case "$2" in
        *"<"*">"*) echo "Error: $1 still holds a placeholder: $2" >&2
                   echo "  Set it in dsh-kit.conf, ~/dsh-kit.env, or with its flag." >&2
                   return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# GitLab URLs
# ---------------------------------------------------------------------------
# Which GitLab namespace a given repo lives in.
#
# It is a property OF THE REPO, not of the run. Mirrors live in the shared group.
# A working repo - one edited inside, KIT_WORKING_REPOS - may live elsewhere,
# typically the operator's personal namespace: GitLab gives every group member at
# least their group role on every project in the group, there is no per-project
# way to hide a project from the group it is in, and a subgroup does not help
# because parent-group members inherit downward. So "only I may see this" means
# "not in the group". The cost, if you take it: the group's merge-request
# approval gate no longer stands between that repo and the outside.
#
# Read from the environment rather than taken as arguments, so that every call
# site exports once (dsh_gitlab_env) and shares one URL shape:
#
#   DSH_GITLAB_HOST          required
#   DSH_GITLAB_GROUP         required; where every mirror lives
#   DSH_WORKING_NAMESPACE    optional; where KIT_WORKING_REPOS live. Unset or
#                            empty means "same as the group".
#   DSH_REMOTE_BASE          TEST ONLY. When set, every repo is
#                            <base>/<namespace>/<repo>.git rather than
#                            https://<host>/..., so a local directory of bare repos
#                            can stand in for GitLab and the clone and push paths
#                            can be exercised outside the DSH.
dsh_repo_namespace() {
    local pkg="$1" ns=""
    if declare -F dsh_is_working_repo >/dev/null && dsh_is_working_repo "$pkg"; then
        ns="${DSH_WORKING_NAMESPACE:-}"
    fi
    [ -n "$ns" ] || ns="${DSH_GITLAB_GROUP:-}"
    if [ -z "$ns" ]; then
        echo "dsh_repo_namespace: no namespace for ${pkg} - DSH_GITLAB_GROUP is unset" >&2
        return 1
    fi
    printf '%s' "$ns"
}

# The repos that live outside the group, one per line. reset_gitlab_credential.sh
# walks them: a credential stored against another namespace's path is exactly the
# stale entry it exists to clear.
dsh_namespaced_repos() {
    local r
    [ -n "${DSH_WORKING_NAMESPACE:-}" ] || return 0
    [ "$DSH_WORKING_NAMESPACE" != "${DSH_GITLAB_GROUP:-}" ] || return 0
    for r in ${KIT_WORKING_REPOS:-}; do
        printf '%s\n' "$r"
    done
}

# The full clone URL for a repo. THE one place the URL shape is assembled.
#
# An unset host or group is an error here rather than an empty path segment,
# because https://host//repo.git is a URL git will happily carry all the way to
# GitLab and be refused at, one step too late to say why.
dsh_repo_remote() {
    local pkg="$1" ns
    ns="$(dsh_repo_namespace "$pkg")" || return 1
    if [ -n "${DSH_REMOTE_BASE:-}" ]; then
        printf '%s/%s/%s.git' "${DSH_REMOTE_BASE%/}" "$ns" "$pkg"
        return 0
    fi
    if [ -z "${DSH_GITLAB_HOST:-}" ]; then
        echo "dsh_repo_remote: DSH_GITLAB_HOST is unset" >&2
        return 1
    fi
    printf 'https://%s/%s/%s.git' "${DSH_GITLAB_HOST}" "$ns" "$pkg"
}

# Publish a script's host / group / working namespace into the environment the
# functions above read. Every carried script that talks to GitLab calls this once,
# right after parsing its arguments.
dsh_gitlab_env() {
    export DSH_GITLAB_HOST="$1"
    export DSH_GITLAB_GROUP="$2"
    export DSH_WORKING_NAMESPACE="${3:-}"
}

# The --working-namespace flag to repeat on any command a script suggests running
# next, so a line copied out of a failure keeps the namespace the failing run
# used. Empty when the two namespaces are the same.
dsh_working_ns_arg() {
    local ns="${DSH_WORKING_NAMESPACE:-}"
    if [ -n "$ns" ] && [ "$ns" != "${DSH_GITLAB_GROUP:-}" ]; then
        printf ' --working-namespace %s' "$ns"
    fi
}
