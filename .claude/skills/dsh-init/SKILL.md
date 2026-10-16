---
name: dsh-init
description: Interview the user about their project and write dsh-kit.conf — which git repos to carry into the UCL Data Safe Haven, in what order, with which extras, installed as a plain venv or a uv workspace, straight from the bundles or through the DSH's internal GitLab, for the VM only or the VM and the cluster. Inspects each repo's pyproject.toml to propose every answer rather than asking blind, checks every repo is committed and pushed, and validates the result. Turns a folder of loose scripts or notebooks into a minimal git-tracked package first, if that is what the user has. Use when dsh-kit.conf does not exist yet, when setting this template up for a new project, when adding or removing a repo from what is carried in, or when asked to "set up dsh-kit", "configure dsh-kit", "init", or "which packages go into the DSH".
---

# dsh-init

Writes `dsh-kit.conf` at the root of this repo — the one file that says what this project
carries into the DSH and how it is installed there. Every script, outside and in, reads it;
nothing else in the repo names the user's packages. `dsh-kit.conf.example` documents every
key; read it first.

**One question at a time, in prose.** Inspect before asking, so each question arrives with a
proposed answer and the reason for it — "I found these three repos; `analysis` depends on
`core`, so `core` goes first. Right?" — and the user only has to confirm or correct. Do not
present option menus for open questions; propose, explain briefly, invite pushback.

If `dsh-kit.conf` already exists, read it, say what it currently says, and ask what is
changing rather than starting over.

## 1. The project name

`KIT_PROJECT`: a short name, used for the default cluster workspace (`~/Scratch/<name>`) and
in log headers. Propose the name of this repo's directory, or of the main package.

## 2. Which repos, and where they are checked out

Ask where the user's package repos are checked out on this machine. They must all be under
**one parent directory** — `KIT_REPOS_DIR`, relative to this repo's root (default `../`, i.e.
siblings of this repo). If they are scattered, say so and have the user move or re-clone
them under one parent; `export_bundles.sh --package <path>` handles a one-off, but
`build_payload.sh` exports `KIT_REPOS` from `KIT_REPOS_DIR` only.

List the candidate directories that are git repos with a `pyproject.toml`, and ask which
ones go in. If the user's code is loose scripts or notebooks instead (a folder that is not
a git repo, has no `pyproject.toml`, or both), it cannot be carried as it is. Offer to
scaffold it into a minimal package, following `references/loose-scripts.md`, and come back
here once it is committed and pushed. For each chosen repo, read its `pyproject.toml`:

- `[project] name` — note if it differs from the directory name; the **directory name** is
  what goes in `KIT_REPOS` (and, in GitLab mode, the GitLab project name inside).
- `[project] dependencies` — which of them are **other chosen repos** (first-party).
- `[project.optional-dependencies]` — the extras on offer.
- `[project.scripts]` — console scripts.
- `requires-python`.
- `[build-system] requires` — the build backend (hatchling, setuptools, uv_build, …).
- The import name: the package directory under `src/` (or at the root) holding
  `__init__.py`. Usually the project name with `-` → `_`, but not always.

Then propose, with reasons:

- **`KIT_REPOS`, base first.** Order by first-party dependencies: a repo comes after every
  repo it depends on. If there is a cycle, stop and say so — it cannot be installed.
  A first-party dependency that is *not* among the chosen repos is a problem: inside the DSH
  it will be looked up on Artifactory, where it does not exist. Ask whether to add it.
- **`KIT_EXTRAS`** — for each repo, which extras the work inside actually needs, written as
  `repo[extra1,extra2]`. Do not default to all of them: every extra is more third-party
  packages Artifactory must have mirrored, and a missing one is the likeliest reason for a
  second trip.
- **`KIT_PYTHON_SPEC`** — the intersection of every repo's `requires-python`. Mention that
  the DSH VM only has the interpreters it has; the probe will say which.
- **`KIT_IMPORT_CHECK`** — leave empty if every import name is the repo name with `-` → `_`;
  otherwise list the real import names.
- **`KIT_CONSOLE_SCRIPTS`** — the `[project.scripts]` names that matter inside (each must run
  `--help` cleanly). Optional; empty skips the smoke test.

Also note each repo's build backend for later: `install_uv.sh --probe-package <backend>`
should be given each one, so an unmirrored backend is caught before the install. Say this
to the user now; it goes into the dsh-setup procedure, not the conf.

## 3. Plain venv, or a uv workspace?

Ask it in these words: *inside the DSH, do you want a uv workspace, or a plain venv?* Then
explain the trade in two or three sentences, and propose based on what you saw:

- **`venv` (default).** One `.venv`, every repo installed editable in a single
  `uv pip install`, so the repos find each other locally. Nothing to maintain, and re-running
  only ever adds. Right for almost everyone.
- **`workspace`.** A root `pyproject.toml` listing every repo as a uv workspace member,
  synced with `uv sync --all-packages`, with a `uv.lock`. Right if the user already works in
  a uv workspace outside and wants the same shape and lockfile inside. A uv sync is exact:
  it removes anything the lock does not name, extras included.

