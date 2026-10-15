#!/bin/bash
# INSIDE. The first step of every trip - get DSH_import.zip off the arrivals drive, unpack it
# somewhere it can actually be used, and hand straight over to verify_payload.sh.
#
# This is the one script that has to travel *beside* the zip rather than inside it:
# everything else in the payload is unreachable until this has run. It travels in
# DSH_upload/, which build_payload.sh stages with the zip, its .sha256 sidecar and
# the scripts (and their lib/) that cannot ride inside it - upload that folder whole.
#
#   bash ./unpack_payload.sh
#   bash ./unpack_payload.sh --zip '/q/<username>/DSH_import.zip' --dest ~/DSH_import
#
# bash ./unpack_payload.sh, not ./unpack_payload.sh: a Windows zip does not carry the
# executable bit and neither does a file dropped on a share, so the direct form gives
# "Permission denied" - which looks like a share permissions problem and is not.
#
# Nothing here touches the network, and nothing outside --dest is written to. The zip
# itself is left where it was found. With --force, files inside --dest ARE deleted -
# see the flag's description below for the guard on that.
#
# Writes Logs/unpack_payload.log under --dest, beside every other script's log, so
# the result is reviewable on the VM without relaying it anywhere. This is the one
# script that cannot source lib/dsh_log.sh - it travels alone, beside the zip that
# holds it - so it opens its own log the same way and in the same place: truncated
# per run, so what is in it is this unpack and not the last one.

set -uo pipefail

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "Run this script instead of sourcing it:   bash ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 1 2>/dev/null || exit 1
fi

ZIP=""
DEST=""
SHA=""
FORCE=0
STRICT=0
RUN_VERIFY=1

usage() {
    cat <<'EOF'
Usage: bash ./unpack_payload.sh [options]

  --zip PATH      the payload zip. Default: search Q:\<username>, $HOME, this
                  directory and ~/Downloads for DSH_import.zip
  --dest DIR      where to unpack. Default: $HOME/DSH_import (local disk)
  --sha HEX       expected sha256 of the zip, if the .sha256 sidecar did not travel
  --force         REPLACE the contents of --dest: everything already in there is
                  removed first (except this run's own log), then the payload is
                  extracted. Not an overlay - a leftover from an older payload
                  that survives into a newer one is how a renamed script keeps
                  answering to its old name. Refuses if --dest has files but no
                  SHA256SUMS.txt/MANIFEST.txt, i.e. is not a payload directory.
  --strict        fail rather than warn when the zip's checksum cannot be checked
  --no-verify     stop after unpacking; do not run verify_payload.sh
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --zip)       ZIP="$2"; shift 2 ;;
        --dest)      DEST="$2"; shift 2 ;;
        --sha)       SHA="$2"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --strict)    STRICT=1; shift ;;
        --no-verify) RUN_VERIFY=0; shift ;;
        -h|--help)   usage ;;
        *)           echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$DEST" ] || DEST="${HOME}/DSH_import"
mkdir -p "$DEST" 2>/dev/null || { echo "Cannot create --dest: $DEST" >&2; exit 1; }
DEST="$(cd "$DEST" && pwd)"

