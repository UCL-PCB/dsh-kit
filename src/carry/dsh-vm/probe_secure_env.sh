#!/bin/bash -l
# INSIDE the secure environment, on the analysis VM. Read-only: installs nothing, changes nothing.
#
# This is the box where the packages get installed and where analysis runs. There is no batch
# scheduler here - that is expected, not a fault. Use probe_cluster.sh for a real cluster.
#
#   ./probe_secure_env.sh
#   ./probe_secure_env.sh --gitlab gitlab.idhs.ucl.ac.uk --artifactory artifactory.idhs.ucl.ac.uk
#
# The -l on the shebang matters: a plain #!/bin/bash gets a non-login shell, which does not source
# /etc/profile.d, so PATH additions are missing and "module" - a shell function, not a program -
# always looks absent even when it works fine interactively.
#
# Save the output to carry back out:   ./probe_secure_env.sh ... | tee probe_secure_env.txt

# UCL-documented hosts from the DSH User Guide & FAQs, so the probe is useful with no
# flags at all. --gitlab / --artifactory still override, and the probe reports what it
# actually got rather than assuming these answer.
GITLAB_HOST="gitlab.idhs.ucl.ac.uk"
ARTIFACTORY_HOST="artifactory.idhs.ucl.ac.uk"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab)      GITLAB_HOST="$2"; shift 2 ;;
        --artifactory) ARTIFACTORY_HOST="$2"; shift 2 ;;
        -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
        *)             echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Refuse to be sourced. This script uses "exit", and in a sourced script exit terminates the
# calling shell - which looks exactly like the terminal closing on you. Run it, do not source it.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    echo "(sourcing it makes its 'exit' close your terminal)" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"
# shellcheck source=../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"
# The Python range comes from the project's dsh-kit.conf. A probe is still useful
# without one - run from a bare copy of the scripts - so a missing conf only means
# "any Python 3", said out loud below rather than failed on.
KIT_PYTHON_SPEC=""
if dsh_kit_settings "$PAYLOAD_DIR" 2>/dev/null; then
    PY_SPEC_SRC="dsh-kit.conf"
else
    PY_SPEC_SRC="no dsh-kit.conf found - any Python 3"
fi
SPEC_SHOWN="${KIT_PYTHON_SPEC:-any 3.x}"

hr() { printf '\n=== %s %s\n' "$1" "$(printf '%.0s-' $(seq 1 $((60 - ${#1}))))"; }
have() { command -v "$1" > /dev/null 2>&1; }
report() { printf '  %-28s %s\n' "$1" "$2"; }

V_ARCH=""; V_PY=""; V_PYPATH=""; V_PYVERDICT=""; V_UV=""
V_GITLAB="not tested"; V_ARTIFACTORY="not tested"; V_PYPI="not tested"; V_DISK=""; V_CORES=""

# The DSH has two boxes and they are not the same OS: the Desktop analysis VM is
# Windows (driven from Git Bash), the cluster login node is Linux. Which uv
# binary to carry, where uv reads its config, and where the venv can live all
# turn on this, so establish it first and say so loudly.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) DSH_OS="windows" ;;
    *)                    DSH_OS="linux"   ;;
esac

hr "Machine"
report "hostname" "$(hostname 2>/dev/null)"
report "os" "$(uname -s -r 2>/dev/null)"
report "PLATFORM" "${DSH_OS}   <- decides which uv asset and which uv.toml path"
V_ARCH="$(uname -m 2>/dev/null)"
report "arch" "${V_ARCH}   <- must be x86_64 for the uv binary we carried in"
[ -f /etc/os-release ] && report "distro" "$(. /etc/os-release && echo "$PRETTY_NAME")"
report "user" "$(id -un 2>/dev/null)"
if [ "$DSH_OS" = "windows" ]; then
    report "needs uv asset" "uv-x86_64-pc-windows-msvc.zip"
    report "uv config path" "%APPDATA%/uv/uv.toml   (NOT ~/.config/uv/uv.toml)"
    report "venv interpreter" ".venv/Scripts/python.exe"
else
    report "needs uv asset" "uv-x86_64-unknown-linux-gnu.tar.gz"
    report "uv config path" "~/.config/uv/uv.toml"
    report "venv interpreter" ".venv/bin/python"
fi

hr "Local compute"
# No scheduler here, so everything runs on this box. These numbers set how much parallelism is
# realistic: an analysis that fans out across processes is bounded by cores and by memory per worker.
V_CORES="$(nproc 2>/dev/null)"
report "cores" "${V_CORES}"
have free && report "memory" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $2" total, "$7" available"}')"
[ "$DSH_OS" = "linux" ] && report "load average" "$(uptime 2>/dev/null | sed 's/.*load average: //')"