Propose `workspace` only if you found evidence of one outside — a parent `pyproject.toml`
with `[tool.uv.workspace]` over these repos. In workspace mode the root is generated from
the conf; only if the user needs something the generated root cannot express (extra
`[tool.uv]` settings, constraint-dependencies) write a `pyproject.dsh.toml` beside the conf,
which is then carried and used verbatim. Never copy the outside workspace root in as-is —
its sources and paths describe this machine (see the dsh-setup skill's `cross-target.md`).

## 4. GitLab inside, or straight from the bundles?

Ask it in these words: *use the DSH's internal GitLab, or install straight from the
bundles?* Then give the honest trade in a few sentences and propose **bundles** unless
something below points the other way:

- **Bundles (`KIT_GITLAB="no"`, default).** Every box clones from the `.bundle` files in the
  payload and refreshes by fetching from the next payload's. Fewer steps on every trip, no
  GitLab project to create, no DSH credential to cache, nothing to go stale between the VM
  and GitLab. Commit SHAs still mean the same on both sides of the airlock. Right for one
  person working alone.
- **GitLab (`KIT_GITLAB="yes"`).** The VM first mirrors the bundles into GitLab projects, and
  every box clones from GitLab. Worth the extra step if **colleagues inside** will clone the
  same code, or if the user wants the cluster to install through **uv git sources** pinned
  to commits (`docs/git_install_route.md`) rather than from a copied payload folder.

Propose GitLab only if the user mentions other people inside, or the git-sources route.
Only when the answer is **yes**, ask:

- `KIT_GITLAB_HOST` — stays `gitlab.idhs.ucl.ac.uk` unless the user says otherwise.
- `KIT_GITLAB_GROUP` — the group (or the user's DSH username, for a personal namespace) the
  projects will live under. UCL recommends a group named with the 5-digit IG case
  reference, because a user-owned repo becomes unreachable if the account lapses. With
  `KIT_GITLAB="yes"` the conf will not load until this is filled in, so if the user does
  not know it yet, write `KIT_GITLAB="no"` for now and say that switching later is two
  lines in the conf and one rebuilt payload.

When the answer is **no**, leave the GitLab keys as the example has them; nothing reads
them.

## 5. Repos edited inside

Ask whether any repo will be **edited inside the DSH** — notebooks, run scripts, anything
saved as it is used. Those go in `KIT_WORKING_REPOS`. Explain the difference: a mirror is
read-only inside and an edit there blocks the next refresh; a working repo is overwritten by
the payload whenever the payload carries it, with the inside edits parked on a
`dsh-local/<stamp>` branch first. Usually empty. Must be a subset of `KIT_REPOS`.

In GitLab mode only, if there are working repos, ask whether they live in a different
GitLab namespace from the mirrors (commonly the user's personal one while mirrors sit in a
shared group) — `KIT_WORKING_NAMESPACE`, else empty.

## 6. Which boxes

`KIT_TARGETS`: `dsh-vm` (the Windows Desktop analysis VM — always needed, it is where the
payload lands) and optionally `dsh-cluster` (the Linux batch cluster). Ask whether they will
run batch jobs on the cluster; if not, `dsh-vm` alone keeps the payload smaller. In bundle
mode the cluster's payload carries the bundles too; in GitLab mode it clones from GitLab.

## 7. Write it, and validate

Write `dsh-kit.conf` in the format of `dsh-kit.conf.example`: plain `KEY="value"` lines, no
`$`, no backticks, no arrays — lists space-separated. Keep the example's comments above
each key; they are what the next reader has. Then validate it with the same parser the
scripts use:

```bash
bash -c '. src/carry/any/lib/dsh_conf.sh && dsh_load_conf dsh-kit.conf && echo "CONF OK: $KIT_REPOS"'
```

Any `unknown key`, `not KEY="value"`, or `must be` line is a fault — fix and re-run until it
prints `CONF OK`.

## 8. Check every repo will export

`export_bundles.sh` refuses, per repo: uncommitted changes to tracked files, a detached HEAD,
no `origin/<branch>`, and a HEAD that is not on origin. Check each now rather than at build
time:

```bash
git -C <repos-dir>/<repo> status --porcelain --untracked-files=no   # must print nothing
git -C <repos-dir>/<repo> rev-parse --abbrev-ref HEAD              # a branch, not HEAD
git -C <repos-dir>/<repo> fetch -q origin
git -C <repos-dir>/<repo> merge-base --is-ancestor HEAD origin/<branch> && echo pushed
```

For each failure say exactly what fixes it in that repo — commit or stash; check out the
branch; `git push -u origin <branch>`; push the commits — and do not offer
`--allow-unpushed` except for a throwaway test payload. The reason is worth one sentence: a
bundle of an unpushed commit becomes the tip inside (in GitLab or in the checkouts), and if
that commit is later rebased outside, every future refresh is a non-fast-forward that has
to be repaired by hand inside.

Then the dry run, into a scratch directory so it does not touch `DSH_import/`:

```bash
./src/workstation/export_bundles.sh --out <scratch-dir>
```

It writes one `.bundle` per repo and `MANIFEST.txt` (`repo  branch  sha  role`). Check the
roles are what step 4 decided.

## 9. Hand over

Tell the user, briefly: what they chose (including bundles or GitLab); the build backends to give
`install_uv.sh --probe-package`; that `dsh-kit.conf` belongs in git and should be committed
to this repo (it holds no path or credential, by design); and that the next step is
`/dsh-setup`, which builds the payload and walks the import.
