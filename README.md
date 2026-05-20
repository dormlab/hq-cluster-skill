# hq-cluster

A Claude Code Skill for submitting and managing compute jobs on the DormLab
mini cluster (lexie, derek, amelia) via [HyperQueue](https://github.com/It4innovations/hyperqueue).

Wraps `hq submit` with sensible defaults — sane CWD on workers, per-job
stdout/stderr capture, MPS resource tagging, and an SCP-back-from-worker
log fetcher so the Mac doesn't see worker-local file paths.

## What it gives an agent

```bash
JID=$(submit -- python train.py --lr 0.05)   # scheduler picks a mini
wait $JID                                    # block until done, exit code = job's
log  $JID                                    # stdout (auto-SCP'd from worker)
status                                       # queue depth + per-worker dispatch
cancel $JID                                  # done with it
```

Agents (and humans) never name a mini. The hq scheduler dispatches across the
three workers based on free resources.

## Install

```sh
./install.sh
```

Symlinks `skills/hq-cluster/` into `~/.claude/skills/hq-cluster/`.

Requires:
- `hq` on `$PATH` of the Mac (the client) — `cargo install --locked --git https://github.com/It4innovations/hyperqueue hyperqueue` (needs `cmake` first: `brew install cmake`).
- `hq worker` running on each mini, registered with the server. See
  [SETUP.md](./SETUP.md) for the one-time bring-up.

## Resource model

Each worker registers `cpus=10`, `mem=14` (GiB), `mps=1` (Apple GPU slot).
The `--mps` flag on `submit` requires the worker to hand out 1 MPS token,
which guarantees only one MPS-tagged job runs per mini at a time. The
`--mem 12` flag refuses to schedule on a worker with less than 12 free.

## Why this exists

The previous workflow was hand-written `ssh -f` + `setsid` + `pgrep` polling.
Hit two real failure modes: (1) race conditions where two scripts grabbed the
same mini in an idle gap, (2) jobs sized for >14 GB OOM'd a 16 GB mini and
swap-thrashed for an hour. Both go away with a real scheduler holding
resource pools atomically.
