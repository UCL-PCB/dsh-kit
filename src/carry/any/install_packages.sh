#!/bin/bash
# INSIDE (both boxes). Clone the project's repos - from the payload's bundles, or
# from GitLab - install them into one .venv, and prove they import.
#
#   ./install_packages.sh                                  # everything from the conf
#   ./install_packages.sh --workspace <workspace-dir> --python <full-path-to-python>
#   ./install_packages.sh --gitlab <host> --group <group>  # GitLab mode: override the conf
#
# What to clone and how to install it comes from dsh-kit.conf beside this script
# (KIT_REPOS, KIT_INSTALL_MODE, KIT_EXTRAS, KIT_IMPORT_CHECK, KIT_CONSOLE_SCRIPTS,
# KIT_GITLAB_*). Where it goes and which python comes from ~/dsh-kit.env
# (KIT_WORKSPACE_DIR, KIT_PYTHON, KIT_CLEAN_PATH) - see dsh_platform.sh. A flag
# beats both.
#
# Where the repos come from is KIT_GITLAB in the conf:
#
#   no   (bundle mode, the default) cloned straight from <repo>.bundle in this
#        payload. The clone keeps no remote - the payload directory is replaced by
#        the next one - so a refresh fetches the branch from the CURRENT payload's
#        bundle and fast-forwards to it. A mirror with local edits, or one that
#        cannot fast-forward, stops the run (see rescue_local_edits.sh).
#   yes  cloned from GitLab rather than from the bundles on purpose: this proves
#        the mirror is usable, which is what everyone inside will clone from.
#        Refreshed with git pull --ff-only.
#
# Two install modes, KIT_INSTALL_MODE in the conf:
#
#   venv       uv venv, then ONE `uv pip install -e src/a -e src/b ...`. Naming every
#              repo in the same call is what makes a first-party dependency resolve
#              to the checkout beside it rather than be looked up on Artifactory,
#              where it does not exist. Additive: re-running never removes anything.
#   workspace  a uv workspace. The root pyproject.toml is generated from the conf
#              (or is pyproject.dsh.toml from the payload, verbatim, if there is
#              one), then `uv sync --all-packages`. A uv sync is EXACT: it removes
#              whatever the lock does not name, extras included.
#
# --workspace is required on Windows. Where the venv lives is not a detail there
# - see check_venv_location.sh - so this refuses to guess. On Linux it defaults
# to ~/Scratch/<KIT_PROJECT>.
#
# GitLab mode only: sets git's credential helper to `cache --timeout=120` if none
# is configured, so the clones ask once rather than once per repo per fetch. In
# memory only; nothing is written to disk. An existing helper is left alone.
#
# --clean-path drops everything except Windows, git and uv out of PATH for the
# install and the smoke test. Use it if check_venv_location.sh showed Anaconda
# shadowing the venv's DLLs.
#
# A WORKING repo (KIT_WORKING_REPOS, the fourth column of MANIFEST.txt) is not a
# mirror: it is refreshed by being OVERWRITTEN rather than pulled, and only when
# this payload carries its bundle.
#
#   payload has <repo>.bundle  -> local edits parked on dsh-local/<stamp>, then
#                                 the checkout is forced to the payload's commit.
#                                 The outside copy wins.
#   payload does not           -> the checkout is not touched at all.
#
# Which is the switch: putting the repo in a payload is the deliberate act that
# says "the outside version wins this trip". A mirror is PULLED and asserted, so a
# local edit stops it dead - but a working repo is edited inside routinely (a
# notebook writes itself back as it is driven), so forcing is the only refresh
# that cannot hit that, and parking first means routine is not the same as lost.
# Untracked and gitignored files are never touched by any of it.
#
# Everything it prints also lands in Logs/install_packages.log in the payload.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    echo "(sourcing it makes its 'exit' close your terminal)" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"
# This clones; git has to be able to run here first.
dsh_git_guard || exit 1

# Log to a file AND to the terminal, reliably. `exec > >(tee f)` loses the tail
# when stdout is a pipe, because the script can exit before tee flushes - which
# is precisely the output you came for. Re-running self with a plain pipe does
# not have that failure mode, and PIPESTATUS keeps the real exit code.
# shellcheck source=lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

dsh_kit_settings "$PAYLOAD_DIR" || exit 1

GITLAB_HOST="$KIT_GITLAB_HOST"
GROUP="$KIT_GITLAB_GROUP"
WORKING_NAMESPACE="$KIT_WORKING_NAMESPACE"
PYTHON="$KIT_PYTHON"
WORKSPACE="$KIT_WORKSPACE_DIR"
CLEAN_PATH="$KIT_CLEAN_PATH"
ALL_EXTRAS="no"

