# dsh-kit

Get your Python packages into the **UCL Data Safe Haven** and installed there — on the
Windows Desktop analysis VM, and optionally on the Linux batch cluster behind it — without
learning every way that goes wrong the hard way.

The DSH is air-gapped. Code goes in through a file-transfer airlock; the VM has no internet,
an Artifactory mirror instead of PyPI, an internal GitLab, TLS interception, SMB-mounted
drives that break Windows DLL loading, credentials that rotate every 90 days, and no way to
copy output back out. dsh-kit is the tooling and the accumulated knowledge for getting a
project's git repos across that gap and into a working `.venv`, verified at every step.

**Who it is for:** a researcher at UCL with one or more Python packages in git repos (a
`pyproject.toml` each, pushed to GitHub or similar) who needs them installed inside the DSH.
It is built to be driven with **Claude Code**: two skills interview you, build the payload,
and walk you through the import one step at a time. Every script also works by hand.

## Quickstart

1. **Use this template** on GitHub to make your own repo, and clone it on your workstation —
   ideally next to the repos you want to carry in (they must all sit under one parent
   directory).
2. Open Claude Code in it.
3. Run **`/dsh-init`**. It finds your repos, reads their `pyproject.toml`s, proposes the
   install order, extras and Python range, asks whether you want a plain venv or a uv
   workspace inside, and writes and validates `dsh-kit.conf`. Commit that file.
4. Run **`/dsh-setup`**. It builds the payload, tells you what to upload, and drives the
   install inside step by step. Inside the DSH, `RUNBOOK.md` in the payload is the same
   procedure on paper.

Without Claude: copy `dsh-kit.conf.example` to `dsh-kit.conf`, fill it in, run
`./src/workstation/build_payload.sh`, upload `DSH_upload/`, and follow `RUNBOOK.md` inside.

Needs, on the workstation: Git Bash (or PowerShell for the bundles alone), git, and the uv
release archives for the target platforms from <https://github.com/astral-sh/uv/releases>.

## The trip

```
OUTSIDE (your workstation)
  dsh-kit.conf ──► export_bundles.sh ──► build_payload.sh ──► DSH_upload/ ──► File Transfer Portal
                   git bundle per repo   scripts, conf, uv,                    (airlock)
                   + MANIFEST.txt        checksums, zip
                                                                                     │
INSIDE — Desktop VM (Windows, Git Bash)                                              ▼
  unpack_payload.sh ─► verify_payload.sh ─► probe_secure_env.sh ─► mirror_to_gitlab.sh
  ─► install_uv.sh ─► check_venv_location.sh ─► install_packages.sh ─► make_console_wrappers.sh
                                                  (clones from GitLab-inside,      (only if the
                                                   checks SHAs vs MANIFEST,         .exe launchers
                                                   installs, smoke-tests)           fail on SMB)
  every later trip:  update_dsh_vm.bat   (unpack ─► mirror --refresh ─► install)
                                                                                     │
INSIDE — batch cluster (Linux), payload folder copied over by WinSCP                 ▼
  verify_payload.sh ─► probe_cluster.sh ─► install_uv.sh ─► install_packages.sh
  every later trip:  update_dsh_cluster.sh --check, then update_dsh_cluster.sh
  optional:          probe_gitlab_install_route.sh ─► install_git_route.sh  (pinned git sources)
```

Every step writes `Logs/<script>.log` in the payload and ends with an explicit `PASS` or
`FAIL` that says what to do next. Every common failure has a `diagnose/` script.

## Plain venv or uv workspace

Set by `KIT_INSTALL_MODE` (`docs/adr/0004-venv-default-workspace-optional.md`):

- **`venv`** (default) — one `.venv`, every repo installed editable in a single
  `uv pip install`, so your repos resolve to each other rather than to Artifactory. Nothing
  else to write. Additive: re-running never removes anything.
- **`workspace`** — a uv workspace root generated from the conf (or your own
  `pyproject.dsh.toml`), synced with `uv sync --all-packages`, with a `uv.lock`. Pick it if you
  already work in a uv workspace outside. Exact sync: it removes what the lock does not name.

## Layout

| Path | What |
|---|---|
| `dsh-kit.conf` | **your project**: which repos, in what order, how installed, which GitLab group. The only file you edit |
| `dsh-kit.conf.example` | every key, documented |
| `src/workstation/` | outside: `export_bundles.sh` (and `.ps1`), `build_payload.sh` (and `.bat`) |
| `src/carry/any/` | carried to both boxes: `install_packages.sh`, `install_uv.sh`, `probe_gitlab_install_route.sh`, `lib/` |
| `src/carry/dsh-vm/` | carried to the VM: unpack, verify, probe, mirror, venv-location check, wrappers, refresh, `RUNBOOK.md` |
| `src/carry/dsh-cluster/` | carried to the cluster: probe, refresh, the git install route |
| `src/carry/diagnose/` | one script per failure already met: DLLs, git permissions, GitLab TLS, push rejections, console scripts |
| `src/lib/` | sourced by the workstation scripts |
| `.claude/skills/` | `dsh-init` and `dsh-setup`, including the distilled UCL DSH facts |
| `docs/` | ADRs and the git install route |
| `tests/` | the test harness |

Where a script lives decides which box it is carried to — there is no list
(`docs/adr/0001-the-directory-is-the-carry-target.md`). Per-machine values (workspace
directory, interpreter path) go in `~/dsh-kit.env` on that machine, never in the conf.

## Out of scope, deliberately

dsh-kit stops at "your packages are installed and import, on the VM and the cluster".
Submitting cluster jobs, moving input data in and carrying results out are specific to each
project. Build them in your own repo as new scripts under `src/carry/<group>/`; they are then
carried like everything else. `CLAUDE.md` says how, and how to keep pulling template updates
without conflicts.

## Testing

```bash
bash tests/run_tests.sh
```

Builds real bundles and payloads from fixture repos; no DSH, network or credential needed.
About 25 minutes in Git Bash on Windows, where every process fork is slow; much faster on
Linux. See `tests/README.md`.
