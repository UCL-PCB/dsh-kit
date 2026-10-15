#!/bin/bash
# INSIDE, Windows VM. Decide WHERE the venv can live before installing into it.
#
# Why this exists: on the Windows Desktop VM a full install can complete and only
# then fail, at the first import, with
#
#   ImportError: DLL load failed while importing _multiarray_umath:
#   The parameter is incorrect.
#
# That is a numpy DLL that loaded but could not initialise. On Windows it has two
# common causes and they need different fixes:
#
#   A. PATH contamination. Anaconda3's Library\bin is ahead of the venv on PATH,
#      so a different MKL/OpenMP pair is found first.
#   B. The venv is on a mapped network drive (S:, N:). Windows returns
#      ERROR_INVALID_PARAMETER - literally "The parameter is incorrect" - when
#      loading some DLLs across SMB.
#
# This script tells you which, in about three minutes, using a throwaway venv
# holding numpy, pandas, scipy and scikit-learn. Do this BEFORE
# install_packages.sh: a full install takes far longer to fail the same way.
# If your project needs none of the compiled scientific stack, this matters less -
# but a wheel with bundled DLLs anywhere in the tree is enough to hit it.
#
# It carries four packages rather than one on purpose. Each ships its own
# bundled DLL directory and registers it at import, and it is the ACCUMULATION
# of those directories that a share refuses - a numpy-only probe can pass on S:
# while the real venv fails the identical import. --package replaces the set
# (repeat it) with what your project actually pulls in.
#
#   ./check_venv_location.sh --python '/c/Program Files/Python312/python.exe'
#   ./check_venv_location.sh --python ... --candidate /s/<share>/<workspace-dir>
#   ./check_venv_location.sh --python ... --package numpy --package torch
#
# Everything lands in Logs/check_venv_location.log beside this script.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"

# Log to a file AND to the terminal, reliably. `exec > >(tee f)` loses the tail
# when stdout is a pipe, because the script can exit before tee flushes - which
# is precisely the output you came for. Re-running self with a plain pipe does
# not have that failure mode, and PIPESTATUS keeps the real exit code.
# shellcheck source=../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

PYTHON=""
CANDIDATES=()
# numpy ALONE IS NOT ENOUGH. Each of these wheels ships its own bundled DLL
# directory (numpy.libs, pandas.libs, scipy.libs, and sklearn's OpenMP runtime)
# and registers it with os.add_dll_directory at import. A probe carrying only
# numpy exercises exactly one of them, which is how a probe can pass on S: while
# the real venv - registering four - fails with the same "parameter is incorrect"
# the probe exists to predict. Test the set your project actually pulls in.
PACKAGES=(numpy pandas scipy scikit-learn)
IMPORTS=(numpy pandas scipy sklearn)

usage() {
    sed -n '2,33p' "$0"
    echo
    echo "Usage: $0 --python PATH [--candidate DIR]... [--package NAME[=IMPORT]]..."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --python)    PYTHON="$2";       shift 2 ;;
        # Probed in a dsh-venv-probe/ subdirectory, NEVER the directory itself:
        # each probe starts with rm -rf of where it builds, and the natural thing
        # to pass here is the workspace you mean to use - which may already exist.
        --candidate) CANDIDATES+=("${2%/}/dsh-venv-probe"); shift 2 ;;
        # NAME=IMPORT when the import name differs (scikit-learn=sklearn). The
        # first --package replaces the default set; the rest add to it.
        --package)
            if [ "${CUSTOM_SET:-0}" -eq 0 ]; then PACKAGES=(); IMPORTS=(); CUSTOM_SET=1; fi
            PACKAGES+=("${2%%=*}")
            if [ "${2#*=}" != "$2" ]; then IMPORTS+=("${2#*=}"); else IMPORTS+=("$(printf '%s' "$2" | tr '-' '_')"); fi
            shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$PYTHON" ] || { echo "Error: --python is required (the interpreter the probe found)" >&2; usage; }
[ -x "$PYTHON" ] || [ -f "$PYTHON" ] || { echo "Error: no interpreter at ${PYTHON}" >&2; exit 1; }

export PATH="${HOME}/.local/bin:${PATH}"
UV="$(command -v "$DSH_UV_EXE" 2>/dev/null || echo "${HOME}/.local/bin/${DSH_UV_EXE}")"
[ -x "$UV" ] || { echo "Error: uv not found - run ./install_uv.sh first" >&2; exit 1; }