usage() {
    echo "Usage: $0 [--workspace DIR] [--python PATH] [--clean-path]"
    echo "          [--gitlab HOST] [--group GROUP] [--working-namespace NS] [--all-extras]"
    echo
    echo "  --workspace DIR    where the clones and their .venv go. REQUIRED on Windows"
    echo "                     (or KIT_WORKSPACE_DIR in ~/dsh-kit.env);"
    echo "                     ~/Scratch/${KIT_PROJECT} on Linux"
    echo "  --python PATH      full path to the interpreter from the probe; only needed"
    echo "                     the first time, uv records it in .venv"
    echo "  --clean-path       strip Anaconda and everything else out of PATH"
    echo "  --gitlab HOST      GitLab mode only; default from the conf: ${KIT_GITLAB_HOST}"
    echo "  --group GROUP      GitLab mode only; default from the conf: ${KIT_GITLAB_GROUP}"
    echo "  --working-namespace NS  GitLab mode only: where the working repos are cloned"
    echo "                     from (default: KIT_WORKING_NAMESPACE, or the group)"
    echo
    echo "  KIT_GITLAB=${KIT_GITLAB} in dsh-kit.conf: no clones from the payload's bundles,"
    echo "  yes from GitLab."
    echo "  --all-extras       workspace mode only: uv sync --all-extras as well"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab)     GITLAB_HOST="$2"; shift 2 ;;
        --group)      GROUP="$2";       shift 2 ;;
        --python)     PYTHON="$2";      shift 2 ;;
        --workspace)  WORKSPACE="$2";   shift 2 ;;
        --clean-path) CLEAN_PATH="yes"; shift 1 ;;
        --all-extras) ALL_EXTRAS="yes"; shift 1 ;;
        --working-namespace) WORKING_NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# shellcheck disable=SC2206
PACKAGES=($KIT_REPOS)
# shellcheck disable=SC2206
MODULES=($KIT_IMPORT_CHECK)
# shellcheck disable=SC2206
CONSOLE_SCRIPTS=($KIT_CONSOLE_SCRIPTS)
MODE="$KIT_INSTALL_MODE"

dsh_no_placeholder "KIT_WORKSPACE_DIR" "$WORKSPACE" || exit 1

NS_ARG=""
if dsh_uses_gitlab; then
    SOURCE="gitlab"
    [ -n "$GITLAB_HOST" ] || { echo "Error: no GitLab host - set KIT_GITLAB_HOST or pass --gitlab" >&2; usage; }
    [ -n "$GROUP" ]       || { echo "Error: no GitLab group - set KIT_GITLAB_GROUP or pass --group" >&2; usage; }
    dsh_no_placeholder "KIT_GITLAB_GROUP" "$GROUP" || exit 1

    # Publish host / group / working namespace for dsh_repo_remote, which reads
    # them from the environment so that one function assembles every URL in every
    # carried script. NS_ARG is the flag to repeat on the commands this script
    # suggests running next; empty when both namespaces are the same.
    dsh_gitlab_env "$GITLAB_HOST" "$GROUP" "$WORKING_NAMESPACE"
    NS_ARG="$(dsh_working_ns_arg)"
else
    # Bundle mode: --gitlab / --group / --working-namespace are accepted and ignored.
    SOURCE="bundles"
fi

if [ -z "$WORKSPACE" ]; then
    if [ "$DSH_OS" = "windows" ]; then
        echo "Error: --workspace is required on Windows." >&2
        echo "Run ./check_venv_location.sh first and use a location it marked OK," >&2
        echo "then pass it as --workspace or set KIT_WORKSPACE_DIR in ~/dsh-kit.env." >&2
        exit 1
    fi
    WORKSPACE="${HOME}/Scratch/${KIT_PROJECT}"
fi

export PATH="${HOME}/.local/bin:${PATH}"
UV="$(command -v "$DSH_UV_EXE" 2>/dev/null || echo "${HOME}/.local/bin/${DSH_UV_EXE}")"
[ -x "$UV" ] || { echo "Error: uv not on PATH - run ./install_uv.sh first" >&2; exit 1; }

if [ "$CLEAN_PATH" = "yes" ]; then
    UVDIR="$(dirname "$UV")"
    GITDIR="$(dirname "$(command -v git)")"
    if [ "$DSH_OS" = "windows" ]; then
        SYSROOT="$(cygpath -u "${SYSTEMROOT:-C:/Windows}")"
        export PATH="${UVDIR}:${GITDIR}:${SYSROOT}/System32:${SYSROOT}:${SYSROOT}/System32/Wbem:/usr/bin:/bin"
    else
        export PATH="${UVDIR}:${GITDIR}:/usr/local/bin:/usr/bin:/bin"
    fi
    unset CONDA_PREFIX CONDA_DEFAULT_ENV PYTHONHOME PYTHONPATH
    echo "=== PATH stripped to: ==="
    echo "$PATH" | tr ':' '\n' | sed 's/^/  /'
    echo
fi

echo "=== Plan ==="
printf '  %-16s %s\n' "project"   "$KIT_PROJECT"
printf '  %-16s %s\n' "platform"  "$DSH_OS"
printf '  %-16s %s\n' "repos"     "${PACKAGES[*]}"
printf '  %-16s %s\n' "mode"      "$MODE"
printf '  %-16s %s\n' "source"    "$SOURCE  (KIT_GITLAB=${KIT_GITLAB})"
printf '  %-16s %s\n' "extras"    "${KIT_EXTRAS:-(none)}"
printf '  %-16s %s\n' "workspace" "$WORKSPACE"
printf '  %-16s %s\n' "uv"        "$UV ($("$UV" --version 2>&1))"
printf '  %-16s %s\n' "python"    "${PYTHON:-(whatever .venv already records)}"
[ -n "$KIT_PYTHON_SPEC" ] && printf '  %-16s %s\n' "requires"  "$KIT_PYTHON_SPEC"
echo

