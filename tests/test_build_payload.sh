#!/bin/bash
# build_payload.sh - the whole DSH_import/ for a two-repo project: bundles, the
# project's conf, the carried scripts, PAYLOAD_CONTENTS.txt and SHA256SUMS.txt.
#
# PAYLOAD_CONTENTS.txt and MANIFEST.txt are read on the far side by verify_payload.sh
# and the install, so here the files ARE the behaviour and are asserted on directly.
# Every case uses --no-zip: which zip tool a workstation has is not this script's
# contract, and the zip route has its own checks inside the script.

source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

OUT() { printf '%s/DSH_import\n' "$FIX_PROJECT"; }

build() {
    fixture_uv_assets "${FIX_ROOT}/uv"
    run_script build_payload.sh --conf "$FIX_CONF" --uv-dir "${FIX_ROOT}/uv" --no-zip "$@"
}

two_repo_project() {
    fixture_repos lib-a app-b
    fixture_conf 'KIT_REPOS=lib-a app-b' 'KIT_WORKING_REPOS=app-b' "$@"
}

test_a_two_repo_payload_carries_conf_bundles_and_roles() {
    two_repo_project 'KIT_TARGETS=dsh-vm'

    build
    assert_exit 0
    assert_files_equal "$FIX_CONF" "$(OUT)/dsh-kit.conf"
    assert_file_exists "$(OUT)/lib-a.bundle"
    assert_file_exists "$(OUT)/app-b.bundle"
    assert_file_contains "$(OUT)/MANIFEST.txt" '^lib-a  .*  mirror$'
    assert_file_contains "$(OUT)/MANIFEST.txt" '^app-b  .*  working$'

    local pc="$(OUT)/PAYLOAD_CONTENTS.txt"
    assert_file_contains "$pc" '^target dsh-vm$'
    assert_file_contains "$pc" '^built '
    assert_file_contains "$pc" '^file conf dsh-kit.conf$'
    assert_file_contains "$pc" '^file bundle lib-a.bundle$'
    assert_file_contains "$pc" '^file bundle app-b.bundle$'
    assert_file_contains "$pc" '^file bundle MANIFEST.txt$'
    assert_file_contains "$pc" '^file uv uv-x86_64-pc-windows-msvc.zip$'
    assert_file_lacks    "$pc" 'uv-x86_64-unknown-linux-gnu'
    assert_file_contains "$pc" '^file any lib/dsh_conf.sh$'
    assert_file_lacks    "$pc" '^file dsh-cluster '
}

test_every_listed_file_is_present_and_hashed() {
    two_repo_project

    build
    assert_exit 0
    local kind group path
    while read -r kind group path; do
        [ "$kind" = file ] || continue
        assert_file_exists "$(OUT)/${path}"
        grep -q " \*${path}\$" "$(OUT)/SHA256SUMS.txt" || fail "not in SHA256SUMS.txt: ${path}"
    done < "$(OUT)/PAYLOAD_CONTENTS.txt"
    ( cd "$(OUT)" && sha256sum -c --quiet SHA256SUMS.txt ) > /dev/null 2>&1 \
        || fail "SHA256SUMS.txt does not verify"
}

test_every_carried_file_is_listed_under_its_group() {
    two_repo_project 'KIT_TARGETS=dsh-vm dsh-cluster'

    build
    assert_exit 0
    local f rel group dest
    # shellcheck source=../src/lib/carry.sh
    . "${REPO_SRC}/lib/carry.sh"
    while IFS= read -r f; do
        rel="${f#"${REPO_CARRY}"/}"
        group="$(dsh_carry_group "carry/${rel}")"
        dest="$(dsh_payload_path "carry/${rel}")"
        case "$group" in any|dsh-vm|dsh-cluster) ;; *) continue ;; esac
        grep -qx "file ${group} ${dest}" "$(OUT)/PAYLOAD_CONTENTS.txt" \
            || fail "PAYLOAD_CONTENTS.txt lacks: file ${group} ${dest}"
        assert_files_equal "$f" "$(OUT)/${dest}"
    done < <(find "$REPO_CARRY" -type f)
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^target dsh$'
}

test_kit_targets_decides_the_default_target() {
    two_repo_project 'KIT_TARGETS=dsh-cluster' 'KIT_GITLAB=yes' 'KIT_GITLAB_GROUP=grp'

    build
    assert_exit 0
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^target dsh-cluster$'
    # In GitLab mode a cluster-only payload rides on a VM that already has the
    # bundles, and the cluster clones from GitLab.
    assert_absent "$(OUT)/lib-a.bundle"
    assert_file_lacks "$(OUT)/PAYLOAD_CONTENTS.txt" '^file bundle '
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^file conf dsh-kit.conf$'
}

