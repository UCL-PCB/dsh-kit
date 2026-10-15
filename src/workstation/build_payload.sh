#!/bin/bash
# OUTSIDE. Assemble the complete DSH_import payload: bundles, conf, scripts, checksums, zip.
#
# export_bundles.sh makes the bundles. This makes everything else - copies the carried
# scripts and the project's dsh-kit.conf in beside them, checks the uv assets are
# there, regenerates SHA256SUMS.txt, and builds the single zip plus its sidecar hash
# for the portal route. It ends by staging DSH_upload/ - the folder that goes through
# the airlock.
#
#   ./build_payload.sh                        # rebuild everything, for KIT_TARGETS
#   ./build_payload.sh --target dsh-vm        # only what the analysis VM needs
#   ./build_payload.sh --no-bundles           # scripts/checksums/zip only, bundles as-is
#   ./build_payload.sh --no-zip               # loose files only, for the FTPS route
#   ./build_payload.sh --conf PATH            # a conf other than the repo root's
#
# WHAT GOES IN THE PAYLOAD is decided by where a file sits in src/carry/: one
# directory per group of boxes, and everything in it goes to those boxes. See
# lib/carry.sh. There is no list to keep in step with the tree, because the tree IS
# the list.
#
# WHERE EACH FILE LANDS is dsh_payload_path's answer: lib/ for what is only ever
# sourced, diagnose/ for what is only ever run once something is wrong, the top level
# for the steps of the procedure. The groups are not reproduced on the far side -
# they answer which box, which is of no interest to an operator standing at one of
# them. What the far side does get is PAYLOAD_CONTENTS.txt, written here, naming
# every file, the group it came from and the path it landed at - so verify_payload.sh
# checks the payload that was actually built for this target rather than a list
# compiled into it.
#
# WHAT IS THE PROJECT'S, rather than the kit's, is up to three files at the payload root:
#   dsh-kit.conf                copied verbatim. Every script inside reads it.
#   pyproject.dsh.toml          only if it sits beside the conf. For
#   pyproject.dsh-cluster.toml  KIT_INSTALL_MODE=workspace, a hand-written workspace
#                               root used instead of the generated one - on the VM,
#                               and on the cluster respectively.
#
# Logs go to <payload dir>/Logs/, with every other script's.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CARRY_DIR="${SRC_DIR}/carry"
# shellcheck source=../lib/common.sh
source "${SRC_DIR}/lib/common.sh"
# shellcheck source=../lib/carry.sh
source "${SRC_DIR}/lib/carry.sh"
# lib/common.sh brings carry/any/lib/dsh_log.sh and dsh_conf.sh with it.

DSH_ARGV=("$@")

CONF=""
OUT_DIR=""
UV_DIR=""
DO_BUNDLES=1
DO_ZIP=1
DO_PRUNE=0
TARGET=""

usage() {
    cat <<'EOF'
Usage: ./build_payload.sh [options]

  --conf PATH       dsh-kit.conf to read   (default: the repo root's)
  --target NAME     which box the payload is for   (default: from KIT_TARGETS)
                      dsh          the analysis VM and the cluster behind it,
                                   refreshed together in one airlock trip
                      dsh-vm       the analysis VM alone
                      dsh-cluster  the data-safe cluster alone
  --out DIR         payload directory   (default: <conf dir>/DSH_import)
  --uv-dir DIR      where to copy the uv assets from, if not already in --out
  --no-bundles      do not re-run export_bundles.sh; keep the bundles already there
  --no-zip          do not build DSH_import.zip (FTPS route sends the files loose)
  --prune           delete files in the payload dir that no longer belong to a
                    payload - scripts a later commit removed, left behind by an
                    earlier build. Reported either way.
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --conf)       CONF="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --out)        OUT_DIR="$2"; shift 2 ;;
        --uv-dir)     UV_DIR="$2"; shift 2 ;;
        --no-bundles) DO_BUNDLES=0; shift ;;
        --no-zip)     DO_ZIP=0; shift ;;
        --prune)      DO_PRUNE=1; shift ;;
        -h|--help)    usage ;;
        *)            echo "Unknown argument: $1" >&2; usage ;;
    esac
