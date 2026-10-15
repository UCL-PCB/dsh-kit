#!/bin/bash
# dsh_load_conf in src/carry/any/lib/dsh_conf.sh - how every script on both sides of
# the airlock reads dsh-kit.conf.
#
# The conf is carried INTO the data safe and read there, so the property that matters
# most is that it is parsed rather than sourced: a line that is not KEY="value" must be
# reported and ignored, never run. The rest is that a mistake in it fails here, on the
# workstation, rather than two boxes later.

source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

CONF_LIB="${REPO_CARRY}/any/lib/dsh_conf.sh"

# Load $FIX_CONF in a clean shell and print the named variables, one per line as
# NAME=value. Sets LOAD_EXIT; stdout in $FIX_ROOT/load.out, stderr in load.err.
#
#   load_conf VAR...
load_conf() {
    env -i PATH="$PATH" HOME="$FIX_HOME" bash -c '
        . "$1"; shift
        conf="$1"; shift
        dsh_load_conf "$conf"; rc=$?
        for v in "$@"; do printf "%s=%s\n" "$v" "${!v-<unset>}"; done
        exit "$rc"
    ' _ "$CONF_LIB" "$FIX_CONF" "$@" > "${FIX_ROOT}/load.out" 2> "${FIX_ROOT}/load.err"
    LOAD_EXIT=$?
}

value_of() { sed -n "s/^$1=//p" "${FIX_ROOT}/load.out"; }

test_the_shipped_example_loads_cleanly() {
    cp "${REPO_DIR}/dsh-kit.conf.example" "$FIX_CONF"
    load_conf KIT_REPOS KIT_INSTALL_MODE
    assert_equals 0 "$LOAD_EXIT" "exit status"
    assert_equals "" "$(cat "${FIX_ROOT}/load.err")" "stderr"
    assert_equals "my-library my-analysis" "$(value_of KIT_REPOS)" "KIT_REPOS"
}

test_a_good_conf_sets_every_value_literally() {
    cat > "$FIX_CONF" <<'EOF'
# a comment
  # an indented comment
KIT_PROJECT="proj"
KIT_REPOS="lib-a app-b"
KIT_WORKING_REPOS="app-b"
KIT_INSTALL_MODE=workspace   # trailing comment
KIT_EXTRAS="lib-a[plots,fast] $HOME"
KIT_GITLAB_GROUP="grp"
EOF
    load_conf KIT_PROJECT KIT_REPOS KIT_WORKING_REPOS KIT_INSTALL_MODE KIT_EXTRAS KIT_GITLAB_GROUP KIT_CONF_DIR
    assert_equals 0 "$LOAD_EXIT" "exit status"
    assert_equals "proj" "$(value_of KIT_PROJECT)" "KIT_PROJECT"
    assert_equals "lib-a app-b" "$(value_of KIT_REPOS)" "KIT_REPOS"
    assert_equals "app-b" "$(value_of KIT_WORKING_REPOS)" "KIT_WORKING_REPOS"
    assert_equals "workspace" "$(value_of KIT_INSTALL_MODE)" "KIT_INSTALL_MODE"
    # Literal: $HOME is not expanded.
    assert_equals 'lib-a[plots,fast] $HOME' "$(value_of KIT_EXTRAS)" "KIT_EXTRAS"
    assert_equals "$FIX_PROJECT" "$(value_of KIT_CONF_DIR)" "KIT_CONF_DIR"
}

test_crlf_line_endings_are_tolerated() {
    printf 'KIT_REPOS="lib-a"\r\nKIT_INSTALL_MODE="venv"\r\n' > "$FIX_CONF"
    load_conf KIT_REPOS KIT_INSTALL_MODE
    assert_equals 0 "$LOAD_EXIT" "exit status"
    assert_equals "lib-a" "$(value_of KIT_REPOS)" "KIT_REPOS"
    assert_equals "venv" "$(value_of KIT_INSTALL_MODE)" "KIT_INSTALL_MODE"
}

