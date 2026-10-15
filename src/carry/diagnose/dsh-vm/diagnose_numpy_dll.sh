#!/bin/bash
# INSIDE. "DLL load failed while importing _multiarray_umath: The parameter is
# incorrect" - but only in the installed venv, not in check_venv_location.sh's probe.
#
# That is the state this exists for, and it is more specific than the generic
# DLL failure:
#
#   check_venv_location.sh built a small probe venv on S: and imported from it
#   - PASSED, on both the inherited PATH and a clean one.
#   The full installed venv, same drive, same interpreter, then fails the same
#   import.
#
# So "S: cannot load DLLs" is already disproved. Something that is true of the
# full venv and not of the probe is doing it. The candidates, and this varies
# one thing at a time to separate them:
#
#   A. PATH CONTAMINATION THAT ONLY BITES THE FULL VENV. numpy alone loads no
#      MKL/OpenMP; scipy, scikit-learn and others do. Anaconda's Library\bin
#      on PATH then supplies a conflicting libiomp/MKL and numpy's own DLL
#      fails to initialise. A probe that installed nothing pulling MKL in could
#      not have caught this.
#   B. A DIFFERENT NUMPY. The probe installs whatever the index offers latest;
#      the install resolves whatever its constraints (or uv.lock) allow - a different
#      build entirely. Section 2 prints both versions.
#   C. THE SMB PATH AFTER ALL, but size- or layout-dependent - a deep venv on a
#      share where a shallow one worked.
#
# ENTIRELY READ-ONLY. It imports things and prints PATH; it installs nothing,
# syncs nothing and removes nothing. The repair is printed for you to run.
#
#   ./diagnose/diagnose_numpy_dll.sh          # workspace from ~/dsh-kit.env
#   ./diagnose/diagnose_numpy_dll.sh --workspace '/s/<share>/<workspace-dir>'
#
# Log: Logs/diagnose_numpy_dll.log beside this script.

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
dsh_kit_settings "$PAYLOAD_DIR" || exit 1

WORKSPACE="$KIT_WORKSPACE_DIR"
SCRIPT="${KIT_CONSOLE_SCRIPTS%% *}"

usage() {
    sed -n '2,35p' "$0"
    echo
    echo "Usage: $0 [--workspace DIR] [--script NAME]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --script)    SCRIPT="$2";    shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$WORKSPACE" ] || { echo "Error: --workspace is required (or KIT_WORKSPACE_DIR in ~/dsh-kit.env)" >&2; usage; }

hr() { echo; echo "=== $* ==="; }

VENV_PY="${WORKSPACE}/.venv/${DSH_VENV_PYTHON}"
BIN_DIR="$(dirname "$VENV_PY")"
[ -f "$VENV_PY" ] || { echo "No venv interpreter at ${VENV_PY}" >&2; exit 1; }

# The clean PATH: Windows, git, and the venv. Nothing else - in particular no
# Anaconda. Same definition check_venv_location.sh uses, so the two are
# comparable.
SYSROOT="$(cygpath -u "${SYSTEMROOT:-C:/Windows}" 2>/dev/null || echo /c/Windows)"
CLEAN_PATH="${BIN_DIR}:${SYSROOT}/System32:${SYSROOT}:${SYSROOT}/System32/Wbem:/usr/bin:/bin"

INHERITED="fail"
CLEAN="fail"

echo "diagnose_numpy_dll - ${WORKSPACE}"
echo "read-only: nothing is installed, synced or removed"

hr "1. What is on PATH that could supply a rival MKL/OpenMP"
printf '  %-24s %s\n' "CONDA_PREFIX" "${CONDA_PREFIX:-unset}"
printf '  %-24s %s\n' "anaconda entries" "$(echo "$PATH" | tr ':' '\n' | grep -ci 'anaconda\|miniconda' || true)"
echo "$PATH" | tr ':' '\n' | grep -i 'anaconda\|miniconda' | sed 's/^/      /' || true
echo "  --- PATH entries actually holding an MKL or OpenMP DLL ---"
# This is the evidence for cause A: a directory earlier on PATH than the venv
# that contains the DLLs numpy's would otherwise load.
found_rival=0
echo "$PATH" | tr ':' '\n' | while read -r d; do
    [ -d "$d" ] || continue
    hits="$(ls "$d" 2>/dev/null | grep -icE '^(libiomp5md|mkl_core|mkl_rt|libomp)\.dll$' || true)"
    [ "${hits:-0}" -gt 0 ] && echo "      ${d}"
done
ls "$SYSROOT/System32" >/dev/null 2>&1 || true

hr "2. Which numpy, and where from"
"$VENV_PY" - <<'PYEOF' 2>&1 | sed 's/^/  /'
import importlib.metadata as md
try:
    print("version:", md.version("numpy"))
