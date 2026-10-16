# DSH facts

Distilled from the UCL DSH User Guide & FAQs:
<https://www.ucl.ac.uk/isd/services/file-storage-sharing/data-safe-haven-dsh/data-safe-haven-user-guide-faqs>

These are UCL-documented values, not guesses — still confirm on the VM before baking any
into a script, and keep `<placeholders>` in generated commands per `ground-rules.md`. UCL
changes things; if the guide and this file disagree, the guide wins and this file is stale.

## Hostnames (documented by UCL)

| | |
|---|---|
| File Transfer Portal / FTPS | `filetransfer.idhs.ucl.ac.uk` |
| GitLab | `gitlab.idhs.ucl.ac.uk` (repos `https://gitlab.idhs.ucl.ac.uk/<user-or-group>/<repo>`) |
| Artifactory | `artifactory.idhs.ucl.ac.uk` (has Conda, PyPI, CRAN remotes; the PyPI remote is named `pypi` for everyone) |
| Cluster login node | `cluster.idhs.ucl.ac.uk` (PuTTY shortcut; also JupyterLab + RStudio Server in the Desktop browser) |
| Application & Data Portal | `accessgateway.idhs.ucl.ac.uk` |
| Security portal | `registration.idhs.ucl.ac.uk/dsc` (self-service), `/drp` (password reset), `/dea` (emergency access) |

## Moving files across the air gap

- **In:** upload at the File Transfer Portal → lands in `Q:\<username>` (MFT Arrivals) on the
  DSH Desktop. May lag for big files. **Q: is auto-wiped 30 days after file creation** — move
  it off promptly.
- **Bulk in (>10 files or >100 GB): use FTPS**, not the portal. Host
  `filetransfer.idhs.ucl.ac.uk`, implicit TLS, port 990, passive mode. In FileZilla: logon
  type *Interactive* (don't save DSH creds). curl works too but prints the password in plain
  text in its debug output.
- **Out:** copy to the share's folder under `R:` (MFT Outbound), then download from the
  portal. Requires **outbound rights** — only the IAO has them by default; delegable by
  request. R: is also wiped after 30 days. Files on R: are visible to all share members.
- **Cluster files never leave directly.** Export path is cluster → WinSCP → DSH Desktop →
  `R:`.
- The File Transfer Portal has its **own lockout: 8 wrong passwords** — you can be locked out
  of it while the Application & Data Portal still works. Unlock via a General DSH Enquiry
  ticket.
- Direct web-portal ingress/egress exists (Data Ingress / Egress Desktop, per-URL firewall
  allowlisting via Request for Service form; egress setup can take ~2 weeks).

## Drives on the DSH Desktop

| Drive | Role | Trap |
|---|---|---|
| `S:` | Group share; all research data | >500 GB → discuss with support first; on-screen free-space figure is wrong |
| `N:` | Home, 50 GB | **No research data here**; but Artifactory config files must live in its root |
| `Q:` | MFT Arrivals | 30-day wipe |
| `R:` | MFT Outbound | 30-day wipe; needs outbound rights to retrieve |

`S:` and `N:` are SMB shares. Windows returns `ERROR_INVALID_PARAMETER` — literally "The
parameter is incorrect" — when loading some DLLs across SMB, which is one of the two causes
of the numpy failure `check_venv_location.sh` exists to distinguish.

## Artifactory / package installs

- Windows Desktop: `.condarc` and `pip.ini` go in the **root of N:** (not a subfolder, not
  S:). Save from Notepad with *All Files* or you silently get `.condarc.txt`.
- On Linux/cluster it's `~/.pip/pip.conf` (Artifactory's "Set Me Up" text says pip.conf; the
  Windows desktop needs pip.ini — the FAQ calls out this mismatch). **uv reads neither** —
  it reads `%APPDATA%\uv\uv.toml` on Windows and `~/.config/uv/uv.toml` on Linux, which is
  what `install_uv.sh` writes.
- The Set Me Up snippets embed a token derived from your password: **regenerate .condarc /
  pip.ini / the CRAN install snippet after every password change** (password expires every
  90 days, so this recurs). Expect the uv config's credential to die the same way —
  symptom is an install that worked last visit now failing 401 on every package.
- Conda envs on the share: add `envs_dirs: [S:\<share>\anaconda-environments]` to `.condarc`,
  create with `conda create --prefix ...`.
- Symptom map: `CondaHTTPError ... repo.anaconda.com` → `.condarc` missing/broken;
  pip `SSL: CERTIFICATE_VERIFY_FAILED self signed certificate` → `pip.ini`/`pip.conf`
  missing/broken (i.e. pip is not actually pointed at Artifactory). The uv equivalent of
  the latter is fixed by `native-tls = true`, which makes uv consult the system
  certificate store instead of its own bundled one.

## GitLab

- Reachable from **both** the Windows Desktop and the cluster — the sanctioned way to move
  *code* between the two environments (data goes via WinSCP).
- AD-backed: sign in with your DSH username and current DSH password; no personal access
  token is needed for https on the Desktop.
- Windows uses https auth; on `unable to get local issuer certificate` run
  `git config --global http.sslBackend schannel`.
- Cluster can use SSH keys, but **2048-bit RSA only — ED25519 is not supported**.
- Prefer a **group-owned** repo over a user-owned one (user account deletion after password
  lapse kills user repos' access); name groups with the 5-digit IG case ref. Collaborators
  must have logged into GitLab once before they can be invited, and need Maintainer to push
  to main.
- Code only, never data: GitLab access control is looser than share ACLs.

## Cluster

- Only reachable from inside the DSH Desktop. SGE scheduler: `qsub`, `qstat`, `qdel`,
  `qlogin`; `-pe smp <n>` with n ≤ 16; `-l gpu=1`; **no MPI**. Batch runtime limit **48 h**
  (temporary exceptions negotiable).
- Home dir quota 50 GB (increasable on request), backed up daily; software stack under
  `/apps`.
- Jobscripts written in Notepad on the Desktop and copied via WinSCP can break on **CRLF
  line endings** — the FAQ warns about this explicitly.
- Patched monthly (a late-month Monday ~01:00–02:00) and **drained of batch jobs in the days
  before** — short-runtime jobs still start. The next patch date is shown at SSH login.
- SSH from the Desktop VM to the cluster for scripted transfer does not work — see
  `docs/adr/0002-ssh-to-the-dsh-cluster-is-closed-by-site-policy.md`. WinSCP is the route.

## Sessions, maintenance, account lifecycle

- Desktop VMs **reboot every Monday 00:00–02:00** (unsaved work lost); Wednesday 08:00–10:00
  is an at-risk change window.
- A disconnected Citrix session survives **18 h**, then apps are killed. Anything longer
  than that belongs in the scheduler, not a Desktop session.
- Password expires every **90 days**; a further 90 days unchanged → **account deleted** (data
  kept; IAO must request re-creation). Log in at least quarterly. Remember the Artifactory
  snippet regeneration — and `reset_gitlab_credential.sh` — that each password change
  triggers.
- No copy/paste or external network from inside the walled garden — this is why
  `ground-rules.md` forbids asking for pasted output.