done

dsh_workstation_conf "$CONF"
[ -n "$TARGET" ] || TARGET="$(dsh_default_target "$KIT_TARGETS")"
dsh_target_boxes "$TARGET" > /dev/null || dsh_die "Unknown --target '${TARGET}'. One of: dsh, dsh-vm, dsh-cluster"

[ -n "$OUT_DIR" ] || OUT_DIR="${KIT_CONF_DIR}/DSH_import"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
# The zip and the upload folder sit beside the payload directory's default home - the
# conf's directory - never inside DSH_import/, which is what gets zipped.
ZIP="${KIT_CONF_DIR}/DSH_import.zip"
UPLOAD_DIR="${KIT_CONF_DIR}/DSH_upload"

# Only now is the payload directory known, and that is where the log belongs - with
# every other script's, and nowhere near this repository's source. Everything above
# is argument parsing; a usage error needs no log.
DSH_LOG_BASE_DIR="$OUT_DIR"
dsh_start_log "${DSH_ARGV[@]+"${DSH_ARGV[@]}"}"

# ---------------------------------------------------------------------------
# What this target carries
# ---------------------------------------------------------------------------
mapfile -t CARRIED < <(dsh_carry_files "$CARRY_DIR" "$TARGET")
[ "${#CARRIED[@]}" -gt 0 ] || dsh_die "No files selected for --target ${TARGET} under ${CARRY_DIR}"

# The far side names scripts by bare filename, so two groups may not offer the same
# one. Checked here because the symptom on the far side is not an error: one file
# silently overwrites the other and whichever lost runs as the other's name.
DUPES="$(dsh_carry_basenames "$CARRY_DIR" "$TARGET" | uniq -d)"
[ -z "$DUPES" ] || dsh_die "Two carried files share a basename, and the payload names scripts by basename: ${DUPES}"

# The project's own files: carried, so listed and hashed like everything else.
PROJECT_FILES=(dsh-kit.conf)
PYPROJECTS=()
for f in pyproject.dsh.toml pyproject.dsh-cluster.toml; do
    if [ -f "${KIT_CONF_DIR}/${f}" ]; then
        PROJECT_FILES+=("$f")
        PYPROJECTS+=("$f")
    fi
done

# The bundles go in whenever the VM is a destination: it is the box that mirrors them
# into GitLab, and the cluster installs by cloning from there (docs/git_install_route.md).
# A cluster-only payload carries none - it rides along on a VM that already has them.
#
# Both uv binaries travel for a --target dsh trip. They are ~25 MB each, the payload
# goes in once, and carrying only the one you think you need is how a second airlock
# trip gets booked.
WANT_BUNDLES=0
UV_ASSETS=()
for box in $(dsh_target_boxes "$TARGET"); do
    case "$box" in
        dsh-vm)
            WANT_BUNDLES=1
            UV_ASSETS+=(uv-x86_64-pc-windows-msvc.zip)
            ;;
        dsh-cluster)
            UV_ASSETS+=(uv-x86_64-unknown-linux-gnu.tar.gz)
            ;;
    esac
done

echo "=== Payload for ${KIT_PROJECT}, --target ${TARGET} ==="
printf '  conf             %s\n' "$KIT_CONF_FILE"
printf '  boxes            %s\n' "$(dsh_target_boxes "$TARGET" | tr '\n' ' ')"
printf '  repos            %s\n' "$KIT_REPOS"
printf '  install mode     %s\n' "$KIT_INSTALL_MODE"
printf '  carried files    %s from src/carry/\n' "${#CARRIED[@]}"
printf '  uv assets        %s\n' "${#UV_ASSETS[@]}"
printf '  payload dir      %s\n' "$OUT_DIR"
echo

# ---------------------------------------------------------------------------
# 1. Bundles
# ---------------------------------------------------------------------------
BUNDLES=()
if [ "$WANT_BUNDLES" -eq 0 ]; then
    echo "=== 1. Bundles (none - ${TARGET} installs from the VM's GitLab) ==="
    echo
