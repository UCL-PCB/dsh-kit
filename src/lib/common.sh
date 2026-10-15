#!/bin/bash
# OUTSIDE. Shared helpers for the workstation scripts. Sourced by every script in
# src/workstation/, and by nothing that crosses the airlock - this file is not under
# src/carry/, so it is never carried anywhere. The carried scripts have their own
# libraries under src/carry/<group>/lib/.
#
# Source it, do not execute it:
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# It brings the two libraries every script on either side shares:
#   src/carry/any/lib/dsh_log.sh    one truncated log per script, in one Logs/
#   src/carry/any/lib/dsh_conf.sh   reads dsh-kit.conf - the one place a project
#                                   says which repos it carries and how they install

DSH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../carry/any/lib/dsh_log.sh
source "${DSH_REPO_ROOT}/src/carry/any/lib/dsh_log.sh"
# shellcheck source=../carry/any/lib/dsh_conf.sh
source "${DSH_REPO_ROOT}/src/carry/any/lib/dsh_conf.sh"

dsh_die() {
    echo "Error: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# dsh-kit.conf
# ---------------------------------------------------------------------------
# dsh_workstation_conf [path]
#
# Find and load the project's dsh-kit.conf. Resolution order, first hit wins:
#   1. the path given (each script's --conf flag)
#   2. $DSH_KIT_CONF
#   3. <repo root>/dsh-kit.conf - the root of the repository this script is in,
#      which for a project made from the template is where the conf is committed
#
# No walking further up than that: a conf picked up from some unrelated parent
# directory would carry the wrong project's repos across the airlock, and nothing
# downstream could tell.
#
# Sets every KIT_* variable plus KIT_CONF_FILE and KIT_CONF_DIR, or dies.
dsh_workstation_conf() {
    local conf="${1:-${DSH_KIT_CONF:-}}"
    if [ -z "$conf" ]; then
        conf="$(dsh_find_conf "$DSH_REPO_ROOT")" || dsh_die "No dsh-kit.conf at ${DSH_REPO_ROOT}.
       Copy dsh-kit.conf.example to dsh-kit.conf and fill it in (the dsh-init skill
       will do it for you), or pass --conf PATH."
    fi
    [ -f "$conf" ] || dsh_die "No such conf: ${conf}"
    dsh_load_conf "$conf" || dsh_die "${conf} is not valid - see the messages above"
    KIT_CONF_FILE="${KIT_CONF_DIR}/$(basename "$conf")"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# dsh_start_workstation_log <payload dir> "$@"
#
# Every workstation script's log goes to <payload dir>/Logs - the directory the
# payload is BUILT into, which is also where the far side writes its own logs into
# the payload it UNPACKED. So a build_payload.log sits next to the verify_payload.log
# that came back from the VM, and nothing writes a log into this repository, where
# it would be untracked clutter at best and something to commit by accident at worst.
#
# DSH_LOG_DIR overrides it outright.
#
# Call it once the payload directory is known and NOT before: everything above that
# in a script is argument parsing, and a usage error needs no log. The call does not
# return in the parent - it re-executes the script through tee - so pass the
# script's ORIGINAL arguments, saved before the parsing loop consumed them.
dsh_start_workstation_log() {
    local payload_dir="$1"
    shift
    [ -n "${DSH_LOG_BASE_DIR:-}" ] || DSH_LOG_BASE_DIR="$payload_dir"
    dsh_start_log "$@"
}
