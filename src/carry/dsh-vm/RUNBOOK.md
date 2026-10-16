# RUNBOOK — installing this project on the DSH Desktop VM

You are inside the DSH; whatever helped build this payload cannot see you. Every step below
writes `Logs/<script>.log` in the payload directory: read the last lines for `PASS` or
`FAIL`. Nothing needs copying out.

Run everything in **Git Bash**. Replace `<placeholders>` with your own values. What the
project is (which repos, bundles or GitLab) comes from `dsh-kit.conf` beside this file —
do not edit it here; it is fixed outside and re-carried.

**Bundles or GitLab?** Look at `KIT_GITLAB` in `dsh-kit.conf` (or at the `GitLab
(KIT_GITLAB)` line `verify_payload.sh` prints).

- `KIT_GITLAB="no"` — **bundle mode**. The packages install straight from the `.bundle` files
  in this payload. **Skip steps 3 and 4**, and every line below marked *GitLab only*. Your
  path is 1, 2, 5, 6, 7, (8), 9.
- `KIT_GITLAB="yes"` — **GitLab mode**. All steps apply.

Steps 1–2 change nothing. In GitLab mode step 4 is the first that changes anything (it
pushes to GitLab); in bundle mode it is step 7, which only writes your workspace.

---

## Refreshing a VM that is already set up

Upload the new `DSH_upload/` folder, then double-click `update_dsh_vm.bat` in it. That
unpacks, refreshes the GitLab mirror (GitLab mode only) and reinstalls in one pass, using `~/dsh-kit.env` (see
the end of this file). **Pass:** the last block of `Logs/update_dsh_vm.log` says PASS.
From a prompt: `bash ./update_dsh_vm.sh --dry-run` shows what it would run.

---

## First import

### 1. Unpack and verify

From wherever the upload landed (usually `Q:\<username>`):

```bash
bash ./unpack_payload.sh
```

PASS: `PASS - payload unpacked to … and verified.` — the payload is now in `~/DSH_import`;
run everything after this from there (`cd ~/DSH_import`).

FAIL:
- zip not found → open a fresh Git Bash (Q: was not mapped when it started), or
  `bash ./unpack_payload.sh --zip '/q/<username>/DSH_import.zip'`
- checksum mismatch → the upload was corrupted (text mode). Upload again; do not continue.
- destination not empty → deliberate. `--force` only if nothing was built there.

### 2. Probe

```bash
./probe_secure_env.sh
```

PASS: `PLATFORM windows`, `arch x86_64`, `git usable in cwd yes`, and a line
`USE FOR INSTALL --python '<path>'`. **Write that path down** — steps 6 and 7 need it.

FAIL:
- `BROKEN HERE - needs GIT_CEILING_DIRECTORIES` → run, then re-run the probe:
  `echo 'export GIT_CEILING_DIRECTORIES=$HOME' >> ~/.bashrc && source ~/.bashrc`
  (detail: `./diagnose/diagnose_git_permissions.sh`)
- no suitable Python → stop. One must be installed on the VM; ask DSH support.
- *GitLab only:* GitLab `HTTP 000` but Artifactory answers →
  `./diagnose/diagnose_gitlab_reachability.sh` (in bundle mode the probe skips GitLab)

### 3. Create the GitLab projects — GitLab only, first time only

Bundle mode: skip to step 5.

In the GitLab web UI (`https://gitlab.idhs.ucl.ac.uk`), under the group named
`KIT_GITLAB_GROUP` in `dsh-kit.conf`, create one project per repo in `KIT_REPOS`, named
exactly as the repo. **Empty: untick "Initialize repository with a README".**

If git later refuses you without ever asking for a password: `./reset_gitlab_credential.sh`
(username and current DSH password).

### 4. Mirror to GitLab — GitLab only, changes state

Bundle mode: skip to step 5. (Run anyway, it prints "not used" and exits.)

```bash
./mirror_to_gitlab.sh             # first time
./mirror_to_gitlab.sh --refresh   # every time after
```

PASS: every repo matches `MANIFEST.txt`.

FAIL:
- `unable to get local issuer certificate` → `git config --global http.sslBackend schannel`
- `pre-receive hook declined` → `./diagnose/diagnose_push_rejection.sh` (usually: the branch
  is protected; unprotect, mirror, re-protect)
