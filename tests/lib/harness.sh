#!/bin/bash
# Test harness for the scripts in src/. Sourced by every tests/test_*.sh, never run.
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
#     test_something() { ...fixture, run_script, assertions... }
#     harness_main "$@"
#
# A test file holds one or more test_* functions. harness_main runs each in its own
# subshell against a fresh fixture: a throwaway HOME, a project directory holding a
# dsh-kit.conf and the git repositories it names, and a TMPDIR. Anything in
# tests/stubs is placed on PATH ahead of the real commands, and the script under test
# runs from an emptied environment so that nothing on the workstation can leak in.
#
# What a test asserts on, and what it does not: the resulting file tree and a
# script's exit status. There is deliberately no assert_output for messages meant
# for the operator - stdout wording changes without behaviour changing. Where a
# script's output IS its behaviour (a report a later step parses, a file the far
# side reads), assert on the file, not on the terminal.
#
# Layout of one case's fixture ($FIX_ROOT):
#   home/                        the script's $HOME
#   project/                     $FIX_PROJECT - a project made from the template:
#     dsh-kit.conf               $FIX_CONF, written by fixture_conf
#     repos/<name>/              the checkouts KIT_REPOS names (KIT_REPOS_DIR="repos"),
#     repos/<name>.origin.git    each pushed to a bare origin beside it
#   payload/                     $FIX_PAYLOAD - src/carry laid out as a payload,
#                                for run_payload_script
#   tmp/                         TMPDIR for the script under test
#   run.out, run.err, run.rc     the last run_script

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_SRC="${REPO_DIR}/src"
REPO_CARRY="${REPO_SRC}/carry"
STUBS_DIR="${TESTS_DIR}/stubs"
TEST_FILE="$(basename "${BASH_SOURCE[1]:-$0}")"

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

# Create the fixture skeleton for one case. Called by harness_main; a test only
# calls the fixture_* builders below.
_fixture_init() {
    FIX_ROOT="$1"
    FIX_HOME="${FIX_ROOT}/home"
    FIX_PROJECT="${FIX_ROOT}/project"
    FIX_CONF="${FIX_PROJECT}/dsh-kit.conf"
    FIX_TMP="${FIX_ROOT}/tmp"
    FIX_PAYLOAD="${FIX_ROOT}/payload"
    FIX_KIT_CONF=""          # passed to the script as $DSH_KIT_CONF when set
    mkdir -p "$FIX_HOME" "$FIX_PROJECT/repos" "$FIX_TMP"
}

# fixture_conf [KEY=value ...]
#
# Write $FIX_CONF. Every argument is one line, quoted as the conf format wants:
#   fixture_conf 'KIT_REPOS=lib-a app-b' 'KIT_WORKING_REPOS=app-b'
# KIT_REPOS_DIR defaults to "repos" (the fixture's layout) unless an argument sets it.
fixture_conf() {
    local kv has_dir=0
    : > "$FIX_CONF"
    printf '# fixture conf\nKIT_PROJECT="fixture"\n' >> "$FIX_CONF"
    for kv in "$@"; do
        case "$kv" in KIT_REPOS_DIR=*) has_dir=1 ;; esac
        printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}" >> "$FIX_CONF"
    done
    [ "$has_dir" -eq 1 ] || printf 'KIT_REPOS_DIR="repos"\n' >> "$FIX_CONF"
}

# A committed git repository at <dir>, holding one file, with its branch pushed to a
# bare `origin` beside it at <dir>.origin.git - the shape of a real checkout that is
# up to date with its remote, which export_bundles.sh requires. Echoes nothing.
#
#   fixture_git_repo <dir>
fixture_git_repo() {
    mkdir -p "$1" || fail_now "fixture_git_repo: could not make $1"
    (
        cd "$1" &&
        git init -q &&
        printf 'tracked\n' > README.md &&
        git add README.md &&
        git -c user.name=harness -c user.email=harness@example.invalid commit -q -m initial &&
        git init -q --bare "${1}.origin.git" &&
        git remote add origin "${1}.origin.git" &&
        git push -q origin HEAD
    ) > /dev/null 2>&1 || fail_now "fixture_git_repo: could not commit and push in $1"
}

# fixture_repos <name>...   - a pushed repo under $FIX_PROJECT/repos for each name
fixture_repos() {
    local r
    for r in "$@"; do fixture_git_repo "${FIX_PROJECT}/repos/${r}"; done
}

# fixture_uv_assets <dir>  - stand-ins for the two uv release assets, which a real
# build copies from --uv-dir. Their content is never looked at, only hashed.
fixture_uv_assets() {
    mkdir -p "$1"
    printf 'not really uv\n' > "${1}/uv-x86_64-pc-windows-msvc.zip"
    printf 'not really uv\n' > "${1}/uv-x86_64-unknown-linux-gnu.tar.gz"
}

