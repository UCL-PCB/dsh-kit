# Target: the DSH Windows Desktop analysis VM

Windows, driven from **Git Bash**. Read `ground-rules.md` first. `RUNBOOK.md` in the payload
(`src/carry/dsh-vm/RUNBOOK.md`) is the operator's copy of this procedure; this file is how to
*drive* it, and carries the rationale the runbook leaves out.

Windows-specific facts that decide the plan:

| | |
|---|---|
| uv asset | `uv-x86_64-pc-windows-msvc.zip` |
| uv config | `%APPDATA%\uv\uv.toml` — **not** `~/.config/uv/uv.toml` |
| venv python | `.venv/Scripts/python.exe` |
| scheduler | none — expected, not a fault |
| where `.venv` lives | not a given; step 6 decides |
| per-machine settings | `~/dsh-kit.env` (optional) |

**Bundle mode or GitLab mode** — `KIT_GITLAB` in the conf. In bundle mode (`no`, the default)
steps 3 and 4 below are **skipped entirely**, the GitLab item in step 2 is skipped, and step 7
clones from the payload's bundles. Every section marked *GitLab-only* applies only when the
conf says `KIT_GITLAB="yes"`. The GitLab-only scripts are carried either way and, in bundle
mode, print `KIT_GITLAB=no in dsh-kit.conf - <script> is not used` and exit 0.

Writing `~/.config/uv/uv.toml` on Windows is the quiet version of this going wrong: uv never
reads that file there, so the index is never configured, and the first download fails looking
exactly like an Artifactory outage. The scripts detect the platform themselves
(`lib/dsh_platform.sh`) and fail loudly rather than guessing.

## Where settings come from

Every inside script reads, in rising precedence:

1. **`dsh-kit.conf`** in the payload — what the project is. Carried; do not edit it inside.
   If it is wrong, fix it outside and rebuild.
2. **`~/dsh-kit.env`** — what this machine is. Optional, written on the VM, never carried.
   Same `KEY="value"` format, parsed not sourced. Keys:
   `KIT_WORKSPACE_DIR`, `KIT_PYTHON`, `KIT_PAYLOAD_DIR` (default `~/DSH_import`), `KIT_ZIP`,
   `KIT_CLEAN_PATH` (`yes`/`no`), and (GitLab mode) per-machine overrides of
   `KIT_GITLAB_HOST`, `KIT_GITLAB_GROUP`, `KIT_WORKING_NAMESPACE`. `$DSH_KIT_ENV` points at
   another file. `KIT_GITLAB` itself is not per-machine: it lives in the conf.
3. **Flags** on the command line.

On a first import, flags are the clearest — the operator sees each value as they type it.
Once step 7 passes, have them write the two values that worked (`KIT_WORKSPACE_DIR`,
`KIT_PYTHON`) into `~/dsh-kit.env`, so every refresh after is `update_dsh_vm.bat` with
nothing typed.

## Ask first

- The Artifactory `<pypi-remote>` (step 5). The GitLab group, in GitLab mode, comes from
  the conf.
- Is this a first import or a return visit? A return visit is `update_dsh_vm.bat` — see the
  end of this file — and a first import is steps 1–8 (1, 2, 5–8 in bundle mode).
- Is a payload rebuild needed? See `payload.md` — usually not.

## Step 0 — get the payload in

Build or confirm the payload (`payload.md`), then have the operator upload the whole
`DSH_upload/` folder through the portal and give them the current sha256. Uploads land in
`Q:\<username>`, wiped 30 days after arrival.

## Step 1 — unpack (and verify)

From wherever the folder landed, in Git Bash:

```bash
bash ./unpack_payload.sh
```

`bash ./…`, not `./…` — a file on a share carries no executable bit, and the direct form gives
`Permission denied`, which reads like a share permissions problem and is not.

It verifies the zip against the sidecar, unpacks to `~/DSH_import` on **local disk**, strips
CRLF, `chmod +x`es everything, then runs `verify_payload.sh` itself. So on the zip route,
unpack and verify are one command. Everything after this runs from `~/DSH_import`.

**Pass:** ends `PASS - payload unpacked to … and verified.` Logs: `Logs/unpack_payload.log`
and `Logs/verify_payload.log` under the destination.

Failures worth naming up front:
- *zip not found* — a Git Bash started before `Q:` was mapped has no `/q`. Open a fresh one,
  or pass `--zip '/q/<username>/DSH_import.zip'`.
- *checksum mismatch* — text-mode transfer. Re-transfer in binary; do not continue.
- *destination not empty* — deliberate. `--force` only if nothing has been built in there.

