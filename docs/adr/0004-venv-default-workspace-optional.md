# 0004 — A plain venv by default; a uv workspace only when asked for

Status: Accepted

## Context

The install inside the DSH has one hard requirement: a project's first-party packages must
resolve to the checkouts cloned inside (from the bundles, or from GitLab-inside), never
to an index. They are not on
Artifactory, and if public PyPI were ever reachable a bare first-party name could resolve to
whatever someone uploaded under it.

The tooling this kit grew out of met that requirement with a **uv workspace**: a root
`pyproject.toml` listing every repo as a member, each mapped to `{ workspace = true }` in
`[tool.uv.sources]`, synced with `uv sync --all-packages`. That works, and suits a project
that already lives in a uv workspace outside. But most projects are one or a few repos with
an ordinary `pyproject.toml` each, and their authors have never written a workspace root.
Asking them to is asking them to learn a uv feature to get past an airlock.

A workspace also has sharp edges that cost real sessions:

- `uv sync` is an **exact** sync: it removes anything the lock does not name. A bare
  `uv sync`, or `uv run` (which syncs first), drops every extra not in the default set, and
  the symptom is an `ImportError` minutes later that says nothing about extras.
- The root is environment-specific and must never be copied between environments, so it
  has to be generated or hand-written per box.

## Decision

**`KIT_INSTALL_MODE="venv"` is the default.** `install_packages.sh` creates one `.venv` and
runs a **single** `uv pip install` naming every repo as an editable path (with its
`KIT_EXTRAS`). Because every first-party package is named in the same call, uv resolves a
dependency on one of them to the local path rather than looking it up on Artifactory. The
install is additive: re-running never removes anything.

**`KIT_INSTALL_MODE="workspace"` is opt-in**, offered by the `dsh-init` interview as "do you
want a uv workspace inside?". `install_packages.sh` then *generates* the root from the conf —
members `src/<repo>`, a `{ workspace = true }` source per repo, `package = false`,
`requires-python` from `KIT_PYTHON_SPEC`, the repos and their extras as dependencies — keeps
the previous root as `.bak`, and runs `uv sync --all-packages` (`--all-extras` on request). A
project that needs more than the generated root can express ships `pyproject.dsh.toml`
beside its conf, carried and used verbatim.

The cluster's optional git route (`install_git_route.sh`) is a third shape, pinned git
sources at the manifest's commits, and is independent of this choice.

## Consequences

- A new project gets a working install with no `pyproject.toml` of its own beyond the ones
  its repos already have.
- `venv` mode has no lockfile: two installs at different times may resolve different
  third-party versions. Projects that need reproducibility inside choose `workspace` (which
  produces `uv.lock` on the box) or the cluster git route.
- Because `venv` mode is additive, removing a dependency from a repo does not remove it from
  the venv. Delete `.venv` and re-run to get a clean one.
- In `workspace` mode, the console-script and import diagnoses warn about exact syncs, and
  the procedure says never to `uv run` on the VM.