else
    if [ "$DO_BUNDLES" -eq 1 ]; then
        echo "=== 1. Bundles ==="
        "${SCRIPT_DIR}/export_bundles.sh" --conf "$KIT_CONF_FILE" --out "$OUT_DIR"
        echo
    else
        echo "=== 1. Bundles (skipped, --no-bundles) ==="
        [ -f "${OUT_DIR}/MANIFEST.txt" ] || dsh_die "--no-bundles but no MANIFEST.txt in ${OUT_DIR}"
        sed 's/^/  /' "${OUT_DIR}/MANIFEST.txt"
        echo
    fi

    # The bundles carried are the ones MANIFEST.txt lists - it is what everything on
    # the far side is driven off, so it is the list. Every repo the conf names must
    # be in it: a --no-bundles build over a manifest from an older conf would
    # otherwise carry a payload that silently lacks a repo the install expects.
    while read -r repo _; do
        case "$repo" in ''|'#'*) continue ;; esac
        BUNDLES+=("${repo}.bundle")
    done < "${OUT_DIR}/MANIFEST.txt"
    for repo in $KIT_REPOS; do
        case " ${BUNDLES[*]-} " in *" ${repo}.bundle "*) ;; *)
            dsh_die "KIT_REPOS names ${repo}, but MANIFEST.txt in ${OUT_DIR} does not list it.
       Re-run without --no-bundles." ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# 2. The project's files, scripts and docs
# ---------------------------------------------------------------------------
echo "=== 2. Conf, scripts and docs ==="
cp "$KIT_CONF_FILE" "${OUT_DIR}/dsh-kit.conf"
printf '  %-40s <- %s\n' "dsh-kit.conf" "$KIT_CONF_FILE"
for f in ${PYPROJECTS[@]+"${PYPROJECTS[@]}"}; do
    cp "${KIT_CONF_DIR}/${f}" "${OUT_DIR}/${f}"
    printf '  %-40s <- %s\n' "$f" "${KIT_CONF_DIR}/${f}"
    if [ "$KIT_INSTALL_MODE" != workspace ]; then
        echo "  note: ${f} is carried, but KIT_INSTALL_MODE=${KIT_INSTALL_MODE} does not use it"
    fi
done

copied=0
CARRIED_PATHS=()
for entry in "${CARRIED[@]}"; do
    rel="${entry#* }"
    dest="$(dsh_payload_path "carry/${rel}")"
    mkdir -p "$(dirname "${OUT_DIR}/${dest}")"
    cp "${CARRY_DIR}/${rel}" "${OUT_DIR}/${dest}"
    printf '  %-40s <- carry/%s\n' "$dest" "$rel"
    CARRIED_PATHS+=("$dest")
    copied=$((copied + 1))
done
echo "  ${copied} copied"

# A script REMOVED from this repo is not removed from a payload directory built by an
# earlier run - nothing here deletes by default, and a renamed or retired script
# left in the payload goes on answering to its old name on the far side. This is the
# last point before the airlock where that is cheap to notice.
#
# Narrowing the target makes this MORE important, not less: everything the previous
# --target left behind is now an extra. The walk goes into lib/ and diagnose/ as well
# as the top level. Logs/ is this machine's record of its builds and is not part of
# any payload, so it is skipped whole.
unexpected=()
while IFS= read -r f; do
    rel="${f#"${OUT_DIR}"/}"
    case "$rel" in
        MANIFEST.txt|SHA256SUMS.txt|PAYLOAD_CONTENTS.txt) continue ;;
    esac
    known=0
    for e in "${PROJECT_FILES[@]}" ${CARRIED_PATHS[@]+"${CARRIED_PATHS[@]}"} ${BUNDLES[@]+"${BUNDLES[@]}"} ${UV_ASSETS[@]+"${UV_ASSETS[@]}"}; do
        [ "$rel" = "$e" ] && { known=1; break; }
    done
    [ "$known" -eq 0 ] && unexpected+=("$rel")