if [ "$DSH_OS" = "windows" ]; then
hr "Windows drives and PATH"
    # Where the venv lives is not a detail on Windows. numpy failing with
    # "DLL load failed ... The parameter is incorrect" has two usual causes:
    # Anaconda shadowing the venv DLLs, and loading DLLs across SMB from a
    # mapped drive. Both are visible from here.
    for d in c d e n q r s t u v; do
        [ -d "/$d" ] || continue
        D=$(echo "$d" | tr 'a-z' 'A-Z')
        free=$(df -h "/$d" 2>/dev/null | awk 'NR==2 {print $4" free of "$2}')
        note=""
        [ "$D" = "S" ] && note="group share - research data lives here"
        [ "$D" = "N" ] && note="home, 50 GB - Artifactory config goes in its ROOT"
        [ "$D" = "Q" ] && note="MFT Arrivals - WIPED 30 days after arrival"
        [ "$D" = "R" ] && note="MFT Outbound - wiped after 30 days"
        [ "$D" = "C" ] && note="local disk - safest place for the venv"
        printf '  %-6s %-32s %s\n' "${D}:" "${free:-unknown}" "$note"
    done
    echo
    n_conda=$(echo "$PATH" | tr ':' '\n' | grep -ciE 'anaconda|miniconda')
    report "Anaconda on PATH" "${n_conda} entries  <- non-zero is the prime suspect for the numpy DLL error"
    echo "$PATH" | tr ':' '\n' | grep -iE 'anaconda|miniconda' | sed 's|^|      |'
    report "CONDA_PREFIX" "${CONDA_PREFIX:-unset}"
    report "APPDATA" "${APPDATA:-unset}"
    report "LOCALAPPDATA" "${LOCALAPPDATA:-unset}"
fi

hr "Python"
# Judged against KIT_PYTHON_SPEC from dsh-kit.conf. With no module system there is no
# loading a different one, so whatever is on this box is what we get.
report "required" "${SPEC_SHOWN}   (${PY_SPEC_SRC})"
BEST_PY=""
# shellcheck disable=SC2206
PY_CANDIDATES=($DSH_PY_CANDIDATES)
if [ "$DSH_OS" = "windows" ]; then
    # There are no python3.13-style binary names on Windows. The py launcher
    # lists every registered install; anything else only shows up via `where`.
    echo "  --- py -0p ---"
    py -0p 2>/dev/null | tr -d '\r' | sed 's|^|    |' || echo "    (no py launcher)"
    echo "  --- where python ---"
    where python 2>/dev/null | tr -d '\r' | sed 's|^|    |' || echo "    (none on PATH)"
    echo "  --- interpreters on disk ---"
    for g in /c/Python3* "/c/Program Files/Python3"* "/c/Program Files (x86)/Python3"*; do
        [ -d "$g" ] && echo "    $g"
    done
    if [ -n "${LOCALAPPDATA:-}" ]; then
        for g in "$(cygpath -u "$LOCALAPPDATA")/Programs/Python/"*; do
            [ -d "$g" ] && echo "    $g"
        done
    fi
    echo
    WIN_PY_LIST=$( { py -0p 2>/dev/null; where python 2>/dev/null; } | tr -d '\r' | grep -i 'python.exe' )
    for w in $WIN_PY_LIST; do
        case "$w" in
            *[Pp]ython.exe)
                u=$(cygpath -u "$w" 2>/dev/null)
                [ -n "$u" ] && PY_CANDIDATES+=("$u")
                ;;
        esac
    done
