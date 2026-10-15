#!/bin/bash
# INSIDE. Why does git say "permission denied" for things that touch no network?
#
# Symptom this exists for: `git config --global --list` fails with a permission
# error. That command reads ~/.gitconfig and nothing else - no host, no
# credential, no TLS. So the earlier GitLab failures that looked like an access
# problem may have been this same local fault wearing a different hat, and every
# conclusion drawn from them is suspect until this is settled.
#
# The candidates, and they are distinguishable:
#
#   A. HOME points somewhere git cannot read or write - a redirected or
#      network-mapped profile is the usual DSH cause. Everything git does
#      touches HOME, so everything fails.
#   B. ~/.gitconfig exists but its ACL denies this account, e.g. written by
#      another user or an installer.
#   C. The system config (/etc/gitconfig, or Git's installed mingw64 copy) is
#      unreadable, which git reports before it ever gets to the global one.
#   D. git itself cannot execute - blocked binary, broken install, or a PATH
#      entry pointing at something this account may not run.
#   E. git cannot STAT AN ANCESTOR of the current directory. Before doing
#      anything, git walks up from the cwd looking for a .git, statting each
#      parent; one it may not stat kills every command with
#      `fatal: failed to stat '<dir>': Permission denied`, config reads and
#      remote operations alike. THIS IS THE ONE THAT ACTUALLY HAPPENS ON THE DSH
#      DESKTOP, and from the outside it is indistinguishable from GitLab
#      denying the account. GIT_CEILING_DIRECTORIES stops the walk.
#
# ENTIRELY READ-ONLY except for one temp file per directory it tests, each
# removed immediately. It writes no git config and contacts no host.
#
#   ./diagnose_git_permissions.sh
#
# The exact error text is captured verbatim into the log - that wording is the
# diagnosis, so it is worth having on disk rather than on screen only.
#
# Log: Logs/diagnose_git_permissions.log beside this script.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

# The payload ROOT: this script lands in DSH_import/diagnose/, and everything
# it reaches for - lib/, the workspace, the other scripts - is named from there.
PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

case "${1:-}" in
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
hr()   { echo; echo "=== $* ==="; }

GIT_RUNS="no"
HOME_READABLE="no"
HOME_WRITABLE="no"
CONFIG_READS="no"
CONFIG_ERR=""
STAT_DENIED="no"
CEILING_FIXES="no"

