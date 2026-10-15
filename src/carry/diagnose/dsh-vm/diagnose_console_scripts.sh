#!/bin/bash
# INSIDE. A console script "failed" in install_packages.sh's smoke test, and the
# smoke test did not say why.
#
# Symptom this exists for: install_packages.sh gets through the install and the
# import checkpoint, then
#
#   === Smoke-testing the console scripts ===
#     <script>                   FAILED
#   RESULT: FAIL - a console script did not run.
#
# One suggestion that follows blames the mirror. Check that FIRST and cheaply -
# section 1 below compares every installed checkout against MANIFEST.txt - because
# if the SHAs match, the mirror is not the problem and re-cutting bundles costs a
# trip through the airlock for nothing.
#
# What else it can be, in the order this checks:
#
#   A. The extras are gone. In a uv workspace, `uv run` - or a bare `uv sync` -
#      performs an EXACT sync to the default extras, removing anything outside
#      that set. The console script then fails on an import that worked minutes
#      earlier, and nothing about the failure says "your extras were
#      uninstalled". Fix: re-run install_packages.sh and stop using `uv run`.
#   B. The entry point is genuinely absent from the venv - the mirror really is
#      short of the commit that declares it. Section 1 settles that.
#   C. The entry point exists but its module raises on import. Section 3 shows
#      the traceback the smoke test threw away.
#
# ENTIRELY READ-ONLY. It runs each console script's --help and imports the
# module; it does not sync, install, or remove anything. The suggested repair is
# printed for you to run.
#
#   ./diagnose/diagnose_console_scripts.sh       # workspace from ~/dsh-kit.env
#   ./diagnose/diagnose_console_scripts.sh --workspace '/s/<share>/<workspace-dir>'
#   ./diagnose/diagnose_console_scripts.sh --script <name>   # instead of KIT_CONSOLE_SCRIPTS
#
# Log: Logs/diagnose_console_scripts.log in the payload.

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
# shellcheck disable=SC2206
SCRIPTS=($KIT_CONSOLE_SCRIPTS)
CUSTOM=0

usage() {
    sed -n '2,38p' "$0"
    echo
    echo "Usage: $0 [--workspace DIR] [--script NAME]..."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --script)
            [ "$CUSTOM" -eq 0 ] && { SCRIPTS=(); CUSTOM=1; }
            SCRIPTS+=("$2"); shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$WORKSPACE" ] || { echo "Error: --workspace is required (or KIT_WORKSPACE_DIR in ~/dsh-kit.env)" >&2; usage; }
[ "${#SCRIPTS[@]}" -gt 0 ] || { echo "Error: no console scripts to check - KIT_CONSOLE_SCRIPTS is empty; pass --script" >&2; usage; }

hr() { echo; echo "=== $* ==="; }

VENV_PY="${WORKSPACE}/.venv/${DSH_VENV_PYTHON}"
BIN_DIR="$(dirname "$VENV_PY")"
[ -f "$VENV_PY" ] || {
    echo "No venv interpreter at ${VENV_PY} - is --workspace right?" >&2
    exit 1
}

echo "diagnose_console_scripts - ${WORKSPACE}"
echo "read-only: nothing is synced, installed or removed"

hr "1. Is the mirror actually short of the commit? (the thing you were told to suspect)"
# Cheapest question, and the one the smoke test's advice sends you to answer the
# expensive way. The installed sources are right there - compare and grep them.
MANIFEST="${PAYLOAD_DIR}/MANIFEST.txt"
MIRROR_VERDICT="match"
for repo in $KIT_REPOS; do
    src="${WORKSPACE}/src/${repo}"
    want="$(awk -v p="$repo" '$1==p {print $3}' "$MANIFEST" 2>/dev/null)"
    got="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo NONE)"
    if [ -z "$want" ]; then
        printf '  %-26s %s  (not in this payload)\n' "$repo" "${got:0:8}"
    elif [ "$want" = "$got" ]; then
        printf '  %-26s %s  matches manifest\n' "$repo" "${got:0:8}"
    else
        printf '  %-26s %s  MISMATCH, manifest says %s\n' "$repo" "${got:0:8}" "${want:0:8}"
        MIRROR_VERDICT="mismatch"
    fi
done
[ "$MIRROR_VERDICT" = "match" ] && echo "  the mirror is FAITHFUL - do not re-cut bundles"
echo "  which installed source declares each entry point:"
for s in "${SCRIPTS[@]}"; do
    owner=""
    for repo in $KIT_REPOS; do
        f="${WORKSPACE}/src/${repo}/pyproject.toml"
        if awk '/^\[project\.scripts\]/{f=1;next} /^\[/{f=0} f' "$f" 2>/dev/null \
           | grep -qE "^[\"']?${s}[\"']? *="; then
            owner="$repo"; break
        fi
    done
    printf '    %-26s %s\n' "$s" "${owner:-NOT DECLARED by any repo in KIT_REPOS}"
done

