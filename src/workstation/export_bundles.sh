#!/bin/bash
# OUTSIDE. Create git bundles of the project's repos for import into the Data Safe Haven.
#
# A bundle is a single file holding real git history, so GitLab-inside becomes a true
# mirror: commit SHAs mean the same thing on both sides of the airlock, which is what
# makes "this ran at commit abc123" a statement you can check.
#
#   ./export_bundles.sh                                  # every repo in KIT_REPOS
#   ./export_bundles.sh --package my-library             # or pick your own set
#   ./export_bundles.sh --out ~/Desktop/dsh_import       # somewhere the airlock can see
#   ./export_bundles.sh --conf /path/to/dsh-kit.conf     # a conf other than the repo's
#
# WHICH REPOS, and where they are, come from dsh-kit.conf: KIT_REPOS names them,
# KIT_REPOS_DIR (relative to the conf) is where they are checked out. The conf is
# found by --conf, else $DSH_KIT_CONF, else dsh-kit.conf at the root of the repo this
# script is in - see dsh_workstation_conf in src/lib/common.sh.
#
# A --package that is a directory with a .git in it is taken as a PATH to a checkout,
# and the bundle is named after that directory. That is how a repo living outside
# KIT_REPOS_DIR is exported. Anything else is a name under KIT_REPOS_DIR.
#
# MANIFEST.txt's fourth column is the repo's ROLE, from KIT_WORKING_REPOS: "working"
# for a repo edited inside, "mirror" for everything else. The far side is told what a
# repo is FOR here, in the payload, rather than having to recognise it by name.
#
# Every exported commit must already be on the remote: HEAD has to be contained in
# origin/<branch>, after a best-effort fetch. A bundle of a local, unpushed commit
# becomes GitLab's tip inside; if that commit is later rebased or amended outside,
# it never reaches the remote, and the next refresh is refused as a non-fast-forward
# that can only be fixed with a force push inside. --allow-unpushed skips the check,
# for a throwaway test payload only.
#
# Verify what you produced before carrying it in:
#   git bundle verify <file>.bundle

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Saved before the parsing loop below consumes them, for dsh_start_workstation_log.
DSH_ARGV=("$@")

CONF=""
OUT_DIR=""
PACKAGES=()
ALLOW_UNPUSHED="no"

usage() {
    echo "Usage: $0 [--conf PATH] [--out DIR] [--package NAME|PATH]... [--allow-unpushed]"
    echo
    echo "  --conf PATH        dsh-kit.conf to read (default: the repo root's)"
    echo "  --out DIR          payload directory   (default: <conf dir>/DSH_import)"
    echo "  --package NAME     a repo under KIT_REPOS_DIR, or a path to a checkout."
    echo "                     Repeatable. Default: every repo in KIT_REPOS"
    echo "  --allow-unpushed   skip the 'is it on origin' check - test payloads only"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --conf)      CONF="$2"; shift 2 ;;
        --out)       OUT_DIR="$2"; shift 2 ;;
        --package)   PACKAGES+=("$2"); shift 2 ;;
        --allow-unpushed) ALLOW_UNPUSHED="yes"; shift 1 ;;
        -h|--help)   usage ;;
        *)           echo "Unknown argument: $1"; usage ;;
    esac
done

dsh_workstation_conf "$CONF"
REPOS_DIR="$(dsh_repos_dir)" || dsh_die "KIT_REPOS_DIR does not exist: ${KIT_REPOS_DIR} (relative to ${KIT_CONF_DIR})"
[ -n "$OUT_DIR" ] || OUT_DIR="${KIT_CONF_DIR}/DSH_import"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
dsh_start_workstation_log "$OUT_DIR" ${DSH_ARGV[@]+"${DSH_ARGV[@]}"}