# One clone plus a fetch per repo is two credential prompts per repo with no
# helper configured. The cache helper keeps the credential in memory only - never
# on disk, unlike credential.store, which would write a DSH account password in
# plaintext to ~/.git-credentials.
#
# Only set it if nothing is configured: an operator who has already chosen a
# helper (or a keyring) should keep it.
#
# Bundle mode skips all of it: every clone and fetch reads a local file.
if [ "$SOURCE" = "gitlab" ]; then
    echo "=== git credential helper ==="
    if [ -n "$(git config --global --get credential.helper 2>/dev/null)" ]; then
        printf '  %s\n' "already set to: $(git config --global --get credential.helper)  - left alone"
    elif ! git help -a 2>/dev/null | grep -q credential-cache; then
        printf '  %s\n' "git-credential-cache not available here - expect one prompt per clone"
    else
        git config --global credential.helper 'cache --timeout=120'
        printf '  %s\n' "set to: cache --timeout=120  (in memory, 2 minutes, never written to disk)"
        printf '  %s\n' "clear it early with:  git credential-cache exit"
        printf '  %s\n' "undo with:            git config --global --unset credential.helper"
    fi
    echo
fi

MANIFEST="${PAYLOAD_DIR}/MANIFEST.txt"
if [ ! -s "$MANIFEST" ]; then
    echo "MANIFEST.txt missing or empty at ${MANIFEST}" >&2
    echo "Nothing to verify against. That is a FAILURE, not a pass." >&2
    exit 1
fi

# Two kinds of repo, and the payload says which is which in MANIFEST.txt's fourth
# column:
#
#   mirror   read-only inside. Pulled to the payload's commit and ASSERTED against
#            it, because the whole point of the bundles is that a SHA means the
#            same thing on both sides of the airlock. An edit here is a fault.
#   working  EDITED inside - that is what it is for. Refreshed by overwrite, see
#            the header; nothing is asserted about its HEAD otherwise.
#
# A line with no fourth column is a mirror.
manifest_line()   { awk -v p="$1" '$1==p {print; exit}' "$MANIFEST"; }
manifest_role()   { awk -v p="$1" '$1==p {print ($4 == "" ? "mirror" : $4)}' "$MANIFEST"; }
manifest_branch() { awk -v p="$1" '$1==p {print $2}' "$MANIFEST"; }
manifest_sha()    { awk -v p="$1" '$1==p {print $3}' "$MANIFEST"; }

STALE_PULL=0
WORKING_REPOS=""
WORKING_PARKED=""
WORKING_OVERWRITE_FAILED=""
if [ "$SOURCE" = "gitlab" ]; then
    echo "=== Cloning from GitLab into ${WORKSPACE}/src ==="
    echo "  from $(dirname "$(dsh_repo_remote "${PACKAGES[0]}")")/"
    if [ -n "$NS_ARG" ] && [ -n "$KIT_WORKING_REPOS" ]; then
        echo "  working repos (${KIT_WORKING_REPOS}) from namespace ${WORKING_NAMESPACE} instead"
    fi
else
    echo "=== Cloning from the payload's bundles into ${WORKSPACE}/src ==="
    echo "  from ${PAYLOAD_DIR}/<repo>.bundle"