test_bundle_mode_carries_bundles_to_the_cluster_too() {
    # KIT_GITLAB defaults to no: the bundles are the cluster's only source.
    two_repo_project 'KIT_TARGETS=dsh-cluster'

    build
    assert_exit 0
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^target dsh-cluster$'
    assert_file_exists "$(OUT)/lib-a.bundle"
    assert_file_exists "$(OUT)/app-b.bundle"
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^file bundle lib-a.bundle$'
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^file bundle MANIFEST.txt$'
    assert_file_contains "$(OUT)/MANIFEST.txt" '^lib-a  .*  mirror$'
    assert_file_contains "${FIX_ROOT}/run.out" 'GitLab  *no - every box installs from the bundles'
}

test_gitlab_mode_still_carries_bundles_for_the_vm() {
    two_repo_project 'KIT_TARGETS=dsh-vm' 'KIT_GITLAB=yes' 'KIT_GITLAB_GROUP=grp'

    build
    assert_exit 0
    assert_file_exists "$(OUT)/lib-a.bundle"
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^file bundle MANIFEST.txt$'
}

test_a_pyproject_beside_the_conf_is_carried() {
    two_repo_project 'KIT_INSTALL_MODE=workspace'
    printf '[project]\nname = "root"\n' > "${FIX_PROJECT}/pyproject.dsh.toml"

    build
    assert_exit 0
    assert_files_equal "${FIX_PROJECT}/pyproject.dsh.toml" "$(OUT)/pyproject.dsh.toml"
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^file conf pyproject.dsh.toml$'
}

test_the_cluster_pyproject_is_carried_too() {
    two_repo_project 'KIT_INSTALL_MODE=workspace'
    printf '[project]\nname = "cluster-root"\n' > "${FIX_PROJECT}/pyproject.dsh-cluster.toml"

    build
    assert_exit 0
    assert_files_equal "${FIX_PROJECT}/pyproject.dsh-cluster.toml" "$(OUT)/pyproject.dsh-cluster.toml"
    assert_file_contains "$(OUT)/PAYLOAD_CONTENTS.txt" '^file conf pyproject.dsh-cluster.toml$'
    assert_file_contains "$(OUT)/SHA256SUMS.txt" ' \*pyproject.dsh-cluster.toml$'
    assert_absent "$(OUT)/pyproject.dsh.toml"
}

test_the_upload_folder_stages_the_zip_unpackers_and_their_lib() {
    # Which zip tool this workstation has is not the script's contract; with none at
    # all there is nothing to stage, so there is nothing to test.
    if ! command -v zip > /dev/null 2>&1 && [ ! -x /c/Windows/System32/tar.exe ] \
       && ! command -v powershell.exe > /dev/null 2>&1; then
        echo "  (skipped: no zip tool)"
        return 0
    fi
    two_repo_project 'KIT_TARGETS=dsh-vm'
    fixture_uv_assets "${FIX_ROOT}/uv"
    run_script build_payload.sh --conf "$FIX_CONF" --uv-dir "${FIX_ROOT}/uv"
    assert_exit 0

    local up="${FIX_PROJECT}/DSH_upload" f
    assert_file_exists "${up}/DSH_import.zip"
    assert_file_exists "${up}/DSH_import.zip.sha256"
    assert_file_exists "${up}/READ_ME_FIRST.txt"
    for f in unpack_payload.sh update_dsh_vm.sh update_dsh_vm.bat \
             lib/dsh_log.sh lib/dsh_platform.sh lib/dsh_conf.sh; do
        assert_files_equal "$(OUT)/${f}" "${up}/${f}"
    done
    ( cd "$up" && sha256sum -c --quiet DSH_import.zip.sha256 ) > /dev/null 2>&1 \
        || fail "the staged zip does not match its sidecar"
}

test_no_bundles_refuses_a_manifest_missing_a_conf_repo() {
    two_repo_project
    build
    assert_exit 0

    # The conf grows a repo; the old manifest does not know it.
    fixture_repos lib-c
    fixture_conf 'KIT_REPOS=lib-a app-b lib-c' 'KIT_WORKING_REPOS=app-b'
    build --no-bundles
    assert_exit 1
    assert_file_contains "${FIX_ROOT}/run.out" 'KIT_REPOS names lib-c'
}

test_a_leftover_file_is_reported_and_pruned_on_request() {
    two_repo_project
    build
    assert_exit 0
    printf 'old\n' > "$(OUT)/retired_script.sh"

    build --no-bundles
    assert_exit 0
    assert_file_exists "$(OUT)/retired_script.sh"

    build --no-bundles --prune
    assert_exit 0
    assert_absent "$(OUT)/retired_script.sh"
}

test_a_missing_uv_asset_fails() {
    two_repo_project
    run_script build_payload.sh --conf "$FIX_CONF" --no-zip
    assert_exit 1
    assert_file_contains "${FIX_ROOT}/run.out" 'uv asset(s) missing'
}

test_an_unknown_target_fails() {
    two_repo_project
    build --target other-hpc
    assert_exit 1
    assert_file_contains "${FIX_ROOT}/run.err" "Unknown --target 'other-hpc'"
}

harness_main "$@"