done < <(find "$OUT_DIR" -name Logs -prune -o -type f -print | sort)
if [ "${#unexpected[@]}" -gt 0 ]; then
    echo
    echo "  NOT part of a --target ${TARGET} payload, but sitting in ${OUT_DIR}:"
    printf '    %s\n' "${unexpected[@]}"
    if [ "$DO_PRUNE" -eq 1 ]; then
        for rel in "${unexpected[@]}"; do rm -f "${OUT_DIR}/${rel}"; done
        # An emptied lib/ or diagnose/ goes too, so the listing does not offer a
        # directory with nothing in it.
        find "$OUT_DIR" -mindepth 1 -maxdepth 1 -type d -not -name Logs -empty -delete
        echo "  --prune: deleted. They will not cross the airlock."
    else
        echo "  Left in place, and they WILL be zipped and carried across. Re-run with"
        echo "  --prune to delete them, or keep them deliberately."
    fi
fi
echo

# ---------------------------------------------------------------------------
# 3. uv assets
# ---------------------------------------------------------------------------
echo "=== 3. uv assets ==="
missing=0
for f in "${UV_ASSETS[@]}"; do
    if [ -f "${OUT_DIR}/${f}" ]; then
        printf '  %-38s present\n' "$f"
    elif [ -n "$UV_DIR" ] && [ -f "${UV_DIR}/${f}" ]; then
        cp "${UV_DIR}/${f}" "${OUT_DIR}/${f}"
        printf '  %-38s copied from --uv-dir\n' "$f"
    else
        printf '  %-38s MISSING\n' "$f"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -gt 0 ]; then
    echo
    echo "  Download them from a machine with internet and put them in ${OUT_DIR}"
    echo "  (or pass --uv-dir). Releases: https://github.com/astral-sh/uv/releases"
    dsh_die "${missing} uv asset(s) missing - the payload is incomplete"
fi
echo

# ---------------------------------------------------------------------------
# 4. Line endings
# ---------------------------------------------------------------------------
echo "=== 4. Line endings ==="
# A CRLF jobscript is a documented DSH trap, and a CR in a script that the far side
# runs through bash fails in ways that look like anything but a line-ending problem.
crlf=0
while IFS= read -r f; do
    if grep -qU $'\r' "$f" 2>/dev/null; then
        sed -i 's/\r$//' "$f"
        echo "  stripped CRLF: ${f#"${OUT_DIR}"/}"
        crlf=$((crlf + 1))
    fi
done < <(find "$OUT_DIR" -name Logs -prune -o -type f \( -name '*.sh' -o -name dsh-kit.conf \) -print | sort)
[ "$crlf" -eq 0 ] && echo "  all LF already"
echo

# ---------------------------------------------------------------------------
# 5. What is in here, and its checksums
# ---------------------------------------------------------------------------
echo "=== 5. Contents and checksums ==="
cd "$OUT_DIR"

# PAYLOAD_CONTENTS.txt is what verify_payload.sh reads on the far side. It names the
# target it was built for and, for every file, the group it came from - so the
# verifier can say "this is a dsh-vm payload and install_uv.sh is missing" rather
# than checking against a list compiled into it, which would be a list for some other
# target half the time.
#
#   target <name>
#   built <utc timestamp>
#   file <group> <path>       group: any, dsh-vm, dsh-cluster, bundle, uv, conf
{
    echo "# DSH payload contents. Written by build_payload.sh; read by verify_payload.sh."
    echo "# <group> <path in this directory>. Do not edit - add files to"
    echo "# src/carry/<group>/ instead, which is what decides both."
    echo "target ${TARGET}"
    echo "built $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for entry in "${CARRIED[@]}"; do
        printf 'file %s %s\n' "${entry%% *}" "$(dsh_payload_path "carry/${entry#* }")"
    done | sort -k3
    for f in "${PROJECT_FILES[@]}"; do printf 'file conf %s\n' "$f"; done | sort -k3
    for f in ${BUNDLES[@]+"${BUNDLES[@]}"}; do printf 'file bundle %s\n' "$f"; done | sort -k3
    for f in "${UV_ASSETS[@]}"; do printf 'file uv %s\n' "$f"; done | sort -k3
    if [ "${#BUNDLES[@]}" -gt 0 ]; then echo "file bundle MANIFEST.txt"; fi
} > PAYLOAD_CONTENTS.txt

rm -f SHA256SUMS.txt
# Deterministic order - bundles, then the project's files, then scripts, then the
# rest - so a diff between two payloads is about content rather than about the order
# the files were listed in.
{
    for f in ${BUNDLES[@]+"${BUNDLES[@]}"}; do echo "$f"; done | sort
    [ "${#BUNDLES[@]}" -gt 0 ] && echo MANIFEST.txt
    for f in "${PROJECT_FILES[@]}"; do echo "$f"; done
    echo PAYLOAD_CONTENTS.txt
    for n in ${CARRIED_PATHS[@]+"${CARRIED_PATHS[@]}"}; do case "$n" in *.sh) echo "$n" ;; esac; done | sort
    for n in ${CARRIED_PATHS[@]+"${CARRIED_PATHS[@]}"}; do case "$n" in *.sh) ;; *) echo "$n" ;; esac; done | sort
    for f in "${UV_ASSETS[@]}"; do echo "$f"; done | sort
} > .payload_order
missing=0
while read -r f; do
    [ -f "$f" ] || { echo "  MISSING  $f"; missing=$((missing + 1)); }
