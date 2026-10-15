#!/bin/bash
# src/lib/carry.sh - which file goes to which box, and where in the payload it lands.
#
# The directory a file sits in under src/carry/ is the only statement of where it is
# carried, so these cases build a small src/carry tree of their own and ask carry.sh
# about it, rather than asserting on the repo's real tree - which changes every time a
# script is added and would make this file a second list to keep in step.

source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# A miniature src/carry with one file in every kind of place.
fixture_carry_tree() {
    local root="${FIX_ROOT}/carry" f
    for f in \
        any/install_packages.sh \
        any/lib/dsh_log.sh \
        dsh-vm/unpack_payload.sh \
        dsh-vm/lib/vm_only_lib.sh \
        dsh-cluster/install_git_route.sh \
        diagnose/dsh-vm/diagnose_numpy_dll.sh \
        diagnose/dsh-cluster/diagnose_cluster_thing.sh \
        other-hpc/left_over_from_elsewhere.sh
    do
        mkdir -p "$(dirname "${root}/${f}")"
        printf '#!/bin/bash\n' > "${root}/${f}"
    done
    printf '%s\n' "$root"
}

# carry <function> <args...>  - call a carry.sh function in a clean shell
carry() {
    bash -c '. "$1"; shift; "$@"' _ "${REPO_SRC}/lib/carry.sh" "$@"
}

test_each_target_gets_its_groups_and_any() {
    local root; root="$(fixture_carry_tree)"

    carry dsh_carry_payload_paths "$root" dsh-vm > "${FIX_ROOT}/vm.txt"
    assert_equals "diagnose/diagnose_numpy_dll.sh
install_packages.sh
lib/dsh_log.sh
lib/vm_only_lib.sh
unpack_payload.sh" "$(sort "${FIX_ROOT}/vm.txt")" "dsh-vm payload"

    carry dsh_carry_payload_paths "$root" dsh-cluster > "${FIX_ROOT}/cl.txt"
    assert_equals "diagnose/diagnose_cluster_thing.sh
install_git_route.sh
install_packages.sh
lib/dsh_log.sh" "$(sort "${FIX_ROOT}/cl.txt")" "dsh-cluster payload"
}

test_dsh_is_both_boxes() {
    local root; root="$(fixture_carry_tree)"
    carry dsh_carry_payload_paths "$root" dsh > "${FIX_ROOT}/dsh.txt"
    assert_equals 7 "$(wc -l < "${FIX_ROOT}/dsh.txt" | tr -d ' ')" "files in a dsh payload"
}

test_a_directory_that_is_no_group_is_carried_nowhere() {
    local root; root="$(fixture_carry_tree)"
    carry dsh_carry_payload_paths "$root" dsh > "${FIX_ROOT}/dsh.txt"
    if grep -q left_over_from_elsewhere "${FIX_ROOT}/dsh.txt"; then
        fail "a file under carry/other-hpc/ was carried"
    fi
}

test_unknown_targets_are_refused() {
    carry dsh_target_boxes other-hpc > /dev/null && fail "other-hpc accepted as a target"
    carry dsh_target_boxes all > /dev/null && fail "all accepted as a target"
    carry dsh_target_boxes dsh > /dev/null || fail "dsh refused"
}

test_the_default_target_follows_kit_targets() {
    assert_equals dsh-vm      "$(carry dsh_default_target 'dsh-vm')" "dsh-vm only"
    assert_equals dsh-cluster "$(carry dsh_default_target 'dsh-cluster')" "dsh-cluster only"
    assert_equals dsh         "$(carry dsh_default_target 'dsh-cluster dsh-vm')" "both"
    assert_equals dsh         "$(carry dsh_default_target '')" "none named"
}

test_a_basename_collision_is_visible() {
    local root; root="$(fixture_carry_tree)"
    mkdir -p "${root}/dsh-cluster"
    printf '#!/bin/bash\n' > "${root}/dsh-cluster/install_packages.sh"
    assert_equals install_packages.sh \
        "$(carry dsh_carry_basenames "$root" dsh | uniq -d)" "duplicated basename"
}

test_the_real_tree_has_no_basename_collision() {
    assert_equals "" \
        "$(carry dsh_carry_basenames "$REPO_CARRY" dsh | uniq -d)" "duplicated basenames in src/carry"
}

harness_main "$@"