hr "1. Who and where"
# HOME is the single most likely culprit, so it is established before anything
# that depends on it.
echo "  whoami:   $(whoami 2>&1)"
echo "  HOME:     ${HOME:-(unset)}"
echo "  cwd:      $(pwd 2>&1)"
echo "  USERPROFILE: ${USERPROFILE:-(unset)}"
# A HOME that differs from USERPROFILE is normal in Git Bash, but a HOME on a
# mapped drive (anything not /c) is worth seeing plainly.
case "${HOME:-}" in
    /c/*) echo "  HOME is on C: (local disk)" ;;
    "")   echo "  HOME IS UNSET - git has nowhere to look for its config" ;;
    *)    echo "  HOME IS NOT ON C: - a redirected or mapped profile is candidate A" ;;
esac

hr "2. Can this shell read and write HOME"
if [ -d "${HOME:-/nonexistent}" ] && [ -r "${HOME:-/nonexistent}" ]; then
    HOME_READABLE="yes"
    echo "  readable: yes"
    ls -ld "$HOME" 2>&1 | sed 's/^/    /'
else
    echo "  readable: NO - $(ls -ld "${HOME:-}" 2>&1 | head -1)"
fi
probe="${HOME:-/nonexistent}/.dsh_write_probe"
if ( : > "$probe" ) 2>/dev/null; then
    HOME_WRITABLE="yes"
    rm -f "$probe"
    echo "  writable: yes"
else
    echo "  writable: NO - git cannot create or lock config here"
fi

hr "3. Is git runnable at all"
echo "  which git: $(command -v git 2>&1 || echo 'NOT FOUND')"
if git --version >/dev/null 2>&1; then
    GIT_RUNS="yes"
    echo "  version:   $(git --version 2>&1)"
else
    echo "  version:   FAILED - $(git --version 2>&1 | head -2)"
fi

hr "4. The failing command, with its exact words"
# The wording is the diagnosis. Captured rather than shown only, because the
# distinction between "unable to read config" and "could not lock" decides
# which of B and C it is.
if git config --global --list > "${PAYLOAD_DIR}/.gitconfig.out" 2>"${PAYLOAD_DIR}/.gitconfig.err"; then
    CONFIG_READS="yes"
    echo "  git config --global --list: OK, $(wc -l < "${PAYLOAD_DIR}/.gitconfig.out" | tr -d ' ') lines"
    echo "  --- the lines that matter ---"
    grep -iE 'insteadof|credential|sslbackend|http\.' "${PAYLOAD_DIR}/.gitconfig.out" | sed 's/^/    /' \
        || echo "    (none of insteadOf / credential / sslBackend are set)"
else
    CONFIG_ERR="$(cat "${PAYLOAD_DIR}/.gitconfig.err" 2>/dev/null)"
    if [ -z "$CONFIG_ERR" ]; then
        # Non-zero with nothing on stderr means the config is merely EMPTY.
        # Reporting that as a permission fault sends the diagnosis somewhere
        # expensive and wrong, which is exactly what happened once.
        CONFIG_READS="empty"
        echo "  git config --global --list: exits non-zero but says nothing -"
        echo "  the global config is EMPTY, not unreadable. Anything you thought"
        echo "  you set globally (http.sslBackend, say) did not persist."
    else
        echo "  git config --global --list: FAILED"
        echo "  --- verbatim ---"
        echo "$CONFIG_ERR" | sed 's/^/    /'
        case "$CONFIG_ERR" in
            *"failed to stat"*)
                STAT_DENIED="yes"
                echo "  --- with the walk stopped at HOME ---"
                if GIT_CEILING_DIRECTORIES="$HOME" git config --global --list >/dev/null 2>&1                    || [ -z "$(GIT_CEILING_DIRECTORIES="$HOME" git config --global --list 2>&1 >/dev/null)" ]; then
                    CEILING_FIXES="yes"
                    echo "    GIT_CEILING_DIRECTORIES=\$HOME clears it - CAUSE E confirmed"
                else
                    echo "    still failing with the ceiling set"
                fi ;;
        esac
    fi
fi

hr "5. Which config files git can see"
# --show-origin names every file it reads, so an unreadable system config shows
# up here as the one that is missing from the list.
git config --list --show-origin 2>&1 | sed 's/^/    /' | head -30

hr "6. The config files themselves"
for f in "${HOME:-/nonexistent}/.gitconfig" "/etc/gitconfig" "/mingw64/etc/gitconfig" "/c/Program Files/Git/etc/gitconfig"; do
    if [ -e "$f" ]; then
        printf '  %-42s %s\n' "$f" "$( [ -r "$f" ] && echo readable || echo 'NOT READABLE' )"
        ls -l "$f" 2>&1 | sed 's/^/      /'
    else
        printf '  %-42s %s\n' "$f" "absent"
    fi
done

hr "7. Environment that overrides where git looks"
for v in GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG GIT_DIR GIT_TERMINAL_PROMPT; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && echo "  ${v}=${val}"
done
echo "  (nothing listed above means none are set, which is normal)"

hr "Verdict"
printf '  %-24s %s\n' "git runs"        "$GIT_RUNS"
printf '  %-24s %s\n' "HOME readable"   "$HOME_READABLE"
printf '  %-24s %s\n' "HOME writable"   "$HOME_WRITABLE"
printf '  %-24s %s\n' "global config reads" "$CONFIG_READS"
rm -f "${PAYLOAD_DIR}/.gitconfig.out" "${PAYLOAD_DIR}/.gitconfig.err"
echo

if [ "$GIT_RUNS" = "no" ]; then
    echo "  CAUSE D - git will not run in this shell. Nothing about GitLab,"
    echo "  credentials or TLS has been established; every earlier failure is"
    echo "  explained by this. Section 3 shows what it said and where it is."
    exit 1
fi
if [ "$STAT_DENIED" = "yes" ]; then
    echo "  CAUSE E - git cannot stat an ancestor of this directory, so EVERY git"
    echo "  command dies here before touching a repo, a config or a host. Any"
    echo "  earlier conclusion about GitLab, credentials or TLS drawn from a"
    echo "  failing git command is void - re-run those checks after the fix."
    echo
    if [ "$CEILING_FIXES" = "yes" ]; then
        echo "  Fix, and keep it across sessions (Citrix drops after 18 h):"
        echo "      export GIT_CEILING_DIRECTORIES=\$HOME"
        echo "      echo 'export GIT_CEILING_DIRECTORIES=\$HOME' >> ~/.bashrc"
    else
        echo "  The ceiling at \$HOME did not clear it - the unstattable directory"
        echo "  is at or below HOME. Section 4 names the path; work from a"
        echo "  directory whose ancestors this account can stat."
    fi
    exit 1
fi
if [ "$CONFIG_READS" = "empty" ]; then
    echo "  Not a permission problem: the global config is empty. If you set"
    echo "  http.sslBackend earlier, that write did not land - re-run it and"
    echo "  confirm with: git config --global --list"
    exit 0
fi
if [ "$CONFIG_READS" = "yes" ]; then
    echo "  Git config is fine HERE. So the permission error came from somewhere"
    echo "  else - a different shell, a different directory, or a command that"
    echo "  was not this one. Section 4 lists insteadOf / credential / sslBackend"
    echo "  if any are set; an insteadOf rewrite is what silently turns an https"
    echo "  URL into ssh and produces 'Permission denied (publickey)'."
    exit 0
fi
if [ "$HOME_READABLE" = "no" ] || [ "$HOME_WRITABLE" = "no" ]; then
    echo "  CAUSE A - HOME is not usable by this account, so every git command"
    echo "  fails before it does anything. Everything else waits on this."
    echo "  Workaround to test it, in this shell only:"
    echo "      export HOME=/c/Users/\$(whoami)"
    echo "  If git config --global --list then works, HOME was the whole problem."
    exit 1
fi
echo "  CAUSE B or C - HOME is usable but a config file is not readable."
echo "  Section 6 marks which one. A file marked NOT READABLE is the answer;"
echo "  if that is the system config, git can be told to skip it:"
echo "      export GIT_CONFIG_NOSYSTEM=1"
echo "  and if that makes it work, the system gitconfig's ACL is the fault."
exit 1