except Exception as e:
    print("version: could not read -", e)
import os, sys
print("executable:", sys.executable)
sp = [p for p in sys.path if p.endswith("site-packages")]
print("site-packages:", sp[0] if sp else "?")
if sp:
    libs = os.path.join(sp[0], "numpy.libs")
    print("numpy.libs:", ", ".join(sorted(os.listdir(libs))) if os.path.isdir(libs) else "absent")
PYEOF

hr "3. import numpy, on the PATH you actually have"
if "$VENV_PY" -c "import numpy; print('  numpy', numpy.__version__, 'from', numpy.__file__)" 2>"${PAYLOAD_DIR}/.np.err"; then
    INHERITED="ok"
else
    sed 's/^/  /' "${PAYLOAD_DIR}/.np.err" | tail -8
fi
echo "  result: ${INHERITED}"

hr "4. import numpy, with PATH stripped to Windows + git + the venv"
# The single variable that separates A from B and C. Same interpreter, same
# venv, same drive - only PATH differs.
if PATH="$CLEAN_PATH" "$VENV_PY" -c "import numpy; print('  numpy', numpy.__version__)" 2>"${PAYLOAD_DIR}/.np2.err"; then
    CLEAN="ok"
else
    sed 's/^/  /' "${PAYLOAD_DIR}/.np2.err" | tail -8
fi
echo "  result: ${CLEAN}"
rm -f "${PAYLOAD_DIR}/.np.err" "${PAYLOAD_DIR}/.np2.err"

hr "5. The console script, under the clean PATH"
exe="${BIN_DIR}/${SCRIPT}"
[ -f "$exe" ] || exe="${BIN_DIR}/${SCRIPT}.exe"
SCRIPT_CLEAN="skipped"
if [ -n "$SCRIPT" ] && [ -f "$exe" ]; then
    if PATH="$CLEAN_PATH" "$exe" --help >/dev/null 2>&1; then
        SCRIPT_CLEAN="ok"
    else
        SCRIPT_CLEAN="fail"
    fi
    echo "  ${SCRIPT} --help: ${SCRIPT_CLEAN}"
else
    echo "  no console script to try"
fi

hr "Verdict"
printf '  %-30s %s\n' "import numpy, inherited PATH" "$INHERITED"
printf '  %-30s %s\n' "import numpy, clean PATH"     "$CLEAN"
printf '  %-30s %s\n' "console script, clean PATH"   "$SCRIPT_CLEAN"
echo

if [ "$INHERITED" = "fail" ] && [ "$CLEAN" = "ok" ]; then
    echo "  CAUSE A - PATH contamination. The venv is fine and S: is fine; a"
    echo "  directory ahead of it on PATH (section 1) supplies a rival"
    echo "  MKL/OpenMP DLL. A small probe misses it because numpy alone pulls no"
    echo "  MKL - scipy, scikit-learn and others do, and only the full venv"
    echo "  has them."
    echo
    echo "  IMPORTANT: re-installing with --clean-path is NOT the fix. That cleans"
    echo "  PATH for the install, not for the work you run afterwards. The fix is"
    echo "  to clean PATH in the shell you work in. Put this in ~/.bashrc:"
    echo
    echo "      export PATH=\"${BIN_DIR}:\${PATH#*Anaconda3*:}\""
    echo
    echo "  or, blunter and more reliable, set the whole thing:"
    echo
    echo "      export PATH=\"${CLEAN_PATH}\""
    echo
    echo "  Then re-run install_packages.sh. Never 'conda activate' in a shell you"
    echo "  then use for this workspace."
    exit 1
fi
if [ "$INHERITED" = "ok" ] && [ "$CLEAN" = "ok" ]; then
    echo "  numpy imports both ways, so the DLL failure is not reproducible from"
    echo "  here. Whatever failed did so under a different environment than this"
    echo "  shell has - a different PATH, or conda activated. Re-run the console"
    echo "  script from THIS shell and see section 5."
    exit 0
fi
echo "  numpy fails to import however PATH is set, so this is not contamination."
echo "  Two things left, and they are distinguishable:"
echo
echo "    CAUSE B - a different numpy from the one check_venv_location.sh installed."
echo "    Section 2 gives the version; the probe's is in check_venv_location.log."
echo "    If they differ, the installed build is the broken one and the answer"
echo "    is to pin numpy to the version that worked."
echo
echo "    CAUSE C - the SMB path after all, despite the probe passing. Test it"
echo "    by installing on a local disk:"
echo "        ./install_packages.sh --workspace '<local-dir>' --python '<python>'"
echo "    If that works, the venv goes local and the data stays on S:."
exit 1
