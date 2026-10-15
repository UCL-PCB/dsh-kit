#!/bin/bash -l
# A CLUSTER with a batch scheduler. Read-only: submits nothing but itself, changes nothing.
#
# ONE file, two modes. It notices whether it is running under a scheduler and probes accordingly:
#
#   ./probe_cluster.sh --gitlab HOST --artifactory HOST
#       -> login-node mode: what scheduler, what Python, what it can reach, and it prints the
#          exact submit line to use next. Also written to Logs/probe_cluster.log beside it,
#          so there is nothing to pipe through tee.
#
#   qsub -V -cwd -t 1-2 -o probe_out.txt -e probe_err.txt probe_cluster.sh      (Grid Engine)
#   sbatch --array=1-2 -o probe_out_%A_%a.txt probe_cluster.sh                  (Slurm)
#       -> compute-node mode: TMPDIR, shared filesystem, array variable, network from the node.
#
# On Grid Engine, -V and -cwd are both needed. -V ships your environment (without it the two
# host variables below arrive unset and the network check silently skips); -cwd runs the job in
# the directory you submitted from (without it Grid Engine uses $HOME and writes the output
# there, so the job looks like it vanished). Slurm does both by default.
#
# Set these before submitting if you want the compute node to test reachability:
#   export DSH_GITLAB_HOST=... DSH_ARTIFACTORY_HOST=...

#$ -S /bin/bash
#$ -l h_rt=0:10:0
#$ -N cluster_probe

#SBATCH --time=00:10:00
#SBATCH --mem=1G
#SBATCH --job-name=cluster_probe

# Deliberately no memory or tmpfs request. Resource names are site-defined, not part of Grid
# Engine: some UCL clusters have "mem" and "tmpfs", other sites use "h_vmem", "m_mem_free", "mem_free"
# or nothing at all, and asking for one that does not exist fails the submission outright with
# 'unknown resource "mem"'. A 10-minute probe needs no reservation, so it asks for none.
#
# To see what this site actually defines:   qconf -sc | grep -iE 'mem|tmp|scratch'
# Then add the right one on the command line for real jobs, e.g.  -l h_vmem=4G

have() { command -v "$1" > /dev/null 2>&1; }
report() { printf '  %-28s %s\n' "$1" "$2"; }
# Refuse to be sourced. This script uses "exit", and in a sourced script exit terminates the
# calling shell - which looks exactly like the terminal closing on you. Run it, do not source it.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    echo "(sourcing it makes its 'exit' close your terminal)" >&2
    return 1 2>/dev/null || exit 1
fi

# Log to Logs/ beside this script - but only in login-node mode. This script is also
# SUBMITTED (see the qsub/sbatch lines above), and a scheduler runs a spooled COPY of
# it from a directory holding nothing else, so there is no dsh_log.sh next to it there.
# Sourcing unconditionally would kill the compute-node probe outright, and the job's
# own -o/-e files are the record in that mode anyway.
DSH_LOG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib/ is where the payload puts it; the sibling is where a hand-copied or
# singly-deployed copy of this script would find it.
DSH_LOG_LIB="${DSH_LOG_HERE}/lib/dsh_log.sh"
[ -f "$DSH_LOG_LIB" ] || DSH_LOG_LIB="${DSH_LOG_HERE}/dsh_log.sh"
if [ -f "$DSH_LOG_LIB" ] && [ -z "${JOB_ID:-}${SLURM_JOB_ID:-}" ]; then
    # shellcheck source=../any/lib/dsh_log.sh
    . "$DSH_LOG_LIB"
    dsh_start_log "$@"
fi

hr() { printf '\n=== %s %s\n' "$1" "$(printf '%.0s-' $(seq 1 $((60 - ${#1}))))"; }

