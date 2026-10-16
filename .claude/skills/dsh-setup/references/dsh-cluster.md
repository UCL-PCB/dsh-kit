# Target: the DSH Linux batch cluster login node

`cluster.idhs.ucl.ac.uk`, Linux, Son of Grid Engine. **Reachable only from inside the DSH
Desktop VM** — there is no path to it from outside, and none from here. Read
`ground-rules.md` first.

Do `desktop-vm.md` before this one, through step 2 at least (step 4 in GitLab mode): the
payload reaches the cluster by WinSCP from the Desktop. Where the code comes from is
`KIT_GITLAB` in the conf:

- **bundle mode** (`no`, the default) — from the `.bundle` files in the payload folder,
  exactly as on the VM. A cluster payload carries the bundles in this mode, and nothing
  here depends on the VM having done anything but pass the folder across.
- **GitLab mode** (`yes`) — by cloning from the GitLab mirror the VM's step 4 populated. The
  cluster is a **reader** of that mirror and never pushes to it.

Everything in `desktop-vm.md` applies except where listed below. The scripts detect the
platform themselves (`lib/dsh_platform.sh`) and pick the right asset and paths, so the
commands read the same on both boxes.

| | Cluster |
|---|---|
| uv asset | `uv-x86_64-unknown-linux-gnu.tar.gz` |
| uv config | `~/.config/uv/uv.toml` |
| venv python | `.venv/bin/python` |
| scheduler | SGE — probe a compute node (step 3) |
| workspace default | `~/Scratch/<KIT_PROJECT>` — no SMB problem, so the venv-location step is optional |
| per-machine settings | `~/dsh-kit.env` on the cluster — its own file, not the VM's |

The payload must have been built for the cluster: `KIT_TARGETS` includes `dsh-cluster`, or
`build_payload.sh --target dsh`. A `dsh-vm`-only payload has no Linux uv and no cluster
scripts.

## Getting the payload there

Two routes, and they answer different needs:

- **Code**: in bundle mode, the bundles inside the payload folder below. In GitLab mode,
  cloned from `gitlab.idhs.ucl.ac.uk`, reachable from both boxes and the sanctioned way to
  move code between them. `install_packages.sh` does either.
- **The payload itself** (scripts, conf, manifest, uv, and in bundle mode the bundles):
  **WinSCP** from the Desktop VM, the whole `~/DSH_import` folder. There is no portal route to the cluster, and scripted SSH from
  the VM is closed by site policy (`docs/adr/0002-…`).

**Binary mode, and CRLF is the documented trap.** A file edited in Notepad on the Desktop and
copied in text mode breaks in ways that look like anything but a line-ending problem.
`unpack_payload.sh` and `verify_payload.sh` both detect and repair it; for a single
hand-copied file, `sed -i 's/\r$//' <file>` is the fix. A hand-copied script also arrives
without its executable bit — `bash ./<script>`, or `chmod +x`.

In bundle mode the `.bundle` files **must** travel — they are the only source, and
`verify_payload.sh` fails without them. In GitLab mode they matter only if a working repo is
being refreshed, but copying the whole folder is simplest either way. What must be current
is `MANIFEST.txt`: the install asserts every mirror clone against it.

## Step 1 — verify

```bash
cd ~/DSH_import && bash ./verify_payload.sh
```

Expect `platform linux`. None of the drive-letter warnings apply. If a zip came over instead
of a folder, `bash ./unpack_payload.sh` as on the VM.

## Step 2 — probe the login node

```bash
./probe_cluster.sh --gitlab gitlab.idhs.ucl.ac.uk --artifactory artifactory.idhs.ucl.ac.uk
```

(In bundle mode GitLab reachability is not needed; its line is informational.)

Expect a **scheduler**: the UCL FAQ documents Son of Grid Engine, so `qsub`/`qstat`. Finding
Slurm means job scripts need rewriting rather than repointing; record it. It also reports
the Python available (`module avail python` may be needed — note the module name) and prints
the exact submit line for step 3. Log: `Logs/probe_cluster.log`.

## Step 3 — probe a compute node

**This is the step the Desktop VM does not have.** Submit the same file. Grid Engine — note
the two flags the main documentation omits:

```bash
export DSH_GITLAB_HOST=gitlab.idhs.ucl.ac.uk DSH_ARTIFACTORY_HOST=artifactory.idhs.ucl.ac.uk
qsub -V -cwd -t 1-2 -o probe_out.txt -e probe_err.txt probe_cluster.sh
```

`-V` ships the environment to the job; without it the host variables arrive unset and the
network section silently self-skips. `-cwd` runs the job in the submission directory; without
it the output lands in `$HOME`, where nobody is looking.

The probe deliberately requests no memory or tmpfs resource — resource names are site-defined,
and an unknown one fails submission with `unknown resource`. `qconf` is an admin command and
may be refused (`denied: … is no admin host`); `qhost -F` / `qstat -F` are ordinary user
commands that list the complex names. Do not read a refused `qconf -sc` as "no resources".

**What matters in `probe_out*.txt`:**

