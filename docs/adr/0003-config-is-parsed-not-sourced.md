# 0003 — One project config, parsed rather than sourced

Status: Accepted

## Context

dsh-kit is a template: the scripts are the kit's, the list of packages is the project's. The
scripts that grew up around one project named its packages directly — a `PACKAGES=(…)` array
in the install script, a `DEFAULT_PACKAGES` in the exporter, a `BUNDLES` list in the payload
builder, a `MODULES` list for the import check, hard-coded console-script names — five places
to edit for a new project, which in practice drifted: renames in the packages left stale
names in the scripts.

The project's description also has to cross the airlock. The scripts inside need to know the
repos, their order, the install mode and the GitLab group, and the far side has no access to
anything outside the payload.

And it has to be read by more than bash: `export_bundles.ps1` exists for machines without
Git Bash, and must export exactly what `export_bundles.sh` would.

## Decision

**One file, `dsh-kit.conf`, at the root of the project's repo, is the only place the
project's packages are named.** Every script, on both sides of the airlock, reads it;
`build_payload.sh` carries it verbatim to the payload root.

**It is parsed, not sourced.** `src/carry/any/lib/dsh_conf.sh` reads it line by line and
takes only lines of the form `KIT_NAME="value"` (or `KIT_NAME=value`), with the name from a
fixed list of known keys, and the value used **literally** — no `$` expansion, no command
substitution, no arrays; lists are space-separated. Anything else is reported with its line
number and ignored. `export_bundles.ps1` implements the same rule.

Machine-specific values — where the workspace goes, which interpreter — do not belong in it
(it is committed, and the same on every box). They go in `~/dsh-kit.env` on the machine
itself, same format, same parser, never carried. Flags on the command line beat both.

## Why parsed

- **A carried file cannot run anything.** The conf travels through the airlock and is read
  by scripts that push to GitLab and install software. Sourcing it would make it executable
  input on the far side: a stray line — or a pasted snippet — would run with the operator's
  credentials. Parsing makes its worst case a warning.
- **One rule for two languages.** A sourced file means whatever bash says it means, which
  PowerShell cannot reproduce. A literal `KEY="value"` grammar can be implemented identically
  in both, so the two exporters cannot disagree about which repos a project has.
- **Mistakes fail early and loudly.** An unknown key (a typo) and a malformed line are
  reported, and `dsh_check_conf` refuses an empty `KIT_REPOS`, an unknown install mode, a
  working repo that is not a repo, or an unknown target — outside, before a payload is
  built, rather than two boxes later.

## Alternatives rejected

**TOML.** The natural format for a Python project, but there is no TOML parser in Git Bash or
in a stock Windows PowerShell 5.1, and the inside scripts run before any Python environment
exists. A hand-rolled TOML subset would be a parser with more ways to disagree with itself.

**A sourced `.env`.** Simplest to read from bash, and exactly the property this rejects.

**Keep per-script defaults and override with flags.** That is the five-places problem, plus a
command line to get right on every trip.

## Consequences

- Adding a repo to what is carried is one edit to `KIT_REPOS`; the `dsh-init` skill writes
  the file and validates it with the same parser.
- Values cannot reference each other or the environment. That is deliberate; a value that
  needs a machine path belongs in `~/dsh-kit.env`.
- New keys must be added to `DSH_CONF_KEYS` in `dsh_conf.sh` (and to the PowerShell reader),
  or every conf using them warns.