# ---------------------------------------------------------------------------
# Running a script
# ---------------------------------------------------------------------------
# run_script <basename> [args...]
#
# A WORKSTATION script, from src/workstation/. Runs from an EMPTY environment - only
# the variables listed in _run_in_fixture - with HOME, TMPDIR and PATH pointing into
# the fixture, and $FIX_PROJECT as the working directory. Not a login shell,
# deliberately: /etc/profile on a workstation could put a real command back ahead of
# a stub. Sets RUN_EXIT and leaves stdout/stderr in $FIX_ROOT/run.out and run.err.
run_script() {
    local script="$1"; shift
    _run_in_fixture "${REPO_SRC}/workstation/${script}" "$FIX_PROJECT" "$@"
}

# fixture_payload
#
# Lays src/carry out at $FIX_PAYLOAD as a payload, with its PAYLOAD_CONTENTS.txt and a
# copy of $FIX_CONF (if one was written), if this case has not already.
# run_payload_script calls it; a case calls it first when it has to put something
# beside the scripts before one of them runs - a MANIFEST.txt, a SHA256SUMS.txt - which
# is what a payload built for real would hold.
fixture_payload() {
    local f rel dest
    [ -d "$FIX_PAYLOAD" ] && return 0
    mkdir -p "$FIX_PAYLOAD" || fail_now "fixture_payload: could not make ${FIX_PAYLOAD}"
    # shellcheck source=../../src/lib/carry.sh
    . "${REPO_SRC}/lib/carry.sh"
    {
        echo "target dsh"
        echo "built 1970-01-01T00:00:00Z"
    } > "${FIX_PAYLOAD}/PAYLOAD_CONTENTS.txt"
    while IFS= read -r f; do
        rel="${f#"${REPO_CARRY}"/}"
        dest="$(dsh_payload_path "carry/${rel}")"
        mkdir -p "$(dirname "${FIX_PAYLOAD}/${dest}")"
        cp "$f" "${FIX_PAYLOAD}/${dest}" \
            || fail_now "fixture_payload: could not copy ${f} into the fixture"
        printf 'file %s %s\n' "$(dsh_carry_group "carry/${rel}")" "$dest" \
            >> "${FIX_PAYLOAD}/PAYLOAD_CONTENTS.txt"
    done < <(find "$REPO_CARRY" -type f)
    if [ -f "$FIX_CONF" ]; then
        cp "$FIX_CONF" "${FIX_PAYLOAD}/dsh-kit.conf"
        echo "file conf dsh-kit.conf" >> "${FIX_PAYLOAD}/PAYLOAD_CONTENTS.txt"
    fi
}

# run_payload_script <basename> [args...]
#
# A PAYLOAD script - one carried through the airlock and run by hand on the Desktop
# VM or on the cluster login node behind it. The case runs a BUILT COPY of src/carry
# at $FIX_PAYLOAD rather than the tree itself, laid out the way build_payload.sh lays
# a payload out - lib/, diagnose/, and the procedure's own steps at the top - so a
# script that reaches for lib/ or for a sibling finds it here exactly as it would on
# the VM. Running in place would instead write each script's log into the repository.
#
# PAYLOAD_CONTENTS.txt is written too, because that is what tells dsh_log.sh which
# directory is the payload root.
#
# A bare basename is enough to name a script - diagnose/ is looked in as well.
run_payload_script() {
    local script="$1" path; shift
    fixture_payload
    path="${FIX_PAYLOAD}/${script}"
    [ -f "$path" ] || path="${FIX_PAYLOAD}/diagnose/${script}"
    _run_in_fixture "$path" "$FIX_PAYLOAD" "$@"
}

_run_in_fixture() {
    local path="$1" cwd="$2"; shift 2
    [ -f "$path" ] || fail_now "no such script ${path}"
    { (
        cd "$cwd" && env -i \
            PATH="${FIX_STUBS}:${PATH}" \
            HOME="$FIX_HOME" \
            TMPDIR="$FIX_TMP" \
            USER=testuser \
            LANG=C \
            DSH_KIT_CONF="$FIX_KIT_CONF" \
            bash "$path" "$@"
    ) > "${FIX_ROOT}/run.out" 2> "${FIX_ROOT}/run.err" ; } 2>/dev/null
    RUN_EXIT=$?
    printf '%s\n' "$RUN_EXIT" > "${FIX_ROOT}/run.rc"
    return 0
}

# ---------------------------------------------------------------------------
# Assertions. Each records a failure and carries on, so one case reports every
# broken expectation, not just the first.
# ---------------------------------------------------------------------------
fail() {
    printf '  FAIL: %s\n' "$*"
    printf '%s\n' "$*" >> "${FIX_ROOT}/failures"
}