fi
mkdir -p "${WORKSPACE}/src" || { echo "Error: cannot create ${WORKSPACE}/src" >&2; exit 1; }
for pkg in "${PACKAGES[@]}"; do
    dir="${WORKSPACE}/src/${pkg}"
    # A repo this payload does not carry is left exactly as it is - cloned or not.
    if [ -z "$(manifest_line "$pkg")" ]; then
        if [ -d "${dir}/.git" ]; then
            printf '  %-26s not in this payload, checkout left alone\n' "$pkg"
        else
            printf '  %-26s not in this payload and never cloned - NOT INSTALLABLE\n' "$pkg"
            STALE_PULL=1
        fi
        continue
    fi
    role="$(manifest_role "$pkg")"
    [ -n "$role" ] || role="mirror"
    [ "$role" = "working" ] && WORKING_REPOS="${WORKING_REPOS} ${pkg}"

    if [ ! -d "${dir}/.git" ] && [ "$SOURCE" = "bundles" ]; then
        bundle="${PAYLOAD_DIR}/${pkg}.bundle"
        mbranch="$(manifest_branch "$pkg")"
        if [ ! -f "$bundle" ]; then
            printf '  %-26s in MANIFEST.txt but %s.bundle is not in the payload - NOT INSTALLABLE\n' "$pkg" "$pkg"
            STALE_PULL=1
            continue
        fi
        # --branch so the checkout is on the manifest's branch, not whatever the
        # bundle's HEAD happened to be. The origin a clone records would point into
        # THIS payload directory, which the next payload replaces - so it is
        # removed, and every refresh names the current payload's bundle instead.
        git clone -q --branch "$mbranch" "$bundle" "$dir" || {
            echo "Error: clone of ${pkg} from ${bundle} failed." >&2
            echo "  'failed to stat' / permission denied" >&2
            echo "      -> ./diagnose/diagnose_git_permissions.sh" >&2
            echo "  'not a valid bundle' / 'does not look like a v2 bundle'" >&2
            echo "      -> the bundle was damaged on the way in: ./verify_payload.sh" >&2
            echo "  'Remote branch ... not found'" >&2
            echo "      -> MANIFEST.txt names a branch the bundle does not carry; re-export" >&2
            exit 1
        }
        git -C "$dir" remote remove origin 2>/dev/null || true
        printf '  %-26s cloned from bundle at %s  (%s)\n' "$pkg" "$(git -C "$dir" rev-parse --short HEAD)" "$role"
        continue
    fi

    if [ ! -d "${dir}/.git" ]; then
        git clone "$(dsh_repo_remote "$pkg")" "$dir" || {
            echo "Error: clone of ${pkg} failed." >&2
            echo "  'unable to get local issuer certificate'" >&2
            echo "      -> git config --global http.sslBackend schannel" >&2
            echo "  'failed to stat' / no prompt at all" >&2
            echo "      -> ./diagnose/diagnose_git_permissions.sh" >&2
            echo "  404 / 'not found'" >&2
            echo "      -> the GitLab project does not exist, or the mirror never pushed it:" >&2
            echo "         ./mirror_to_gitlab.sh --refresh${NS_ARG}" >&2
            exit 1
        }
        printf '  %-26s cloned at %s  (%s)\n' "$pkg" "$(git -C "$dir" rev-parse --short HEAD)" "$role"
        continue
    fi

    if [ "$role" = "working" ]; then
        bundle="${PAYLOAD_DIR}/${pkg}.bundle"
        mbranch="$(manifest_branch "$pkg")"

        if [ ! -f "$bundle" ]; then
            printf '  %-26s working repo - NOT in this payload, checkout left alone\n' "$pkg"
            continue
        fi
        if [ -z "$mbranch" ]; then
            printf '  %-26s working repo - no branch in MANIFEST.txt, cannot refresh\n' "$pkg"
            WORKING_OVERWRITE_FAILED="${WORKING_OVERWRITE_FAILED} ${pkg}"
            continue
        fi
        # Straight from the bundle, not from GitLab: the overwrite is "what the
        # payload carries", and the bundle IS that, with no mirror in between to
        # be stale.
        if ! git -C "$dir" fetch -q --force "$bundle" "refs/heads/${mbranch}:refs/outside/${mbranch}"; then
            printf '  %-26s working repo - COULD NOT read %s.bundle, checkout left alone\n' "$pkg" "$pkg"
            WORKING_OVERWRITE_FAILED="${WORKING_OVERWRITE_FAILED} ${pkg}"
            continue
        fi
        incoming="refs/outside/${mbranch}"

        dirty="$(git -C "$dir" status --porcelain --untracked-files=no)"
        ahead="$(git -C "$dir" rev-list --count "${incoming}..HEAD" 2>/dev/null || echo 0)"
        if [ -n "$dirty" ] || [ "$ahead" != "0" ]; then
            park="dsh-local/$(date '+%Y%m%d-%H%M%S')"
            # A fresh account inside has no user.name / user.email, and git refuses
            # to commit without them. Unchecked, that failure let the overwrite
            # below carry the uncommitted edit onto the payload's branch while the
            # "parked" branch held nothing. Supply an identity only if there is
            # none, and treat a failed park commit as a failed park.
            ident=()
            git -C "$dir" config user.name  >/dev/null 2>&1 || ident+=(-c "user.name=dsh-kit")
            git -C "$dir" config user.email >/dev/null 2>&1 || ident+=(-c "user.email=dsh-kit@localhost")
            parked=1
            if git -C "$dir" checkout -q -B "$park" 2>/dev/null; then
                git -C "$dir" add -u
                if [ -n "$dirty" ]; then
                    git ${ident[@]+"${ident[@]}"} -C "$dir" commit -q -m "VM state parked before the payload overwrote ${pkg}

