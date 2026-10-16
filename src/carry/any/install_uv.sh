#!/bin/bash
# INSIDE (both boxes). Unpack the uv binary and point it at Artifactory.
#
# Runs on BOTH DSH boxes and picks the right asset and config path for each:
#   Windows Desktop VM   uv-x86_64-pc-windows-msvc.zip     -> %APPDATA%\uv\uv.toml
#   Linux cluster node   uv-x86_64-unknown-linux-gnu.tar.gz -> ~/.config/uv/uv.toml
#
# Run from the directory the airlock payload landed in:
#
#   ./install_uv.sh
#
# Host and PyPI remote default to UCL's (artifactory.idhs.ucl.ac.uk, remote "pypi");
# --artifactory / --pypi-remote override them.
#
# Artifactory needs credentials - anonymous fetches get a 401. Three routes, best
# first. All three want the <user> and <token> from the "Set Me Up" page; the
# token is derived from your DSH password and dies with every 90-day rotation.
#
#   1. ~/.netrc - persistent, no credential in any config this script rewrites:
#        printf 'machine artifactory.idhs.ucl.ac.uk login <user> password <token>\n' > ~/.netrc
#        chmod 600 ~/.netrc
#
#   2. Environment, per index name (this script always writes name = "artifactory"):
#        export UV_INDEX_ARTIFACTORY_USERNAME='<user>' UV_INDEX_ARTIFACTORY_PASSWORD='<token>'
#      Not sourced by non-interactive shells, so a batch job loses it unless qsub -V.
#
#   3. The whole "Set Me Up" URL, as one string rather than assembled from parts:
#        ./install_uv.sh --index-url 'https://<user>:<token>@artifactory.idhs.ucl.ac.uk/artifactory/api/pypi/pypi/simple'
#      Last resort: it puts a live token in uv.toml AND in the uv.toml.bak this
#      script makes on the next run. Percent-encode @ / : # % in the token, or uv
#      parses the URL at the wrong character and sends a mangled username.
#
# Everything it prints also lands in Logs/install_uv.log beside this script, so the
# result is reviewable on the VM without relaying it anywhere.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    echo "(sourcing it makes its 'exit' close your terminal)" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../any/lib/dsh_platform.sh
. "${PAYLOAD_DIR}/lib/dsh_platform.sh"

# Log to a file AND to the terminal, reliably. `exec > >(tee f)` loses the tail
# when stdout is a pipe, because the script can exit before tee flushes - which
# is precisely the output you came for. Re-running self with a plain pipe does
# not have that failure mode, and PIPESTATUS keeps the real exit code.
# shellcheck source=../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

# UCL-documented host from the DSH User Guide & FAQs, and the PyPI remote's name on it,
# which is "pypi" for every DSH user. --artifactory / --pypi-remote still override, and
# --index-url overrides both.
ARTIFACTORY_HOST="artifactory.idhs.ucl.ac.uk"
PYPI_REMOTE="pypi"
INDEX_URL=""
# What the checkpoint fetches to prove the index works. pandas proves auth and URL;
# add each repo's BUILD BACKEND with --probe-package (see the checkpoint below).
PROBES=(pandas)
UV_ARCHIVE=""
BINDIR="${HOME}/.local/bin"
NATIVE_TLS=""
WANT_NETRC="yes"

usage() {
    sed -n '2,20p' "$0"
    echo
    echo "Usage: $0 [--artifactory HOST] [--pypi-remote NAME] [--index-url URL]"
    echo "          [--archive FILE] [--bindir DIR] [--native-tls yes|no] [--no-netrc]"
    echo "          [--probe-package SPEC]...   e.g. hatchling, setuptools, 'uv_build<0.12'"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifactory) ARTIFACTORY_HOST="$2"; shift 2 ;;
        --pypi-remote) PYPI_REMOTE="$2";      shift 2 ;;
        --index-url)   INDEX_URL="$2";        shift 2 ;;
        --archive)     UV_ARCHIVE="$2";       shift 2 ;;
        --bindir)      BINDIR="$2";           shift 2 ;;
        --native-tls)  NATIVE_TLS="$2";       shift 2 ;;
        --no-netrc)    WANT_NETRC="no";       shift 1 ;;
        --probe-package) PROBES+=("$2");      shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [ -z "$INDEX_URL" ]; then
    [ -n "$ARTIFACTORY_HOST" ] || { echo "Error: --artifactory (or --index-url) is required" >&2; usage; }
    [ -n "$PYPI_REMOTE" ]      || { echo "Error: --pypi-remote (or --index-url) is required" >&2; usage; }
    INDEX_URL="https://${ARTIFACTORY_HOST}/artifactory/api/pypi/${PYPI_REMOTE}/simple"
    echo "Index: ${INDEX_URL}   (host ${ARTIFACTORY_HOST}, remote ${PYPI_REMOTE})"
fi

