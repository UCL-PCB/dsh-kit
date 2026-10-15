<#
.SYNOPSIS
    OUTSIDE. Create git bundles of the project's repos for import into the Data Safe Haven.

.DESCRIPTION
    PowerShell port of export_bundles.sh, for running natively on a Windows workstation
    without Git Bash. Same output: one .bundle per repo plus a MANIFEST.txt recording
    branch, commit SHA and role, so GitLab-inside is a true mirror and "this ran at
    commit abc123" is a statement you can check.

    Reads the same dsh-kit.conf with the same rule as src/carry/any/lib/dsh_conf.sh:
    only KIT_* lines of the form KEY="value" or KEY=value are taken, values are used
    literally, and nothing in the file is executed. The conf is -Conf, else
    $env:DSH_KIT_CONF, else dsh-kit.conf at the root of the repo this script is in.

    Every safety check of the shell version is kept: a dirty tracked tree, a detached
    HEAD, and a commit not on origin/<branch> each skip the repo; any skip fails the
    run and leaves MANIFEST.txt exactly as it was.

.EXAMPLE
    .\export_bundles.ps1

.EXAMPLE
    .\export_bundles.ps1 -Package my-library -Out D:\dsh_import
#>
[CmdletBinding()]
param(
    [string] $Conf,

    [string] $Out,

    # Repo names under KIT_REPOS_DIR, or paths to checkouts. Default: KIT_REPOS.
    [string[]] $Package,

    # Skip the "every exported commit is on origin" check. Throwaway test payloads only.
    [switch] $AllowUnpushed
)

$ErrorActionPreference = 'Stop'