done < .payload_order
[ "$missing" -eq 0 ] || { rm -f .payload_order; dsh_die "${missing} file(s) missing from ${OUT_DIR}"; }
# -b so the format matches what sha256sum -c expects for the binaries inside the DSH.
xargs -a .payload_order sha256sum -b > SHA256SUMS.txt
rm -f .payload_order
echo "  PAYLOAD_CONTENTS.txt: ${#CARRIED[@]} carried + $((${#BUNDLES[@]} + ${#UV_ASSETS[@]} + ${#PROJECT_FILES[@]})) project/generated"
echo "  SHA256SUMS.txt:       $(wc -l < SHA256SUMS.txt | tr -d ' ') files"
echo

# ---------------------------------------------------------------------------
# 6. Zip
# ---------------------------------------------------------------------------
if [ "$DO_ZIP" -eq 0 ]; then
    echo "=== 6. Zip (skipped, --no-zip) ==="
else
    echo "=== 6. Zip ==="
    rm -f "$ZIP" "${ZIP}.sha256"
    # Every file in the payload, each named by the path it must keep inside the zip:
    # lib/ and diagnose/ are part of what a payload IS, and a zip that flattened them
    # would unpack into a directory none of the scripts can source from. Logs/ is NOT
    # part of it - it is this machine's record of its builds and grows without limit -
    # and naming each file explicitly is what keeps it out of all three routes below
    # alike, rather than relying on which of them recurses.
    ZIP_FILES=()
    while IFS= read -r f; do
        ZIP_FILES+=("${f#"${OUT_DIR}"/}")
    done < <(find "$OUT_DIR" -name Logs -prune -o -type f -print | sort)
    [ "${#ZIP_FILES[@]}" -gt 0 ] || dsh_die "Nothing to zip in ${OUT_DIR}"

    # Git for Windows ships no zip(1). Windows' own tar.exe and PowerShell's
    # Compress-Archive both write a plain zip, so try all three rather than assume one.
    #
    # ORDER MATTERS because the payload has directories in it. Windows PowerShell
    # 5.1's Compress-Archive writes the separator as a BACKSLASH - "diagnose\x.sh"
    # rather than "diagnose/x.sh" - which is not what the zip format says, and Git
    # Bash's unzip then creates one file literally named "diagnose\x.sh" at the top
    # level instead of a directory. Explorer and tar.exe both cope, unzip does not,
    # and unzip is what unpack_payload.sh reaches for first. So Compress-Archive is
    # the LAST resort, and the result is checked below whichever tool wrote it.
    built=0
    if command -v zip > /dev/null 2>&1; then
        echo "  using: zip"
        ( cd "$OUT_DIR" && zip -q -X -9 "$ZIP" "${ZIP_FILES[@]}" ) && built=1
    fi
    if [ "$built" -eq 0 ] && [ -x /c/Windows/System32/tar.exe ]; then
        echo "  using: C:\\Windows\\System32\\tar.exe"
        ( cd "$OUT_DIR" && /c/Windows/System32/tar.exe -a -c -f "$(cygpath -w "$ZIP")" "${ZIP_FILES[@]}" ) && built=1
    fi
    if [ "$built" -eq 0 ] && command -v powershell.exe > /dev/null 2>&1; then
        echo "  using: powershell Compress-Archive (last resort - see the separator note above)"
        # Everything but Logs/ is passed, and Compress-Archive stores a directory's
        # contents under its own name, which is the layout wanted.
        powershell.exe -NoProfile -NonInteractive -Command \
            "Compress-Archive -Path (Get-ChildItem -LiteralPath '$(cygpath -w "$OUT_DIR")' | Where-Object { \$_.Name -ne 'Logs' }).FullName -DestinationPath '$(cygpath -w "$ZIP")' -CompressionLevel Optimal" \
            && built=1
    fi
    [ "$built" -eq 1 ] || dsh_die "No zip tool found (tried zip, tar.exe, Compress-Archive). Use --no-zip and send the files loose over FTPS."

    # What the zip actually says the paths are. A backslash here unpacks into files
    # named "diagnose\something.sh" on the far side - no diagnose/ directory, every
    # script in lib/ unreachable by the scripts that source it - and the airlock is
    # behind you by the time anyone notices.
    ZIP_ENTRIES=""
    if command -v unzip > /dev/null 2>&1; then
        ZIP_ENTRIES="$(unzip -Z1 "$ZIP" 2>/dev/null)"
    elif [ -x /c/Windows/System32/tar.exe ]; then
        ZIP_ENTRIES="$(/c/Windows/System32/tar.exe -tf "$(cygpath -w "$ZIP")" 2>/dev/null)"
    fi
    if [ -n "$ZIP_ENTRIES" ]; then
        case "$ZIP_ENTRIES" in
            *\\*) dsh_die "The zip names its paths with backslashes, which will not unpack into
       directories on the far side. Install zip(1) (or use a shell where
       C:\\Windows\\System32\\tar.exe is available) and rebuild." ;;
        esac
        printf '  %s entries, paths checked\n' "$(printf '%s\n' "$ZIP_ENTRIES" | grep -c .)"
    else
        echo "  (no tool to list the zip back - its paths are unchecked)"
    fi

    # The sidecar sits beside the zip, never inside it: a hash of the zip cannot be in
    # the zip it hashes.
    ( cd "$(dirname "$ZIP")" && sha256sum -b "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
    echo "  $(basename "$ZIP"): $(wc -c < "$ZIP" | tr -d ' ') bytes"
fi
echo

# ---------------------------------------------------------------------------
# 6b. The upload folder
# ---------------------------------------------------------------------------
# The files that cross the airlock do not naturally sit together: the zip and its
# sidecar are written beside DSH_import/, the unpackers live inside it among every
# other file that is ALREADY in the zip. Selecting a handful out of that by hand, at
# the portal, is where an older copy of an unpacker gets picked.
#
# So assemble them. This directory is a staging area, not a source of truth: emptied
# and rewritten every build, so what is in it always belongs to the zip beside it and
# there is nothing to choose between.
#
# The unpackers source lib/ from beside themselves, so the libraries they need are
# staged with them, in a lib/ of their own - an unpacker staged without them fails
# on its first line, before it has unpacked anything that could supply them.
STAGED_UNPACKERS=(unpack_payload.sh update_dsh_vm.sh update_dsh_vm.bat)
STAGED_LIBS=(lib/dsh_log.sh lib/dsh_platform.sh lib/dsh_conf.sh)
if [ "$DO_ZIP" -eq 1 ]; then
    echo "=== 6b. Upload folder ==="
    # Only ever remove a directory this script named and can see is the one it means
    # - an unset variable must not turn this into rm -rf on something else.
    if [ "$(basename "$UPLOAD_DIR")" != "DSH_upload" ]; then
        dsh_die "Refusing to clear ${UPLOAD_DIR} - not the expected DSH_upload directory"
    fi
    rm -rf "$UPLOAD_DIR"
    mkdir -p "$UPLOAD_DIR"

    cp "$ZIP"          "${UPLOAD_DIR}/"
    cp "${ZIP}.sha256" "${UPLOAD_DIR}/"
    # Every payload lands on the VM first, so the unpackers travel whenever this
    # target carries them. A cluster-only payload is unpacked by the copies an
    # earlier VM payload already left there.
    staged=0
    for f in "${STAGED_UNPACKERS[@]}"; do
        if [ -f "${OUT_DIR}/${f}" ]; then
            cp "${OUT_DIR}/${f}" "${UPLOAD_DIR}/${f}"
            staged=1
        elif [ "$WANT_BUNDLES" -eq 1 ]; then
            dsh_die "Missing ${f} in ${OUT_DIR} - cannot stage the upload folder"
        fi
    done
    if [ "$staged" -eq 1 ]; then
        mkdir -p "${UPLOAD_DIR}/lib"
        for f in "${STAGED_LIBS[@]}"; do
            [ -f "${OUT_DIR}/${f}" ] || dsh_die "Missing ${f} in ${OUT_DIR} - the staged unpackers source it"
            cp "${OUT_DIR}/${f}" "${UPLOAD_DIR}/${f}"
        done
    fi

    # The sidecar hash names DSH_import.zip with no path, so `sha256sum -c` works from
    # inside this folder exactly as it does beside DSH_import/. That is the first
    # thing to do on the far side and it needs no other file.
    cat > "${UPLOAD_DIR}/READ_ME_FIRST.txt" <<UPEOF
Everything in this folder, and nothing else, goes through the airlock.

Project: ${KIT_PROJECT}
Built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Target: ${TARGET}
DSH_import.zip sha256: $(awk '{print $1}' "${ZIP}.sha256")

The unpack scripts, and the lib/ they source, sit OUTSIDE the zip on purpose: they
are what unpacks it, and a copy inside a zip cannot unpack that zip. Upload lib/ as
a folder beside them. They are also inside the zip, so after the first unpack the
copies on disk are the ones that matter.

On the far side, from wherever this folder landed:

  1. Check the transfer did not corrupt the zip (binary mode, not text):
       sha256sum -c DSH_import.zip.sha256

  2. First import ever:
       bash ./unpack_payload.sh
     then open RUNBOOK.md in the unpacked payload (~/DSH_import/RUNBOOK.md)
     and follow it from step 2.

  3. Refreshing an already-built VM:
       double-click update_dsh_vm.bat     (unpack, mirror to GitLab, reinstall)

Every script writes its log into Logs/ beside the payload, so the result of any
step is reviewable there without relaying it anywhere.

This folder is REBUILT FROM EMPTY by every ./build_payload.sh run, so what is here
always matches the zip here. Do not add files to it by hand - add them to
src/carry/<group>/ in the project's dsh-kit repo, which is the one definition of
what goes to which box, and rebuild.
UPEOF

    ( cd "$UPLOAD_DIR" && find . -type f | sed 's|^\./|  |' | sort )
    echo
else
    echo "=== 6b. Upload folder (skipped, --no-zip) ==="
    echo "  The FTPS route sends ${OUT_DIR} itself, so there is nothing to stage."
    echo
fi

# ---------------------------------------------------------------------------
# 7. What to carry
# ---------------------------------------------------------------------------
echo "=== 7. Upload this ==="
if [ "$DO_ZIP" -eq 1 ]; then
    echo "  Portal route - one folder, upload everything in it:"
    echo
    printf '    %s\n' "$UPLOAD_DIR"
    echo
    echo "  sha256: $(awk '{print $1}' "${ZIP}.sha256")"
    echo
    echo "  Then on the far side, from wherever the folder landed:"
    echo "    first import   bash ./unpack_payload.sh   then RUNBOOK.md in the payload"
    echo "    refresh        double-click update_dsh_vm.bat  (unpack, mirror, reinstall)"
    echo
    echo "  READ_ME_FIRST.txt in that folder says the same, on the far side."
else
    echo "  The whole directory, in BINARY mode:"
    echo
    printf '    %s\n' "$OUT_DIR"
    echo
    echo "  Then on the far side:"
    echo "    cd <wherever it landed> && bash ./verify_payload.sh"
fi
echo
