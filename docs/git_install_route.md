# Installing from git instead of cloning — the cluster's optional route

Both DSH boxes can reach GitLab-inside, and once the Desktop VM has mirrored the bundles there
it holds every repo in `KIT_REPOS` at the commits `MANIFEST.txt` records. On the cluster that
opens a second way to install: instead of cloning each repo into `src/` and installing it
editable (`install_packages.sh`), let **uv** fetch each one as a **pinned git source** —
`install_git_route.sh`.

## What it is

One file decides it: the workspace root's `[tool.uv.sources]`. In the clone route each repo is
`{ workspace = true }` (or an editable path, in `venv` mode). In the git route each is

```toml
[tool.uv.sources]
my-library  = { git = "https://gitlab.idhs.ucl.ac.uk/<group>/my-library.git",  rev = "<sha from MANIFEST.txt>" }
my-analysis = { git = "https://gitlab.idhs.ucl.ac.uk/<group>/my-analysis.git", rev = "<sha from MANIFEST.txt>" }
```

`install_git_route.sh` generates that root from `dsh-kit.conf` and `MANIFEST.txt` — every
`KIT_REPOS` entry as a dependency with its `KIT_EXTRAS`, each pinned to its manifest commit —
or uses `pyproject.dsh-cluster.toml` from the payload instead, with `<group>` substituted.
The repos themselves change nothing.

**`[tool.uv.sources]` is not transitive**, which is why every repo is listed, including ones
nothing asks for directly. A source entry applies to the requirements of *the project that
declares it*. A package that arrives from git carries its own metadata, and uv does not
re-point that package's dependencies through the root's table — so a root naming only the top
repo clones it, reads its bare requirement on the base repo, finds no source in scope, looks
on Artifactory and fails with `not found in the package registry`. Listing every first-party
repo in the root gives each name a source and a node, and the bare requirements resolve
against it.

## What it costs

1. **No editable installs.** A git source is a snapshot. The loop stops being "edit the file,
   the venv already sees it" and becomes *commit outside → new payload → mirror → re-run*. On a
   box you are actively debugging on, that is the whole difference.
2. **A stored credential.** uv shells out to git and cannot answer a password prompt.
3. **The lock is made on the box.** `uv lock` needs GitLab-inside, so `uv.lock` is generated on
   the cluster and, like the root, is never carried anywhere.
4. **`uv lock` resolves every declared extra.** Extras the cluster never runs are not free —
   they are resolved on every lock. Keep `KIT_EXTRAS` to what jobs need.

Point 1 decides it. The git route is right for *installing a known-good state* that batch jobs
run against — nothing can be edited or fast-forwarded under a running job. The clone route is
right while you are still changing that state on the box. Nothing forces a choice: keep both,
in two directories.

## Measure first — `probe_gitlab_install_route.sh`

The assumption is that the cluster can *clone* from GitLab-inside, not merely reach it. The
probe measures it, read-only (it clones to a temp directory and deletes it, writes no git
config, pushes nothing), and answers four questions separately because they fail for different
reasons: does the host answer, can git *read* each repo, can git *clone* one (reading refs is
not fetching a pack), and can **uv** resolve a git source — its own question, because uv has
its own git client and CA store. It ends with a verdict line.

The gate is almost always the **credential**, not reachability. The probe sets
`GIT_TERMINAL_PROMPT=0`, so a missing credential returns
`could not read Username … terminal prompts disabled` rather than hanging — that message is the
probe working. The fix:

- A GitLab token with **`Repository > Code (Download)`** — DSH GitLab uses the granular token UI;
  this is not the classic `read_repository` scope, and emphatically not `api`. Nothing needs
  write access.
- Stored with `git config --global credential.helper 'store --file ~/.git-credentials'` and a
  line `https://<user>:<token>@gitlab.idhs.ucl.ac.uk` in `~/.git-credentials` (`chmod 600`).
  That is a live token in plaintext; an expired one fails as a `uv lock` auth error weeks after
  anyone last touched this. Note its expiry somewhere you will see it.

A hand-copied probe arrives without its executable bit — a bare `Permission denied` with no log
beside the script is that, not git. Run it with `bash ./…`.

## Installing — `install_git_route.sh`

```bash
./install_git_route.sh --workspace '<new-workspace-dir>' --dry-run
./install_git_route.sh --workspace '<new-workspace-dir>'
```

**It builds a second workspace and refuses to convert the first.** If `--workspace` holds a
clone-route workspace it stops: overwriting that root would leave clones on disk, unreferenced
and stale, while uv resolved the same names from GitLab — two sources of truth for one package.
It refuses on Windows outright; `--workspace` never defaults.

Its checks, each answering something a green `uv sync` does not:

| Question | Why a sync alone does not answer it |
|---|---|
| Is there a usable credential? | Run non-interactively, so "no credential" is a result rather than a batch shell waiting for a username. |
| Do the packages import? | Per-module errors, kept only on failure. |
| Is anything **editable**? | A git source must land in `site-packages`. An editable install shadowing it means the code running is not the pinned commit. |
| Do the entry points resolve? | Through `importlib.metadata`, not off `PATH` — `PATH` may still hold the clone-route venv's copies. |
| Did uv pin **the payload's** commits? | A mismatch means GitLab was never refreshed from this payload, and the venv is built from older code that imports cleanly and quietly behaves like the last trip. |

Re-running after a new payload rewrites the root to the new commits and re-syncs: that is the
update path.

## What does not change

- **Artifactory still supplies every third-party package**, with credentials in `~/.netrc`
  and `native-tls` set in uv's config.
- **The Desktop VM still needs the bundles**, because it is where the mirror is pushed *from*.
  The git route removes cloning from the *cluster*, not bundles from the payload.
- **`GIT_CEILING_DIRECTORIES`** must still be set on the Desktop VM, or every git command fails
  as "permission denied" and looks exactly like GitLab refusing you.
