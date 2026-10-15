#!/bin/bash
# INSIDE. numpy imports fine, but the packages - or a console script - die
# importing numpy (or another compiled package).
#
# The state this exists for, which is narrower than a generic DLL failure:
#
#   diagnose_numpy_dll.sh: `import numpy` OK on the inherited PATH AND on a
#   clean one. Same venv, same drive, same interpreter.
#   The real thing, on that same clean PATH: still fails, with
#   "DLL load failed while importing _multiarray_umath: The parameter is
#   incorrect".
#
# So it is not PATH, and it is not numpy in isolation. Two things are still
# different between the two, and this separates them by varying one at a time:
#
#   A. THE IMPORT CHAIN. numpy alone registers ONE extra DLL directory
#      (numpy.libs, via os.add_dll_directory). A real project typically pulls
#      pandas, scipy, scikit-learn, numba and friends too, which register
#      pandas.libs, scipy.libs, llvmlite.libs as well - all on the share. Across
#      SMB, "The parameter is incorrect" IS ERROR_INVALID_PARAMETER from the
#      loader. A check_venv_location.sh probe with too small a package set
#      exercises too few of those directories to catch it.
#   B. THE LAUNCHER. A console script is a generated .exe stub, not python.exe.
#      If the stub is the thing that cannot be loaded across SMB, every console
#      script fails while `python -c` on the same venv works.
#
# Section 3 decides it: the SAME entry-point function, called in-process by
# python, vs called through the .exe. If in-process works and the .exe does
# not, it is B. If both fail at the same import, it is A.
#
# ENTIRELY READ-ONLY. Imports and runs --help; installs nothing, syncs nothing.
#
#   ./diagnose/diagnose_import_chain.sh          # workspace from ~/dsh-kit.env
#   ./diagnose/diagnose_import_chain.sh --workspace '/s/<share>/<workspace-dir>'
#   ./diagnose/diagnose_import_chain.sh --script <console-script>
#
# Log: Logs/diagnose_import_chain.log in the payload. Tracebacks are kept in full
# - the last line of one is the whole diagnosis.

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
    sed -n '2,38p' "$0"
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

echo "diagnose_import_chain - ${WORKSPACE}"
echo "read-only: nothing is installed, synced or removed"

hr "1. Which DLL directories the venv will register, and where they live"
"$VENV_PY" - <<'PYEOF' 2>&1 | sed 's/^/  /'
import os, sys
sp = next((p for p in sys.path if p.endswith("site-packages")), None)
print("site-packages:", sp)
if sp:
    libs = sorted(d for d in os.listdir(sp) if d.endswith(".libs"))
    print("bundled DLL dirs:", len(libs))
    for d in libs:
        n = len(os.listdir(os.path.join(sp, d)))
        print(f"    {d:<24} {n} dll(s)")
    print("on a network path:", "yes" if not sp[:2].lower().startswith("c:") else "no")
PYEOF

hr "2. The import chain, one step at a time, in ONE process"
# Cumulative and in dependency order, so the FIRST failure names the package
# whose DLL directory the loader choked on: the compiled packages that bundle
# DLLs first (only those actually installed), then the project's own modules
# from KIT_IMPORT_CHECK. Each line is printed before the import is attempted, so
# a hard crash still shows how far it got.
# shellcheck disable=SC2086
"$VENV_PY" - $KIT_IMPORT_CHECK <<'PYEOF' 2>&1 | sed 's/^/  /'
import importlib, importlib.util, sys, traceback
compiled = ["numpy", "pandas", "scipy", "scipy.linalg", "sklearn", "llvmlite",
            "numba", "torch", "pyarrow", "shapely", "netCDF4", "h5py"]
chain = [m for m in compiled if importlib.util.find_spec(m.split(".")[0])]
chain += sys.argv[1:]
for name in chain:
    sys.stdout.write(f"    {name:<58}")
    sys.stdout.flush()
    try:
        importlib.import_module(name)
        print("OK")
    except Exception:
        print("FAILED")
        print()
        traceback.print_exc()
        print()
        print(f"    ^ the chain breaks at: {name}")
        raise SystemExit(1)
print("    whole chain imported")
PYEOF
CHAIN_RC=${PIPESTATUS[0]}