Everything this checkout had that the payload's commit does not is here:
$(printf '%s\n' "$dirty" | wc -l | tr -d ' ') modified file(s), ${ahead} commit(s).
Nothing was discarded. To look at it:  git log ${park}
To take a file back:  git checkout ${park} -- <path>" || parked=0
                fi
            else
                parked=0
            fi
            if [ "$parked" -eq 1 ]; then
                printf '  %-26s working repo - VM state parked on %s\n' "$pkg" "$park"
                printf '  %-26s   get it back:  git -C "%s" checkout %s -- <path>\n' "" "$dir" "$park"
                WORKING_PARKED="${WORKING_PARKED} ${pkg}:${park}"
            else
                printf '  %-26s working repo - COULD NOT park local state, NOT overwriting\n' "$pkg"
                WORKING_OVERWRITE_FAILED="${WORKING_OVERWRITE_FAILED} ${pkg}"
                continue
            fi
        fi

        if git -C "$dir" checkout -q -B "$mbranch" "$incoming"; then
            printf '  %-26s working repo - OVERWRITTEN to %s (%s)\n' \
                "$pkg" "$(git -C "$dir" rev-parse --short HEAD)" "$mbranch"
        else
            printf '  %-26s working repo - reset to the payload commit FAILED\n' "$pkg"
            WORKING_OVERWRITE_FAILED="${WORKING_OVERWRITE_FAILED} ${pkg}"
        fi
        continue
    fi

    if [ "$SOURCE" = "bundles" ]; then
        # A mirror refreshed from the bundle: fetch the manifest's branch, then
        # fast-forward to it and nothing else. A tracked edit is refused outright -
        # a fast-forward can carry one along silently, and a mirror is read-only.
        bundle="${PAYLOAD_DIR}/${pkg}.bundle"
        mbranch="$(manifest_branch "$pkg")"
        if [ ! -f "$bundle" ]; then
            echo "  ${pkg}: in MANIFEST.txt but ${pkg}.bundle is not in the payload." >&2
            STALE_PULL=1
            continue
        fi
        if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
            echo "  ${pkg}: has local edits to tracked files - this mirror is NOT being updated." >&2
            git -C "$dir" status --short --untracked-files=no | sed 's/^/    /' >&2
            STALE_PULL=1
            continue
        fi
        if ! git -C "$dir" fetch -q --force "$bundle" "refs/heads/${mbranch}:refs/outside/${mbranch}"; then
            echo "  ${pkg}: could not read ${pkg}.bundle - this mirror is NOT being updated." >&2
            STALE_PULL=1
            continue
        fi
        cur="$(git -C "$dir" symbolic-ref --quiet --short HEAD || echo "")"
        if [ "$cur" != "$mbranch" ]; then
            if git -C "$dir" rev-parse -q --verify "refs/heads/${mbranch}" >/dev/null; then
                git -C "$dir" checkout -q "$mbranch"
            else
                git -C "$dir" checkout -q -b "$mbranch" "refs/outside/${mbranch}"
            fi
        fi
        if ! git -C "$dir" merge -q --ff-only "refs/outside/${mbranch}" 2>&1 | sed 's/^/    /'; then
            echo "  ${pkg}: cannot fast-forward to the payload's ${mbranch} - this mirror is NOT being updated." >&2
            STALE_PULL=1
        fi
        printf '  %-26s refreshed from bundle, now at %s\n' "$pkg" "$(git -C "$dir" rev-parse --short HEAD)"
        continue
    fi

    git -C "$dir" fetch origin --prune --tags 2>&1 | sed 's/^/    /'
    if ! git -C "$dir" pull --ff-only 2>&1 | sed 's/^/    /'; then
        echo "  ${pkg}: pull --ff-only FAILED - this clone is NOT being updated." >&2
        STALE_PULL=1
    fi
    printf '  %-26s already cloned, now at %s\n' "$pkg" "$(git -C "$dir" rev-parse --short HEAD)"
done
echo

echo "=== Cloned HEADs vs MANIFEST.txt (mirror repos) ==="
DRIFT=0
for pkg in "${PACKAGES[@]}"; do
    [ -z "$(manifest_line "$pkg")" ] && continue
    role="$(manifest_role "$pkg")"
    [ "$role" = "working" ] && continue
    head_sha="$(git -C "${WORKSPACE}/src/${pkg}" rev-parse HEAD)"
    want_sha="$(manifest_sha "$pkg")"
    if [ "$head_sha" = "$want_sha" ]; then
        printf '  %-26s %s  matches manifest\n' "$pkg" "${head_sha:0:8}"
    else
        printf '  %-26s %s  MISMATCH, manifest says %s\n' "$pkg" "${head_sha:0:8}" "${want_sha:0:8}"
        DRIFT=1
    fi
done
if [ "$DRIFT" -ne 0 ] || [ "$STALE_PULL" -ne 0 ]; then
    echo >&2
    echo "RESULT: FAIL - what is checked out is not what this payload carries." >&2
    echo "  Stopping rather than installing code the manifest does not describe." >&2
    echo >&2
    if [ "$SOURCE" = "bundles" ]; then
    echo "  Most likely, in this order:" >&2
    echo "  1. A mirror has local edits, or commits the payload does not have, so it" >&2
    echo "     could not fast-forward (the lines above say which). Park the work and" >&2
    echo "     restore the checkout:  ./rescue_local_edits.sh --rescue --repo <repo>" >&2
    echo "  2. A repo in MANIFEST.txt has no bundle in this payload. Re-run" >&2
    echo "     ./verify_payload.sh - the payload is incomplete; rebuild it outside." >&2
    echo "  3. A repo in KIT_REPOS was never in any payload. Export it outside and" >&2
    echo "     carry it in." >&2
    echo "  4. Nothing else works: delete ${WORKSPACE}/src/<repo> and re-run; it is" >&2
    echo "     re-cloned from the bundle." >&2
    else
    echo "  Most likely, in this order:" >&2
    echo "  1. GitLab has not been refreshed from THIS payload. Re-run the mirror:" >&2
    echo "       ./mirror_to_gitlab.sh --refresh --gitlab ${GITLAB_HOST} --group ${GROUP}${NS_ARG}" >&2
    echo "     then re-run this script." >&2
    echo "  2. The GitLab project does not exist, so the mirror had nothing to push" >&2
    echo "     into. Create it EMPTY - no README, no initial commit - and re-mirror." >&2
    echo "  3. The local clone has diverged and cannot fast-forward. Delete" >&2
    echo "     ${WORKSPACE}/src/<repo> and re-run; it will be re-cloned." >&2
    echo "  4. A repo in KIT_REPOS was never in any payload. Export it outside and" >&2
    echo "     carry it in." >&2
    fi
    echo >&2
    echo "  Note these are all MIRROR repos - read-only inside. If one of them has" >&2
    echo "  local edits, that is a fault rather than work, but it is still work" >&2
    echo "  somebody did: ./rescue_local_edits.sh parks it before restoring." >&2
    exit 1
