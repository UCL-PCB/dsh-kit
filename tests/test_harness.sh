#!/bin/bash
# The harness's own contract, exercised without any script from src/: a script runs
# from an emptied environment with the fixture's HOME and TMPDIR, stubs come first on
# PATH, the exit status and both output streams are captured, and the fixture
# builders produce what they say. If this file fails, no other test's verdict means
# anything.
#
# Tiny throwaway scripts stand in for the scripts under test, so this file does not
# depend on what src/ currently does.

source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# Write a one-off script into the fixture and run it the way run_script would.
run_snippet() {
    local snippet="$1"; shift
    printf '#!/bin/bash\nset -euo pipefail\n%s\n' "$snippet" > "${FIX_ROOT}/snippet.sh"
    _run_in_fixture "${FIX_ROOT}/snippet.sh" "$FIX_PROJECT" "$@"
}

test_the_environment_is_emptied_and_points_into_the_fixture() {
    export DSH_SHOULD_NOT_LEAK=1
    run_snippet 'printf "%s\n" "$HOME" "$TMPDIR" "$PWD" "${DSH_SHOULD_NOT_LEAK:-unset}" > env.txt'
    assert_exit 0
    assert_equals "$FIX_HOME" "$(sed -n 1p "${FIX_PROJECT}/env.txt")" "HOME"
    assert_equals "$FIX_TMP" "$(sed -n 2p "${FIX_PROJECT}/env.txt")" "TMPDIR"
    assert_equals "unset" "$(sed -n 4p "${FIX_PROJECT}/env.txt")" "a variable from the caller"
}

test_exit_status_and_streams_are_captured() {
    run_snippet 'echo to-stdout; echo to-stderr >&2; exit 7'
    assert_exit 7
    assert_file_contains "${FIX_ROOT}/run.out" '^to-stdout$'
    assert_file_contains "${FIX_ROOT}/run.err" '^to-stderr$'
}

test_a_stub_shadows_the_real_command() {
    printf '#!/bin/bash\necho stubbed\n' > "${FIX_STUBS}/git"
    chmod +x "${FIX_STUBS}/git"
    run_snippet 'git --version > which.txt'
    assert_exit 0
    assert_file_contains "${FIX_PROJECT}/which.txt" '^stubbed$'
}

test_fixture_repos_are_pushed_to_their_origin() {
    fixture_repos lib-a
    local dir="${FIX_PROJECT}/repos/lib-a"
    assert_dir_exists "${dir}/.git"
    assert_equals "$(git -C "$dir" rev-parse HEAD)" \
        "$(git -C "${dir}.origin.git" rev-parse HEAD)" "origin's tip"
}

test_fixture_conf_writes_quoted_lines_and_a_repos_dir() {
    fixture_conf 'KIT_REPOS=lib-a app-b'
    assert_file_contains "$FIX_CONF" '^KIT_REPOS="lib-a app-b"$'
    assert_file_contains "$FIX_CONF" '^KIT_REPOS_DIR="repos"$'
}

test_fixture_payload_lays_out_lib_and_the_conf() {
    fixture_conf 'KIT_REPOS=lib-a'
    fixture_payload
    assert_file_exists "${FIX_PAYLOAD}/PAYLOAD_CONTENTS.txt"
    assert_file_exists "${FIX_PAYLOAD}/lib/dsh_conf.sh"
    assert_file_exists "${FIX_PAYLOAD}/lib/dsh_log.sh"
    assert_files_equal "$FIX_CONF" "${FIX_PAYLOAD}/dsh-kit.conf"
    assert_file_contains "${FIX_PAYLOAD}/PAYLOAD_CONTENTS.txt" '^file conf dsh-kit.conf$'
}

harness_main "$@"