fail_now() {            # a broken fixture or harness call, not a broken script
    printf '  ERROR: %s\n' "$*"
    printf 'ERROR: %s\n' "$*" >> "${FIX_ROOT}/failures"
    exit 2
}

assert_exit() {         # assert_exit <expected>    (checks the last run_script)
    [ "${RUN_EXIT:-unset}" = "$1" ] || fail "exit status: expected $1, got ${RUN_EXIT:-unset} (see ${FIX_ROOT}/run.err)"
}

assert_equals() {       # assert_equals <expected> <actual> [what]
    [ "$1" = "$2" ] || fail "${3:-value}: expected '$1', got '$2'"
}

assert_file_exists()  { [ -f "$1" ] || fail "file missing: $1"; }
assert_dir_exists()   { [ -d "$1" ] || fail "directory missing: $1"; }
assert_absent()       { [ ! -e "$1" ] || fail "should not exist: $1"; }
assert_files_equal()  { # assert_files_equal <a> <b>
    if [ ! -f "$1" ]; then fail "file missing: $1"
    elif [ ! -f "$2" ]; then fail "file missing: $2"
    elif ! cmp -s "$1" "$2"; then fail "files differ: $1 vs $2"; fi
}
assert_file_contains() { # assert_file_contains <file> <grep pattern>
    [ -f "$1" ] || { fail "file missing: $1"; return; }
    grep -q -- "$2" "$1" || fail "$1 does not contain /$2/"
}
assert_file_lacks() {    # assert_file_lacks <file> <grep pattern>
    [ -f "$1" ] || { fail "file missing: $1"; return; }
    if grep -q -- "$2" "$1"; then fail "$1 should not contain /$2/"; fi
}

# ---------------------------------------------------------------------------
# The case runner
# ---------------------------------------------------------------------------
# harness_main [--keep] [test_name...]
#
# Runs every test_* function in the sourcing file (or the named ones), each in a
# subshell with its own fixture. Prints one --- marker per case and PASS/FAIL, keeps
# the fixture of any failing case and says where it is, and exits non-zero if any
# case failed. --keep (or DSH_TEST_KEEP=1) keeps passing fixtures too.
harness_main() {
    local keep="${DSH_TEST_KEEP:-0}" wanted=() cases=() name root rc passed=0 failed=0 run_root
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep) keep=1; shift ;;
            -h|--help) echo "Usage: $0 [--keep] [test_name...]"; exit 0 ;;
            *) wanted+=("$1"); shift ;;
        esac
    done

    if [ ${#wanted[@]} -gt 0 ]; then
        cases=("${wanted[@]}")
    else
        mapfile -t cases < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
    fi
    [ ${#cases[@]} -gt 0 ] || { echo "${TEST_FILE}: no test_* functions"; exit 2; }

    run_root="$(mktemp -d "${TMPDIR:-/tmp}/dsh-tests.XXXXXX")"

    for name in "${cases[@]}"; do
        declare -F "$name" > /dev/null || { echo "--- ${TEST_FILE}::${name} ---"; echo "  ERROR: no such test"; failed=$(( failed + 1 )); continue; }
        echo "--- ${TEST_FILE}::${name} ---"
        root="${run_root}/${name}"
        mkdir -p "$root"
        (
            _fixture_init "$root"
            # A private copy of the stubs per case, so a case can add or rewrite one
            # without touching the checked-in stubs or another case.
            FIX_STUBS="${FIX_ROOT}/stubs"
            mkdir -p "$FIX_STUBS"
            cp -r "${STUBS_DIR}/." "$FIX_STUBS/" 2>/dev/null || true
            RUN_EXIT=""
            cd "$FIX_ROOT" || exit 2
            "$name"
        )
        rc=$?
        if [ $rc -eq 0 ] && [ ! -s "${root}/failures" ]; then
            echo "PASS ${name}"
            passed=$(( passed + 1 ))
            [ "$keep" = 1 ] || rm -rf "$root"
        else
            echo "FAIL ${name} (fixture kept at ${root})"
            [ $rc -eq 0 ] || echo "  test function exited ${rc}"
            if [ -f "${root}/run.err" ] && [ -s "${root}/run.err" ]; then
                echo "  last lines of the script's stderr:"
                tail -n 5 "${root}/run.err" | sed 's/^/    | /'
            fi
            failed=$(( failed + 1 ))
        fi
    done

    echo "${TEST_FILE}: ${passed} passed, ${failed} failed"
    if [ "$failed" -eq 0 ] && [ "$keep" != 1 ]; then
        rmdir "$run_root" 2>/dev/null || true
    else
        echo "fixtures under ${run_root}"
    fi
    [ "$failed" -eq 0 ]
}