fi
echo

if [ -n "$WORKING_REPOS" ]; then
    echo "=== Working repos - overwritten only when this payload carries them ==="
    for pkg in $WORKING_REPOS; do
        dir="${WORKSPACE}/src/${pkg}"
        msha="$(manifest_sha "$pkg")"
        [ -d "${dir}/.git" ] || { printf '  %-26s not cloned\n' "$pkg"; continue; }
        cur="$(git -C "$dir" symbolic-ref --quiet --short HEAD || echo "DETACHED")"
        head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo '?')"
        if [ ! -f "${PAYLOAD_DIR}/${pkg}.bundle" ]; then
            printf '  %-26s on %s at %s - NOT in this payload, untouched\n' \
                "$pkg" "$cur" "${head:0:8}"
        elif [ "$head" = "$msha" ]; then
            printf '  %-26s on %s at %s - overwritten by this payload\n' \
                "$pkg" "$cur" "${head:0:8}"
        else
            printf '  %-26s on %s at %s - EXPECTED %s, see below\n' \
                "$pkg" "$cur" "${head:0:8}" "${msha:0:8}"
        fi
    done
    echo
fi

if [ -n "$WORKING_PARKED" ]; then
    echo "=== What the overwrite moved out of the way ==="
    for entry in $WORKING_PARKED; do
        pkg="${entry%%:*}"; park="${entry#*:}"
        dir="${WORKSPACE}/src/${pkg}"
        printf '  %-26s %s\n' "$pkg" "$park"
        printf '      %s\n' "git -C '${dir}' log --stat ${park}       # what was there"
        printf '      %s\n' "git -C '${dir}' checkout ${park} -- <path>   # take one file back"
    done
    echo
    echo "  Nothing was discarded. These branches are local to this machine and stay"
    echo "  until you delete them. Untracked and gitignored files were never touched."
    echo
fi

if [ -n "$WORKING_OVERWRITE_FAILED" ]; then
    echo "=== A working repo could NOT be refreshed ===" >&2
    for pkg in $WORKING_OVERWRITE_FAILED; do
        printf '  %s\n' "$pkg" >&2
    done
    echo >&2
    echo "  The checkout was left exactly as it was - this fails safe rather than" >&2
    echo "  half-overwriting. The install below carries on against the code that is" >&2
    echo "  there, which may be older than this payload's." >&2
    echo >&2
fi

# extras_for <repo>  ->  "[a,b]" from KIT_EXTRAS' "<repo>[a,b]", or nothing.
extras_for() {
    local spec
    for spec in $KIT_EXTRAS; do
        case "$spec" in
            "$1["*"]") printf '%s' "${spec#"$1"}"; return 0 ;;
        esac
    done
}

cd "$WORKSPACE" || exit 1
VENV_PY="${WORKSPACE}/.venv/${DSH_VENV_PYTHON}"

install_fail() {
    echo >&2
    echo "RESULT: FAIL - $1 did not complete." >&2
    echo "  a THIRD-PARTY name  -> Artifactory has not mirrored it. Write down which;" >&2
    echo "                         that is a mirror request, and the likeliest reason" >&2
    echo "                         to need a second visit." >&2
    echo "  a FIRST-PARTY name  -> a repo depends on something not in KIT_REPOS. Add" >&2
    echo "                         it to dsh-kit.conf outside and carry it in." >&2
    echo "  a build backend     -> (hatchling, setuptools, uv_build ...) Artifactory" >&2
    echo "                         must mirror the backend each repo names in its" >&2
    echo "                         [build-system] too, not just its dependencies." >&2
    echo "  interpreter         -> the Python is outside ${KIT_PYTHON_SPEC:-what the repos require}." >&2
    exit 1
}

