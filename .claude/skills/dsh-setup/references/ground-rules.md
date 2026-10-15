# Ground rules for the air-gapped targets

Applies to both `dsh-vm` and `dsh-cluster`.

## The VM is air-gapped

The secure-environment analysis VM has no internet access and cannot reach Claude. Nothing
run there can be observed directly — there is no live terminal, no shared filesystem, no way
to read its output back automatically. Every interaction is: hand the operator something to
run on the VM, they run it by hand, they bring results back out.

The cluster is one step further away still: it is reachable only from inside the Desktop VM.

## Do not ask for VM output to be pasted back

Pasting output out of the VM is the thing to avoid, not a convenience to lean on — there is
no copy/paste out of the walled garden, so the ask is impossible rather than merely
tedious. Do not end a message with "paste what that prints." Instead:

- Give commands that are self-verifying — exit codes, explicit `RESULT: PASS` / `FAIL`
  lines — written to a file on the VM, so the operator can check the file themselves
  without relaying it.
- Every script in the payload already does this: `Logs/unpack_payload.log`,
  `Logs/verify_payload.log`, `Logs/probe_secure_env.log`, `Logs/install_uv.log`,
  `Logs/check_venv_location.log`, `Logs/install_packages.log`. Name the file and say what
  a pass looks like in it.
- If the operator reports a failure, work from what they volunteer rather than
  interrogating for more pasted detail. A step's log usually already contains the answer;
  ask which line, not for the whole file.

## A script that finds nothing must say what it looked for

The worst failure mode behind an airlock is not a crash — it is a script that does nothing,
says something reasonable about it, and exits 0. On a machine you can see, that costs
minutes. Here it costs a round trip, and it arrives as the operator's paraphrase of a message
that sounded like a normal outcome.

The typical case: a script builds a path out of a *local* one, searches somewhere that does
not exist on the far side, reports "nothing found" and exits 0 — indistinguishable from "there
is genuinely nothing yet". So, for every carried script:

- **Print the path, host or pattern that came back empty**, not just the fact that it did.
  `Nothing under <path>` is one round trip; `Nothing found` is three.
- **Distinguish "empty and that is expected" from "empty and something is wrong."** If a
  lookup returning nothing is always a fault, exit non-zero and say `FAIL`.
- **Echo the resolved value of anything derived** — a path assembled from the conf,
  `~/dsh-kit.env` or another machine's layout — into the log, once, before using it.
- Keep `set -o pipefail`. Every script in `src/carry/` sets it; a pipeline into `tee` or
  `tail` otherwise reports the *last* command's status and turns a dead step into a clean
  log.

## Every command carries placeholders, not guesses

Never assume a path, hostname, or drive letter that is not in `dsh-facts.md`. Use
`<placeholder>` tokens for anything environment-specific — `<workspace-dir>`, `<group>`,
`<username>`, `<drive-letter>` — and let the operator substitute. Do not invent a
plausible-looking default and present it as a command to run as-is; inside the airlock a
wrong path costs a round trip that cannot be shortened.

The hostnames in `dsh-facts.md` are the exception: they are UCL-documented, the probes check
them rather than trusting them, and turning them back into placeholders just makes the
commands harder to run.

## Long commands become scripts

A command longer than one line, or longer than ~30 characters, does not get typed into chat
to be copied — the operator would have to retype it inside, by hand. Instead:

1. Write it into the directory for the box that will run it — a diagnosis goes in
   `src/carry/diagnose/<group>/`, where `<group>` is `dsh-vm`, `dsh-cluster` or `any`.
   **The directory is what makes it carried**, and it is the only statement of where it
   goes. Name it for the specific failure, not the general area:
   `diagnose_numpy_dll.sh`, not `fix_path2.sh`.
2. Source `dsh_log.sh` and call `dsh_start_log "$@"` near the top, as every other carried
   script does:

   ```bash
   # A diagnosis lands in DSH_import/diagnose/, so the payload root is one up.
   # A script carried to the top level uses the same line without the /..
   PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
   . "${PAYLOAD_DIR}/lib/dsh_log.sh"
   dsh_start_log "$@"
   ```

   Everything it prints then also lands in `Logs/<name>.log` at the payload root, so the
   result is self-contained and reviewable on the box that produced it. Each run truncates
   that file. Do not hand-write a `tee` block, and do not write a log into the repo.
3. There is no list to add it to. Being under `src/carry/` is what gets it copied,
   checksummed and recorded in `PAYLOAD_CONTENTS.txt`. Two carried files may not share a
   basename; the build refuses.
4. Rebuild the payload (`payload.md`) and tell the operator to import it, then run it.
   Nothing longer than that single run command goes in chat.

For one script written mid-session, a full payload is heavy: the operator can upload just
that file through the portal and run it with `./q.sh <name>`, which imports it off `Q:`,
strips CRLF and runs it.

Short one-liners under the threshold can still be given directly.

## Nothing is destructive until the mirror

Unpack, verify and probe are read-only. `mirror_to_gitlab.sh` pushes to GitLab and is the
first thing that changes state on the far side. Say so when handing it over, and confirm the
`--refresh` question (see `desktop-vm.md`) before it runs, not after.

## Sessions expire underneath you

A disconnected Citrix session is killed after 18 h, and Desktop VMs reboot every Monday
00:00–02:00 with unsaved work lost. Anything long-running belongs in the scheduler, not a
Desktop session. When a session has been open a while, prefer a checkpoint the operator can
resume from over a step that has to complete in one sitting.
