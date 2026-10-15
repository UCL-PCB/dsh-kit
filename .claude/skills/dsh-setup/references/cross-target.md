# Rules for both targets

`ground-rules.md` is about the airlock. This file is about config and verification. Read it
before changing anything on either box.

## Generate what describes a machine; copy only what describes the project

The single most expensive class of failure in this kind of work: a config file authored on
the workstation is copied to a target, and its Windows-shaped paths follow it.

Split every config by what it describes:

| Describes | Examples | How it gets there |
|---|---|---|
| **The project** | `dsh-kit.conf` — which repos, which extras, venv or workspace, bundles or GitLab (and which group); your own analysis parameters | Carried in the payload. It is the same project on either box. |
| **The machine** | `~/dsh-kit.env` — workspace dir, python path, payload dir; the workspace root `pyproject.toml`; `uv.toml`; anything holding an absolute path or a credential | **Written on the target.** Never carried. |

dsh-kit already keeps to this: `dsh-kit.conf` holds no path that means anything inside,
`install_packages.sh` *generates* the workspace root from it rather than carrying one, and
`install_uv.sh` writes `uv.toml` on the box. Hold your own project's configs to the same
rule: if a file of yours carries `C:\Users\…` or a results directory, regenerate it inside
and overlay only the keys that describe the analysis.

Corollaries worth stating on their own:

- **A backslash is an ordinary filename character on Linux.** A `Results\run1` carried to the
  cluster does not fail — it silently creates a directory with a backslash in its name, and
  every later step works against the wrong tree. It surfaces as debris, not as an error.
- **A colon in a path breaks GNU tar in Git Bash.** Shell-derived paths (`pwd`, `$HOME`) are
  `/c/Users/…` and safe; a path read out of a TOML or JSON is `C:/Users/…`, and tar reads it
  as `host:path` — `Cannot connect to C: resolve failed`. Convert with `cygpath -u` at the
  boundary, or pass `--force-local`.
- **Audit anything that seeds one config tree from another.** A copy step that was correct
  when written becomes a Windows-path injector the moment the source tree goes stale.

## Verify the premise before acting on it

An operator's diagnosis names the symptom they saw, which is not always the cause. Read the
actual error before accepting it — the key that is wrong is often the one next to the one
they named.

Same discipline for your own explanations: reproduce a hypothesis locally before shipping a
fix built on it, through the airlock, at the cost of a round trip.

A regression test that does not fail without the fix has tested nothing. Revert the fix, watch
it fail, put it back.

## Guard your own verification against false passes

Checks on a remote machine fail *open* far more often than they fail closed. Each of these
reports success while proving nothing:

- **Grepping a file that was empty.** No match, no error. Guard with `[ ! -s "$f" ]` before
  drawing a conclusion from a grep.
- **A poll loop that exits on one missing `qstat` line.** A transient miss reads identically to
  a finished job. Require two consecutive misses, and match with `grep -w` so job `2891` does
  not match `28910`.
- **`echo "done"` after a command whose exit status nobody checked.** `set -e`, or test the
  status.
- **A green setup checker** that tests that files exist, not that they work.
- **Treating silence as success.** A check written as "empty output means nothing went wrong"
  gives a clean bill to a probe that never ran — a subshell that died before reaching Python
  reports every module importing fine. Make every check demand a positive sentinel — print
  `IMPORTS_OK`, grep for it. Silence is a failure.
- **`set -u` inherited into a command substitution.** `$( … )` inherits the caller's shell
  options, and `/etc/profile`, `module` init and a venv's `activate` all touch unset
  variables. Under `set -u` the subshell dies at the first `source`, before any `echo`, and
  every check downstream reads an empty string. `set +u` inside any subshell that sources
  environment scripts.
- **String-comparing two paths.** The mirror image — a check that fails for a reason that is
  not real. One directory is often reachable by two paths (a symlinked home, an automount).
  Resolve both sides with `cd "$p" && pwd -P` before comparing.

## A hand-edit to a generated file is half a change

If a file on the target is written by a script, editing it in place fixes today and loses the
fix the next time that script runs — and the rerun looks like a regression appearing from
nowhere, days later. `install_packages.sh` rewrites the workspace `pyproject.toml` on every
run (keeping a `.bak`); `install_uv.sh` rewrites `uv.toml`.

Before hand-editing anything on a target, ask what wrote it. If the answer is a script in
this repo, change the conf or the script, rebuild the payload, and re-run.

## Trace debris to its producer

When something unexpected exists on a target, do not just delete it. Find what created it —
it is probably still running. After removing debris, re-run the thing that made it and
confirm it does not come back.

## One task before the fleet

Before a fan-out — an array job of many tasks — submit exactly one and confirm exit 0, an
output artefact, and an empty error stream for that task. All three matter: a job can exit 0
while writing nothing.

Fanning out is the operator's call, not yours. Report the one task green and stop.