if [ "$MODE" = "workspace" ]; then
    echo "=== Workspace root pyproject.toml ==="
    ROOT_NEW="${PAYLOAD_DIR}/pyproject.workspace.generated.toml"
    if [ -f "${PAYLOAD_DIR}/pyproject.dsh.toml" ]; then
        cp "${PAYLOAD_DIR}/pyproject.dsh.toml" "$ROOT_NEW"
        echo "  from the payload's pyproject.dsh.toml, verbatim"
    else
        {
            echo "# Generated by install_packages.sh from dsh-kit.conf. Edit the conf, not this."
            echo "[project]"
            echo "name = \"${KIT_PROJECT}-workspace\""
            echo "version = \"0.0.0\""
            [ -n "$KIT_PYTHON_SPEC" ] && echo "requires-python = \"${KIT_PYTHON_SPEC}\""
            echo "dependencies = ["
            for pkg in "${PACKAGES[@]}"; do
                echo "    \"${pkg}$(extras_for "$pkg")\","
            done
            echo "]"
            echo
            echo "[tool.uv]"
            echo "package = false"
            echo
            echo "[tool.uv.workspace]"
            echo "members = ["
            for pkg in "${PACKAGES[@]}"; do
                echo "    \"src/${pkg}\","
            done
            echo "]"
            echo
            echo "[tool.uv.sources]"
            for pkg in "${PACKAGES[@]}"; do
                echo "${pkg} = { workspace = true }"
            done
        } > "$ROOT_NEW"
        echo "  generated from dsh-kit.conf"
    fi
    if [ -f "${WORKSPACE}/pyproject.toml" ] && cmp -s "$ROOT_NEW" "${WORKSPACE}/pyproject.toml"; then
        echo "  already in place and identical"
    else
        if [ -f "${WORKSPACE}/pyproject.toml" ]; then
            cp "${WORKSPACE}/pyproject.toml" "${WORKSPACE}/pyproject.toml.bak"
            echo "  replaced (previous saved as pyproject.toml.bak)"
        else
            echo "  copied in"
        fi
        cp "$ROOT_NEW" "${WORKSPACE}/pyproject.toml"
    fi
    rm -f "$ROOT_NEW"
    echo

    SYNC_ARGS=(sync --all-packages)
    [ "$ALL_EXTRAS" = "yes" ] && SYNC_ARGS+=(--all-extras)
    [ -n "$PYTHON" ] && SYNC_ARGS+=(--python "$PYTHON")
    echo "=== uv ${SYNC_ARGS[*]} ==="
    "$UV" "${SYNC_ARGS[@]}" || install_fail "uv sync"
    echo
else
    echo "=== uv venv ==="
    if [ -f "$VENV_PY" ]; then
        echo "  ${WORKSPACE}/.venv already exists - reused"
        if [ -n "$PYTHON" ]; then
            echo "  (--python ignored: to rebuild on a different interpreter, delete .venv first)"
        fi
    else
        VENV_ARGS=(venv)
        [ -n "$PYTHON" ] && VENV_ARGS+=(--python "$PYTHON")
        VENV_ARGS+=("${WORKSPACE}/.venv")
        "$UV" "${VENV_ARGS[@]}" || install_fail "uv venv"
    fi
    echo

    PIP_ARGS=(pip install --python "$VENV_PY")
    for pkg in "${PACKAGES[@]}"; do
        PIP_ARGS+=(-e "./src/${pkg}$(extras_for "$pkg")")
    done
    echo "=== uv ${PIP_ARGS[*]} ==="
    "$UV" "${PIP_ARGS[@]}" || install_fail "uv pip install"
    echo
fi

echo "=== Checkpoint: do the packages import? ==="
printf '  %-26s ' "interpreter"
"$VENV_PY" -c "import sys,platform; print(sys.version.split()[0], platform.machine())" || {
    echo "  the venv interpreter does not run at all: ${VENV_PY}" >&2
    exit 1
}

rc=0
FAILED_MODS=""
for mod in "${MODULES[@]}"; do
    printf '  %-26s ' "$mod"
    if "$VENV_PY" -c "import ${mod}" 2>"${PAYLOAD_DIR}/import_err_${mod}.txt"; then
        echo "OK"
        rm -f "${PAYLOAD_DIR}/import_err_${mod}.txt"
    else
        echo "FAILED"
        sed 's/^/      /' "${PAYLOAD_DIR}/import_err_${mod}.txt"
        echo "      (also saved as import_err_${mod}.txt)"
        FAILED_MODS="${FAILED_MODS} ${mod}"
        rc=1
    fi
done
if [ "$rc" -ne 0 ]; then
    echo >&2
    echo "RESULT: FAIL - import checkpoint. Failed:${FAILED_MODS}" >&2
    echo "  'DLL load failed ... The parameter is incorrect'" >&2
    echo "      -> a Windows DLL problem, not a packaging one. Re-run" >&2
    echo "         ./check_venv_location.sh and follow what it says: either install" >&2
    echo "         with --clean-path, or move --workspace off the network drive." >&2
    echo "         ./diagnose/diagnose_numpy_dll.sh narrows it down." >&2
    echo "  ModuleNotFoundError on the module itself" >&2
    echo "      -> its import name is not its repo name. List the real import names" >&2
    echo "         in KIT_IMPORT_CHECK in dsh-kit.conf." >&2
    echo "  ModuleNotFoundError on a THIRD-PARTY name -> Artifactory mirror gap, or a" >&2
    echo "         dependency the repo imports but never declared." >&2
    echo "  ./diagnose/diagnose_import_chain.sh --workspace '${WORKSPACE}' walks it." >&2
    exit 1
fi
echo

