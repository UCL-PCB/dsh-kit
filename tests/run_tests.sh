#!/bin/bash
# Run the harness: every tests/test_*.sh, or the files named as arguments.
#
#     ./tests/run_tests.sh                      all of them
#     ./tests/run_tests.sh tests/test_export_bundles.sh
#     ./tests/run_tests.sh --keep               keep every fixture for inspection
#
# Needs bash 4.4+, coreutils and git. Nothing beyond that: no DSH, no network, no
# credential. A copy of the output is left in tests/last_run.log (gitignored) so a
# result can be read after the terminal is gone.
#
# Exit status is the number of test files that failed - non-zero whenever any did
# (taken mod 256, which only matters if there are ever 256 test files).

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${TESTS_DIR}/last_run.log"

KEEP=()
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=(--keep); shift ;;
        -h|--help) echo "Usage: $0 [--keep] [tests/test_*.sh ...]"; exit 0 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[ ${#FILES[@]} -gt 0 ] || FILES=("${TESTS_DIR}"/test_*.sh)

{
    echo "=== dsh test harness: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
    echo "stubs on PATH from ${TESTS_DIR}/stubs"
    failed=0
    for f in "${FILES[@]}"; do
        echo
        echo "=== $(basename "$f") ==="
        if bash "$f" "${KEEP[@]}"; then
            echo "=== $(basename "$f"): OK"
        else
            echo "=== $(basename "$f"): FAILED"
            failed=$(( failed + 1 ))
        fi
    done
    echo
    if [ "$failed" -eq 0 ]; then
        echo "ALL PASSED (${#FILES[@]} file(s))"
    else
        echo "FAILED: ${failed} of ${#FILES[@]} file(s)"
    fi
    exit "$failed"
} 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
