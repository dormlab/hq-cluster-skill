---
name: hq-cluster
description: Submit and manage compute jobs on the local 3-Mac-mini cluster (lexie, derek, amelia) via HyperQueue. Use whenever the user wants to run training, sweeps, experiments, or any background compute on the minis — also use to check queue status, follow logs, or cancel jobs.
allowed-tools: Bash, Read
---

# When to use this skill

Use any time the work is "run code on the minis":
- "Run this sweep on lexie/derek/amelia/the minis"
- "Submit this script to the cluster"
- "Queue these N runs"
- "Is X done yet?" / "what's running on the minis?"
- "Kill that job"

Do NOT use this skill for code that runs on the user's Mac or in this Claude session.

# Cluster facts (don't re-discover, use them)

- Three Mac mini M4s, each 16 GB unified memory: **lexie**, **derek**, **amelia**.
- Each has a Python venv at `$HOME/mccl-store/.venv` and an experiment tree at `/tmp/run2/`.
- HyperQueue server runs on the user's Mac (bound to Tailscale IP <MAC_IP>). Workers run on each mini.
- Each worker registers resources: `cpus=10`, `mem=14`, `mps=1`. The `mem` value represents GB; `mps=1` means one Metal GPU "slot" — only one MPS-tagged job runs per worker at a time.
- Jobs requesting `--mem 20` will never land on a 16 GB worker (no worker has mem=20 free). This is the load-bearing guarantee — protects against the swap-thrashing incidents.

# How scheduling works (the user asked, write this down)

**Dispatch is automatic.** When you call `submit`, hq's scheduler picks any worker with enough resources free and dispatches the job. You never name a mini.

**Resource pools, not load averages.** Each worker has a pool: `{cpus: 10, mem: 14, mps: 1}`. When a job is submitted with `--mps`, it consumes 1 mps token from a worker's pool. While the job runs, that token is HELD by the job. Concretely:

- Submit `--mps` job A → scheduler picks any worker with mps=1 free (say lexie). lexie pool: mps=0.
- Submit `--mps` job B → lexie's mps is 0; derek and amelia each have mps=1. So B lands on derek.
- Submit `--mps` job C → amelia.
- Submit `--mps` job D → all three workers at mps=0. Job D **queues** until any worker frees up. When A finishes, lexie returns mps=1 → D dispatches there.

**No polling, no race conditions.** The scheduler tracks the pool state atomically. The "ssh -f race" failure mode that bit us earlier (two scripts firing in the same idle gap) cannot happen here.

**Knowing what's running**:
```
scripts/status         # one-line summary across workers
scripts/status --json  # full state, parseable
hq jobs                # all jobs, raw
hq worker list         # which worker holds which pool tokens
```

# Overhead (negligible)

- `hq server` + `hq worker` are static Rust binaries.
- RSS at idle: ~30 MB each.
- CPU at idle: ~0%.
- A submit-to-dispatch round trip is well under 1 second on the LAN.

Compared to a typical PyTorch process eating 8+ GB of MPS memory and a CPU core, the scheduler is rounding error. Workers don't intercept jobs in any way — they just `fork+exec` the script and wait for it to exit.

# Knowing if a job is mine vs the user's manual run

The `hq worker list` shows running jobs. If a worker is busy WITHOUT a job in `hq jobs`, that's a non-scheduled (manual `ssh`) run by the user — leave it alone. All agent-submitted runs appear in `hq jobs`.

# How to invoke

All operations go through the wrappers in `scripts/`. They emit one-line, parseable output so you can pipe them.

## Submit a job

```
scripts/submit <command...>            # default: any worker, any memory
scripts/submit --mem 12 <command...>   # only land on a worker with ≥12 GB free
scripts/submit --mps <command...>      # require MPS (always true on minis, but explicit)
scripts/submit --name my_sweep <cmd>   # human-readable job name
```

Prints the assigned job ID on a single line. Save it.

## Wait for jobs

```
scripts/wait <id>             # block until done; exit code = job's exit code
scripts/wait <id1> <id2> ...  # wait for all; exit 0 iff all succeeded
```

## Check status

```
scripts/status                # pretty summary: queue depth, per-worker, recent failures
scripts/status --json         # JSON, for downstream parsing
```

## Tail logs

```
scripts/log <id>              # print full stdout+stderr
scripts/log <id> --tail       # follow live (run in background; ctrl-c to stop)
```

## Cancel

```
scripts/cancel <id>
scripts/cancel --name my_sweep   # cancel everything matching name
```

# Workflow patterns

## Single job, foreground

```
JID=$(scripts/submit -- python train.py --lr 0.01)
scripts/wait $JID
scripts/log $JID | tail -20
```

## Multi-job sweep, parallel

```
JIDS=()
for LR in 0.01 0.025 0.05 0.1 0.2; do
  JIDS+=($(scripts/submit --name sweep_lr$LR -- python train.py --lr $LR))
done
scripts/wait "${JIDS[@]}"   # blocks until all done
```

The scheduler dispatches across the three workers automatically. You do NOT pick which mini gets which lr.

## "Run this then come back when it's done"

```
JID=$(scripts/submit -- /tmp/big_job.sh)
echo "queued as job $JID; doing other work"
# ... do other things ...
scripts/wait $JID && scripts/log $JID
```

# Important constraints (the user's hard rules)

- **Memory**: Never submit a job that needs >14 GB without an explicit `--mem` tag. A 50M-param model with full batch=64 will OOM and swap-thrash a 16 GB mini — we hit this once, lost an hour.
- **No `ssh -f`**: The user is migrating off ad-hoc `ssh -f` patterns. Always use `scripts/submit`. If a script you find still has `ssh -f`, mention it but don't reproduce the pattern.
- **Existing experiment scripts**: `/tmp/run2/scripts/harness.py`, `aurora_jac_eig.py`, `bench_step_time.py`, etc. work as-is. Just invoke them via `submit`.
- **No mini name in submit**: Don't pass `--host lexie`. Let the scheduler pick. The whole point of this skill is to NOT think about which mini.

# Result pulling

Jobs write their output to `/tmp/run2/results/` on whichever worker ran them. After completion:

```
# `scripts/log $JID` tells you which worker ran the job.
WORKER=$(scripts/status --json | jq -r ".jobs[] | select(.id==$JID) | .worker")
scp $WORKER:/tmp/run2/results/<filename>.json ~/silicon_scripts/src/run2/results/
```

# Troubleshooting

- **Server not reachable**: Check `launchctl list | grep hqserver` on the Mac.
- **Worker offline**: ssh to the mini, run `launchctl list | grep hqworker` and `tail ~/.hq-worker.err`.
- **Build error compiling hq on a mini**: most likely a Linux-only syscall (`prctl(PR_SET_PDEATHSIG)`) — add `#[cfg(target_os = "linux")]` guard, rebuild.

# Verbosity

When using this skill, be quiet on success: "submitted as job 42" / "job 42 done in 8m" is enough. Don't narrate the polling. Only surface output when something fails or the user explicitly asks.
