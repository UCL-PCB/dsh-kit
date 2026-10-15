# 0005 — GitLab-inside is optional; by default every box installs from the bundles

Status: Accepted

## Context

The tooling this kit grew out of routed every repo through the DSH's internal GitLab: the
Desktop VM pushed the carried bundles into GitLab projects (`mirror_to_gitlab.sh`), and every
box then cloned from GitLab. That made GitLab the one place inside where the code lived,
which pays off when several people inside clone the same history, and it is what makes the
cluster's pinned git-sources route possible (`docs/git_install_route.md`).

It also costs, on every project and every trip:

- a GitLab project per repo, created empty by hand before the first trip;
- a DSH credential cached for git, which rotates with the password every 90 days and fails
  as a silent denial when stale;
- a mirror step that can fail on its own — TLS backend, protected branches, a push declined
  by a hook, a mirror clone edited in place — before anything is installed;
- an ordering rule between boxes: the cluster must not refresh until the VM has mirrored.

For one person carrying a few repos in, none of that buys anything. The bundles already carry
real git history, and the commit SHAs in `MANIFEST.txt` mean the same on both sides of the
airlock whether the checkout came from GitLab or straight from the bundle.

## Decision

**`KIT_GITLAB` in `dsh-kit.conf`, `"no"` by default.**

- **`no` — bundle mode.** `install_packages.sh` clones each repo straight from
  `<repo>.bundle` in the payload, on the manifest's branch, and removes the `origin` the
  clone records (it points into a payload directory the next payload replaces). A refresh
  fetches the manifest's branch from the *current* payload's bundle into
  `refs/outside/<branch>` and fast-forwards to it; a mirror with tracked edits, or one that
  cannot fast-forward, is refused, exactly as a failed `git pull --ff-only` is in GitLab
  mode. Working repos are overwritten from the bundle with edits parked first, as before.
  `build_payload.sh` carries the bundles to the cluster as well, because they are its only
  source, and `verify_payload.sh` fails a payload missing a bundle for any repo in
  `KIT_REPOS`.
- **`yes` — GitLab mode.** Unchanged from before: the VM mirrors, every box clones from
  GitLab, and the git-sources route is available on the cluster.

The GitLab-only scripts (`mirror_to_gitlab.sh`, `reset_gitlab_credential.sh`,
`probe_gitlab_install_route.sh`, `install_git_route.sh`, `diagnose_gitlab_*.sh`,
`diagnose_push_rejection.sh`) are **still carried in bundle mode**. Each calls
`dsh_gitlab_only` after loading the conf and, in bundle mode, prints one line —
`KIT_GITLAB=no in dsh-kit.conf - <script> is not used; repos install from the bundles.` —
and exits 0. One payload layout for both modes is simpler to build, verify and reason about
than a conditional one, and a project can switch modes without the carried set changing
shape. Exit 0 rather than an error because nothing is wrong: there is nothing for the
script to do.

`dsh-init` asks the question directly — *use the DSH's internal GitLab, or install straight
from the bundles?* — and proposes bundles unless the user mentions colleagues inside or the
git-sources route.

## Consequences

- A bundle-mode project's first trip is two steps shorter (no GitLab projects, no mirror)
  and has no credential that expires.
- Inside, the code exists only in each box's workspace checkouts. A second person inside
  cannot clone it; switching to GitLab mode is two lines in the conf and a rebuilt payload.
- The cluster no longer depends on the VM having done anything but pass the payload folder
  across — and therefore the whole folder, bundles included, must be copied.
- `rescue_local_edits.sh` measures "ahead" against `refs/outside/<branch>` when a checkout
  has no `origin`, and is carried to both boxes, since a refused refresh can happen on either.
- `KIT_GITLAB_GROUP` must be filled in for the conf to load in GitLab mode, so a per-machine
  override of the group in `~/dsh-kit.env` cannot stand in for it there.