# The DSH terminates TLS with its own CA on BOTH boxes. uv bundles webpki and
# never reads the system certificate store unless told to, so it rejects the
# intercepted certificate where curl - which does read the system store - gets a
# clean 200. On Windows that surfaces as a self-signed-certificate error, the uv
# equivalent of the FAQ's "SSL: CERTIFICATE_VERIFY_FAILED"; on Linux it surfaces
# as "invalid peer certificate: UnknownIssuer", which reads like a broken index
# rather than a trust-store problem.
#
# Defaulting it to yes on Windows only is a mistake that has been made: the
# cluster then fails on exactly that. The interception is a property of the DSH,
# not of the operating system, so it defaults to yes on both.
[ -n "$NATIVE_TLS" ] || NATIVE_TLS="yes"

echo "=== Platform ==="
printf '  %-22s %s\n' "uname"          "$(uname -s -m 2>/dev/null)"
printf '  %-22s %s\n' "detected as"    "$DSH_OS"
printf '  %-22s %s\n' "expects asset"  "$DSH_UV_ASSET"
printf '  %-22s %s\n' "uv config path" "$DSH_UV_CONFIG"
printf '  %-22s %s\n' "native-tls"     "$NATIVE_TLS"
echo

if [ -z "$UV_ARCHIVE" ]; then
    UV_ARCHIVE="${PAYLOAD_DIR}/${DSH_UV_ASSET}"
fi
if [ ! -f "$UV_ARCHIVE" ]; then
    echo "Error: ${UV_ARCHIVE} not found." >&2
    echo "This box is ${DSH_OS}, so it needs ${DSH_UV_ASSET}." >&2
    echo "Present in the payload:" >&2
    ls -1 "${PAYLOAD_DIR}"/uv-* 2>/dev/null | sed 's/^/  /' >&2 || echo "  (no uv archive at all)" >&2
    exit 1
fi

echo "=== Unpacking uv ==="
tmp="$(mktemp -d)"
dsh_unpack "$UV_ARCHIVE" "$tmp" || exit 1
mkdir -p "$BINDIR"
find "$tmp" -maxdepth 2 -type f \( -name 'uv' -o -name 'uvx' -o -name 'uv.exe' -o -name 'uvx.exe' -o -name 'uvw.exe' \) \
    -exec cp {} "$BINDIR/" \;
rm -rf "$tmp"
chmod +x "$BINDIR"/uv* 2>/dev/null

export PATH="${BINDIR}:${PATH}"
UV="${BINDIR}/${DSH_UV_EXE}"
[ -x "$UV" ] || { echo "Error: ${UV} did not land - unpack failed" >&2; ls -la "$BINDIR" >&2; exit 1; }

for rc in "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
    [ -f "$rc" ] || continue
    grep -qF '.local/bin:$PATH' "$rc" 2>/dev/null && break
done
if ! grep -qsF '.local/bin:$PATH' "${HOME}/.bashrc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
    echo "  added ${BINDIR} to PATH in ~/.bashrc"
fi
echo "  installed: $UV"
echo "  version:   $("$UV" --version 2>&1)"
echo

echo "=== Writing ${DSH_UV_CONFIG} ==="
mkdir -p "$(dirname "$DSH_UV_CONFIG")"
if [ -f "$DSH_UV_CONFIG" ]; then
    cp "$DSH_UV_CONFIG" "${DSH_UV_CONFIG}.bak"
    echo "  existing config backed up to ${DSH_UV_CONFIG}.bak"
fi

# python-downloads = "never" matters. With no internet, uv's default of fetching
# a managed CPython when it cannot find a suitable interpreter fails with a
# confusing network error rather than a clear "no interpreter" one. Turning it
# off forces uv to use the system Python the probe found.
{
    echo 'python-downloads = "never"'
    [ "$NATIVE_TLS" = "yes" ] && echo 'native-tls = true'
    echo
    echo '[[index]]'
    echo 'name = "artifactory"'
    echo "url = \"${INDEX_URL}\""
    echo 'default = true'
} > "$DSH_UV_CONFIG"
# Do not echo the file: with --index-url it contains a credential.
sed 's#//[^@/]*@#//<credentials-redacted>@#' "$DSH_UV_CONFIG" | sed 's/^/  /'
echo

# Artifactory refuses anonymous fetches (401). The credential has to outlive this
# shell, or the next new shell - and install_packages.sh, which re-execs itself -
# fails on the first wheel with "could not be queried due to a lack of valid
# authentication credentials". On the cluster that is the commonest second-visit
# cause.
#
# ~/.netrc rather than the index URL: uv reads it, it survives this script
# rewriting uv.toml, and it keeps the token out of the config and out of the
# uv.toml.bak the next run makes. chmod 600 because it is a live credential.
#
# Read from the terminal, never from an argument: an argument is visible in ps
# and lands in shell history, and this script's own log is tee'd to disk.
echo "=== Artifactory credential (~/.netrc) ==="
NETRC="${HOME}/.netrc"
CRED_HOST="$(echo "$INDEX_URL" | sed -e 's#^https\?://##' -e 's#^[^@/]*@##' -e 's#/.*##')"
if [ "$WANT_NETRC" != "yes" ]; then
    echo "  --no-netrc given - skipped. Supply credentials some other way."