test_defaults_fill_what_the_conf_leaves_out() {
    printf 'KIT_REPOS="lib-a app-b"\n' > "$FIX_CONF"
    load_conf KIT_PROJECT KIT_REPOS_DIR KIT_INSTALL_MODE KIT_GITLAB_HOST KIT_TARGETS KIT_IMPORT_CHECK KIT_WORKING_REPOS
    assert_equals 0 "$LOAD_EXIT" "exit status"
    assert_equals "dsh-project" "$(value_of KIT_PROJECT)" "KIT_PROJECT"
    assert_equals "../" "$(value_of KIT_REPOS_DIR)" "KIT_REPOS_DIR"
    assert_equals "venv" "$(value_of KIT_INSTALL_MODE)" "KIT_INSTALL_MODE"
    assert_equals "gitlab.idhs.ucl.ac.uk" "$(value_of KIT_GITLAB_HOST)" "KIT_GITLAB_HOST"
    assert_equals "dsh-vm" "$(value_of KIT_TARGETS)" "KIT_TARGETS"
    # Import names derive from the repo names, - to _.
    assert_equals "lib_a app_b" "$(value_of KIT_IMPORT_CHECK)" "KIT_IMPORT_CHECK"
    assert_equals "" "$(value_of KIT_WORKING_REPOS)" "KIT_WORKING_REPOS"
}

test_an_explicit_import_check_is_not_overridden() {
    printf 'KIT_REPOS="lib-a"\nKIT_IMPORT_CHECK="liba"\n' > "$FIX_CONF"
    load_conf KIT_IMPORT_CHECK
    assert_equals "liba" "$(value_of KIT_IMPORT_CHECK)" "KIT_IMPORT_CHECK"
}

test_an_unknown_key_is_reported_and_ignored() {
    printf 'KIT_REPOS="lib-a"\nKIT_BOGUS="x"\n' > "$FIX_CONF"
    load_conf KIT_BOGUS
    assert_equals 0 "$LOAD_EXIT" "exit status"
    assert_equals "<unset>" "$(value_of KIT_BOGUS)" "KIT_BOGUS"
    assert_file_contains "${FIX_ROOT}/load.err" 'unknown key KIT_BOGUS'
}

test_a_line_that_is_not_key_value_is_reported_and_never_run() {
    local marker="${FIX_ROOT}/ran"
    cat > "$FIX_CONF" <<EOF
KIT_REPOS="lib-a"
touch ${marker}
KIT_PROJECT="\$(touch ${marker})"
KIT_GITLAB_GROUP=\`touch ${marker}\`
EOF
    load_conf KIT_PROJECT KIT_GITLAB_GROUP
    assert_absent "$marker"
    assert_file_contains "${FIX_ROOT}/load.err" 'not KEY="value" - ignored: touch'
    # The command substitution survives as text - literal, never executed.
    assert_equals "\$(touch ${marker})" "$(value_of KIT_PROJECT)" "KIT_PROJECT"
    # Backticks are not a bare value either, so that line is refused outright.
    assert_file_contains "${FIX_ROOT}/load.err" 'ignored: KIT_GITLAB_GROUP='
}

test_a_bad_install_mode_fails() {
    printf 'KIT_REPOS="lib-a"\nKIT_INSTALL_MODE="conda"\n' > "$FIX_CONF"
    load_conf
    assert_equals 1 "$LOAD_EXIT" "exit status"
    assert_file_contains "${FIX_ROOT}/load.err" 'KIT_INSTALL_MODE must be venv or workspace'
}

test_a_working_repo_not_in_repos_fails() {
    printf 'KIT_REPOS="lib-a"\nKIT_WORKING_REPOS="app-b"\n' > "$FIX_CONF"
    load_conf
    assert_equals 1 "$LOAD_EXIT" "exit status"
    assert_file_contains "${FIX_ROOT}/load.err" 'KIT_WORKING_REPOS names app-b'
}

test_empty_repos_fails() {
    printf 'KIT_PROJECT="p"\n' > "$FIX_CONF"
    load_conf
    assert_equals 1 "$LOAD_EXIT" "exit status"
    assert_file_contains "${FIX_ROOT}/load.err" 'KIT_REPOS is empty'
}

test_an_unknown_target_fails() {
    printf 'KIT_REPOS="lib-a"\nKIT_TARGETS="dsh-vm other-hpc"\n' > "$FIX_CONF"
    load_conf
    assert_equals 1 "$LOAD_EXIT" "exit status"
    assert_file_contains "${FIX_ROOT}/load.err" "unknown target 'other-hpc'"
}

test_a_missing_conf_fails() {
    load_conf
    assert_equals 1 "$LOAD_EXIT" "exit status"
    assert_file_contains "${FIX_ROOT}/load.err" 'no such file'
}

harness_main "$@"
