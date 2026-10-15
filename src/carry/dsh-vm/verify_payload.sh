#!/bin/bash
# INSIDE. Prove the payload survived the airlock intact, and is self-consistent.
#
# Run it from wherever DSH_import landed. Nothing here is destructive; nothing
# here needs the network.
#
#   ./verify_payload.sh
#
# What a payload is supposed to contain is NOT compiled into this script any more.
# build_payload.sh writes PAYLOAD_CONTENTS.txt into the payload, naming the target it
# was built for and every file in it; this reads that. The list used to live here, in
# an EXPECTED array that build_payload.sh read back out with awk - which meant one
# list for every target, so a payload narrowed to one box was checked against
# the other box's scripts and could not pass.
#
# PAYLOAD_CONTENTS.txt is itself in SHA256SUMS.txt, so a tampered or truncated one is
# caught in section 2 rather than quietly shortening the list of things to look for.
#
# It names each file by the PATH it landed at - lib/dsh_log.sh, not dsh_log.sh - so
# everything below walks the payload rather than listing its top level. A file that
# arrived in the wrong directory is a missing file here, which is what it is: the
# script that sources it will not find it either.
#
# Writes Logs/verify_payload.log beside itself, so the result is reviewable on the
# VM without relaying it anywhere.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../any/lib/dsh_log.sh
. "${PAYLOAD_DIR}/lib/dsh_log.sh"
dsh_start_log "$@"

cd "$PAYLOAD_DIR" || exit 1
FAIL=0

# The floor: without these two there is nothing to verify against, and a payload
# that lost them is broken in a way no later section would name clearly.
for f in PAYLOAD_CONTENTS.txt SHA256SUMS.txt; do
    if [ ! -f "$f" ]; then
        echo "FAIL: ${f} is not here. This directory is not an unpacked payload, or the"
        echo "      transfer was incomplete. Nothing else can be checked without it."
        exit 1
    fi
done

TARGET="$(awk '$1 == "target" {print $2; exit}' PAYLOAD_CONTENTS.txt)"
BUILT="$(awk '$1 == "built" {print $2; exit}' PAYLOAD_CONTENTS.txt)"
mapfile -t EXPECTED < <(awk '$1 == "file" {print $3}' PAYLOAD_CONTENTS.txt)
if [ "${#EXPECTED[@]}" -eq 0 ]; then
    echo "FAIL: PAYLOAD_CONTENTS.txt names no files. It is corrupt."
    exit 1
fi

# The group each file was carried as, for the report below.
dsh_group_of() {
    awk -v want="$1" '$1 == "file" && $3 == want {print $2; exit}' PAYLOAD_CONTENTS.txt
}


# What the payload is FOR - its repos - comes from dsh-kit.conf, which travels in it.
# Loaded for the consistency check in section 1; a payload without one is not a
# dsh-kit payload, and that is a FAIL rather than a reason to stop here, so the
# checksum and bundle sections still run and say what else is wrong.
# shellcheck source=../any/lib/dsh_conf.sh
. "${PAYLOAD_DIR}/lib/dsh_conf.sh"
CONF_OK=0
if [ -f dsh-kit.conf ] && dsh_load_conf "${PAYLOAD_DIR}/dsh-kit.conf"; then
    CONF_OK=1
fi

echo "=== Where am I ==="
printf '  %-18s %s\n' "payload dir" "$PAYLOAD_DIR"
printf '  %-18s %s\n' "uname" "$(uname -s -m 2>/dev/null)"
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)                    PLATFORM="linux"   ;;
esac
printf '  %-18s %s\n' "platform" "$PLATFORM"
printf '  %-18s %s\n' "payload target" "${TARGET:-unstated}"
printf '  %-18s %s\n' "built" "${BUILT:-unstated}"
echo

echo "=== 1. Every expected file present ==="
echo "  (as PAYLOAD_CONTENTS.txt lists them for target ${TARGET:-unstated})"
missing=0
for f in "${EXPECTED[@]}"; do
    if [ ! -f "$f" ]; then
        echo "  MISSING  $f   [group: $(dsh_group_of "$f")]"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -eq 0 ]; then
    echo "  all ${#EXPECTED[@]} present"
