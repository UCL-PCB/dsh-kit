#!/bin/bash
# export_bundles.sh - bundles what dsh-kit.conf names, records each repo's role, and
# refuses anything that would make the manifest a lie.
#
# A bundle of a local, unpushed commit becomes GitLab's tip inside the data safe. If
# that commit is then rebased or amended outside it never reaches the remote, and the
# next refresh is refused as a non-fast-forward that only a force push inside can
# clear. The export must stop it at source - and a refused export must leave the
# previous MANIFEST.txt exactly as it was.

source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

OUT() { printf '%s/out\n' "$FIX_ROOT"; }
PKG_DIR() { printf '%s/repos/%s\n' "$FIX_PROJECT" "${1:-lib-a}"; }

export_all() {
    run_script export_bundles.sh --conf "$FIX_CONF" --out "$(OUT)" "$@"
}

commit_locally() {
    (
        cd "$(PKG_DIR "${1:-lib-a}")" &&
        printf 'local\n' >> README.md &&
        git -c user.name=harness -c user.email=harness@example.invalid commit -qam "local only"
    ) > /dev/null 2>&1 || fail_now "commit_locally: could not commit"
}

test_every_repo_in_the_conf_is_exported_with_its_role() {
    fixture_repos lib-a app-b
    fixture_conf 'KIT_REPOS=lib-a app-b' 'KIT_WORKING_REPOS=app-b'

    export_all
    assert_exit 0
    assert_file_exists "$(OUT)/lib-a.bundle"
    assert_file_exists "$(OUT)/app-b.bundle"
    assert_file_contains "$(OUT)/MANIFEST.txt" "^lib-a  [^ ]*  $(git -C "$(PKG_DIR lib-a)" rev-parse HEAD)  mirror\$"
    assert_file_contains "$(OUT)/MANIFEST.txt" "^app-b  [^ ]*  $(git -C "$(PKG_DIR app-b)" rev-parse HEAD)  working\$"
    git -C "$(PKG_DIR lib-a)" bundle verify "$(OUT)/lib-a.bundle" > /dev/null 2>&1 \
        || fail "lib-a.bundle does not verify"
}

test_the_default_out_dir_is_beside_the_conf() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'

    run_script export_bundles.sh --conf "$FIX_CONF"
    assert_exit 0
    assert_file_exists "${FIX_PROJECT}/DSH_import/lib-a.bundle"
    assert_file_exists "${FIX_PROJECT}/DSH_import/Logs/export_bundles.log"
}

test_the_conf_can_come_from_the_environment() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'
    FIX_KIT_CONF="$FIX_CONF"

    run_script export_bundles.sh --out "$(OUT)"
    assert_exit 0
    assert_file_exists "$(OUT)/lib-a.bundle"
}

test_no_conf_is_an_error_not_a_guess() {
    # The template repo itself ships only dsh-kit.conf.example.
    run_script export_bundles.sh --out "$(OUT)"
    assert_exit 1
    assert_file_contains "${FIX_ROOT}/run.err" 'No dsh-kit.conf'
}

test_a_package_can_be_named_by_path() {
    fixture_repos lib-a
    fixture_git_repo "${FIX_ROOT}/elsewhere/side-repo"
    fixture_conf 'KIT_REPOS=lib-a'

    export_all --package "${FIX_ROOT}/elsewhere/side-repo"
    assert_exit 0
    assert_file_exists "$(OUT)/side-repo.bundle"
    assert_absent "$(OUT)/lib-a.bundle"
    assert_file_contains "$(OUT)/MANIFEST.txt" '^side-repo  .*  mirror$'
}

test_an_unpushed_commit_is_refused_and_the_manifest_is_untouched() {
    fixture_repos lib-a app-b
    fixture_conf 'KIT_REPOS=lib-a app-b'
    export_all
    assert_exit 0
    cp "$(OUT)/MANIFEST.txt" "${FIX_ROOT}/manifest.before"

    commit_locally app-b
    export_all
    assert_exit 1
    assert_files_equal "${FIX_ROOT}/manifest.before" "$(OUT)/MANIFEST.txt"
    assert_file_contains "${FIX_ROOT}/run.out" 'is not on origin/'
    assert_file_contains "${FIX_ROOT}/run.out" 'local only'
    assert_absent "$(OUT)/MANIFEST.txt.$$"
}

test_a_dirty_tracked_tree_is_refused() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'
    printf 'edit\n' >> "$(PKG_DIR)/README.md"

    export_all
    assert_exit 1
    assert_absent "$(OUT)/MANIFEST.txt"
    assert_file_contains "${FIX_ROOT}/run.out" 'uncommitted changes to TRACKED files'
}

test_an_untracked_file_is_only_a_note() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'
    printf 'debris\n' > "$(PKG_DIR)/debris.log"

    export_all
    assert_exit 0
    assert_file_contains "${FIX_ROOT}/run.out" 'untracked files'
}

test_a_branch_behind_origin_exports() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'
    commit_locally
    git -C "$(PKG_DIR)" push -q origin HEAD > /dev/null 2>&1 || fail_now "push failed"
    git -C "$(PKG_DIR)" reset -q --hard HEAD~1 || fail_now "reset failed"

    export_all
    assert_exit 0
}

test_a_branch_with_no_origin_is_refused() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'
    git -C "$(PKG_DIR)" remote remove origin || fail_now "remote remove failed"

    export_all
    assert_exit 1
    assert_file_contains "${FIX_ROOT}/run.out" 'there is no origin/'
}

test_allow_unpushed_overrides_the_check() {
    fixture_repos lib-a
    fixture_conf 'KIT_REPOS=lib-a'
    commit_locally

    export_all --allow-unpushed
    assert_exit 0
    assert_file_exists "$(OUT)/lib-a.bundle"
}

test_a_missing_repo_is_an_error() {
    fixture_conf 'KIT_REPOS=nope'
    export_all
    assert_exit 1
    assert_file_contains "${FIX_ROOT}/run.out" 'Not a git repository'
}

harness_main "$@"