# Default candidates: local disk first, then home. Local disk is the one most
# likely to work and the least likely to be tried, because the share is where
# everything else lives.
if [ ${#CANDIDATES[@]} -eq 0 ]; then
    if [ "$DSH_OS" = "windows" ]; then
        [ -n "${LOCALAPPDATA:-}" ] && CANDIDATES+=("$(cygpath -u "$LOCALAPPDATA")/dsh-venv-probe")
        CANDIDATES+=("${HOME}/dsh-venv-probe")
    else
        CANDIDATES+=("${HOME}/dsh-venv-probe" "${TMPDIR:-/tmp}/dsh-venv-probe")
    fi
fi

echo "=== Interpreter ==="
"$PYTHON" -c "import platform,sys; print('  version:', sys.version.replace(chr(10),' ')); print('  machine:', platform.machine()); print('  exe    :', sys.executable)"
echo

if [ "$DSH_OS" = "windows" ]; then
    echo "=== Windows environment that affects DLL loading ==="
    printf '  %-22s %s\n' "Anaconda on PATH" "$(echo "$PATH" | tr ':' '\n' | grep -ci 'anaconda\|miniconda' || true)  entries"
    echo "$PATH" | tr ':' '\n' | grep -i 'anaconda\|miniconda' | sed 's/^/      /' || true
    printf '  %-22s %s\n' "CONDA_PREFIX" "${CONDA_PREFIX:-unset}"
    echo "  --- mapped drives ---"
    for d in c d n q r s t; do
        [ -d "/$d" ] && printf '      %s:  present\n' "$(echo "$d" | tr 'a-z' 'A-Z')"
    done
    echo
fi

# A clean PATH: enough to run Windows and git, plus uv, and nothing else. If a
# location fails with the full PATH but passes with this one, the cause is A.
UVDIR="$(dirname "$UV")"
if [ "$DSH_OS" = "windows" ]; then
    SYSROOT="$(cygpath -u "${SYSTEMROOT:-C:/Windows}")"
    CLEAN_PATH="${UVDIR}:${SYSROOT}/System32:${SYSROOT}:${SYSROOT}/System32/Wbem:/usr/bin:/bin"
else
    CLEAN_PATH="${UVDIR}:/usr/local/bin:/usr/bin:/bin"
fi

RESULTS=()

try_location() {
    local dir="$1" label="$2" use_path="$3"
    local venv="${dir}/.venv" py="${dir}/.venv/${DSH_VENV_PYTHON}"
    printf '  %-64s ' "${label}"

    rm -rf "$dir" 2>/dev/null
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "SKIP (cannot create ${dir})"; RESULTS+=("${label}|SKIP|not writable"); return
    fi
    if ! PATH="$use_path" "$UV" venv --python "$PYTHON" "$venv" > "${dir}/step.log" 2>&1; then
        echo "FAIL (uv venv)"; RESULTS+=("${label}|FAIL|uv venv: $(tail -3 "${dir}/step.log" | tr '\n' ' ')"); return
    fi
    if ! PATH="$use_path" "$UV" pip install --python "$py" "${PACKAGES[@]}" >> "${dir}/step.log" 2>&1; then
        echo "FAIL (install)"; RESULTS+=("${label}|FAIL|install: $(tail -3 "${dir}/step.log" | tr '\n' ' ')"); return
    fi
    # Imported in ONE process, cumulatively, because that is how the real venv
    # loads them - and it is the accumulation of bundled DLL directories, not
    # any single one of them, that the share refuses.
    local imp
    imp="$(printf 'import %s; ' "${IMPORTS[@]}")"
    if PATH="$use_path" "$py" -c "${imp} print('all imported')" >> "${dir}/step.log" 2>&1; then
        echo "OK"; RESULTS+=("${label}|OK|")
    else
        echo "FAIL (import)"
        RESULTS+=("${label}|FAIL|import: $(tail -4 "${dir}/step.log" | tr '\n' ' ')")
        echo "      --- import error ---"
        tail -12 "${dir}/step.log" | sed 's/^/      /'
    fi
}

echo "=== Building a throwaway venv with ${PACKAGES[*]} in each candidate location ==="
echo "  (inherited PATH = whatever your shell has; clean PATH = no Anaconda)"
echo
for dir in "${CANDIDATES[@]}"; do
    try_location "$dir" "${dir}  [inherited PATH]" "$PATH"
    try_location "$dir" "${dir}  [clean PATH]"     "$CLEAN_PATH"
done
echo

echo "=== RESULT ==="
ok_any=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r label status detail <<< "$r"
    printf '  %-46s %s\n' "$label" "$status"
    [ -n "$detail" ] && echo "      ${detail}"
    [ "$status" = "OK" ] && ok_any=1
done
echo
echo "  How to read this:"
echo "    a location OK on clean PATH but FAIL on inherited PATH"
echo "        -> Anaconda is shadowing the venv's DLLs. Install with --clean-path"
echo "           (or KIT_CLEAN_PATH=\"yes\" in ~/dsh-kit.env); do not 'conda activate'."
echo "    every location FAILS on both PATHs, network drives included"
echo "        -> not a PATH problem. Try --candidate on a LOCAL disk."
echo "    a network location FAILS where a local one passes"
echo "        -> SMB DLL loading. Put .venv on local disk and keep only data on S:."
echo
if [ "$ok_any" -eq 1 ]; then
    echo "  Use a location marked OK as install_packages.sh's --workspace (or as
  KIT_WORKSPACE_DIR in ~/dsh-kit.env) - the directory the dsh-venv-probe/ shown
  above sat in, on the same drive. Prefer a local disk over S: or N:."
else
    echo "  Nothing passed. Do not run install_packages.sh yet - it will fail the" >&2
    echo "  same way after a much longer wait. check_venv_location.log has the detail." >&2
fi

rm -rf "${CANDIDATES[@]}" 2>/dev/null
exit 0
