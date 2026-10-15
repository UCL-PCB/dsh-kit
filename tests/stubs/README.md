# tests/stubs

Anything placed here is put on `PATH` ahead of the real commands for every script a test
runs (each case gets a private copy, so a case may add or rewrite one). Empty by default:
nothing the kit runs on the workstation reaches a network or a cluster - the DSH cluster
is not reachable by ssh at all (docs/adr/0002) - so there is no transport to stand in for.

A stub that is added must refuse to act outside the harness, so that a stray `PATH` entry
can never make it answer for the real command.