hr "3. Same function, two launchers"
# The variable that separates A from B. Left: python resolves the entry point
# and calls it. Right: the generated .exe stub does. Same code either way.
IN_PROC="fail"
EXE_RUN="fail"
if [ -z "$SCRIPT" ]; then
    echo "  no console script to test - KIT_CONSOLE_SCRIPTS is empty; pass --script"
    IN_PROC="n/a"; EXE_RUN="n/a"
else
    echo "  --- ${SCRIPT}, via python, in-process ---"
    if "$VENV_PY" - "$SCRIPT" <<'PYEOF' 2>&1 | sed 's/^/    /'
import sys
from importlib.metadata import entry_points
name = sys.argv[1]
eps = [e for e in entry_points(group="console_scripts") if e.name == name]
if not eps:
    print("no console_scripts entry point named %r is installed" % name)
    raise SystemExit(1)
sys.argv = [name, "--help"]
try:
    eps[0].load()()
except SystemExit as e:
    print("exited", e.code, "- argparse --help does that; the import worked")
    raise SystemExit(0 if e.code in (0, None) else e.code)
PYEOF
    then IN_PROC="ok"; fi
    echo "  result: ${IN_PROC}"

    echo "  --- ${SCRIPT}, via the generated .exe ---"
    exe="${BIN_DIR}/${SCRIPT}"
    [ -f "$exe" ] || exe="${BIN_DIR}/${SCRIPT}.exe"
    if [ -f "$exe" ]; then
        # Output KEPT this time. The traceback is the diagnosis.
        if "$exe" --help > "${PAYLOAD_DIR}/.exe.out" 2>&1; then
            EXE_RUN="ok"
        else
            sed 's/^/    /' "${PAYLOAD_DIR}/.exe.out" | tail -20
        fi
        rm -f "${PAYLOAD_DIR}/.exe.out"
    else
        echo "    no .exe to run"
    fi
    echo "  result: ${EXE_RUN}"
fi

hr "Verdict"
printf '  %-30s %s\n' "import chain" "$( [ "$CHAIN_RC" -eq 0 ] && echo complete || echo 'broke - see section 2' )"
printf '  %-30s %s\n' "entry point, in-process" "$IN_PROC"
printf '  %-30s %s\n' "entry point, via .exe"   "$EXE_RUN"
echo

if [ "$CHAIN_RC" -ne 0 ]; then
    echo "  CAUSE A - the import CHAIN is what fails, and section 2 names the"
    echo "  package it breaks on. numpy alone was never the test: each of these"
    echo "  packages registers its own bundled DLL directory on the share, and"
    echo "  the loader is refusing one of them across SMB."
    echo
    echo "  The experiment that settles it is to put the venv on a local disk"
    echo "  and change nothing else:"
    echo "      ./install_packages.sh --workspace '<local-dir>' --python '<python>'"
    echo "  If the chain then imports, S: cannot host this venv - the workspace"
    echo "  and .venv move to local disk, and the DATA stays on S:. Re-run"
    echo "  check_venv_location.sh with --package for each package section 2"
    echo "  lists, so its probe is big enough to see this next time."
    exit 1
fi
if [ "$IN_PROC" = "ok" ] && [ "$EXE_RUN" = "fail" ]; then
    echo "  CAUSE B - the code is fine and the imports are fine; the generated"
    echo "  .exe stub is what will not run. Every console script is affected"
    echo "  equally, and nothing about the packaging is wrong."
    echo
    echo "  Fix, and it is a real one - replace the stubs with wrappers that call"
    echo "  the same function through python:"
    echo "      ./make_console_wrappers.sh --workspace '${WORKSPACE}'"
    exit 1
fi
if [ "$IN_PROC" = "ok" ] && [ "$EXE_RUN" = "ok" ]; then
    echo "  Both work now. The failure is not reproducible from this shell, so"
    echo "  whatever broke it was environmental and is no longer present."
    echo "  Re-run install_packages.sh and take the result at face value."
    exit 0
fi
if [ "$IN_PROC" = "n/a" ]; then
    echo "  The chain imports. With no console script to compare, there is no"
    echo "  launcher question to answer here."
    exit 0
fi
echo "  The chain imports but the entry point fails both ways, so this is not a"
echo "  DLL problem at all - section 3 has the traceback and it will be an"
echo "  ordinary error inside the code."
exit 1