elif grep -qs "machine[[:space:]]\+${CRED_HOST}" "$NETRC"; then
    echo "  ${NETRC} already has an entry for ${CRED_HOST} - left alone"
    chmod 600 "$NETRC" 2>/dev/null
elif echo "$INDEX_URL" | grep -q '@'; then
    echo "  --index-url carries its own credential - no netrc entry written"
    echo "  note: that token is now in ${DSH_UV_CONFIG}, and in its .bak on the next run"
elif [ -n "${UV_INDEX_ARTIFACTORY_USERNAME:-}" ] && [ -n "${UV_INDEX_ARTIFACTORY_PASSWORD:-}" ]; then
    printf 'machine %s login %s password %s\n'         "$CRED_HOST" "$UV_INDEX_ARTIFACTORY_USERNAME" "$UV_INDEX_ARTIFACTORY_PASSWORD" > "$NETRC"
    chmod 600 "$NETRC"
    echo "  wrote ${NETRC} from UV_INDEX_ARTIFACTORY_* (mode 600)"
    echo "  the exports are now redundant - a new shell will work without them"
elif [ -t 0 ]; then
    echo "  no credential found. Both values come off the Artifactory 'Set Me Up' page."
    echo "  The token is derived from your DSH password and dies with every 90-day change."
    echo "  Press Enter at the username to skip."
    printf '    Artifactory username: '
    read -r NETRC_USER
    if [ -n "$NETRC_USER" ]; then
        printf '    Artifactory token (not shown): '
        read -rs NETRC_TOKEN
        echo
        printf 'machine %s login %s password %s\n' "$CRED_HOST" "$NETRC_USER" "$NETRC_TOKEN" > "$NETRC"
        chmod 600 "$NETRC"
        NETRC_TOKEN=""
        echo "  wrote ${NETRC} (mode 600)"
    else
        echo "  skipped - the checkpoint below will 401 if the index needs auth"
    fi
else
    echo "  no credential found and no terminal to ask on."
    echo "  Write it by hand, then re-run:"
    echo "    printf 'machine ${CRED_HOST} login <user> password <token>\n' > ${NETRC}"
    echo "    chmod 600 ${NETRC}"
fi
echo

echo "=== Checkpoint: can uv reach the index? ==="
probe_dir="$(mktemp -d)"
rc=0
# NOT `uv pip download` - that subcommand does not exist in uv 0.11.x, and its
# "unrecognized subcommand" error inside the airlock reads exactly like an
# Artifactory failure. `pip install --no-deps --target` into a throwaway
# directory really does fetch a wheel from the index, which is the thing being
# proved.
#
# Probe the BUILD BACKENDS too (--probe-package). Each repo's [build-system]
# requires (hatchling, setuptools, uv_build, ...) is fetched at BUILD time,
# including for editable installs. If Artifactory has not mirrored one, the
# install fails on a FIRST-party package name and looks exactly like a resolution
# bug when it is not.
for spec in "${PROBES[@]}"; do
    printf '  %-32s ' "$spec"
    if "$UV" pip install --no-deps --target "$probe_dir" "$spec" > "${probe_dir}/last.log" 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        sed 's/^/      /' "${probe_dir}/last.log" | tail -15
        rc=1
    fi
done
rm -rf "$probe_dir"
echo

if [ "$rc" -eq 0 ]; then
    echo "RESULT: PASS - the index works."
    if [ "$DSH_OS" = "windows" ]; then
        echo "Next: ./check_venv_location.sh --python <full-path-to-python>"
    else
        echo "Next: ./install_packages.sh --python <full-path-to-python>"
    fi
else
    echo "RESULT: FAIL - fix this before install_packages.sh." >&2
    echo "Everything downstream fails the same way for the same reason." >&2
    echo >&2
    echo "  self-signed certificate / CERTIFICATE_VERIFY_FAILED   (Windows)" >&2
    echo "  invalid peer certificate: UnknownIssuer                 (Linux)" >&2
    echo "      -> the DSH's TLS interception, and uv is not reading the system" >&2
    echo "         CA store. Re-run with --native-tls yes. Defaults to yes now," >&2
    echo "         so seeing this means it was explicitly set to no." >&2
    echo "  401 / 403" >&2
    echo "      -> the index needs auth. Put the Set Me Up credential in ~/.netrc" >&2
    echo "         (see the header) and re-run. Regenerate the snippet first if" >&2
    echo "         your DSH password has rotated in the last 90 days." >&2
    echo "      -> to tell a dead credential from a trust-store failure, curl the" >&2
    echo "         index yourself - curl reads the system CA store and sends auth" >&2
    echo "         preemptively, so a curl 200 next to a uv failure means the" >&2
    echo "         credential is fine and the problem is uv's:" >&2
    echo "           curl -s -o /dev/null -w '%{http_code}\n' -u '<user>:<token>' \\" >&2
    echo "             'https://HOST/artifactory/api/pypi/REMOTE/simple/pandas/'" >&2
    echo "  timeout / could not resolve" >&2
    echo "      -> wrong host, or this box has no route to it." >&2
    exit 1
fi