hr "2. Is the entry point installed in the venv?"
# Distinguishes "never generated" from "generated but broken". An editable
# install regenerates these; a copied directory does not.
for s in "${SCRIPTS[@]}"; do
    if [ -f "${BIN_DIR}/${s}" ] || [ -f "${BIN_DIR}/${s}.exe" ]; then
        printf '  %-26s present\n' "$s"
    else
        printf '  %-26s MISSING from %s\n' "$s" "$BIN_DIR"
    fi
done

hr "3. What does it actually say? (the output the smoke test discarded)"
RC=0
for s in "${SCRIPTS[@]}"; do
    echo "  --- ${s} --help ---"
    exe="${BIN_DIR}/${s}"
    [ -f "$exe" ] || exe="${BIN_DIR}/${s}.exe"
    if [ -f "$exe" ]; then
        # Run the installed script DIRECTLY. Not `uv run`: that syncs first, and
        # a sync here is what may have caused the failure in the first place.
        if "$exe" --help > "${PAYLOAD_DIR}/.cs.out" 2>&1; then
            echo "    OK"
        else
            RC=1
            sed 's/^/    /' "${PAYLOAD_DIR}/.cs.out" | head -25
        fi
    else
        RC=1
        echo "    not installed, so nothing to run"
    fi
done
rm -f "${PAYLOAD_DIR}/.cs.out"

hr "4. Did the extras survive?"
# For every extra KIT_EXTRAS asks for, every requirement that extra adds must be
# installed. Read from each distribution's own metadata, so nothing here names a
# package: `repo[a,b]` in the conf is checked against what repo says a and b need.
EXTRAS_OK="yes"
if [ -z "$KIT_EXTRAS" ]; then
    echo "  KIT_EXTRAS is empty - no extras were asked for, so none can be missing"
else
    "$VENV_PY" - $KIT_EXTRAS > "${PAYLOAD_DIR}/.extras.out" 2>&1 <<'PYEOF'
import re, sys
from importlib import metadata
bad = 0
for spec in sys.argv[1:]:
    m = re.match(r"([A-Za-z0-9._-]+)\[([^\]]*)\]$", spec)
    if not m:
        continue
    dist, extras = m.group(1), [e.strip() for e in m.group(2).split(",") if e.strip()]
    try:
        reqs = metadata.distribution(dist).requires or []
    except metadata.PackageNotFoundError:
        print("  %-26s NOT INSTALLED AT ALL" % dist); bad = 1; continue
    for extra in extras:
        norm = re.sub(r"[-_.]+", "-", extra).lower()
        need = []
        for r in reqs:
            mk = re.search(r"extra\s*==\s*['\"]([^'\"]+)['\"]", r)
            if mk and re.sub(r"[-_.]+", "-", mk.group(1)).lower() == norm:
                need.append(re.match(r"[A-Za-z0-9._-]+", r).group(0))
        gone = []
        for n in need:
            try:
                metadata.distribution(n)
            except metadata.PackageNotFoundError:
                gone.append(n)
        label = "%s[%s]" % (dist, extra)
        if not need:
            print("  %-26s declares nothing (or no such extra)" % label)
        elif gone:
            print("  %-26s GONE: %s" % (label, ", ".join(gone))); bad = 1
        else:
            print("  %-26s installed (%d requirement(s))" % (label, len(need)))
raise SystemExit(bad)
PYEOF
    [ $? -eq 0 ] || EXTRAS_OK="no"
    cat "${PAYLOAD_DIR}/.extras.out"
    rm -f "${PAYLOAD_DIR}/.extras.out"
fi

hr "Verdict"
if [ "$MIRROR_VERDICT" = "mismatch" ]; then
    echo "  A workspace clone is not at the manifest SHA. That IS a mirror problem:"
    echo "  re-run mirror_to_gitlab.sh --refresh, then install_packages.sh again."
    echo "  Everything below is downstream of it."
    exit 1
fi
if [ "$EXTRAS_OK" = "no" ]; then
    echo "  CAUSE A - extras the conf asks for are no longer installed. Something"
    echo "  ran a sync that dropped them - in a uv workspace 'uv run' or a bare"
    echo "  'uv sync' does exactly that. The venv you built is not the venv that"
    echo "  got tested."
    echo
    echo "  Repair: re-run ./install_packages.sh (it asks for the extras every time)."
    echo
    echo "  Then re-check with THIS script, not with 'uv run' - running an"
    echo "  installed console script directly does not touch the environment."
    exit 1
fi
if [ "$RC" -eq 0 ]; then
    echo "  Every console script runs. Whatever failed during the install has since"
    echo "  been repaired, or the smoke test failed for a reason that has gone away."
    echo "  If install_packages.sh said 'STUB FAILED, function OK', that is the SMB"
    echo "  launcher problem: make_console_wrappers.sh."
    exit 0
fi
echo "  CAUSE C - the entry point exists but its module raises on import, and"
echo "  section 3 has the traceback. Read the LAST line: a ModuleNotFoundError"
echo "  on a third-party name is an Artifactory mirror gap; on a first-party"
echo "  name a repo missing from KIT_REPOS; an ImportError naming an extra means"
echo "  that extra is not installed - see section 4. 'DLL load failed' is the"
echo "  share or Anaconda: diagnose_import_chain.sh, then diagnose_numpy_dll.sh."
exit 1
