#!/bin/bash
# EVERYWHERE. Read dsh-kit.conf. Sourced, not run.
#
# The conf is PARSED rather than sourced: only lines of the form KEY="value" (or
# KEY=value) with KEY starting KIT_ are taken, and the value is used literally. So a
# conf carried in from outside cannot run anything here, and PowerShell
# (export_bundles.ps1) reads the same file with the same rule.
#
#   dsh_load_conf <path>     sets every KIT_* variable it finds, then the defaults
#   dsh_find_conf <dir>...   prints the first <dir>/dsh-kit.conf that exists
#
# After dsh_load_conf, these are always set (possibly empty):
#   KIT_PROJECT KIT_REPOS KIT_REPOS_DIR KIT_WORKING_REPOS KIT_INSTALL_MODE KIT_EXTRAS
#   KIT_PYTHON_SPEC KIT_IMPORT_CHECK KIT_CONSOLE_SCRIPTS KIT_GITLAB_HOST
#   KIT_GITLAB_GROUP KIT_WORKING_NAMESPACE KIT_TARGETS
# and KIT_CONF_DIR is the directory the conf was read from.

DSH_CONF_KEYS="KIT_PROJECT KIT_REPOS KIT_REPOS_DIR KIT_WORKING_REPOS KIT_INSTALL_MODE
KIT_EXTRAS KIT_PYTHON_SPEC KIT_IMPORT_CHECK KIT_CONSOLE_SCRIPTS KIT_GITLAB_HOST
KIT_GITLAB_GROUP KIT_WORKING_NAMESPACE KIT_TARGETS"

dsh_find_conf() {
    local d
    for d in "$@"; do
        [ -n "$d" ] && [ -f "${d}/dsh-kit.conf" ] && { printf '%s\n' "${d}/dsh-kit.conf"; return 0; }
    done
    return 1
}

dsh_load_conf() {
    local conf="$1" line key val n=0
    [ -f "$conf" ] || { echo "dsh_load_conf: no such file: ${conf}" >&2; return 1; }
    KIT_CONF_DIR="$(cd "$(dirname "$conf")" && pwd)"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        n=$((n + 1))
        case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
        if [[ "$line" =~ ^(KIT_[A-Z_]+)=\"([^\"]*)\"[[:space:]]*(#.*)?$ ]] \
           || [[ "$line" =~ ^(KIT_[A-Z_]+)=([^[:space:]\"]*)[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            case " $(echo $DSH_CONF_KEYS) " in
                *" ${key} "*) printf -v "$key" '%s' "$val" ;;
                *) echo "dsh_load_conf: ${conf}:${n}: unknown key ${key} - ignored" >&2 ;;
            esac
        else
            echo "dsh_load_conf: ${conf}:${n}: not KEY=\"value\" - ignored: ${line}" >&2
        fi
    done < "$conf"

    : "${KIT_PROJECT:=dsh-project}"
    : "${KIT_REPOS_DIR:=../}"
    : "${KIT_INSTALL_MODE:=venv}"
    : "${KIT_GITLAB_HOST:=gitlab.idhs.ucl.ac.uk}"
    : "${KIT_TARGETS:=dsh-vm}"
    : "${KIT_WORKING_REPOS:=}" "${KIT_EXTRAS:=}" "${KIT_PYTHON_SPEC:=}" "${KIT_GITLAB_GROUP:=}"
    : "${KIT_CONSOLE_SCRIPTS:=}" "${KIT_WORKING_NAMESPACE:=}" "${KIT_REPOS:=}"
    if [ -z "${KIT_IMPORT_CHECK:-}" ]; then
        KIT_IMPORT_CHECK="$(printf '%s' "$KIT_REPOS" | tr '-' '_')"
    fi

    dsh_check_conf
}

# Fail on what would otherwise surface two boxes later.
dsh_check_conf() {
    local bad=0 r
    [ -n "$KIT_REPOS" ] || { echo "dsh-kit.conf: KIT_REPOS is empty" >&2; bad=1; }
    case "$KIT_INSTALL_MODE" in venv|workspace) ;; *)
        echo "dsh-kit.conf: KIT_INSTALL_MODE must be venv or workspace, not '${KIT_INSTALL_MODE}'" >&2; bad=1 ;;
    esac
    for r in $KIT_WORKING_REPOS; do
        case " $KIT_REPOS " in *" $r "*) ;; *)
            echo "dsh-kit.conf: KIT_WORKING_REPOS names ${r}, which is not in KIT_REPOS" >&2; bad=1 ;;
        esac
    done
    for r in $KIT_TARGETS; do
        case "$r" in dsh-vm|dsh-cluster) ;; *)
            echo "dsh-kit.conf: KIT_TARGETS: unknown target '${r}' (dsh-vm, dsh-cluster)" >&2; bad=1 ;;
        esac
    done
    return "$bad"
}

# dsh_is_working_repo <name>  - true if the conf marks it as edited inside.
dsh_is_working_repo() {
    case " ${KIT_WORKING_REPOS} " in *" $1 "*) return 0 ;; esac
    return 1
}

# dsh_repos_dir  - KIT_REPOS_DIR made absolute against the conf's directory.
dsh_repos_dir() {
    case "$KIT_REPOS_DIR" in
        /*|[A-Za-z]:*) (cd "$KIT_REPOS_DIR" && pwd) ;;
        *)             (cd "${KIT_CONF_DIR}/${KIT_REPOS_DIR}" && pwd) ;;
    esac
}
