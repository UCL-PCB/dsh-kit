# CLAUDE.md

Guidance for Claude Code in a repo made from the **dsh-kit** template: tooling that carries a
project's Python packages through the UCL Data Safe Haven (DSH) airlock and installs them on
the Windows Desktop analysis VM and, optionally, the Linux batch cluster behind it.

**Two skills do the work. Invoke them rather than reconstructing their content here.**

- **`/dsh-init`** — interviews the user and writes `dsh-kit.conf`. Run it first, and whenever
  the set of repos carried in changes.
- **`/dsh-setup`** — builds the payload and drives the import on either box, step by step,
  with the UCL DSH facts and the failure modes already met. If `dsh-kit.conf` is missing it
  sends you to `/dsh-init`.

What follows are the rules that apply whenever this repo is in context, skill or no skill.

## The VM is air-gapped

The DSH Desktop VM has no internet access and cannot reach Claude; the cluster is reachable
only from the VM. Nothing run there can be observed. Every interaction is: hand the user
something to run, they run it by hand, they bring the result back out — by reading it, not
by copying it.

- **Never ask for output to be pasted back.** Copy/paste out of the DSH is blocked; the ask
  is impossible, not just tedious. Every carried script writes `Logs/<script>.log` in the
  payload and ends with an explicit `PASS`/`FAIL` line. Name the log, say what a pass looks
  like, ask "pass or fail?".
- **One step at a time.** One command, what a pass looks like, then stop. A queued step 3 has
  already been run by the time step 2 shows it should have been different.
- **Placeholders, not guesses.** Anything environment-specific — `<workspace-dir>`, `<group>`,
  `<username>`, `<pypi-remote>` — is written as a placeholder for the user to fill. Do not
  invent a plausible default; inside, a wrong path costs a round trip. The UCL hostnames in
  `.claude/skills/dsh-setup/references/dsh-facts.md` are the exception.
- **Long commands become scripts.** Anything over one line or ~30 characters is written as a
  script under `src/carry/`, carried in the payload, and run by name — the user would
  otherwise retype it by hand inside. One-off mid-session scripts can travel alone through
  the portal and run with `./q.sh <name>`.

## The directory is the carry target

`src/` is grouped by destination, and the directory is the **only** statement of that.
`build_payload.sh` reads the tree; there is no list to keep in step
(`docs/adr/0001-the-directory-is-the-carry-target.md`).

| Directory | Goes to |
|---|---|
| `src/workstation/` | nowhere — runs on this machine |
| `src/lib/` | nowhere — sourced by the workstation scripts |
| `src/carry/any/` | both DSH boxes |
| `src/carry/dsh-vm/` | the Windows analysis VM |
| `src/carry/dsh-cluster/` | the Linux batch cluster |
| `src/carry/diagnose/<group>/` | diagnosis, carried to that group; lands in `diagnose/` |
| `src/carry/<group>/lib/` | sourced-only libraries; land in `lib/` |

Put a file in the wrong one and it goes to the wrong box, or none. Two carried files may never
share a basename; the build refuses. Every carried script sources `lib/dsh_log.sh` and calls
`dsh_start_log "$@"` near the top, and keeps `set -o pipefail`.

## The conf contract

`dsh-kit.conf` at the repo root is the **one** place the project's packages are named
(`docs/adr/0003-config-is-parsed-not-sourced.md`). Every script, outside and inside, reads it;
`build_payload.sh` carries it verbatim. `dsh-kit.conf.example` documents every key.

- Plain `KIT_NAME="value"` lines. **Parsed, never sourced**: no `$`, no backticks, no arrays —
  lists are space-separated. Unknown keys and malformed lines are reported and ignored.
- It describes **the project**, so it is committed and identical everywhere. It holds no
  machine path and no credential.
- New keys go in `DSH_CONF_KEYS` in `src/carry/any/lib/dsh_conf.sh` *and* in the reader in
  `src/workstation/export_bundles.ps1`.
- Validate after any edit:
  `bash -c '. src/carry/any/lib/dsh_conf.sh && dsh_load_conf dsh-kit.conf && echo OK'`

## Where per-machine values go

What describes **a machine** — the workspace directory, the interpreter path, where the
payload unpacks — goes in `~/dsh-kit.env` **on that machine**, same `KEY="value"` format,
parsed the same way, never carried: `KIT_WORKSPACE_DIR`, `KIT_PYTHON`, `KIT_PAYLOAD_DIR`,
`KIT_ZIP`, `KIT_CLEAN_PATH`, plus (GitLab mode) per-machine overrides of `KIT_GITLAB_HOST`,
`KIT_GITLAB_GROUP`, `KIT_WORKING_NAMESPACE`. Precedence: flag > `~/dsh-kit.env` > conf.

## GitLab is optional

`KIT_GITLAB` in the conf (`docs/adr/0005-gitlab-is-optional.md`). `no`, the default, is
**bundle mode**: every box clones from the payload's `.bundle` files and refreshes from the
next payload's, and there is no mirror step, GitLab project or credential. `yes` routes the
repos through GitLab-inside: the VM mirrors the bundles there and every box clones from it.
A script that only means anything in GitLab mode calls `dsh_gitlab_only` right after
`dsh_kit_settings` and exits 0 with one "not used" line in bundle mode; keep new
GitLab-only scripts to that pattern rather than carrying them conditionally. Never call
`dsh_repo_remote` in a code path bundle mode reaches.

Never carry a config that holds an absolute path or a credential from one machine to
another. Generate it on the target. A Windows path carried to the Linux cluster does not
error — a backslash is a legal filename character there — it silently writes to the wrong
tree.

## Your project's scripts go in your tree, not in the kit's

This repo is a copy of the template, and the template will keep improving. To keep pulling
those improvements without conflicts:

- **Do not edit the kit's own scripts for project needs.** If the kit cannot express something
  your project needs, that is a missing conf key or a template bug — raise it upstream.
- **Put project-specific scripts in new files** under `src/carry/<group>/` (jobs to submit on
  the cluster, a config generator, a data check). They are carried with no other change. Give
  them distinctive names so they never collide with a kit script's basename.
- Running batch jobs and carrying outputs back are deliberately **not** in the kit. Build them
  here, following `.claude/skills/dsh-setup/references/cross-target.md`.

## Pulling template updates

```bash
git remote add template <template-repo-url>      # once
git fetch template
git merge template/main --allow-unrelated-histories   # first time only
git merge template/main                               # every time after
```

A repo made with GitHub's "Use this template" button has no shared history with the template,
hence `--allow-unrelated-histories` the first time. Conflicts should only ever be in files you
were told not to edit; resolve them in the template's favour, then re-apply your change as a
new file. After merging, rebuild the payload so the new scripts are what is carried.

## Testing

```bash
bash tests/run_tests.sh                          # everything, ~25 min in Git Bash on Windows
bash tests/run_tests.sh tests/test_conf.sh       # one file
```

No DSH, no network, no credential needed: the tests build real payloads from fixture repos.
A copy of the output lands in `tests/last_run.log`. `bash -n` every script you touch.