STUB_ONLY=""
if [ "${#CONSOLE_SCRIPTS[@]}" -gt 0 ]; then
    echo "=== Smoke-testing the console scripts ==="
    BIN_DIR="$(dirname "$VENV_PY")"
    WRAP_DIR="${HOME}/.local/bin"
    # Run the INSTALLED script directly, not through `uv run`. `uv run` performs an
    # implicit sync, and in a uv workspace a sync is exact - so it uninstalls the
    # extras this environment was built with: a check that damages what it checks.
    for script in "${CONSOLE_SCRIPTS[@]}"; do
        printf '  %-26s ' "$script"
        exe="${BIN_DIR}/${script}"
        [ -f "$exe" ] || exe="${BIN_DIR}/${script}.exe"
        if [ ! -f "$exe" ]; then
            echo "MISSING (no entry point in ${BIN_DIR})"
            rc=1
            continue
        fi
        if "$exe" --help > "${PAYLOAD_DIR}/console_err_${script}.txt" 2>&1; then
            echo "OK"
            rm -f "${PAYLOAD_DIR}/console_err_${script}.txt"
            continue
        fi
        # The .exe failed. On a Windows SMB share the launcher stub itself can fail
        # to start while the function behind it is fine - so call the entry point
        # in-process, bypassing the launcher, before blaming the code.
        if "$VENV_PY" -c '
import sys
from importlib.metadata import entry_points
name = sys.argv[1]
eps = [e for e in entry_points(group="console_scripts") if e.name == name]
if not eps:
    print("no console_scripts entry point named %r is installed" % name)
    raise SystemExit(1)
sys.argv = [name, "--help"]
raise SystemExit(eps[0].load()())
' "$script" > "${PAYLOAD_DIR}/console_inproc_${script}.txt" 2>&1; then
            echo "STUB FAILED, function OK"
            STUB_ONLY="${STUB_ONLY} ${script}"
            rm -f "${PAYLOAD_DIR}/console_err_${script}.txt" \
                  "${PAYLOAD_DIR}/console_inproc_${script}.txt"
        else
            echo "FAILED"
            sed 's/^/      /' "${PAYLOAD_DIR}/console_err_${script}.txt" | tail -12
            echo "      --- and in-process, with the launcher bypassed: ---"
            sed 's/^/      /' "${PAYLOAD_DIR}/console_inproc_${script}.txt" | tail -12
            rc=1
        fi
    done

    if [ -n "$STUB_ONLY" ]; then
        first="${STUB_ONLY# }"; first="${first%% *}"
        echo
        echo "  The .exe launchers for:${STUB_ONLY}"
        echo "  will not run, but the entry points behind them do. This is the known SMB"
        echo "  launcher problem, not a dependency, mirror, extras or PATH problem - do"
        echo "  not re-install, re-mirror or re-cut bundles over it. Fix it with wrappers:"
        echo
        echo "    ./make_console_wrappers.sh --workspace '${WORKSPACE}'"
        echo
        if [ -f "${WRAP_DIR}/${first}" ]; then
            echo "  ${WRAP_DIR} already holds wrappers from an earlier run. They are not"
            echo "  what was tested above - this section always tests the .exe, so it will"
            echo "  report this every rebuild. Check the wrappers win on PATH:"
            echo "      type -a ${first}      # the first hit must be ${WRAP_DIR}"
        else
            echo "  Then keep them ahead of the venv's Scripts directory on PATH:"
            echo "      echo 'export PATH=\"${WRAP_DIR}:\$PATH\"' >> ~/.bashrc"
        fi
        echo
        echo "  Call them by NAME once wrapped - never 'uv run <script>'. uv run execs"
        echo "  the .exe in .venv/Scripts directly, so it bypasses the wrappers no"
        echo "  matter how PATH is ordered, and fails with the same DLL message."
        echo
        echo "  Windows only. Do NOT carry the wrappers to the cluster."
    fi
    echo
fi

if [ "$rc" -eq 0 ]; then
    echo "RESULT: PASS"
    echo "  workspace: ${WORKSPACE}"
    echo "  python:    ${VENV_PY}"
    [ "$MODE" = "workspace" ] && echo "  uv.lock:   keep it - it is what makes the next sync reproducible"
    if [ -n "$STUB_ONLY" ]; then
        # A PASS here means the CODE is good. It does not mean you can type the
        # script's name at a prompt, and saying PASS without this line would be a
        # pass for the wrong reason.
        echo "  caveat:    the .exe launchers do not run -${STUB_ONLY}"
        echo "             run make_console_wrappers.sh before using them by name"
    fi
else
    echo "RESULT: FAIL - a console script did not run." >&2
    echo "The traceback above is the answer; do not go by this list alone." >&2
    echo "  MISSING, no entry point   -> the venv was built from a source that does" >&2
    echo "                               not declare it. Compare the cloned SHAs" >&2
    echo "                               above against MANIFEST.txt - only a" >&2
    echo "                               MISMATCH means the mirror is at fault." >&2
    echo "  ImportError naming an extra -> the extras are not installed. In workspace" >&2
    echo "                               mode, anything that ran 'uv run' or a bare" >&2
    echo "                               'uv sync' strips them, because a uv sync is" >&2
    echo "                               exact. Re-run this script." >&2
    echo "  ModuleNotFoundError, third-party -> Artifactory mirror gap." >&2
    echo "  ModuleNotFoundError, first-party -> KIT_REPOS is missing a repo." >&2
    echo "NOT in this list: the SMB launcher problem. A script whose .exe fails but" >&2
    echo "whose entry point runs is reported as 'STUB FAILED, function OK' and does" >&2
    echo "not fail the install, so if you are reading this it is something else." >&2
    echo "./diagnose/diagnose_console_scripts.sh --workspace '${WORKSPACE}' sorts these out." >&2
    exit 1
fi