On the FTPS route the files arrive loose: `cd <dir> && bash ./verify_payload.sh`.
**Pass:** `PASS - the payload is intact.`

## Step 2 — probe

```bash
./probe_secure_env.sh
```

Read-only. The UCL hosts are its defaults. What decides the plan, all readable off
`Logs/probe_secure_env.log`:

1. **`PLATFORM`** — must say `windows`. If it says `linux`, this is the cluster; switch to
   `dsh-cluster.md`.
2. **Python** — must satisfy `KIT_PYTHON_SPEC` from the conf. The probe prints
   `USE FOR INSTALL --python '<path>'` with the full resolved path. Have the operator note
   it; it is quoted at steps 6 and 7 and **will contain spaces**. No suitable interpreter is
   a hard stop: uv is configured with `python-downloads = "never"` and cannot fetch one.
3. **`arch`** — must be `x86_64`.
4. **Artifactory** — 200/401/403 all mean the host answers. A timeout means steps 5 and 7
   both fail. 401/403 means step 5 needs credentials.
5. **`git usable in cwd`** — must be `yes`. `BROKEN HERE - needs GIT_CEILING_DIRECTORIES`
   means git dies on *every* command, network or not, because it cannot stat an ancestor of
   the cwd while walking up looking for a `.git`. It presents as GitLab denying the account
   — no prompt, same on both TLS backends, unaffected by being Owner — and is easy to lose a
   session to. `git config --global --list`, which contacts nothing, failing identically is
   the tell. Fix and persist:

   ```bash
   export GIT_CEILING_DIRECTORIES=$HOME
   echo 'export GIT_CEILING_DIRECTORIES=$HOME' >> ~/.bashrc
   ```

   Then **re-run every git-dependent check made before the fix** — their results are void.
   `diagnose/diagnose_git_permissions.sh` confirms it as cause E; the payload's git-using
   scripts self-guard via `dsh_git_guard`.

Also: **public PyPI should be unreachable.** If it answers, say so — a first-party package
name that is unregistered on PyPI could then resolve to whatever someone uploads under it.

Windows-only section: the **count of Anaconda entries on PATH**, and which of
`C: N: Q: R: S:` are mapped. A non-zero Anaconda count is the prime suspect for the numpy
DLL failure at step 7, and is what step 6 tests.

GitLab-only: GitLab answering `HTTP 000` while Artifactory answers is almost always TLS,
not reachability: `diagnose/diagnose_gitlab_reachability.sh` separates the two in a minute.
In bundle mode the probe skips GitLab and says so (`--gitlab` probes it anyway).

## Step 3 — the GitLab projects (GitLab-only)

Skip in bundle mode. First visit only. In the GitLab web UI, under `KIT_GITLAB_GROUP` (and `KIT_WORKING_NAMESPACE`
for working repos, if set), create one project per repo in `KIT_REPOS`, named exactly as the
repo, and **empty** — no README, no initial commit. An initial commit makes the first push a
non-fast-forward.

If git will later fail without ever prompting, the stored credential is stale (the DSH
password rotates every 90 days):

```bash
./reset_gitlab_credential.sh
```

It erases the stored credential for the GitLab host and tests with a prompt. Username and
**current DSH password**; GitLab here is AD-backed, so no personal access token.

## Step 4 — mirror to GitLab (GitLab-only)

Skip in bundle mode. **First thing on this run that changes state.** Say so before handing it over.

```bash
./mirror_to_gitlab.sh             # first visit
./mirror_to_gitlab.sh --refresh   # every visit after, projects already populated
```

Host and group come from the conf; `--gitlab` / `--group` override.

**Get `--refresh` right before running it.** Without it, an existing clone directory is
skipped and the checkpoint flags it against the new manifest — deliberate, because a silent
skip is how a stale mirror survives a run that reports success. With it, each clone is
fetched forward out of the new bundle and re-pushed, failing loudly if the new history is
not a fast-forward.

**Pass:** every cloned HEAD matches `MANIFEST.txt`; the script exits non-zero and says
`MISMATCH - do not continue` on any difference.

Failures by what they say:
- `unable to get local issuer certificate` — the documented DSH fix, not a proxy problem:
  `git config --global http.sslBackend schannel`. Confirm it landed — that write fails
  silently when git cannot stat the cwd's ancestors (step 2, item 5).
- A denial that **never prompts** — check `git config --global --list` first; if that fails
  too, no git command has reached GitLab at all. Otherwise `reset_gitlab_credential.sh`.