- **`$TMPDIR` set, writable, has room** — where a job should do its scratch work.
- **`$HOME` / Scratch visible from the compute node** — the workspace and venv live there.
- **Which array variable is set** — `SGE_TASK_ID` or `SLURM_ARRAY_TASK_ID`.
- **Network from the compute node** — often closed even when the login node is open. That is
  expected: all installing happens on the login node and jobs only *use* the venv. Say so
  rather than treating it as a fault.

Plan job sizes around the documented limits: 48 h, `-pe smp <n>` with n ≤ 16, `-l gpu=1`, no
MPI, 50 GB home quota. Drained of batch jobs before the monthly patch.

## Step 4 — install uv

```bash
./install_uv.sh
```

Differences from the VM:

- It unpacks the **linux-gnu** tarball and writes `~/.config/uv/uv.toml`.
- **`native-tls` matters here too.** The DSH intercepts TLS on both boxes, and uv's bundled
  CA store rejects it as `invalid peer certificate: UnknownIssuer` while `curl` against the
  same URL returns 200. It is on by default on both platforms.
- **Artifactory needs credentials, and the cluster has none of the VM's.** Put the "Set Me
  Up" credential in `~/.netrc` (`chmod 600`) rather than in `--index-url`. A `curl -u`
  returning 200 beside a failing uv proves the credential is good and the fault is uv's —
  curl reads the system CA store and sends auth preemptively; uv does neither.
- Probe the build backends with `--probe-package`, exactly as on the VM.

## Step 5 — install the packages

```bash
./install_packages.sh --python '<full-path-to-python>'
```

`--workspace` defaults to `~/Scratch/<KIT_PROJECT>` here; pass it if the jobs expect the venv
somewhere else. `check_venv_location.sh` is optional: Scratch is not SMB and there is no
Anaconda-on-PATH problem. If Python comes from a module, `module load` it first and pass
the interpreter's full path — and remember that jobs must `module load` the same module
before using the venv, because the venv's interpreter links against the module's libpython.

Same modes, same pass line, same diagnosis as `desktop-vm.md` step 7. Same CRLF and
backslash cautions for anything that came from the VM (`cross-target.md`).

GitLab mode only: if SSH keys are wanted for GitLab from here, **2048-bit RSA only, ED25519
is not supported.** An https credential stored by git works too, and is what uv needs for the
git route below.

## Every trip after the first

```bash
bash ./update_dsh_cluster.sh --check     # change nothing, report what is behind
bash ./update_dsh_cluster.sh             # unpack if a zip is here, then install
```

In bundle mode: WinSCP the new payload folder over, then this. The bundles in it are the
source; nothing on the VM has to run first.

In GitLab mode **order matters across the two boxes**: `update_dsh_vm.bat` on the VM first
(that is what pushes the new commits to GitLab), then WinSCP the payload over, then this.
Running it before the VM has mirrored gets a clean fast-forward to the *old* commit and a
MANIFEST mismatch, which the install reports as a FAIL rather than installing it.

`--check` compares three things per repo — what is checked out here, what the manifest says,
and the source's tip (the bundle's in bundle mode, GitLab's in GitLab mode) — and names which
is behind. Run it before submitting a job rather
than discovering a stale install partway into one. Settings come from the cluster's own
`~/dsh-kit.env` (`KIT_WORKSPACE_DIR`, `KIT_PYTHON`).

## Optional: the git install route (GitLab-only)

Needs `KIT_GITLAB="yes"`; in bundle mode both scripts below print "not used" and exit 0. An
alternative for the cluster only: let uv fetch each repo straight from GitLab-inside as a
**pinned git source**, at the exact commit `MANIFEST.txt` records, instead of editable clones.
A batch job then runs one known commit, and nothing can be edited or fast-forwarded under a
running job. The cost is that nothing is editable — new code arrives as a new payload. The
full reasoning is `docs/git_install_route.md`.

First measure that it can work (read-only; clones to a temp dir and deletes it):

```bash
./probe_gitlab_install_route.sh
```

The gate is almost always a **stored credential**: uv cannot answer a password prompt. The
probe runs with `GIT_TERMINAL_PROMPT=0`, so `terminal prompts disabled` is the probe working,
and the fix is a GitLab token with `Repository > Code (Download)` (granular UI — not `api`)
in `~/.git-credentials` (`chmod 600`) via
`git config --global credential.helper 'store --file ~/.git-credentials'`. That file holds a
live token in plaintext, and an expired one fails as a `uv lock` auth error weeks later.

Then, into a **new** directory — it refuses one that already holds a clone-route workspace:

```bash
./install_git_route.sh --workspace '<new-workspace-dir>' --dry-run
./install_git_route.sh --workspace '<new-workspace-dir>'
```

**Pass:** `PASS - the git route is installed and pinned to the payload's commits.` It also
checks nothing is editable and that the entry points resolve. Re-run after each new payload
to move to the new commits. Keep the clone-route workspace too: it stays the place to debug.

## Getting results out

Files **cannot leave the cluster directly** — WinSCP to the Desktop, copy to `R:`, download
from the portal, and retrieving from `R:` needs outbound rights.

## Running jobs — not covered

dsh-kit stops at "the packages import and the console scripts run" on the cluster. Submitting
jobs, carrying inputs and collecting outputs are project-specific; build them in your own
repo under `src/carry/dsh-cluster/` (see the template's `CLAUDE.md`), following the rules in
`cross-target.md` — in particular, one task before the fleet.
