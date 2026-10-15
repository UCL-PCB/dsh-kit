# 0001 — The directory a script lives in is the box it is carried to

Status: Accepted

## Context

A payload for the DSH is a set of scripts, and different scripts belong on different boxes:
some run on the workstation outside and are never carried, some run on the Windows analysis
VM, some on the Linux batch cluster, some on both. That fact has to be recorded somewhere the
build can read it.

The obvious places are a comment in each script's header, or a list — an `EXPECTED` array in
the verifier, a manifest with a target column. A comment is invisible to the build and
unreadable from a directory listing. A list is a second place: a script can be added to the
tree and forgotten in the list, or removed from the tree and left in it, and nothing notices
until the far side reports a missing file — at the cost of an airlock round trip.

## Decision

**A script's directory is the statement of where it goes, and the only one.**

```
src/workstation/          nowhere — runs on this machine
src/lib/                  nowhere — sourced by the workstation scripts
src/carry/any/            both boxes
src/carry/dsh-vm/         the analysis VM
src/carry/dsh-cluster/    the batch cluster behind it
src/carry/diagnose/<g>/   diagnosis scripts, carried to group <g>
src/carry/<g>/lib/        sourced-only libraries, carried to group <g>
```

`src/lib/carry.sh` maps a group directory to the boxes it serves; `build_payload.sh
--target dsh|dsh-vm|dsh-cluster` walks the tree and carries only what the named box needs.
There is no list, so there is nothing to forget. `any` exists because a file genuinely
wanted on both boxes should be in one place rather than copied into two.

## The payload lands in three directories, not five and not one

The groups do **not** reach the far side. They answer *which box*, which is of no interest
to an operator already standing at one. Landing everything flat is the other extreme: a
listing in which a sourced library, a once-a-year diagnosis and the next step of the
procedure are indistinguishable.

So the payload is laid out by **what a file is to the person at the box**:

| | |
|---|---|
| top level | the steps of the procedure, and `RUNBOOK.md` |
| `lib/` | sourced, never run: `dsh_log.sh`, `dsh_platform.sh`, `dsh_conf.sh` |
| `diagnose/` | run only when something has already gone wrong |
| `Logs/` | one log per script |

`dsh_payload_path` in `src/lib/carry.sh` is the whole mapping, and it too is driven by the
tree. Basenames stay unique across the whole payload even so, and `build_payload.sh` refuses
a collision rather than letting one file silently overwrite another: `RUNBOOK.md` names
scripts by bare filename and `q.sh` imports them off `Q:` by name.

`verify_payload.sh` reads `PAYLOAD_CONTENTS.txt`, which `build_payload.sh` writes naming the
target and every file *with the path it landed at* — so a file that arrived in the wrong
directory reads as missing, which is what it is to the script that sources it. That file is
hashed in `SHA256SUMS.txt` like everything else, so a truncated one is caught rather than
quietly shortening the list of things to check.

## Alternatives rejected

**A manifest file with a target column.** Reintroduces a file and a list that can disagree.
The value of the directory scheme is that a file in the wrong place is visible in a listing
and a diff, and a file in no place is simply not carried.

**Tag the target in each script's header and parse it.** Makes the build depend on parsing
free text a human writes; a typo reads as "no target" and the file is silently not carried. A
directory cannot be misspelt without `find` reporting an unknown group.

**Mirror the groups in the payload.** The groups answer a question the operator at the box
has already answered by being there.

## Consequences

- Adding a script to the payload means putting it in the right directory. `CLAUDE.md` and
  the dsh-setup skill's `ground-rules.md` say so.
- `tests/` and `docs/` being workstation-only is structural: only `src/carry/` is carried.
- A project built on this template adds its own carried scripts the same way — in its own
  `src/carry/<group>/` — and they are carried with no other change.