- `pre-receive hook declined` — a GitLab *policy* refusal: the push authenticated and
  arrived. Usually a protected branch: being Owner does not help, because "Allowed to push"
  is a separate setting. Unprotect, mirror, re-protect; or push a side branch and merge in
  the UI, never squashed (squash rewrites the SHAs the manifest pins).
  `diagnose/diagnose_push_rejection.sh` separates the four families of decline.
- `non-fast-forward` on `--refresh` — GitLab holds commits the bundle does not, so they were
  made inside. `diagnose/diagnose_gitlab_divergence.sh` says whether they are real work.
- `Your local changes … would be overwritten` — something edited a mirror clone here.
  `./rescue_local_edits.sh` (report), then `--rescue` (parks the edits on a
  `dsh-local/<stamp>` branch, restores the branch). Never just delete the clone.

The mirror stops at the first failure under `set -e`, so a failure partway means the repos
after it were never tried; it is safe to repeat once fixed.

Afterwards, in the GitLab UI: **protect the default branch and restrict push to yourself.**
Otherwise someone commits inside, it never reaches the outside, and "this SHA means the same
thing on both sides" is quietly dead.

## Step 5 — install uv, point it at Artifactory

Artifactory needs credentials — anonymous fetches get a 401. Best route first, all three
wanting the `<user>` and `<token>` from the Artifactory "Set Me Up" page:

1. `~/.netrc` (persistent, no credential in any file the script rewrites) — the header of
   `install_uv.sh` has the exact line. Then:
   ```bash
   ./install_uv.sh --artifactory artifactory.idhs.ucl.ac.uk --pypi-remote <pypi-remote>
   ```
2. `UV_INDEX_ARTIFACTORY_USERNAME` / `_PASSWORD` in the environment.
3. Last resort, the whole "Set Me Up" URL as one string — do **not** assemble it from parts:
   ```bash
   ./install_uv.sh --index-url 'https://<user>:<token>@artifactory.idhs.ucl.ac.uk/artifactory/api/pypi/<pypi-remote>/simple'
   ```
   This leaves a live token in `uv.toml` and in the `.bak` the next run makes. Percent-encode
   `@ / : # %` in the token.