main() {
    local FAIL=0

    echo "=== Where am I ==="
    printf '  %-18s %s\n' "uname" "$(uname -s -m 2>/dev/null)"
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *)                    PLATFORM="linux"   ;;
    esac
    printf '  %-18s %s\n' "platform" "$PLATFORM"
    printf '  %-18s %s\n' "dest" "$DEST"
    echo

    echo "=== 1. Finding the payload zip ==="
    if [ -n "$ZIP" ]; then
        if [ ! -f "$ZIP" ]; then
            echo "  --zip does not exist: $ZIP"
            echo "  Q: is wiped 30 days after a file arrives - if the upload was long ago, re-upload."
            return 1
        fi
        echo "  given:   $ZIP"
    else
        # Arrivals first, then the places a hand-copy tends to land. Git Bash mounts
        # Q:\ as /q, but only if the drive was mapped when the shell started.
        local candidates=(
            "/q/${USERNAME:-$USER}/DSH_import.zip"
            "${HOME}/DSH_import.zip"
            "$(pwd)/DSH_import.zip"
            "${HOME}/Downloads/DSH_import.zip"
        )
        local c
        for c in /q/*/DSH_import.zip; do
            [ -f "$c" ] && candidates+=("$c")
        done
        for c in "${candidates[@]}"; do
            if [ -f "$c" ]; then ZIP="$c"; break; fi
        done
        if [ -z "$ZIP" ]; then
            echo "  Not found. Looked in:"
            printf '    %s\n' "${candidates[@]}"
            echo
            echo "  If Q: is mapped but /q does not exist, this shell started before the"
            echo "  drive was mapped - open a fresh Git Bash, or pass --zip with the path."
            return 1
        fi
        echo "  found:   $ZIP"
    fi
    # The absolutise-through-pwd line below fails open. When the directory does not
    # exist - a typo, an unmapped drive, or a Windows-shaped path whose dirname is
    # "D:" - the $(cd ... && pwd) comes back EMPTY and the surrounding string hides
    # it, so ZIP silently becomes "/DSH_import.zip" and the failure surfaces two
    # steps later as a missing file nobody typed. Measured: "D:/x/p.zip",
    # "D:\x\p.zip" and "/d/x/p.zip" all collapse to "/p.zip" when /d/x is absent.
    #
    # So: normalise Windows shapes to POSIX first, then insist the file is really
    # there. Inside the airlock a path that fails three steps later costs a round
    # trip, and the operator cannot paste the error back.
    if command -v cygpath > /dev/null 2>&1; then
        ZIP="$(cygpath -u "$ZIP" 2>/dev/null || echo "$ZIP")"
    fi
    if [ ! -f "$ZIP" ]; then
        echo "  FAIL - no such file: $ZIP" >&2
        echo "  Pass --zip with a Git Bash path (/d/DSH_import/DSH_import.zip)," >&2
        echo "  or cd to the folder holding the zip and re-run with no --zip." >&2
        return 1
    fi
    ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
    printf '  %-18s %s bytes\n' "size" "$(wc -c < "$ZIP" | tr -d ' ')"
    echo

    echo "=== 2. Checksum of the zip ==="
    # Only guards the transfer of the zip itself. The contents are covered by
    # SHA256SUMS.txt, which verify_payload.sh checks at the end of this script.
    local sidecar="${ZIP}.sha256"
    if [ -z "$SHA" ] && [ -f "$sidecar" ]; then
        SHA="$(awk '{print $1}' "$sidecar" | head -1)"
        echo "  expected (from $(basename "$sidecar")): $SHA"
    elif [ -n "$SHA" ]; then
        echo "  expected (from --sha): $SHA"
    fi

    if [ -z "$SHA" ]; then
        echo "  No .sha256 sidecar and no --sha - cannot check the transfer."
        if [ "$STRICT" -eq 1 ]; then
            echo "  --strict was given, so stopping here."
            return 1
        fi
        echo "  Continuing; SHA256SUMS.txt inside the zip still covers every file."
    else
        local actual
        actual="$(sha256sum "$ZIP" | awk '{print $1}')"
        echo "  actual:   $actual"
        if [ "$actual" = "$SHA" ]; then
            echo "  OK"
        else
            echo "  MISMATCH - the airlock mangled the zip. Re-transfer in BINARY mode."
            return 1
        fi
    fi
    echo

    echo "=== 3. Unpacking ==="
    local existing
    # Logs/ does not count as contents: this script has already created it and is
    # writing its own log into it, so counting it would make every first unpack into
    # a fresh --dest refuse as "not empty".
    existing="$(ls -A "$DEST" 2>/dev/null | grep -v '^Logs$' || true)"
    if [ -n "$existing" ] && [ "$FORCE" -eq 0 ]; then
        echo "  $DEST is not empty:"
        echo "$existing" | sed 's/^/    /'
        echo
        echo "  Refusing to unpack over it. Re-run with --force to REPLACE it, or"
        echo "  --dest somewhere else. Replacing is safe if this is the same payload;"
        echo "  it is not safe if a build already happened in there."
        return 1
    fi

    # --force REPLACES the directory; it does not extract over the top of it.
    #
    # Extracting over the top leaves behind every file that was in the old payload
    # and is not in the new one - a script that got renamed keeps answering to its
    # old name indefinitely, and stale *.log files sit there reading as the result
    # of this run. verify_payload.sh tolerates unexpected files ("also present, not
    # expected, harmless"), so nothing downstream catches it either. This payload
    # is easily bitten by a leftover that looks like part of it: a bundle for a
    # repo the new payload no longer carries is still read by install_packages.sh,
    # and an update_dsh_vm.bat from an older trip sits beside a newer zip.
    if [ -n "$existing" ]; then
        echo "  --force: replacing the contents of ${DEST}"
        # Only clear something that is recognisably a payload. If DEST is wrong -
        # a mistyped --dest, or KIT_PAYLOAD_DIR pointing at $HOME - this is the
        # difference between a no-op and deleting the operator's files.
        if [ ! -f "${DEST}/SHA256SUMS.txt" ] && [ ! -f "${DEST}/MANIFEST.txt" ]; then
            echo "  REFUSING: ${DEST} has contents but neither SHA256SUMS.txt nor"
            echo "  MANIFEST.txt, so it does not look like a payload directory and"
            echo "  this will not delete from it. Check --dest / KIT_PAYLOAD_DIR is"
            echo "  right, then clear it by hand if it really is the place."
            return 1
        fi
        swept=0
        # Logs/ is kept. It holds this run's own record - being written by the tee
        # this function runs under, and deleting an open file fails on Windows - and
        # the last run of every other script besides. Each log is truncated by the
        # run that writes it and opens with that run's timestamp, so one left here
        # by the payload being replaced cannot read as the result of this one.
        while IFS= read -r -d '' entry; do
            [ "$(basename "$entry")" = "Logs" ] && continue
            rm -rf "$entry" && swept=$((swept + 1))
        done < <(find "$DEST" -mindepth 1 -maxdepth 1 -print0)
        echo "  removed ${swept} old entr$([ "$swept" -eq 1 ] && echo y || echo ies)"
        echo "  (Logs/ is kept - each log is stamped with the run that wrote it,"
        echo "  so one left over cannot read as the result of this one)"
    fi

    # Git for Windows does not always ship unzip. Windows 10's own tar.exe reads zip,
    # and Expand-Archive is the last resort - all three are checked rather than assumed.
    local unpacked=0
    if command -v unzip > /dev/null 2>&1; then
        echo "  using: unzip"
        unzip -o -q "$ZIP" -d "$DEST" && unpacked=1
    fi
    if [ "$unpacked" -eq 0 ] && [ -x /c/Windows/System32/tar.exe ]; then
        echo "  using: C:\\Windows\\System32\\tar.exe"
        ( cd "$DEST" && /c/Windows/System32/tar.exe -xf "$(cygpath -w "$ZIP" 2>/dev/null || echo "$ZIP")" ) && unpacked=1
    fi
    if [ "$unpacked" -eq 0 ] && command -v tar > /dev/null 2>&1; then
        echo "  using: tar"
        ( cd "$DEST" && tar -xf "$ZIP" ) && unpacked=1
    fi
    if [ "$unpacked" -eq 0 ] && command -v powershell.exe > /dev/null 2>&1; then
        echo "  using: powershell Expand-Archive"
        powershell.exe -NoProfile -NonInteractive -Command \
            "Expand-Archive -LiteralPath '$(cygpath -w "$ZIP" 2>/dev/null || echo "$ZIP")' -DestinationPath '$(cygpath -w "$DEST" 2>/dev/null || echo "$DEST")' -Force" \
            && unpacked=1
    fi
    if [ "$unpacked" -eq 0 ]; then
        echo "  No working unpacker found (tried unzip, tar.exe, tar, Expand-Archive)."
        echo "  Extract by hand in Explorer: right-click the zip -> Extract All -> $DEST"
        echo "  then re-run with --no-verify skipped; this script's remaining work is"
        echo "  chmod +x and CRLF stripping, which verify_payload.sh also does."
        return 1
    fi

    # The payload HAS directories - lib/ and diagnose/ - so a nested tree is no
    # longer proof that the zip carried a wrapper folder. What identifies a wrapper
    # is that the whole payload is inside it: one entry, a directory, holding
    # PAYLOAD_CONTENTS.txt. Lift that one, and leave every other shape alone.
    local inner
    inner="$(ls -A "$DEST" | grep -v '^Logs$' || true)"
    if [ "$(echo "$inner" | wc -l)" -eq 1 ] && [ -d "${DEST}/${inner}" ] \
       && [ -f "${DEST}/${inner}/PAYLOAD_CONTENTS.txt" ]; then
        echo "  lifting the payload out of its wrapper directory: ${inner}/"
        mv "${DEST}/${inner}"/* "${DEST}/" 2>/dev/null
        mv "${DEST}/${inner}"/.[!.]* "${DEST}/" 2>/dev/null
        rmdir "${DEST}/${inner}" 2>/dev/null
    fi
    printf '  %s files in %s\n' \
        "$(find "$DEST" -name Logs -prune -o -type f -print | wc -l | tr -d ' ')" "$DEST"
    for d in lib diagnose; do
        [ -d "${DEST}/${d}" ] && printf '    %s/  %s files\n' \
            "$d" "$(find "${DEST}/${d}" -type f | wc -l | tr -d ' ')"
    done
    echo

    echo "=== 4. Repairing what the zip could not carry ==="
    # A zip carries neither the executable bit nor, if anything was opened in Notepad
    # on the way through, LF line endings. Both are documented DSH traps.
    # Every script, lib/ and diagnose/ included: a CR in a sourced library breaks
    # the script that sources it, and fixing only the top level would leave exactly
    # the files nobody looks at broken.
    local crlf=0 chmodded=0 f
    while IFS= read -r f; do
        if grep -qU $'\r' "$f" 2>/dev/null; then
            sed -i 's/\r$//' "$f"
            crlf=$((crlf + 1))
        fi
        chmod +x "$f" 2>/dev/null
        chmodded=$((chmodded + 1))
    done < <(find "$DEST" -name Logs -prune -o -type f -name '*.sh' -print | sort)
    if [ "$crlf" -gt 0 ]; then
        echo "  stripped CRLF from ${crlf} script(s)"
    else
        echo "  no CRLF found in the scripts"
    fi
    echo "  chmod +x applied to ${chmodded} script(s)"
    echo

    echo "=== 5. Where this landed ==="
    # The payload is code, not research data, so local disk breaks no rule - and Q: and
    # R: are both wiped 30 days after a file arrives, which is why neither is a home.
    case "$DEST" in
        /q/*|/Q/*) echo "  WARNING: this is Q: (MFT Arrivals) - wiped 30 days after arrival."
                   echo "           Re-run with --dest \$HOME/DSH_import before doing any work here." ;;
        /r/*|/R/*) echo "  WARNING: this is R: (MFT Outbound) - wiped, and visible to every share member." ;;
        /s/*|/S/*) echo "  On S: (the group share). Fine for the payload. The .venv is a separate"
                   echo "  question - check_venv_location.sh decides that; SMB is a known cause of DLL failures." ;;
        /n/*|/N/*) echo "  WARNING: this is N: (home, 50 GB) - no research data here per the DSH rules."
                   echo "           The payload itself is code, so it is allowed, but S: or C: is the better home." ;;
        *)         echo "  $DEST - local disk. Good." ;;
    esac
    echo

    if [ "$RUN_VERIFY" -eq 0 ]; then
        echo "=== RESULT ==="
        echo "  Unpacked. --no-verify was given, so stopping before verification."
        echo "  Next:  cd '$DEST' && bash ./verify_payload.sh"
        return 0
    fi

    if [ ! -f "${DEST}/verify_payload.sh" ]; then
        echo "=== RESULT ==="
        echo "  Unpacked, but verify_payload.sh is not in there - the zip is not the payload."
        return 1
    fi

    echo "=== 6. Handing over to verify_payload.sh ==="
    echo
    ( cd "$DEST" && bash ./verify_payload.sh )
    FAIL=$?
    echo
    echo "=== RESULT ==="
    if [ "$FAIL" -eq 0 ]; then
        echo "  PASS - payload unpacked to $DEST and verified."
        echo "  Full detail in ${DEST}/Logs/ - verify_payload.log and unpack_payload.log"
    else
        echo "  FAIL - verify_payload.sh rejected the payload. See ${DEST}/Logs/verify_payload.log"
    fi
    return "$FAIL"
}

mkdir -p "${DEST}/Logs"
# Truncating, as dsh_log.sh is for every other script: the log is this run.
main 2>&1 | tee "${DEST}/Logs/unpack_payload.log"
exit "${PIPESTATUS[0]}"