# ---------------------------------------------------------------------------
# Compute-node mode: we are running inside a scheduled job.
# ---------------------------------------------------------------------------
if [ -n "${JOB_ID:-}${SLURM_JOB_ID:-}" ]; then
    echo "=== Compute node probe ==="
    report "hostname" "$(hostname)"
    report "date" "$(date)"

    echo "--- Array indexing ---"
    report "SGE_TASK_ID" "${SGE_TASK_ID:-unset}"
    report "SLURM_ARRAY_TASK_ID" "${SLURM_ARRAY_TASK_ID:-unset}"
    report "JOB_ID / SLURM_JOB_ID" "${JOB_ID:-unset} / ${SLURM_JOB_ID:-unset}"
    report "cores visible" "$(nproc 2>/dev/null)"
    report "NSLOTS / CPUS_PER_TASK" "${NSLOTS:-unset} / ${SLURM_CPUS_PER_TASK:-unset}"
    report "working directory" "$(pwd)   <- if this is \$HOME on Grid Engine, you forgot -cwd"

    echo "--- TMPDIR ---"
    # A job that copies its inputs to node-local scratch and works there needs this.
    report "TMPDIR" "${TMPDIR:-UNSET - a job using node-local scratch cannot}"
    if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
        df -h "$TMPDIR" 2>/dev/null | sed 's/^/    /'
        if touch "${TMPDIR}/.probe" 2>/dev/null; then
            report "writable" "yes"
            rm -f "${TMPDIR}/.probe"
        else
            report "writable" "NO - job scripts will fail"
        fi
    fi

    echo "--- Shared filesystem ---"
    # The workspace and venv live on shared storage; the job must be able to see them.
    report "HOME" "$HOME"
    report "HOME visible" "$([ -d "$HOME" ] && echo yes || echo NO)"
    for d in "$HOME/Scratch" "/scratch/$USER" /data; do
        [ -d "$d" ] && report "visible" "$d"
    done
    if [ -n "${DSH_WORKSPACE:-}" ]; then
        report "workspace" "${DSH_WORKSPACE} -> $([ -d "$DSH_WORKSPACE" ] && echo visible || echo NOT VISIBLE)"
        report "venv python" "$([ -x "${DSH_WORKSPACE}/.venv/bin/python" ] && "${DSH_WORKSPACE}/.venv/bin/python" --version 2>&1 || echo 'no venv yet')"
    else
        report "DSH_WORKSPACE" "unset - export it before submitting to check the venv is visible"
    fi

    echo "--- Toolchain here ---"
    for c in python3 uv git; do
        if have "$c"; then report "$c" "$(command -v "$c")"; else report "$c" "NOT on PATH here"; fi
    done

    echo "--- Network from the compute node ---"
    # Often closed even when the login node is open. That is fine: it means every install happens
    # on the login node and jobs only ever use the venv, never touch an index.
    if have curl; then
        for host in "${DSH_GITLAB_HOST:-}" "${DSH_ARTIFACTORY_HOST:-}"; do
            [ -z "$host" ] && continue
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${host}" 2>/dev/null)
            report "$host" "HTTP ${code:-unreachable}"
        done
        [ -z "${DSH_GITLAB_HOST:-}${DSH_ARTIFACTORY_HOST:-}" ] && \
            report "(skipped)" "export DSH_GITLAB_HOST / DSH_ARTIFACTORY_HOST and resubmit with -V"
    else
        report "curl" "not available"
    fi

    echo "=== End of compute node probe ==="
    exit 0
fi

# ---------------------------------------------------------------------------
# Login-node mode: run interactively.
# ---------------------------------------------------------------------------
GITLAB_HOST=""
ARTIFACTORY_HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitlab)      GITLAB_HOST="$2"; shift 2 ;;
        --artifactory) ARTIFACTORY_HOST="$2"; shift 2 ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *)             echo "Unknown argument: $1"; exit 1 ;;
    esac
done

SCHEDULER="none"

hr "Machine"
report "hostname" "$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
report "os" "$(uname -s -r 2>/dev/null)"
report "arch" "$(uname -m 2>/dev/null)   <- decides which uv binary you need"
[ -f /etc/os-release ] && report "distro" "$(. /etc/os-release && echo "$PRETTY_NAME")"

hr "Scheduler"
# The big one. A job script written for Grid Engine (qsub -t, SGE_TASK_ID, "#$" headers)
# needs rewriting, not repointing, for Slurm - and vice versa.
for cmd in qsub qstat sbatch squeue bsub condor_submit; do
    have "$cmd" && report "$cmd" "$(command -v "$cmd")"
done
if have sbatch || have squeue; then
    SCHEDULER="slurm"
elif have qsub || have qstat; then
    SCHEDULER="gridengine"
fi
if [ "$SCHEDULER" = "none" ]; then
    report "(none on PATH)" "looking for an off-PATH install before concluding..."
    ls -d /opt/sge* /opt/slurm* /etc/slurm* /etc/sge* /usr/share/gridengine 2>/dev/null | sed 's/^/    found: /'
    report "verdict" "no scheduler - if this is the analysis VM, use probe_secure_env.sh instead"
else
    report "VERDICT" "${SCHEDULER}"