It writes `%APPDATA%\uv\uv.toml` with `python-downloads = "never"` (a missing interpreter
fails as "no interpreter", not a confusing network error) and `native-tls = true` (uv
consults the Windows certificate store, behind the DSH's TLS interception).

**Pass:** `RESULT: PASS - the index works.` Log: `Logs/install_uv.log`.

**Add each repo's build backend as a probe**: `--probe-package hatchling`,
`--probe-package setuptools`, `--probe-package uv_build` — whatever each repo's
`[build-system] requires` names. A backend is fetched at *build* time, including for editable
installs; if Artifactory has not mirrored it, step 7 fails on a *first-party* package name
and looks exactly like a source-resolution bug. Catch it here.

If either fails, fix it here. Everything downstream fails the same way for the same reason.

## Step 6 — decide where the `.venv` can live

**Do not skip this.** A full install can complete and only then fail, at the first import,
with `DLL load failed while importing _multiarray_umath: The parameter is incorrect`. This
step catches it in a few minutes.

```bash
./check_venv_location.sh --python '<full-path-to-python>'
./check_venv_location.sh --python '<full-path-to-python>' --candidate '/s/<share>/<workspace-dir>'
```

It builds a throwaway venv with numpy, pandas, scipy and scikit-learn in `<candidate>/dsh-venv-probe`
(never in the candidate itself) and imports on the inherited PATH and on a clean one.
`--package` (repeatable) replaces that set with what the project actually pulls in —
use it if the project needs none of the scientific stack, or something heavier.

Two causes, opposite fixes:

| Result | Means | Do |
|---|---|---|
| OK on clean PATH, FAIL on inherited | Anaconda shadowing the venv's DLLs | `install_packages.sh --clean-path` |
| local OK, network FAIL | Windows cannot load some DLLs across SMB | `--workspace` on a local disk |
| everything FAILS | neither | stop; `Logs/check_venv_location.log` has the detail |

Whatever it marks OK is what goes in `--workspace` at step 7. **Code and the venv on whatever
passes; research data stays on `S:` regardless.** A `.venv` is software, not research data,
so local disk breaks no rule — but a re-imaged VM takes it with it, which is what re-running
the install is for. Never `conda activate` first.

## Step 7 — install the packages

```bash
./install_packages.sh --workspace '<workspace-dir>' --python '<full-path-to-python>'
```

Add `--clean-path` if step 6 showed Anaconda shadowing. `--workspace` is **required on
Windows** — this refuses to guess, because step 6 is what decides it.

It clones every repo in `KIT_REPOS` into `<workspace-dir>/src/`, checks each mirror clone's
HEAD against `MANIFEST.txt`, then installs by `KIT_INSTALL_MODE`. Where it clones from is
`KIT_GITLAB`:

- **bundle mode** — straight from `<repo>.bundle` in the payload, on the manifest's branch.
  The clone keeps no remote, because the payload directory is replaced by the next one; a
  refresh fetches from the *current* payload's bundle and fast-forwards. No credential, no
  network.
- **GitLab mode** — from GitLab, not from the bundles: that proves the mirror is what
  everyone inside will clone from. Refreshed with `git pull --ff-only`.

Then the install:

- **`venv`** — `uv venv`, then **one** `uv pip install` naming every repo editable, with
  `KIT_EXTRAS`. One call is what makes a first-party dependency resolve to the checkout
  beside it rather than be looked up on Artifactory, where it does not exist. Additive:
  re-running never removes anything.
- **`workspace`** — writes `<workspace-dir>/pyproject.toml` generated from the conf (or
  `pyproject.dsh.toml` from the payload, verbatim), keeps the previous one as `.bak`, then
  `uv sync --all-packages` (`--all-extras` adds every extra). A uv sync is **exact**: it
  removes whatever the lock does not name.

Re-running is safe: existing clones are fetched and fast-forwarded rather than re-cloned. A
mirror with local edits to tracked files is refused, not merged over.
A working repo (`KIT_WORKING_REPOS`) is never pulled: if this payload carries its bundle, its
local edits are parked on `dsh-local/<stamp>` and it is overwritten to the payload's commit;
if not, it is left exactly as it is.

**Pass:** `RESULT: PASS`, after the import checkpoint has imported every name in
`KIT_IMPORT_CHECK` one at a time (so a failure names which) and every `KIT_CONSOLE_SCRIPTS`
entry has run `--help`. Log: `Logs/install_packages.log`.

Diagnosing a failure by what it names:
- a **third-party** name → Artifactory has not mirrored it. **Write it down** — that is a
  mirror request, and the likeliest reason to need a second visit.
- `DLL load failed … The parameter is incorrect` → not a packaging problem. Back to step 6;
  if step 6 passed, `diagnose/diagnose_numpy_dll.sh` then `diagnose/diagnose_import_chain.sh`.
- a **first-party** name → in `venv` mode, a repo missing from `KIT_REPOS`; in `workspace`
  mode, the generated (or carried) root's sources.
- a build backend → step 5's probe was missing it.
- the interpreter → outside `KIT_PYTHON_SPEC`.
- `what is checked out is not what this payload carries` → a clone has local edits or
  local commits (`rescue_local_edits.sh` — never "delete the clone", which destroys them);
  in bundle mode, a bundle missing from the payload (`verify_payload.sh` FAILs on that);
  in GitLab mode, GitLab not refreshed from this payload (step 4 with `--refresh`) or a
  project that does not exist. The script's own hints follow the mode.

## Step 8 — console scripts

Only if `KIT_CONSOLE_SCRIPTS` is set. `install_packages.sh` already smoke-tested them. If it
reported **`STUB FAILED, function OK`**, the `.exe` launchers cannot be loaded across SMB but
the code behind them is fine — the known launcher problem, not numpy, the mirror or the
extras. Do not re-sync or re-mirror over it. Fix it with wrappers on local disk:

```bash
./make_console_wrappers.sh --workspace '<workspace-dir>'
```

and keep `~/.local/bin` ahead of the venv on PATH. **Call them by name, never through
`uv run`**: `uv run <script>` execs the `.exe` in `.venv/Scripts` directly, bypassing the
wrappers however PATH is ordered. And in `workspace` mode, a bare `uv run` or `uv sync` also
re-syncs exactly — uninstalling any extra not in the default set.
`diagnose/diagnose_console_scripts.sh` sorts out the other causes.

## Then — make refreshes one click

Have the operator write what worked into `~/dsh-kit.env`:

```
KIT_WORKSPACE_DIR="<workspace-dir>"
KIT_PYTHON="<full-path-to-python>"
```

(and `KIT_CLEAN_PATH="yes"` if step 6 needed it). Every later trip is then: upload the new
`DSH_upload/`, double-click `update_dsh_vm.bat` beside it — unpack, `mirror --refresh`
(GitLab mode only; reported as "not used" in bundle mode), install, in one pass.
`--skip unpack,mirror,install` and `--dry-run` work from a prompt.

## Getting results out

The logs on the VM are the record. If they need to leave: `R:` (MFT Outbound) then the portal,
which needs **outbound rights** — only the IAO has them by default. Usually the operator can
read the PASS/FAIL lines and report them, which is all that is needed.
