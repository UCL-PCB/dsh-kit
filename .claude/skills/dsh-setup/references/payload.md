# Building the airlock payload

Shared by `dsh-vm` and `dsh-cluster`. Runs **outside**, on the workstation, in Git Bash (or
PowerShell for the bundles alone). Nothing here needs a DSH session.

The payload is one directory, `<repo>/DSH_import/` (beside `dsh-kit.conf`), holding a git
bundle per repo in `KIT_REPOS`, `MANIFEST.txt`, `dsh-kit.conf`, every script the targets
need, `RUNBOOK.md`, the uv binary for each target platform, and a `SHA256SUMS.txt` over all
of it. For the portal route it is also packed into `DSH_import.zip`, and the folder that
actually goes through the airlock is staged as `<repo>/DSH_upload/`.

## Before the first build

- `dsh-kit.conf` exists and `KIT_REPOS` is right. If not, `/dsh-init`.
- Every repo in `KIT_REPOS` is **committed and pushed**. `export_bundles.sh` refuses a dirty
  tracked tree (the SHA in `MANIFEST.txt` would be a lie), a detached HEAD, a branch with no
  `origin/<branch>`, and a commit not on origin. The last one is deliberate: a bundle of an
  unpushed commit becomes GitLab's tip inside; if that commit is later rebased or amended
  outside, the next refresh is a non-fast-forward that only a force-push inside can fix.
  The fix is always to commit/push in that repo, not to force it. `--allow-unpushed` exists
  for a throwaway test payload only.
- The uv release assets are on disk: `uv-x86_64-pc-windows-msvc.zip` for `dsh-vm`,
  `uv-x86_64-unknown-linux-gnu.tar.gz` for `dsh-cluster`, from
  <https://github.com/astral-sh/uv/releases>. Put them in `DSH_import/` or pass `--uv-dir`.

## Is a rebuild needed at all?

Ask before rebuilding. A payload already on disk is often still current, and rebuilding
changes the zip hash, which invalidates anything already uploaded.

Rebuild when: a repo has new commits to carry in; a script under `src/carry/` changed;
`dsh-kit.conf` changed; or the payload directory is missing or incomplete. Do not rebuild
merely because a session started.

## One command

```bash
./src/workstation/build_payload.sh
```

That runs `export_bundles.sh`, copies in the `src/carry/` files the targets need plus
`dsh-kit.conf`, checks the uv assets are present, strips CRLF, writes `PAYLOAD_CONTENTS.txt`
and `SHA256SUMS.txt`, builds the zip and its sidecar hash, stages `DSH_upload/`, and prints
what to upload. Its own log goes to `DSH_import/Logs/build_payload.log`. Flags:

| Flag | When |
|---|---|
| `--target NAME` | `dsh` (both boxes, one trip), `dsh-vm`, `dsh-cluster`. Default from `KIT_TARGETS` |
| `--no-bundles` | scripts or conf changed but no repo did — much faster. Dies if `MANIFEST.txt` does not list every `KIT_REPOS` entry |
| `--no-zip` | FTPS route; send the directory loose instead |
| `--prune` | remove files in `DSH_import/` that the build no longer carries |
| `--conf PATH` | a conf other than `<repo>/dsh-kit.conf` (also `$DSH_KIT_CONF`) |
| `--out DIR` | build somewhere other than `<conf dir>/DSH_import` |
| `--uv-dir DIR` | the uv assets live somewhere else and need copying in |

`export_bundles.sh` can also be run alone, e.g. to check what would be bundled:
`./src/workstation/export_bundles.sh --out <scratch-dir>`. On a machine without Git Bash,
`export_bundles.ps1 -Out <dir>` reads the same conf by the same rule and behaves the same.

## What defines a payload

**The tree under `src/carry/`.** One directory per group of boxes, and everything in it is
carried to those boxes:

| Directory | Goes to |
|---|---|
| `src/carry/any/` | both boxes |
| `src/carry/dsh-vm/` | the analysis VM |
| `src/carry/dsh-cluster/` | the batch cluster behind it |
| `src/carry/diagnose/<group>/` | diagnosis, carried to that group |
| `src/carry/<group>/lib/` | sourced-only libraries, carried to that group |

**Adding a script to the payload means putting it in the right directory** — there is no
array to update, which is the point (`docs/adr/0001-the-directory-is-the-carry-target.md`).

The payload lands in three places: `lib/` for what is sourced, `diagnose/` for what is run
when something is wrong, the top level for the procedure's steps. Two carried files may never
share a basename even so; the build refuses rather than letting one overwrite the other.

Besides the carried scripts, the payload root holds what is the **project's** rather than the
kit's: `dsh-kit.conf` (verbatim), and `pyproject.dsh.toml` / `pyproject.dsh-cluster.toml` if
they sit beside the conf — hand-written workspace roots used instead of the generated one
when `KIT_INSTALL_MODE=workspace`.

`MANIFEST.txt` records, per repo, `repo  branch  sha  role`. Role is `working` for repos in
`KIT_WORKING_REPOS`, `mirror` otherwise. Everything inside is driven off it: the mirror pushes
what it lists, the install asserts every mirror clone's HEAD against it.

`PAYLOAD_CONTENTS.txt` names the target and every file with the path it landed at;
`verify_payload.sh` checks against that rather than a list compiled into itself.

## The upload folder

`<repo>/DSH_upload/` is rebuilt from empty by every run, and is what goes through the portal:

```
DSH_import.zip
DSH_import.zip.sha256
unpack_payload.sh
update_dsh_vm.sh
update_dsh_vm.bat
lib/dsh_log.sh  lib/dsh_platform.sh  lib/dsh_conf.sh
READ_ME_FIRST.txt
```

The unpackers and their `lib/` travel *beside* the zip as well as inside it: a copy inside a
zip cannot unpack that zip. Do not describe any of it as optional — an upload without them
strands the operator with a zip and no scripted way to open it. The portal flattens nothing,
but tell the operator to upload `lib/` as a folder.

The sidecar hash sits **beside** the zip, never inside. It guards only the transfer of the
zip; the contents are covered by `SHA256SUMS.txt`, which `verify_payload.sh` checks on the
far side.

**Give the operator the new hash** whenever the payload is rebuilt, and say plainly that any
previously quoted hash is now stale. `build_payload.sh` prints it at the end, and
`READ_ME_FIRST.txt` carries it.

## Which route

- **Portal** (`https://filetransfer.idhs.ucl.ac.uk`): the `DSH_upload/` folder. The route
  this payload is built for.
- **FTPS**: UCL recommends it above 10 files or 100 GB. Build with `--no-zip` and send
  `DSH_import/` in **binary mode** — a text-mode transfer rewrites LF to CRLF and corrupts the
  bundles and the uv archives beyond repair. `verify_payload.sh` detects this and says so.

Either way the files land in `Q:\<username>`, which is wiped 30 days after arrival.