fi
have qstat && report "grid engine" "$(qstat -help 2>&1 | head -1)"
have sinfo && report "slurm partitions" "$(sinfo -h -o '%P' 2>/dev/null | tr '\n' ' ')"

hr "Python"
# Judged against KIT_PYTHON_SPEC from the payload's dsh-kit.conf, when this copy is
# standing in the payload. A spooled compute-node copy has no lib/ and no conf
# beside it, so there it only lists what it finds - the login-node run already
# gave the verdict, and the interpreters are the same image.
PY_JUDGE=0
if [ -f "${DSH_LOG_HERE}/lib/dsh_platform.sh" ]; then
    # shellcheck source=../any/lib/dsh_platform.sh
    . "${DSH_LOG_HERE}/lib/dsh_platform.sh"
    if dsh_kit_settings "$DSH_LOG_HERE" 2>/dev/null; then
        PY_JUDGE=1
        report "required" "${KIT_PYTHON_SPEC:-any 3.x}   (dsh-kit.conf)"
    fi
fi
for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3 python; do
    if have "$py"; then
        if [ "$PY_JUDGE" -eq 0 ]; then
            report "$py" "$("$py" --version 2>&1)   $(command -v "$py")"
        elif dsh_py_satisfies "$py"; then
            report "$py" "$("$py" --version 2>&1)   [IN RANGE]   $(command -v "$py")"
        else
            report "$py" "$("$py" --version 2>&1)   [OUT OF RANGE]   $(command -v "$py")"
        fi
    fi
done
if type module > /dev/null 2>&1; then
    report "module system" "present"
    module avail python 2>&1 | sed 's/^/    /' | head -30
else
    report "module system" "absent"
fi

hr "uv and git"
if have uv; then
    report "uv" "$(command -v uv) - $(uv --version 2>&1)"
else
    report "uv" "NOT FOUND - the standalone binary must cross the airlock"
fi
have git && report "git" "$(git --version)"

hr "Network reachability"
probe_host() {
    local label="$1" host="$2" code
    [ -z "$host" ] && { report "$label" "(not given - pass --${label} HOST)"; return; }
    if have curl; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${host}" 2>/dev/null)
        report "$label" "https://${host} -> HTTP ${code:-no response}"
    elif have getent; then
        report "$label" "$(getent hosts "$host" || echo 'does not resolve')"
    else
        report "$label" "no curl or getent to test with"
    fi
}
probe_host gitlab "$GITLAB_HOST"
probe_host artifactory "$ARTIFACTORY_HOST"
if have curl; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://pypi.org/simple/ 2>/dev/null)
    report "public pypi" "HTTP ${code:-unreachable}  <- expect unreachable; if it answers, say so"
fi
[ -n "${HTTPS_PROXY:-}${https_proxy:-}" ] && report "proxy env" "${HTTPS_PROXY:-$https_proxy}"

hr "Filesystem"
report "HOME" "$HOME"
report "TMPDIR (login node)" "${TMPDIR:-unset}"
for d in "$HOME/Scratch" /scratch "/scratch/$USER" /data; do
    [ -d "$d" ] && report "found" "$d"
done
have df && df -h "$HOME" 2>/dev/null | sed 's/^/    /'

hr "Next: probe a compute node"
# The login node is not where jobs run, so half the answers are only available from a job.
echo "  Set the hosts first so the job can test reachability from the node:"
echo
echo "    export DSH_GITLAB_HOST=${GITLAB_HOST:-gitlab.idhs.ucl.ac.uk} DSH_ARTIFACTORY_HOST=${ARTIFACTORY_HOST:-artifactory.idhs.ucl.ac.uk}"
echo "    export DSH_WORKSPACE=\$HOME/Scratch/<project>     # optional, checks the venv is visible"
echo
case "$SCHEDULER" in
    gridengine)
        echo "    qsub -V -cwd -t 1-2 -o probe_out.txt -e probe_err.txt $(basename "$0")"
        echo
        echo "  -V ships your environment, -cwd runs and writes here. Both are needed."
        echo "  If qsub rejects an unknown resource, add: -l tmpfs=1G" ;;
    slurm)
        echo "    sbatch --array=1-2 -o probe_out_%A_%a.txt $(basename "$0")"
        echo
        echo "  sbatch exports the environment and runs in this directory by default."
        echo "  NOTE: job scripts written for Grid Engine (#\$ lines, qsub) need rewriting for Slurm." ;;
    *)
        echo "    (no scheduler found - nothing to submit to)" ;;
esac
echo
echo "  Then: cat probe_out.txt"
