# 0002 — SSH from the Desktop VM to the DSH cluster is closed by site policy, and the hand-carry is the design

Status: Accepted

## Context

Behind the airlock, everything that reaches the batch cluster gets there because an operator
drags it with WinSCP from the Desktop VM. Scripted transfer — `scp`/`ssh` from the VM, driven
by a script — would take the operator out of that step, so it was worth a real
investigation, run on both boxes as a numbered probe with a verdict rather than an
interactive session, so each negative result was durable enough not to be re-tested.

**Every link in the chain is good except one.** `ssh` and `scp` are present on the Desktop
VM; `cluster.idhs.ucl.ac.uk` resolves; tcp/22 from the Desktop is open; sshd answers and
offers `publickey,password,keyboard-interactive`; a 2048-bit RSA key with no passphrase,
installed in `~/.ssh/authorized_keys` with the right fingerprint, `~/.ssh` at `0700`,
`authorized_keys` at `0600`, `$HOME` not group-writable, sent explicitly with `-i` and
`IdentitiesOnly=yes`, is still refused. Re-enabling SHA-1 `ssh-rsa` signatures changed
nothing.

**The broken link is not reachable by a user.** On the login node `use_nfs_home_dirs` is
**off** and `$HOME` is on NFS, so under SELinux policy sshd is forbidden from reading
`~/.ssh/authorized_keys` for any key at all. The fix is `setsebool -P use_nfs_home_dirs 1`,
as root. That is a policy boundary, not a defect.

It was expensive to diagnose because CRLF from a WinSCP text-mode transfer, wrong
permissions on `~/.ssh` or `$HOME`, a missing final newline in `authorized_keys`, a key
authorized for the wrong account, and an unreadable `authorized_keys` all present to the
client as the same `Permission denied (publickey)`. Each had to be excluded separately.

Password authentication, the other method sshd advertises, was probed separately and also
refused at the authentication attempt itself.

## Decision

**The WinSCP hand-carry is the design, not a workaround. SSH from the Desktop VM to the DSH
cluster is treated as closed.** dsh-kit's cluster scripts assume the payload folder arrives
by WinSCP, in binary mode, and do nothing over the network between the two boxes except
through GitLab-inside, which both can reach.

A service-desk request is the only remaining move, and it is optional. If sent, send it
specifically — a vague "SSH keys do not work" invites a reply about key formats this
diagnosis has already excluded:

> On `cluster.idhs.ucl.ac.uk`, public-key authentication for my account fails from the
> Desktop VM. The key is a 2048-bit RSA key with no passphrase, present in
> `~/.ssh/authorized_keys` with the correct fingerprint, `~/.ssh` is `0700`,
> `authorized_keys` is `0600`, and `$HOME` is not group-writable. `ssh -v` shows
> `Offering public key` with no `Server accepts key`. `getsebool use_nfs_home_dirs` reports
> **off** and `$HOME` is on NFS, so sshd cannot read `authorized_keys` under SELinux policy.
> Please confirm whether `setsebool -P use_nfs_home_dirs 1` is permissible on the login
> node, or whether key authentication from the Desktop VM is intentionally not supported.

"Intentionally not supported" is a complete answer: it makes the hand-carry permanent by
design.

## Consequences

- No script in this repo transfers files between the VM and the cluster. The cluster
  procedure begins "WinSCP the payload folder over, binary mode".
- Code moves between the two boxes through GitLab-inside: the VM pushes the mirror, the
  cluster clones from it. That route is sanctioned by UCL and works.
- If site policy ever changes, the three silent ways `cat key.pub >> ~/.ssh/authorized_keys`
  fails — CRLF, permissions, missing final newline — are recorded above, so they are not
  rediscovered.