else
    echo "  ${missing} missing - the transfer was incomplete"
    FAIL=1
fi

# Bundles, manifest and conf must agree. Present on disk is not the same as
# declared: export_bundles.sh writes MANIFEST.txt from the repos it was ASKED to
# bundle, so a narrower export leaves the previous export's bundles sitting here
# while the manifest no longer mentions them. Everything downstream is driven off
# the manifest - mirror_to_gitlab.sh pushes what it lists - so such a repo never
# reaches GitLab, and install_packages.sh clones whatever GitLab held from some
# earlier trip. The file being here makes it look deliberate. So it is a FAIL.
echo
echo "  --- bundles vs MANIFEST.txt vs dsh-kit.conf ---"
if [ "$CONF_OK" -eq 0 ]; then
    echo "  dsh-kit.conf: MISSING or invalid - every step after this one reads it"
    FAIL=1
else
    printf '  %-34s %s\n' "project" "$KIT_PROJECT"
    printf '  %-34s %s\n' "repos (dsh-kit.conf)" "$KIT_REPOS"
    printf '  %-34s %s\n' "install mode" "$KIT_INSTALL_MODE"
fi
FAIL_BEFORE="$FAIL"
FAIL=0
if [ ! -f MANIFEST.txt ]; then
    echo "  MANIFEST.txt: MISSING - nothing says what the bundles are"
    FAIL=1
else
    shopt -s nullglob
    for b in *.bundle; do
        repo="${b%.bundle}"
        if ! awk -v p="$repo" '$1==p {f=1} END {exit !f}' MANIFEST.txt; then
            echo "  ${b}: present but NOT IN MANIFEST.txt - left over from an earlier"
            echo "    export. It will not be mirrored. Re-export with it, or delete it."
            FAIL=1
        fi
    done
    shopt -u nullglob
    while read -r repo _; do
        case "$repo" in ''|'#'*) continue ;; esac
        if [ ! -f "${repo}.bundle" ]; then
            echo "  ${repo}: in MANIFEST.txt but ${repo}.bundle is MISSING"
            FAIL=1
        fi
        if [ "$CONF_OK" -eq 1 ]; then
            case " $KIT_REPOS " in *" $repo "*) ;; *)
                echo "  ${repo}: bundled, but not in KIT_REPOS - it will be mirrored and"
                echo "    never installed. Add it to dsh-kit.conf outside, or stop exporting it."
                FAIL=1 ;;
            esac
        fi
    done < MANIFEST.txt
    if [ "$CONF_OK" -eq 1 ]; then
        for repo in $KIT_REPOS; do
            awk -v p="$repo" '$1==p {f=1} END {exit !f}' MANIFEST.txt \
                || echo "  ${repo}: in KIT_REPOS, not in this payload - its checkout is left as it is"
        done
    fi
    [ "$FAIL" -eq 0 ] && echo "  consistent"
fi
# FAIL was zeroed for this section only, so "consistent" speaks for it alone.
[ "$FAIL_BEFORE" -eq 1 ] && FAIL=1

# Logs/ is this box's own record and belongs here; PAYLOAD_CONTENTS.txt and
# SHA256SUMS.txt describe the payload rather than being listed by it. The whole tree
# is walked, Logs/ excepted, because lib/ and diagnose/ are as much the payload as
# the top level is.
extra="$(find . -name Logs -prune -o -type f -print \
    | sed 's|^\./||' | sort \
    | grep -vxF -f <( { printf '%s\n' "${EXPECTED[@]}" MANIFEST.txt dsh-kit.conf \
        pyproject.dsh.toml pyproject.dsh-cluster.toml PAYLOAD_CONTENTS.txt SHA256SUMS.txt; ls -1 -- *.bundle 2>/dev/null; } ) \
    || true)"
if [ -n "$extra" ]; then
    echo "  also present, and NOT part of a ${TARGET:-} payload:"
    echo "$extra" | sed 's/^/    /'
    echo "    A script a later commit renamed or retired goes on answering to its old"
    echo "    name here. Rebuild with ./build_payload.sh --prune to clear them."