fi
# Resolve each candidate to its real interpreter before judging it, so the same
# python reached by three different names is reported once. Sorting on the
# version rather than taking the first hit matters: the first name that happens
# to be on PATH is often a shim or an old install, and the install wants the newest
# interpreter inside the range, not the first one found.
BEST_VER="0.0.0"
SEEN=""
for py in "${PY_CANDIDATES[@]}"; do
    have "$py" || [ -x "$py" ] || continue
    # Resolve to the BASE interpreter. A candidate that is itself a virtualenv
    # (bare "python" very often is) resolves to the real install behind it, so
    # this both deduplicates and stops the install being handed a venv to build a
    # venv from. Reporting the resolved path, not the name that found it, is
    # what makes the recommendation copy-pasteable.
    real="$("$py" -c 'import sys,os; print(os.path.realpath(getattr(sys,"_base_executable",None) or sys.executable))' 2>/dev/null)"
    if [ -n "$real" ] && command -v cygpath >/dev/null 2>&1; then
        real="$(cygpath -u "$real" 2>/dev/null || echo "$real")"
    fi
    [ -n "$real" ] || { report "$py" "$("$py" --version 2>&1 | head -1)   [NOT A WORKING INTERPRETER]"; continue; }
    case "$SEEN" in *"|${real}|"*) continue ;; esac
    SEEN="${SEEN}|${real}|"

    ver3="$("$py" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)"
    path="$real"
    if dsh_py_satisfies "$py"; then
        report "Python ${ver3}" "[IN RANGE]   ${path}"
        newest="$(printf '%s\n%s\n' "$BEST_VER" "$ver3" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
        if [ "$newest" = "$ver3" ]; then
            BEST_VER="$ver3"; BEST_PY="$path"; V_PY="Python ${ver3}"; V_PYPATH="$path"; V_PYVERDICT="IN RANGE"
        fi
    else
        report "Python ${ver3}" "[OUT OF RANGE]   ${path}"
        [ -z "$V_PY" ] && { V_PY="Python ${ver3}"; V_PYPATH="$path"; V_PYVERDICT="OUT OF RANGE"; }
    fi
done
ls -1 /usr/bin/python3* /usr/local/bin/python3* 2>/dev/null | sed 's|^|    |'
echo
if [ -n "$BEST_PY" ]; then
    report "USE FOR INSTALL" "--python '${BEST_PY}'"
    report "" "(newest interpreter inside ${SPEC_SHOWN}; quote it, the path may have spaces)"
    report "" "or put KIT_PYTHON=\"${BEST_PY}\" in ~/dsh-kit.env"
else
    report "VERDICT" "no interpreter in ${SPEC_SHOWN} - STOP, this is an admin request"
fi

hr "Environment modules"
# Informational only - nothing in the plan needs modules. Checked here rather than in a script
# shell, because a non-login shell always reports absent.
if type module > /dev/null 2>&1; then
    report "module" "present"
    module avail 2>&1 | sed 's/^/    /' | head -20
else
    report "module" "absent"
    for f in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/lmod/lmod/init/bash; do
        [ -f "$f" ] && report "but found" "$f  <- modules exist; you are not in a login shell"
    done
fi

hr "Scheduler (expected: none on this box)"
FOUND_SCHED=""
for cmd in qsub qstat sbatch squeue bsub condor_submit; do
    have "$cmd" && { report "$cmd" "$(command -v "$cmd")"; FOUND_SCHED="yes"; }
done
if [ -z "$FOUND_SCHED" ]; then
    report "none on PATH" "expected for an analysis VM - jobs run directly here"
    ls -d /opt/sge* /opt/slurm* /etc/slurm* /etc/sge* /usr/share/gridengine 2>/dev/null | sed 's/^/    found: /'
else
    report "NOTE" "a scheduler IS present - run probe_cluster.sh as well"
fi

hr "uv and git"
if have uv; then
    V_UV="$(uv --version 2>&1)"
    report "uv" "$(command -v uv) - ${V_UV}"
else
    V_UV="not installed"
    report "uv" "NOT FOUND - ./install_uv.sh installs the binary we carried in"
    report "note" "no internet means curl-pipe-sh and uv python install both fail"
fi
have git && report "git" "$(git --version)"
# Existing is not the same as working. git walks up from the cwd statting every
# ancestor before it does anything; where an ancestor is not stattable by this
# account it dies with `fatal: failed to stat ...: Permission denied` - on every
# command, including ones that touch no repository and no network. Untreated,
# that surfaces at the mirror step as GitLab apparently refusing the account.
V_GITRUN="not tested"
if have git; then
    git_err="$(git rev-parse --git-dir 2>&1 >/dev/null)"
    case "$git_err" in
        *"failed to stat"*)
            V_GITRUN="BROKEN HERE - needs GIT_CEILING_DIRECTORIES"
            report "git usable here" "NO - ${git_err}"
            report "git fix" "export GIT_CEILING_DIRECTORIES=\$HOME  (add it to ~/.bashrc)"
            if [ -z "$(GIT_CEILING_DIRECTORIES="$HOME" git rev-parse --git-dir 2>&1 >/dev/null | grep 'failed to stat')" ]; then
                report "git fix works" "yes - the ceiling at \$HOME clears it"
            else
                report "git fix works" "NO - run diagnose/diagnose_git_permissions.sh"
            fi ;;
        *)  V_GITRUN="yes" ;;
    esac
fi

