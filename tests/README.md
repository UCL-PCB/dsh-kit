# tests/

A bash harness for the scripts in `src/`. It runs on the workstation with no DSH, no
network and no credentials: each case gets a throwaway project directory holding a
`dsh-kit.conf` and the git repositories it names (each pushed to a bare `origin` beside
it), and the script under test runs from an emptied environment so nothing on the
workstation can leak in.

Nothing here ships in the airlock payload. `tests/` is workstation-only, and that is
structural rather than a matter of being left off a list: only `src/carry/` is carried.

```bash
./tests/run_tests.sh                              # everything
./tests/run_tests.sh tests/test_export_bundles.sh
./tests/run_tests.sh --keep                       # keep every fixture for a look
bash tests/test_conf.sh test_a_bad_install_mode_fails
```

Needs bash 4.4+, coreutils and git. A copy of the output lands in `tests/last_run.log`
(gitignored). A failing case keeps its fixture and prints where; a passing one is deleted
unless `--keep` or `DSH_TEST_KEEP=1`. Fixtures go under `$TMPDIR` - point it somewhere
private if other jobs share `/tmp`.

## Layout

```
run_tests.sh                 runs every test_*.sh, tees to last_run.log, exits non-zero on failure
lib/harness.sh               sourced by every test: fixture builders, run_script, assertions, harness_main
stubs/                       put on PATH ahead of the real commands; empty by default (see its README)
test_harness.sh              the harness's own contract, without touching src/
test_conf.sh                 dsh_load_conf: parsed never run, defaults, and what it refuses
test_carry_manifest.sh       carry.sh: which file goes to which box, and where it lands
test_export_bundles.sh       the export: roles, the conf lookup, and every refusal
test_build_payload.sh        the payload: conf, bundles, PAYLOAD_CONTENTS.txt, checksums, prune
```

## Workstation scripts and payload scripts

`run_script` is for a script in `src/workstation/`, run with `$FIX_PROJECT` as the
working directory. Pass `--conf "$FIX_CONF"`, or set `FIX_KIT_CONF` to hand it the conf
through `$DSH_KIT_CONF` - the template repo itself ships only `dsh-kit.conf.example`, so a
script given neither fails, which is a case of its own.

`run_payload_script` is for one of the carried scripts. It runs a **built copy of
`src/carry`** at `$FIX_PAYLOAD`, made once per case by `fixture_payload` (call it first to
put files beside the scripts before one runs), laid out the way `build_payload.sh` lays a
payload out - `lib/`, `diagnose/`, the procedure's steps at the top - with a
`PAYLOAD_CONTENTS.txt` and a copy of `$FIX_CONF` if one was written. A script that reaches
for a sibling or for `lib/` finds it exactly as it would on the VM, and its log lands in
the fixture rather than in the repository. Name it by bare filename.

## What a test looks like

One file per script or library under test, one `test_*` function per case, each run in its
own subshell against a fresh fixture:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

test_every_repo_in_the_conf_is_exported_with_its_role() {
    fixture_repos lib-a app-b
    fixture_conf 'KIT_REPOS=lib-a app-b' 'KIT_WORKING_REPOS=app-b'

    run_script export_bundles.sh --conf "$FIX_CONF" --out "${FIX_ROOT}/out"
    assert_exit 0
    assert_file_contains "${FIX_ROOT}/out/MANIFEST.txt" '^app-b  .*  working$'
}

harness_main "$@"
```

**Assert on file state and exit status, not on wording.** The scripts' messages are for
the operator and change without the behaviour changing. The exceptions are files another
step parses - `MANIFEST.txt`, `PAYLOAD_CONTENTS.txt`, `SHA256SUMS.txt` - which ARE the
behaviour, and a refusal whose whole point is to name what it refused.

Where a message goes matters for which file to look in: once a script has called
`dsh_start_log`, its stdout and stderr are joined and teed, so everything it prints lands
in `run.out`. Only what it prints BEFORE that - a usage error, a missing conf, an unknown
`--target` - is in `run.err`.

### The fixture

| Variable | What it is |
|---|---|
| `FIX_ROOT` | the case's root |
| `FIX_HOME` | the script's `$HOME` |
| `FIX_PROJECT` | a project made from the template; the cwd for `run_script` |
| `FIX_CONF` | `$FIX_PROJECT/dsh-kit.conf`, written by `fixture_conf` |
| `FIX_TMP` | the script's `$TMPDIR` |
| `FIX_PAYLOAD` | `src/carry` laid out as a payload, for `run_payload_script` |
| `FIX_STUBS` | this case's private copy of `stubs/`, first on `PATH` |
| `FIX_KIT_CONF` | passed to the script as `$DSH_KIT_CONF`; empty unless a case sets it |

Builders: `fixture_conf 'KEY=value'...` (`KIT_REPOS_DIR` defaults to `repos`),
`fixture_repos NAME...` (a pushed repo under `$FIX_PROJECT/repos`), `fixture_git_repo DIR`
for one anywhere else, `fixture_uv_assets DIR` (stand-ins for the two uv release assets).

Assertions: `assert_exit N`, `assert_equals EXPECTED ACTUAL [WHAT]`,
`assert_file_exists`, `assert_dir_exists`, `assert_absent`, `assert_files_equal A B`,
`assert_file_contains FILE PATTERN`, `assert_file_lacks FILE PATTERN`. Each records a
failure and carries on, so a case reports everything that is wrong. `fail MSG` records one
directly; `fail_now MSG` is for a broken fixture and stops the case.