fi
echo

echo "=== 2. Checksums ==="
if sha256sum -c SHA256SUMS.txt > sha_result.txt 2>&1; then
    echo "  all OK"
else
    grep -v ': OK$' sha_result.txt | sed 's/^/  /'
    FAIL=1
    # A text-mode transfer rewrites LF to CRLF. That corrupts the binaries
    # outright, but for the shell scripts it is recoverable and worth naming,
    # because the FAQ warns about exactly this for jobscripts.
    echo
    echo "  --- is this a CRLF (text-mode) transfer? ---"
    crlf=0
    while IFS= read -r f; do
        if grep -qU $'\r' "$f" 2>/dev/null; then
            echo "    ${f#./} contains CR characters"
            crlf=$((crlf + 1))
        fi
    done < <(find . -name Logs -prune -o -type f -name '*.sh' -print | sort)
    if [ "$crlf" -gt 0 ]; then
        echo "    -> the airlock transferred in TEXT mode. Re-transfer in BINARY mode."
        echo "       The .bundle and uv archives cannot be repaired by stripping CRs;"
        echo "       do not continue with them."
    else
        echo "    no CRs found - the corruption is something else."
    fi
fi
rm -f sha_result.txt
echo

echo "=== 3. Bundles ==="
# git bundle verify has to run inside a git repository - it searches upward for
# a .git, and the payload directory is not one. Outside a repo it fails with
# "not a git repository", or "permission denied" if git walks up into a
# directory it cannot read, which is common on a share. Neither says anything
# about the bundle. A throwaway repo sidesteps it wherever the payload landed.
bv="$(mktemp -d)"
git -C "$bv" init -q
shopt -s nullglob
for b in *.bundle; do
    printf '  %-34s ' "$b"
    if git -C "$bv" bundle verify "${PAYLOAD_DIR}/${b}" > "${bv}/out.txt" 2>&1; then
        echo "valid"
    else
        echo "INVALID"
        sed 's/^/      /' "${bv}/out.txt"
        FAIL=1
    fi
done
shopt -u nullglob
rm -rf "$bv"
[ -f MANIFEST.txt ] || echo "  none in this payload (${TARGET:-} installs from a repo host)"
echo

echo "=== 4. Manifest ==="
if [ -f MANIFEST.txt ]; then
    sed 's/^/  /' MANIFEST.txt
    echo
    echo "  Every SHA above is what mirror_to_gitlab.sh pushes and install_packages.sh"
    echo "  must clone back."
else
    echo "  no MANIFEST.txt - this payload carries no bundles."
fi
echo

echo "=== 5. Making the scripts executable ==="
# Including the ones in lib/ and diagnose/. lib/ is only ever sourced, which needs
# no execute bit, but a library that is never executable is one a reader cannot run
# to see what it complains about, and the cost of setting it is nothing.
while IFS= read -r f; do
    chmod +x "$f" 2>/dev/null
    ls -l "$f" | awk '{printf "  %s %s\n", $1, $NF}'
done < <(find . -name Logs -prune -o -type f -name '*.sh' -print | sort)
echo

echo "=== RESULT ==="
if [ "$FAIL" -eq 0 ]; then
    echo "  PASS - the payload is intact."
    echo
    if [ "$PLATFORM" = "windows" ]; then
        echo "  This is the Windows Desktop VM. Next (first trip only):"
    else
        echo "  This is a Linux box. Next (first trip only):"
    fi
    echo "    ./probe_secure_env.sh --gitlab ${KIT_GITLAB_HOST:-gitlab.idhs.ucl.ac.uk} --artifactory artifactory.idhs.ucl.ac.uk"
    echo "  On a refresh: ./mirror_to_gitlab.sh --refresh, then ./install_packages.sh"
    exit 0
else
    echo "  FAIL - do not continue. See the sections marked above," >&2
    echo "  or the whole of it in ${DSH_LOG_FILE:-Logs/verify_payload.log}." >&2
    echo "  The usual cause is a text-mode transfer corrupting the binaries." >&2
    exit 1
fi