if [ ${#PACKAGES[@]} -eq 0 ]; then
    # shellcheck disable=SC2206  # KIT_REPOS is a space-separated list by definition
    PACKAGES=($KIT_REPOS)
fi

MANIFEST="${OUT_DIR}/MANIFEST.txt"
SKIPPED=""

# Built in a temporary file and moved into place only on success.
#
# Truncating MANIFEST.txt up front meant a run that skipped a repo left the payload
# in a WORSE state than before it ran: the old manifest was gone, the new one did not
# list the skipped repo, and its bundle was still sitting there from the last export.
# That is the "present but NOT IN MANIFEST.txt" state verify_payload.sh checks for.
# A failed export must change nothing.
MANIFEST_TMP="${MANIFEST}.$$"
trap 'rm -f "$MANIFEST_TMP"' EXIT

{
    echo "# Bundles exported $(date -u '+%Y-%m-%dT%H:%M:%SZ') for ${KIT_PROJECT}"
    echo "# repo  branch  sha  role"
    echo "#"
    echo "# role decides what the far side may do with the checkout:"
    echo "#   mirror   read-only inside. Reset to this sha on every refresh and"
    echo "#            asserted against it. An edit there is a fault."
    echo "#   working  edited inside, and OVERWRITTEN by the payload when the"
    echo "#            payload carries it. Local edits are parked on a"
    echo "#            dsh-local/<stamp> branch first, then the checkout is forced"
    echo "#            to this sha. If no bundle for it is in the payload, the"
    echo "#            checkout is not touched at all - that is the switch."
} > "$MANIFEST_TMP"

for spec in "${PACKAGES[@]}"; do
    # A --package is either a bare name under KIT_REPOS_DIR or a path to a checkout
    # that lives somewhere else entirely. Deciding by "does it look like a path"
    # means quoting a Windows separator in a glob; deciding by "is there a
    # repository there" does not, and it is the question that matters. `cd && pwd`
    # also normalises a relative path and a Git Bash drive mount, so the name in
    # MANIFEST.txt is the basename of the real directory either way.
    if [ -d "${spec}/.git" ]; then
        pkg_dir="$(cd "$spec" && pwd)"
        pkg="$(basename "$pkg_dir")"
    else
        pkg="$spec"
        pkg_dir="${REPOS_DIR}/${pkg}"
    fi
    [ -d "${pkg_dir}/.git" ] || dsh_die "Not a git repository: ${pkg_dir}"

    # Refuse to export a dirty tree - what crosses the airlock must be what is
    # committed, or the SHA in the manifest is a lie.
    #
    # TRACKED changes only. A bundle carries committed refs, so an untracked file
    # cannot make the sha wrong - and blocking on one would silently drop a repo
    # with runtime debris in it (logs, generated config) from the manifest. Untracked
    # files are worth a warning, because someone may expect them to travel, but
    # they are not a fault.
    if [ -n "$(git -C "$pkg_dir" status --porcelain --untracked-files=no)" ]; then
        echo "Skipping ${pkg}: uncommitted changes to TRACKED files - commit or stash first" >&2
        git -C "$pkg_dir" status --short --untracked-files=no >&2
        SKIPPED="${SKIPPED} ${pkg}"
        continue
    fi
    if [ -n "$(git -C "$pkg_dir" status --porcelain)" ]; then
        echo "Note: ${pkg} has untracked files. They are NOT in the bundle:" >&2
        git -C "$pkg_dir" status --short >&2
    fi

    branch="$(git -C "$pkg_dir" rev-parse --abbrev-ref HEAD)"
    sha="$(git -C "$pkg_dir" rev-parse HEAD)"

    # Refuse to export a commit the remote does not have - see the header. Behind
    # origin is fine (that commit is on the remote); ahead or diverged is not.
    if [ "$ALLOW_UNPUSHED" != "yes" ]; then
        if [ "$branch" = "HEAD" ]; then
            echo "Skipping ${pkg}: detached HEAD - check out the branch to export" >&2
            SKIPPED="${SKIPPED} ${pkg}"
            continue
        fi
        if ! git -C "$pkg_dir" fetch -q origin "$branch" 2>/dev/null; then
            echo "Note: could not fetch origin/${branch} for ${pkg} - checking against the last-fetched copy" >&2
        fi
        upstream="refs/remotes/origin/${branch}"
        if ! git -C "$pkg_dir" rev-parse -q --verify "$upstream" > /dev/null; then
            echo "Skipping ${pkg}: there is no origin/${branch} - push the branch first" >&2
            SKIPPED="${SKIPPED} ${pkg}"
            continue
        fi
        if ! git -C "$pkg_dir" merge-base --is-ancestor HEAD "$upstream"; then
            echo "Skipping ${pkg}: ${branch} @ ${sha:0:8} is not on origin/${branch} - push it first." >&2
            echo "  Not on the remote:" >&2
            git -C "$pkg_dir" log --oneline "${upstream}..HEAD" | head -10 | sed 's/^/    /' >&2
            SKIPPED="${SKIPPED} ${pkg}"
            continue
        fi
    fi

    bundle="${OUT_DIR}/${pkg}.bundle"

    # --branches --tags rather than --all: --all would drag refs/remotes across too,
    # which land inside as confusing origin/* refs pointing at a remote that is
    # unreachable.
    git -C "$pkg_dir" bundle create "$bundle" --branches --tags

    # From inside the repo just bundled: git bundle verify needs a repository to run
    # in, and the directory this was started from need not be one.
    git -C "$pkg_dir" bundle verify "$bundle" > /dev/null

    role="mirror"
    if dsh_is_working_repo "$pkg"; then
        role="working"
    fi
    printf '%s  %s  %s  %s\n' "$pkg" "$branch" "$sha" "$role" >> "$MANIFEST_TMP"
    echo "Bundled ${pkg} (${branch} @ ${sha:0:8}, ${role}) -> $(basename "$bundle")"
done

echo
echo "Bundles in: ${OUT_DIR}"
cat "$MANIFEST_TMP"

# A skip must not exit 0. A repo could otherwise vanish from MANIFEST.txt while its
# stale bundle stayed on disk from a previous export - and everything downstream is
# driven off the manifest, so the repo would never be mirrored to GitLab and the
# install would clone whatever was there from an older trip. That surfaces two boxes
# later as an ImportError, far from its cause.
if [ -n "${SKIPPED# }" ]; then
    echo >&2
    echo "RESULT: FAIL - not every requested repo was exported. Skipped:${SKIPPED}" >&2
    echo "  The manifest printed above was NOT written. ${OUT_DIR}/MANIFEST.txt is" >&2
    echo "  untouched, so the payload is exactly as it was before this run - which" >&2
    echo "  may still be consistent. Any bundle from an earlier export is also still" >&2
    echo "  there. Commit, stash or push in each repo above, as its line says, and" >&2
    echo "  re-run before building." >&2
    exit 1
fi

# Only now, with every requested repo bundled, does this become the manifest.
# Everything downstream is driven off it - mirror_to_gitlab.sh pushes what it lists,
# install_packages.sh checks cloned SHAs against it - so a partial one is worse than
# the previous complete one.
mv "$MANIFEST_TMP" "$MANIFEST"
echo
echo "Next: ./build_payload.sh --no-bundles   (or just ./build_payload.sh, which runs this too)"