- `non-fast-forward` → `./diagnose/diagnose_gitlab_divergence.sh`
- `local changes … would be overwritten` → `./rescue_local_edits.sh`, then
  `./rescue_local_edits.sh --rescue`. Never delete the folder: the edits are lost for good.

Then in the GitLab UI: protect the default branch, push allowed for you only.

### 5. Install uv and point it at Artifactory

Get `<user>` and `<token>` from Artifactory's "Set Me Up" page
(`https://artifactory.idhs.ucl.ac.uk`). Put the credential in `~/.netrc` — the exact line is
at the top of `install_uv.sh`. Then:

```bash
./install_uv.sh --probe-package <build-backend>
```

`<build-backend>` is each repo's build backend (hatchling, setuptools, uv_build …) —
repeat `--probe-package` for each. The host and the PyPI remote (`pypi`) are UCL's
defaults; `--artifactory` / `--pypi-remote` override them.

PASS: `RESULT: PASS - the index works.`
FAIL: 401 → credential wrong or expired (it dies with every 90-day password change);
a backend fails → Artifactory has not mirrored it; ask for it to be mirrored.

### 6. Decide where the venv can live

```bash
./check_venv_location.sh --python '<python-path>'
./check_venv_location.sh --python '<python-path>' --candidate '/s/<share>/<workspace-dir>'
```

PASS: at least one location marked OK. Use it as `<workspace-dir>` in step 7.
- OK only on the clean PATH → add `--clean-path` in step 7.
- OK locally, FAIL on the share → put `<workspace-dir>` on local disk.
- FAIL everywhere → stop; the log has the detail.

### 7. Install the packages

```bash
./install_packages.sh --workspace '<workspace-dir>' --python '<python-path>'
```

(add `--clean-path` if step 6 said so)

PASS: `RESULT: PASS`.

FAIL, by what it names:
- a third-party package not found → Artifactory has not mirrored it. Write the name down.
- `DLL load failed … The parameter is incorrect` → back to step 6; then
  `./diagnose/diagnose_numpy_dll.sh --workspace '<workspace-dir>'` and
  `./diagnose/diagnose_import_chain.sh --workspace '<workspace-dir>'`
- `what is checked out is not what this payload carries` → read the lines above it:
  - `has local edits to tracked files` / `cannot fast-forward` / `pull --ff-only FAILED` →
    `./rescue_local_edits.sh --workspace '<workspace-dir>'`, then the same with `--rescue`,
    then step 7 again. Never delete the folder: the edits are lost for good.
  - `.bundle is not in the payload` (bundle mode) → the payload is incomplete;
    `./verify_payload.sh` says what is missing. Rebuild it outside.
  - *GitLab only:* otherwise, step 4 with `--refresh` first.
- `STUB FAILED, function OK` → step 8.

### 8. Console scripts (only if step 7 said STUB FAILED)

```bash
./make_console_wrappers.sh --workspace '<workspace-dir>'
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Call the scripts by name. Never `uv run <script>`. Other console-script failures:
`./diagnose/diagnose_console_scripts.sh --workspace '<workspace-dir>'`

### 9. Remember the answers

So every later refresh is a double-click, create `~/dsh-kit.env` with:

```
KIT_WORKSPACE_DIR="<workspace-dir>"
KIT_PYTHON="<python-path>"
```

(and `KIT_CLEAN_PATH="yes"` if step 6 needed it).

---

## Reminders

- `Q:` and `R:` are wiped 30 days after a file arrives. The payload lives in `~/DSH_import`.
- The VM reboots every Monday 00:00–02:00; a disconnected session dies after 18 h.
- Your DSH password expires every 90 days. After changing it: regenerate the Artifactory
  credential (step 5) and, *GitLab only*, run `./reset_gitlab_credential.sh`.
- The cluster, if this payload was built for it: finish this VM through step 2 (step 4 in
  GitLab mode) first, then copy the whole `~/DSH_import` folder — bundles included — to the
  cluster with WinSCP in **binary** mode and run there, in order:
  `bash ./verify_payload.sh`, `./probe_cluster.sh`, `./install_uv.sh …` (as step 5),
  `./install_packages.sh --python '<cluster-python-path>'`. Every later trip there:
  `bash ./update_dsh_cluster.sh --check`, then `bash ./update_dsh_cluster.sh`. In GitLab
  mode always after this VM has refreshed the mirror, never before; in bundle mode the
  copied folder is all it needs.
