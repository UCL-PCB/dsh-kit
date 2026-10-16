---
name: dsh-setup
description: Get this project's Python packages into the UCL Data Safe Haven and installed there — the Windows Desktop analysis VM, and optionally the Linux batch cluster behind it. Builds and verifies the airlock payload outside, then drives the operator through unpack, verify, (optionally) the GitLab mirror, uv, venv location and install inside, one step at a time, knowing the failure modes each box has already produced. Use when asked to set up, import into, provision, refresh, rebuild or re-verify the DSH VM or DSH cluster, to build a DSH_import payload, or when something inside the DSH fails to install or import.
---

# dsh-setup

Two places this project's packages get installed, both behind the DSH airlock. They are not
variations on one procedure — different operating systems, different transports, different
failure modes:

| Target | What it is | Reference |
|---|---|---|
| `dsh-vm` | UCL DSH **Windows** Desktop analysis VM, driven from Git Bash, behind the airlock | `references/desktop-vm.md` |
| `dsh-cluster` | UCL DSH **Linux** batch cluster login node, reached only from the Desktop VM | `references/dsh-cluster.md` |

Building the thing that crosses the airlock is its own job, shared by both:
`references/payload.md`. `references/cross-target.md` holds what is true of both.

The per-target files are the whole procedure for that target; this file only routes. Keep
it that way — a rule that holds everywhere belongs in `cross-target.md` or
`ground-rules.md`, not restated in two places where one copy goes stale.

## Start here

0. **Is there a `dsh-kit.conf` at the repo root?** If not, stop and run `/dsh-init` first.
   Every script reads it; nothing here works without it, and guessing its contents is how
   the wrong repos get carried in. If there is one, read it — `KIT_REPOS`,
   `KIT_INSTALL_MODE`, `KIT_TARGETS` and **`KIT_GITLAB`** decide most of what follows.
   `KIT_GITLAB="no"` (the default, "bundle mode") means every box installs straight from
   the payload's bundles: **skip every step marked GitLab-only** in the references — the
   mirror, the GitLab credential, the GitLab project, the git install route. Those scripts
   print one "not used" line and exit 0 if run anyway. `KIT_GITLAB="yes"` means the VM
   mirrors the bundles into `KIT_GITLAB_GROUP` and every box clones from GitLab.
1. **Establish the target.** If the request does not say, ask — do not infer it from the
   working directory. The VM always comes first: the cluster is reached from it (the
   payload folder is copied across from it) and, in GitLab mode, reads the mirror the VM
   pushes.
2. **Read `references/cross-target.md`** — always. Config that is generated versus config
   that is copied, and how to keep a check from passing for the wrong reason.
3. **Read `references/ground-rules.md`** before issuing a single command. It is short, and
   it is the difference between this working and this wasting a VM session.
4. **Read the target's reference file**, then work through it.

Paths written `src/…` and `docs/…` are relative to this repo's root.

`references/dsh-facts.md` is the UCL DSH User Guide & FAQs distilled — hostnames, drive
roles, quotas, lockouts, maintenance windows. Consult it when a step involves a host, a
drive letter, or a limit. Do not answer questions about DSH behaviour from memory when
that file is right there.

## How to drive it

The operator runs everything inside; this skill never touches the target machine, and
cannot — there is no network path to either box.

**One step at a time, and wait.** Give one command, say what a pass looks like, stop. Do
not queue three steps in one message: when step 2 changes what step 3 should be, a queued
step 3 has already been run.

**Never ask for output to be pasted back** from a DSH box. Copy/paste out of the walled
garden is blocked, so the request is not merely inconvenient, it is impossible. Every
script writes its own log under `Logs/` in the payload for exactly this reason. Ask "pass or
fail?" and work from what the operator volunteers.

**Anything over one line becomes a script**, carried through the airlock, not typed into
chat. See `references/ground-rules.md`.

**Track where you are.** The first import runs to nine steps across more than one session,
and a Citrix session dies after 18 h disconnected. When resuming, ask which step last
completed rather than restarting — the logs on the box name it.

## Before you begin, know these

Most values come from the conf and are not asked for again. One is genuinely
machine-specific and **must not be guessed**; ask for it once and carry it through:

- `<workspace-dir>` — where the clones and `.venv` go on the VM. Not known until
  `check_venv_location.sh` has run; never default it.

In GitLab mode the conf will not load with `KIT_GITLAB_GROUP` still `<gitlab-group>`, so
that is settled before the payload is built. In bundle mode it is never read.

Hostnames and the Artifactory PyPI remote name (`pypi`, the same for every DSH user), by
contrast, are known — see `references/dsh-facts.md`. They are `install_uv.sh`'s defaults; use
them as written rather than turning them back into placeholders.

## The procedure inside the payload

`RUNBOOK.md` travels in the payload (from `src/carry/dsh-vm/RUNBOOK.md`). It is the
operator's copy of the VM procedure, readable on the VM when this conversation is not.
Keep it in step with `references/desktop-vm.md` when either changes, and rebuild the
payload so the new copy is the one carried.
