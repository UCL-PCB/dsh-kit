#!/bin/bash
# OUTSIDE. What goes to which box. Sourced, not run.
#
# The DIRECTORY IS THE ANSWER. src/carry/<group>/ holds the files that go to a group
# of targets, and nothing else does; add a script to the right directory and it is
# carried, delete it and it is not. There is no second list to update and therefore
# no list to forget - a hand-kept list of "what the payload contains" drifts from the
# tree the first time someone adds a script and forgets the list.
#
#   src/carry/any/           every target
#   src/carry/dsh-vm/        the Windows analysis VM in the data safe
#   src/carry/dsh-cluster/   the Linux batch cluster behind it
#   src/carry/diagnose/<g>/  diagnosis scripts, carried to group <g>
#   src/carry/<g>/lib/       sourced-only libraries, carried to group <g>
#
# The directory also decides WHERE IN THE PAYLOAD a file lands - see
# dsh_payload_path. The far side is not one flat pile either: a diagnosis script
# lands in diagnose/ and a sourced library in lib/, so a listing of the payload
# root is the scripts an operator might actually run and nothing else.
#
# The two TARGETS - the actual boxes - are dsh-vm and dsh-cluster. "any" is the union
# of them, and exists because a file genuinely wanted on both should be in one place
# rather than two.
#
# Note what is NOT here: src/workstation/ and src/lib/ are never carried anywhere,
# which is visible from the path rather than from a comment.

# The boxes a group directory serves.
dsh_group_targets() {
    case "$1" in
        any)          printf '%s\n' dsh-vm dsh-cluster ;;
        dsh-vm)       printf '%s\n' dsh-vm ;;
        dsh-cluster)  printf '%s\n' dsh-cluster ;;
        *)            return 1 ;;
    esac
}

# The boxes a --target selects. "dsh" is one airlock trip: the VM and the cluster
# behind it are refreshed together, because the cluster is reached FROM the VM and
# its scripts have to land there first.
dsh_target_boxes() {
    case "$1" in
        dsh)          printf '%s\n' dsh-vm dsh-cluster ;;
        dsh-vm)       printf '%s\n' dsh-vm ;;
        dsh-cluster)  printf '%s\n' dsh-cluster ;;
        *)            return 1 ;;
    esac
}

# dsh_default_target <KIT_TARGETS value>  ->  the --target that selects exactly those
# boxes. Both, or neither named, is "dsh".
dsh_default_target() {
    local vm=0 cl=0 t
    for t in $1; do
        case "$t" in
            dsh-vm)      vm=1 ;;
            dsh-cluster) cl=1 ;;
        esac
    done
    if [ "$vm" -eq 1 ] && [ "$cl" -eq 0 ]; then
        echo dsh-vm
    elif [ "$vm" -eq 0 ] && [ "$cl" -eq 1 ]; then
        echo dsh-cluster
    else
        echo dsh
    fi
}

# dsh_carry_group <path under src/carry>  ->  the group directory name
#
# diagnose/dsh-vm is the dsh-vm group; everything else is its own first component,
# and a trailing lib/ says where a file lands rather than which box it goes to.
dsh_carry_group() {
    local rel="${1#carry/}"
    case "$rel" in
        diagnose/*) rel="${rel#diagnose/}" ;;
    esac
    printf '%s\n' "${rel%%/*}"
}

# dsh_payload_path <path under src/carry>  ->  where it lands, relative to the
# payload directory.
#
#   any/lib/dsh_log.sh                     ->  lib/dsh_log.sh
#   diagnose/dsh-vm/diagnose_numpy_dll.sh  ->  diagnose/diagnose_numpy_dll.sh
#   any/install_packages.sh                ->  install_packages.sh
#
# Three directories on the far side, not the groups. The groups answer WHICH BOX,
# which is of no interest to an operator standing at one of them; what they want
# from a listing is the steps they might run. So lib/ takes what is only ever
# sourced, diagnose/ what is only ever run once something is already wrong, and the
# procedure's own steps are what is left at the top.
#
# Basenames stay unique across the whole payload regardless, and build_payload.sh
# refuses a collision: the procedure names scripts by bare filename, so a payload where
# two files answer to one name is not made safe by their sitting in different
# directories.
dsh_payload_path() {
    local rel="${1#carry/}"
    case "$rel" in
        diagnose/*) printf 'diagnose/%s\n' "$(basename "$rel")" ;;
        */lib/*)    printf 'lib/%s\n'      "$(basename "$rel")" ;;
        *)          basename "$rel" ;;
    esac
}

# dsh_carry_files <carry root> <target>
#
# Every file that goes to <target>, one "<group> <relative path>" per line, sorted
# by the name it lands under. Relative to <carry root>, which is src/carry.
#
# Where each one lands is dsh_payload_path's answer rather than this one's. Two
# files in different groups may not share a basename whatever directory they land
# in, and that is checked rather than assumed: the symptom of a collision on the
# far side is not an error but one file quietly answering to the other's name.
dsh_carry_files() {
    local root="$1" target="$2" rel group wanted path box boxes group_boxes

    # Both sides as space-delimited strings, matched with bash's own pattern test.
    # Spawning a `grep` per file per box is some hundreds of processes for a single
    # build, and on Git Bash for Windows, where a fork is expensive, that takes
    # longer than everything else the build does put together.
    boxes=" $(dsh_target_boxes "$target" | tr '\n' ' ')"
    [ "$boxes" = " " ] && return 1

    while IFS= read -r path; do
        rel="${path#"${root}"/}"
        group="$(dsh_carry_group "carry/${rel}")"
        group_boxes="$(dsh_group_targets "$group" | tr '\n' ' ')" || continue
        wanted=0
        for box in $group_boxes; do
            case "$boxes" in *" ${box} "*) wanted=1; break ;; esac
        done
        [ "$wanted" -eq 1 ] || continue
        printf '%s %s\n' "$group" "$rel"
    done < <(find "$root" -type f | sort) | sort -k2
}

# The payload-relative paths of a target's carried files, in the order they land.
dsh_carry_payload_paths() {
    local entry
    while read -r entry; do
        dsh_payload_path "carry/${entry#* }"
    done < <(dsh_carry_files "$1" "$2")
}

# The bare filenames of a target's carried files, in the order they land.
dsh_carry_basenames() {
    dsh_carry_files "$1" "$2" | awk '{n=split($2,p,"/"); print p[n]}' | sort
}
