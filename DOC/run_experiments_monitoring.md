# run_experiments Monitoring and Job Management

This guide describes how to submit, inspect, monitor, and terminate jobs
launched by `run_experiments.py`.

## Model

The launcher uses two layers of metadata:

- `run_logs/status/*.json`
  - One file per `(flow, tech, case)`.
  - This is the user-facing task status.
  - It stores the exact `dispatch_job_id` of the current submission.
- `run_logs/dispatch/<flow>/<tech>/<case>/`
  - Remote host dispatch metadata.
  - Each detached remote task creates:
    - `*.wrapper.sh`
    - `*.state`
    - `*.phase`
    - `*.rc`
    - `*.pid`

For remote jobs, the monitor reads both:

- the status JSON
- the exact remote dispatch job bound in that status JSON

This lets the script detect:

- `starting`
- `queued`
- `running`
- `ok`
- `failed`
- stale dispatch files where the recorded pid is already gone

## Submit Jobs

Example:

```bash
python run_experiments.py \
  --flow cds \
  --host-list {hnode01,hnode02,hnode03,hnode04}
```

When `--host-list` is used, the launcher now submits detached remote task
wrappers and exits immediately. It behaves more like `bsub` than a persistent
local scheduler.

Local mode still works:

```bash
python run_experiments.py --flow cds --jobs 4
```

Running the same submission command again skips tasks that already finished
successfully and retries tasks whose last status is `failed`. Active tasks are
left running and are not submitted twice.

## Show Current Active Status Once

This synchronizes task status with dispatch metadata and prints one snapshot.
By default it only prints active tasks.

```bash
python run_experiments.py --flow cds --show-status
```

You can narrow the scope:

```bash
python run_experiments.py --flow cds --tech nangate45_3D --case gcd --show-status
```

To also print terminal tasks:

```bash
python run_experiments.py --flow cds --show-status --all-status
```

## Monitor Until Done

This re-syncs status repeatedly and exits when all matched tasks are terminal.

```bash
python run_experiments.py --flow cds --monitor --status-interval 10
```

Example with filters:

```bash
python run_experiments.py \
  --flow cds \
  --tech asap7_nangate45_3D \
  --monitor \
  --status-interval 15
```

## Kill Running Jobs

This terminates matched running or queued tasks and marks them failed.

```bash
python run_experiments.py --flow cds --kill-running
```

Kill only one slice:

```bash
python run_experiments.py \
  --flow cds \
  --tech nangate45_3D \
  --case jpeg \
  --kill-running
```

## Kill by Job ID

`--show-status` prints the exact dispatch `job=` id. You can kill one specific
job directly with:

```bash
python run_experiments.py --flow cds --kill-job task.12345.1775140000000
```

## Notes

- Management commands do not need `--host-list`.
- In management mode, the script uses the existing status JSON and bound
  `dispatch_job_id` to locate the exact remote wrapper.
- Remote kill uses the recorded remote process group from `*.pid`.
- Local kill uses the recorded local launcher pid from the status JSON.
- `--host-list` is ignored in management mode by design.

## Interpreting Status Output

Typical detail lines look like:

```text
[TASK] hnode10 cds/nangate45_3D/jpeg status=running phase=run job=task.12345.1775140000000 dispatch=running dispatch_pid=123456 dispatch_pid_alive=True
```

Meaning:

- `status` / `phase`: current synchronized task status
- `job=...`: exact dispatch wrapper bound to this task
- `dispatch=...`: current remote dispatch state
- `dispatch_pid`: recorded remote wrapper pid / process group leader
- `dispatch_pid_alive`: whether that recorded remote pid still exists

If `dispatch_pid_alive=False` while dispatch still says `running`, the monitor
will convert the task to `failed` because the remote job is stale.

## Files to Check

- user-facing status:
  - `run_logs/status/*.json`
- remote dispatch internals:
  - `run_logs/dispatch/<flow>/<tech>/<case>/`
- stage logs:
  - `run_logs/<tech>/<flow>/run/<case>_run.log`
  - `run_logs/<tech>/<flow>/eval/<case>_eval.log`