# Run git for its exit status alone, its chatter discarded. git writes progress and
# verdicts ("<bundle> is okay") to STDERR, and Windows PowerShell 5.1 under
# ErrorActionPreference=Stop turns any native stderr line into a terminating
# NativeCommandError - so a perfectly good `git bundle verify` would end the run.
# Returns git's exit code.
function Invoke-GitStatus {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git @args 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# dsh-kit.conf - parsed, never executed. Keep in step with dsh_conf.sh.
# ---------------------------------------------------------------------------
$knownKeys = @('KIT_PROJECT', 'KIT_REPOS', 'KIT_REPOS_DIR', 'KIT_WORKING_REPOS',
    'KIT_INSTALL_MODE', 'KIT_EXTRAS', 'KIT_PYTHON_SPEC', 'KIT_IMPORT_CHECK',
    'KIT_CONSOLE_SCRIPTS', 'KIT_GITLAB_HOST', 'KIT_GITLAB_GROUP',
    'KIT_WORKING_NAMESPACE', 'KIT_TARGETS')

if (-not $Conf) { $Conf = $env:DSH_KIT_CONF }
if (-not $Conf) {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $Conf = Join-Path $repoRoot 'dsh-kit.conf'
}
if (-not (Test-Path -LiteralPath $Conf -PathType Leaf)) {
    throw "No dsh-kit.conf at $Conf. Copy dsh-kit.conf.example to dsh-kit.conf and fill it in, or pass -Conf."
}
$ConfPath = (Resolve-Path -LiteralPath $Conf).Path
$ConfDir = Split-Path $ConfPath -Parent

$kit = @{}
$n = 0
foreach ($line in [System.IO.File]::ReadAllLines($ConfPath)) {
    $n++
    $line = $line.TrimEnd("`r")
    if ($line -eq '' -or $line -match '^\s*#') { continue }
    if ($line -match '^(KIT_[A-Z_]+)="([^"]*)"\s*(#.*)?$' -or
        $line -match '^(KIT_[A-Z_]+)=([^\s"]*)\s*(#.*)?$') {
        $key = $Matches[1]; $val = $Matches[2]
        if ($knownKeys -contains $key) { $kit[$key] = $val }
        else { Write-Warning "${ConfPath}:${n}: unknown key $key - ignored" }
    } else {
        Write-Warning "${ConfPath}:${n}: not KEY=`"value`" - ignored: $line"
    }
}
foreach ($k in $knownKeys) { if (-not $kit.ContainsKey($k)) { $kit[$k] = '' } }
if (-not $kit.KIT_PROJECT)   { $kit.KIT_PROJECT = 'dsh-project' }
if (-not $kit.KIT_REPOS_DIR) { $kit.KIT_REPOS_DIR = '../' }

$repos   = @($kit.KIT_REPOS -split '\s+' | Where-Object { $_ })
$working = @($kit.KIT_WORKING_REPOS -split '\s+' | Where-Object { $_ })
if ($repos.Count -eq 0) { throw "dsh-kit.conf: KIT_REPOS is empty" }
foreach ($w in $working) {
    if ($repos -notcontains $w) { throw "dsh-kit.conf: KIT_WORKING_REPOS names $w, which is not in KIT_REPOS" }
}

if ([System.IO.Path]::IsPathRooted($kit.KIT_REPOS_DIR)) { $reposDir = $kit.KIT_REPOS_DIR }
else { $reposDir = Join-Path $ConfDir $kit.KIT_REPOS_DIR }
if (-not (Test-Path -LiteralPath $reposDir -PathType Container)) {
    throw "KIT_REPOS_DIR does not exist: $($kit.KIT_REPOS_DIR) (relative to $ConfDir)"
}
$ReposDir = (Resolve-Path -LiteralPath $reposDir).Path

if (-not $Package -or $Package.Count -eq 0) { $Package = $repos }

if (-not $Out) { $Out = Join-Path $ConfDir 'DSH_import' }
if (-not (Test-Path -LiteralPath $Out)) {
    New-Item -ItemType Directory -Path $Out -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $Out).Path

$manifest = Join-Path $OutDir 'MANIFEST.txt'
$lines = @(
    "# Bundles exported $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) for $($kit.KIT_PROJECT)",
    "# repo  branch  sha  role",
    "#",
    "# role decides what the far side may do with the checkout:",
    "#   mirror   read-only inside. Reset to this sha on every refresh and",
    "#            asserted against it. An edit there is a fault.",
    "#   working  edited inside, and OVERWRITTEN by the payload when the",
    "#            payload carries it. Local edits are parked on a",
    "#            dsh-local/<stamp> branch first, then the checkout is forced",
    "#            to this sha. If no bundle for it is in the payload, the",
    "#            checkout is not touched at all - that is the switch."
)
$skipped = @()

foreach ($spec in $Package) {
    # A directory with a .git in it is a path to a checkout; anything else is a name
    # under KIT_REPOS_DIR. Same rule as the shell version.
    if (Test-Path -LiteralPath (Join-Path $spec '.git')) {
        $pkgDir = (Resolve-Path -LiteralPath $spec).Path
        $pkg = Split-Path $pkgDir -Leaf
    } else {
        $pkg = $spec
        $pkgDir = Join-Path $ReposDir $pkg
    }
    if (-not (Test-Path -LiteralPath (Join-Path $pkgDir '.git'))) {
        throw "Not a git repository: $pkgDir"
    }

    # Refuse a dirty TRACKED tree - what crosses the airlock must be what is committed,
    # or the SHA in the manifest is a lie. Untracked files cannot change the sha, so
    # they are only a note.
    $dirty = git -C $pkgDir status --porcelain --untracked-files=no
    if ($dirty) {
        Write-Warning "Skipping ${pkg}: uncommitted changes to TRACKED files - commit or stash first"
        git -C $pkgDir status --short --untracked-files=no
        $skipped += $pkg
        continue
    }
    $untracked = git -C $pkgDir status --porcelain
    if ($untracked) {
        Write-Warning "${pkg} has untracked files. They are NOT in the bundle."
    }

    $branch = (git -C $pkgDir rev-parse --abbrev-ref HEAD).Trim()
    $sha    = (git -C $pkgDir rev-parse HEAD).Trim()

    # Refuse to export a commit the remote does not have -- see export_bundles.sh. A
    # bundled local commit that is later rebased outside leaves GitLab-inside on a tip
    # the remote never had, and the next refresh is a non-fast-forward only a force push
    # inside can clear.
    if (-not $AllowUnpushed) {
        if ($branch -eq 'HEAD') {
            Write-Warning "Skipping ${pkg}: detached HEAD - check out the branch to export"
            $skipped += $pkg
            continue
        }
        # A failed fetch here is only a warning - see Invoke-GitStatus for why it is not
        # called bare.
        if ((Invoke-GitStatus -C $pkgDir fetch -q origin $branch) -ne 0) {
            Write-Warning "Could not fetch origin/$branch for $pkg - checking against the last-fetched copy"
        }
        $upstream = "refs/remotes/origin/$branch"
        if ((Invoke-GitStatus -C $pkgDir rev-parse -q --verify $upstream) -ne 0) {
            Write-Warning "Skipping ${pkg}: there is no origin/$branch - push the branch first"
            $skipped += $pkg
            continue
        }
        if ((Invoke-GitStatus -C $pkgDir merge-base --is-ancestor HEAD $upstream) -ne 0) {
            Write-Warning "Skipping ${pkg}: $branch @ $($sha.Substring(0, 8)) is not on origin/$branch - push it first"
            git -C $pkgDir log --oneline "$upstream..HEAD"
            $skipped += $pkg
            continue
        }
    }

    $bundle = Join-Path $OutDir "$pkg.bundle"

    # --branches --tags rather than --all: --all would drag refs/remotes across too,
    # which land inside as confusing origin/* refs pointing at a remote that is unreachable.
    if ((Invoke-GitStatus -C $pkgDir bundle create $bundle --branches --tags) -ne 0) {
        throw "git bundle create failed for $pkg"
    }
    if ((Invoke-GitStatus -C $pkgDir bundle verify $bundle) -ne 0) {
        throw "git bundle verify failed for $pkg"
    }

    $role = 'mirror'
    if ($working -contains $pkg) { $role = 'working' }
    $lines += ('{0}  {1}  {2}  {3}' -f $pkg, $branch, $sha, $role)
    Write-Host ("Bundled {0} ({1} @ {2}, {3}) -> {4}" -f $pkg, $branch, $sha.Substring(0, 8), $role, (Split-Path $bundle -Leaf))
}

Write-Host ""
Write-Host "Bundles in: $OutDir"
$lines | ForEach-Object { Write-Host $_ }

# A skip must not succeed, and must not touch MANIFEST.txt: everything downstream is
# driven off it, so a partial manifest is worse than the previous complete one.
if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Error ("RESULT: FAIL - not every requested repo was exported. Skipped: {0}. MANIFEST.txt was NOT written." -f ($skipped -join ' ')) -ErrorAction Continue
    exit 1
}

# LF and no BOM: the far side parses this file in a bash loop, where a UTF-8 BOM
# corrupts the first repo name and CRLF appends a carriage return to every branch name.
# Windows PowerShell 5.1's Set-Content -Encoding utf8 emits both, so bypass it.
$text = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText($manifest, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Next: build_payload.sh --no-bundles (Git Bash) to add the conf, scripts and checksums."