hr "Network reachability"
probe_host() {
    local label="$1" host="$2" code
    if [ -z "$host" ]; then
        report "$label" "(not given - pass --${label} HOST)"
        RESULT="not tested"; return
    fi
    if have curl; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${host}" 2>/dev/null)
        report "$label" "https://${host} -> HTTP ${code:-no response}   (200/401/403 all answer)"
        RESULT="HTTP ${code:-none}"
    elif have getent; then
        report "$label" "$(getent hosts "$host" || echo 'does not resolve')"
        RESULT="dns only"
    else
        report "$label" "no curl or getent to test with"
        RESULT="untestable"
    fi
}
probe_host gitlab "$GITLAB_HOST";           V_GITLAB="$RESULT"
probe_host artifactory "$ARTIFACTORY_HOST"; V_ARTIFACTORY="$RESULT"
if have curl; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://pypi.org/simple/ 2>/dev/null)
    V_PYPI="HTTP ${code:-unreachable}"
    report "public pypi" "${V_PYPI}   <- SHOULD be unreachable; if it answers, report it"
fi
[ -n "${HTTPS_PROXY:-}${https_proxy:-}" ] && report "proxy env" "${HTTPS_PROXY:-$https_proxy}"

hr "Filesystem"
report "HOME" "$HOME"
report "TMPDIR" "${TMPDIR:-unset (defaults to /tmp)}"
for d in "$HOME/Scratch" /scratch "/scratch/$USER" /data "$HOME/Projects"; do
    [ -d "$d" ] && report "found" "$d"
done
if have df; then
    V_DISK="$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $4" free of "$2}')"
    echo "  --- df ---"
    df -h "$HOME" /tmp 2>/dev/null | sed 's/^/    /'
fi

hr "Build tools"
# Only matters if Artifactory lacks a wheel and something has to compile from sdist.
for c in gcc g++ make cmake; do
    have "$c" && report "$c" "$("$c" --version 2>&1 | head -1)"
done

hr "Existing package-manager config"
UV_CFGS=("$HOME/.config/uv/uv.toml" "$HOME/.config/pip/pip.conf" "$HOME/.pip/pip.conf" "$HOME/.netrc")
if [ "$DSH_OS" = "windows" ]; then
    [ -n "${APPDATA:-}" ] && UV_CFGS+=("$(cygpath -u "$APPDATA")/uv/uv.toml")
    # The FAQ is explicit: on the Desktop these go in the ROOT of N:, and
    # Notepad will happily save them as .txt without telling you.
    UV_CFGS+=(/n/pip.ini /n/.condarc /n/pip.ini.txt /n/.condarc.txt)
fi
for f in "${UV_CFGS[@]}"; do
    if [ -f "$f" ]; then
        report "found" "$f"
        case "$f" in
            *netrc) report "" "(contents not shown - holds credentials)" ;;
            *)      sed 's/^/    /' "$f" ;;
        esac
    fi
done

hr "REPORT SHEET"
echo "  Copy this back out."
echo
printf '    %-28s %s\n' "Machine type"          "analysis VM (no scheduler)"
printf '    %-28s %s\n' "Platform"              "${DSH_OS}"
printf '    %-28s %s\n' "arch"                  "${V_ARCH}"
printf '    %-28s %s\n' "cores"                 "${V_CORES}"
printf '    %-28s %s\n' "Python found"          "${V_PY:-none}"
printf '    %-28s %s\n' "Python path"           "${V_PYPATH:-n/a}"
printf '    %-28s %s\n' "Python verdict"        "${V_PYVERDICT:-NONE FOUND - blocker}"
printf '    %-28s %s\n' "uv"                    "${V_UV}"
printf '    %-28s %s\n' "git usable in cwd"    "${V_GITRUN:-not tested}"
printf '    %-28s %s\n' "GitLab reachable"      "${V_GITLAB}"
printf '    %-28s %s\n' "Artifactory reachable" "${V_ARTIFACTORY}"
printf '    %-28s %s\n' "Public PyPI"           "${V_PYPI}  (should be unreachable)"
printf '    %-28s %s\n' "Free space on HOME"    "${V_DISK:-unknown}"
echo
echo "  Still to answer by hand after install_uv.sh and install_packages.sh:"
echo "    uv pip download pandas        y / n"
echo "    each repo's build backend     y / n   (hatchling / setuptools / uv_build ...)"
echo "    install completed             y / n   (if not, which package: ..........)"
echo "    imports + console scripts     y / n   (install_packages.sh's checkpoint)"

hr "Done"
echo "  Next: push the mirror (./mirror_to_gitlab.sh)."
echo "  No compute-node probe applies here; probe_cluster.sh is for a real cluster."
