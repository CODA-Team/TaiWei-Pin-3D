#!/usr/bin/env python3
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import run_experiments_remote as remote


# ==============================================================================
# Experiment definitions
# ==============================================================================


@dataclass(frozen=True)
class RunConfig:
    flow: str  # "ord" or "cds"
    tech: str
    case: str
    repo_root: Path  # local repo root (where test/ exists)
    do_run: bool
    do_eval: bool
    host: Optional[str] = None
    host_slot: int = 0

def _log_paths(flow: str, tech: str, case: str) -> Tuple[Path, Path]:
    base = Path(f"run_logs/{tech}/{flow}")
    run_log = base / "run" / f"{case}_run.log"
    eval_log = base / "eval" / f"{case}_eval.log"
    return run_log, eval_log


def _status_dir(repo_root: Path) -> Path:
    return repo_root / "run_logs" / "status"


def _status_path(cfg: RunConfig) -> Path:
    return _status_dir(cfg.repo_root) / f"{cfg.flow}__{cfg.tech}__{cfg.case}.json"


def _dispatch_dir(cfg: RunConfig) -> Path:
    return cfg.repo_root / "run_logs" / "dispatch" / cfg.flow / cfg.tech / cfg.case


def _script_paths(repo_root: Path, flow: str, tech: str,
                  case: str) -> Tuple[Path, Path]:
    run_script = repo_root / "test" / tech / case / flow / "run.sh"
    eval_script = repo_root / "test" / tech / case / flow / "eval.sh"
    return run_script, eval_script


def discover_available_tasks(repo_root: Path) -> List[Tuple[str, str, str]]:
    test_root = repo_root / "test"
    if not test_root.exists():
        return []

    found = set()
    for run_script in sorted(test_root.glob("*/*/*/run.sh")):
        rel = run_script.relative_to(test_root)
        if len(rel.parts) != 4:
            continue
        tech, case, flow, _ = rel.parts
        if flow not in ("ord", "cds"):
            continue
        found.add((flow, tech, case))

    return sorted(found, key=lambda item: (item[0], item[1], item[2]))


def _load_env_from_script(env_script: Path) -> None:
    if not env_script.exists():
        return
    cmd = [
        "bash",
        "-lc",
        f'export FLOW_ENV_QUIET=1; source "{env_script}"; env -0',
    ]
    proc = subprocess.run(cmd,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,
                          check=True)
    for entry in proc.stdout.split(b"\0"):
        if not entry:
            continue
        key, _, value = entry.partition(b"=")
        os.environ[key.decode(errors="ignore")] = value.decode(errors="ignore")


def parse_host_list(values: Sequence[str]) -> List[str]:
    if not values:
        return []

    text = " ".join(values).strip()
    if text.startswith("{") and text.endswith("}"):
        text = text[1:-1]
    text = text.replace(",", " ")
    return _dedup_keep_order([item.strip() for item in text.split() if item.strip()])


def _target_label(cfg: RunConfig, local_host: Optional[str] = None) -> str:
    if cfg.host:
        if cfg.host_slot > 0:
            return f"{cfg.host}[{cfg.host_slot}]"
        return cfg.host
    return local_host if local_host else "localhost"


def write_task_status(
    cfg: RunConfig,
    status: str,
    phase: str,
    message: str = "",
    pid: Optional[int] = None,
    local_host: Optional[str] = None,
    extra: Optional[Dict[str, object]] = None,
    target_host: Optional[str] = None,
) -> None:
    status_path = _status_path(cfg)
    status_path.parent.mkdir(parents=True, exist_ok=True)
    run_log, eval_log = _log_paths(cfg.flow, cfg.tech, cfg.case)
    payload = {
        "flow": cfg.flow,
        "tech": cfg.tech,
        "case": cfg.case,
        "target_host": target_host if target_host else _target_label(
            cfg, local_host),
        "pwd": str(cfg.repo_root),
        "launcher_pwd": os.getcwd(),
        "status": status,
        "phase": phase,
        "message": message,
        "pid": pid,
        "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "run_log": str(run_log),
        "eval_log": str(eval_log),
    }
    if extra:
        payload.update(extra)
    tmp_path = status_path.with_name(
        f"{status_path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    try:
        with open(tmp_path, "w") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
        os.replace(tmp_path, status_path)
    finally:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except Exception:
            pass


def read_task_status(cfg: RunConfig) -> Dict[str, object]:
    status_path = _status_path(cfg)
    if not status_path.exists():
        return {
            "flow": cfg.flow,
            "tech": cfg.tech,
            "case": cfg.case,
            "target_host": _target_label(cfg),
            "status": "unknown",
            "phase": "unknown",
            "message": "",
        }
    with open(status_path, "r") as fh:
        return json.load(fh)


def init_task_statuses(tasks: Sequence[RunConfig]) -> None:
    for task in tasks:
        current = sync_task_status(task)
        current_status = str(current.get("status", "unknown"))
        if current_status in ("queued", "running", "ok", "failed"):
            continue
        write_task_status(task, "queued", "queued")


def print_status_summary(tasks: Sequence[RunConfig]) -> None:
    payloads = [read_task_status(task) for task in tasks]
    print_status_summary_from_payloads(payloads)


def print_status_summary_from_payloads(payloads: Sequence[Dict[str, object]]
                                       ) -> None:
    counts: Dict[str, int] = {}
    for payload in payloads:
        status = str(payload.get("status", "unknown"))
        counts[status] = counts.get(status, 0) + 1

    ordered = []
    for key in ("queued", "running", "ok", "failed", "unknown"):
        if counts.get(key):
            ordered.append(f"{key}={counts[key]}")
    print(f"[STATUS] {' '.join(ordered)}")


def _active_payloads(payloads: Sequence[Dict[str, object]]
                     ) -> List[Dict[str, object]]:
    return [
        payload for payload in payloads
        if str(payload.get("status", "unknown")) in ("queued", "running")
    ]


def _repo_root_from_payload(payload: Dict[str, object]) -> Path:
    raw = str(payload.get("pwd", "")).strip()
    if raw:
        return Path(raw)
    return Path.cwd()


def _path_from_payload(payload: Dict[str, object],
                       key: str) -> Optional[Path]:
    raw = str(payload.get(key, "")).strip()
    if not raw:
        return None
    path = Path(raw)
    if not path.is_absolute():
        path = _repo_root_from_payload(payload) / path
    return path


def _run_context_from_log(payload: Dict[str, object]) -> Tuple[str, str, str]:
    enablement = str(payload.get("tech", "")).strip()
    design = str(payload.get("case", "")).strip()
    flow = str(payload.get("flow", "")).strip()
    flow_variant = "openroad" if flow == "ord" else "cadence"

    run_log = _path_from_payload(payload, "run_log")
    if run_log is None or not run_log.exists():
        return enablement, design, flow_variant

    try:
        with open(run_log, "r", errors="ignore") as fh:
            for line in fh:
                if not line.startswith("[run] "):
                    continue
                fields = {}
                for token in line.strip().split()[1:]:
                    if "=" not in token:
                        continue
                    key, value = token.split("=", 1)
                    fields[key] = value
                if "enablement" in fields:
                    enablement = fields["enablement"]
                if "design" in fields:
                    design = fields["design"]
                if "flow_variant" in fields:
                    flow_variant = fields["flow_variant"]
                if enablement and design and flow_variant:
                    break
    except OSError:
        pass

    return enablement, design, flow_variant


def _newest_file(paths: Iterable[Path]) -> Optional[Path]:
    newest = None
    newest_mtime = -1.0
    for path in paths:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if mtime > newest_mtime:
            newest = path
            newest_mtime = mtime
    return newest


def _stage_log_from_payload(payload: Dict[str, object]) -> str:
    repo_root = _repo_root_from_payload(payload)
    enablement, design, flow_variant = _run_context_from_log(payload)
    if not enablement or not design or not flow_variant:
        return "-"

    log_dir = repo_root / "logs" / enablement / design / flow_variant
    if not log_dir.exists():
        return "-"

    current_log = _newest_file(log_dir.glob("*.log.tmp"))
    if current_log is None:
        current_log = _newest_file(log_dir.glob("*.log"))
    if current_log is None:
        return "-"
    return current_log.name


def print_status_details(payloads: Sequence[Dict[str, object]],
                         *,
                         only_active: bool = False) -> None:
    items = _active_payloads(payloads) if only_active else list(payloads)
    if not items:
        return

    rows = []
    for payload in items:
        rows.append({
            "host": str(payload.get("target_host", "localhost")),
            "task": f"{payload.get('flow')}/{payload.get('tech')}/{payload.get('case')}",
            "status": str(payload.get("status", "")),
            "phase": str(payload.get("phase", "")),
            "dispatch": str(payload.get("dispatch_state", "")) or "-",
            "job": str(payload.get("dispatch_job_id", "")) or "-",
            "pid": str(payload.get("dispatch_pid", "")) if payload.get("dispatch_pid") is not None else "-",
            "alive": str(payload.get("dispatch_pid_alive", "")) if payload.get("dispatch_pid_alive") is not None else "-",
            "stage_log": _stage_log_from_payload(payload),
        })

    widths = {
        "host": max(len("HOST"), max(len(row["host"]) for row in rows)),
        "task": max(len("TASK"), max(len(row["task"]) for row in rows)),
        "status": max(len("STATUS"), max(len(row["status"]) for row in rows)),
        "phase": max(len("PHASE"), max(len(row["phase"]) for row in rows)),
        "dispatch": max(len("DISPATCH"), max(len(row["dispatch"]) for row in rows)),
        "job": max(len("JOB"), max(len(row["job"]) for row in rows)),
        "pid": max(len("PID"), max(len(row["pid"]) for row in rows)),
        "alive": max(len("ALIVE"), max(len(row["alive"]) for row in rows)),
        "stage_log": max(len("STAGE_LOG"),
                         max(len(row["stage_log"]) for row in rows)),
    }

    header = (
        f"[TASK] "
        f"{'HOST':<{widths['host']}} "
        f"{'TASK':<{widths['task']}} "
        f"{'STATUS':<{widths['status']}} "
        f"{'PHASE':<{widths['phase']}} "
        f"{'DISPATCH':<{widths['dispatch']}} "
        f"{'JOB':<{widths['job']}} "
        f"{'PID':>{widths['pid']}} "
        f"{'ALIVE':<{widths['alive']}} "
        f"{'STAGE_LOG':<{widths['stage_log']}}"
    )
    print(header)
    print("[TASK] " + "-" * max(0, len(header) - len("[TASK] ")))

    for row in rows:
        print(
            f"[TASK] "
            f"{row['host']:<{widths['host']}} "
            f"{row['task']:<{widths['task']}} "
            f"{row['status']:<{widths['status']}} "
            f"{row['phase']:<{widths['phase']}} "
            f"{row['dispatch']:<{widths['dispatch']}} "
            f"{row['job']:<{widths['job']}} "
            f"{row['pid']:>{widths['pid']}} "
            f"{row['alive']:<{widths['alive']}} "
            f"{row['stage_log']:<{widths['stage_log']}}"
        )


def _status_host_from_payload(payload: Dict[str, object]) -> Optional[str]:
    raw = str(payload.get("target_host", "")).strip()
    if not raw:
        return None
    return raw.split("[", 1)[0]


def _dispatch_backend_from_payload(payload: Dict[str, object]) -> str:
    backend = str(payload.get("dispatch_backend", "")).strip()
    if backend:
        return backend
    if str(payload.get("dispatch_job_id", "")).strip():
        host = _status_host_from_payload(payload)
        if host and host not in ("localhost", socket.gethostname()):
            return "remote"
        return "local"
    return ""


def _status_has_terminal_state(payload: Dict[str, object]) -> bool:
    return str(payload.get("status", "unknown")) in ("ok", "failed")


def _local_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except Exception:
        return False


def _dispatch_metadata(cfg: RunConfig,
                       snapshot: remote.RemoteLaunchSnapshot,
                       backend: str) -> Dict[str, object]:
    return {
        "dispatch_backend": backend,
        "dispatch_dir": str(_dispatch_dir(cfg)),
        "dispatch_job_id": snapshot.launch.job_id,
        "dispatch_stage": snapshot.launch.stage,
        "dispatch_state": snapshot.state,
        "dispatch_phase": snapshot.phase,
        "dispatch_rc": snapshot.rc,
        "dispatch_pid": snapshot.pid,
        "dispatch_pid_alive": snapshot.pid_alive,
    }


def sync_task_status(cfg: RunConfig) -> Dict[str, object]:
    payload = read_task_status(cfg)
    backend = _dispatch_backend_from_payload(payload)
    host = _status_host_from_payload(payload)
    target_host = str(payload.get("target_host", "")).strip() or None
    phase = str(payload.get("phase", "unknown"))
    status = str(payload.get("status", "unknown"))

    if backend == "remote" and host:
        dispatch_dir = _dispatch_dir(cfg)
        launch = None
        dispatch_job_id = str(payload.get("dispatch_job_id", "")).strip()
        if dispatch_job_id:
            launch = remote.launch_from_job_id(dispatch_dir, dispatch_job_id)
        else:
            preferred_stage = phase if phase in ("run", "eval") else None
            if preferred_stage:
                launch = remote.latest_remote_launch(dispatch_dir,
                                                    stage=preferred_stage)
            if launch is None:
                launch = remote.latest_remote_launch(dispatch_dir, stage="task")
            if launch is None:
                launch = remote.latest_remote_launch(dispatch_dir, stage="eval")
            if launch is None:
                launch = remote.latest_remote_launch(dispatch_dir, stage="run")

        if launch is not None:
            snapshot = remote.snapshot_remote_launch(host, launch)
            dispatch_phase = snapshot.phase or launch.stage or phase
            extra = _dispatch_metadata(cfg, snapshot, "remote")
            if snapshot.state in ("starting", "running"):
                if snapshot.pid_alive is False:
                    write_task_status(
                        cfg,
                        status="failed",
                        phase=dispatch_phase,
                        message=
                        "[monitor] dispatch says running, but remote pid is gone",
                        pid=int(payload.get("pid"))
                        if str(payload.get("pid", "")).isdigit() else None,
                        extra=extra,
                        target_host=target_host,
                    )
                else:
                    running_status = "queued" if snapshot.state == "starting" else "running"
                    write_task_status(
                        cfg,
                        status=running_status,
                        phase=dispatch_phase,
                        message=str(payload.get("message", "")),
                        pid=int(payload.get("pid"))
                        if str(payload.get("pid", "")).isdigit() else None,
                        extra=extra,
                        target_host=target_host,
                    )
            elif snapshot.state == "failed":
                msg = str(payload.get("message", ""))
                if not msg or "[manual]" not in msg:
                    msg = f"[monitor] remote {dispatch_phase} failed"
                write_task_status(
                    cfg,
                    status="failed",
                    phase=dispatch_phase,
                    message=msg,
                    pid=int(payload.get("pid"))
                    if str(payload.get("pid", "")).isdigit() else None,
                    extra=extra,
                    target_host=target_host,
                )
            elif snapshot.state == "ok":
                write_task_status(
                    cfg,
                    status="ok",
                    phase="done",
                    message=str(payload.get("message", "")),
                    pid=int(payload.get("pid"))
                    if str(payload.get("pid", "")).isdigit() else None,
                    extra=extra,
                    target_host=target_host,
                )
            return read_task_status(cfg)

    if backend == "local":
        dispatch_job_id = str(payload.get("dispatch_job_id", "")).strip()
        if dispatch_job_id:
            launch = remote.launch_from_job_id(_dispatch_dir(cfg), dispatch_job_id)
            snapshot = remote.snapshot_local_launch(launch)
            dispatch_phase = snapshot.phase or launch.stage or phase
            extra = _dispatch_metadata(cfg, snapshot, "local")
            if snapshot.state in ("starting", "running"):
                running_status = "queued" if snapshot.state == "starting" else "running"
                write_task_status(
                    cfg,
                    status=running_status,
                    phase=dispatch_phase,
                    message=str(payload.get("message", "")),
                    pid=snapshot.pid,
                    extra=extra,
                    target_host=target_host,
                )
            elif snapshot.state == "failed":
                msg = str(payload.get("message", ""))
                if not msg or "[manual]" not in msg:
                    msg = f"[monitor] local {dispatch_phase} failed"
                write_task_status(
                    cfg,
                    status="failed",
                    phase=dispatch_phase,
                    message=msg,
                    pid=snapshot.pid,
                    extra=extra,
                    target_host=target_host,
                )
            elif snapshot.state == "ok":
                write_task_status(
                    cfg,
                    status="ok",
                    phase="done",
                    message=str(payload.get("message", "")),
                    pid=snapshot.pid,
                    extra=extra,
                    target_host=target_host,
                )
            return read_task_status(cfg)

    pid_text = str(payload.get("pid", "")).strip()
    if status in ("running", "queued") and pid_text.isdigit():
        pid = int(pid_text)
        if not _local_pid_alive(pid):
            write_task_status(
                cfg,
                status="failed",
                phase=phase,
                message="[monitor] local launcher pid is gone",
                pid=pid,
                target_host=target_host,
            )
            return read_task_status(cfg)

    return payload


def collect_task_statuses(tasks: Sequence[RunConfig],
                          *,
                          sync: bool) -> List[Dict[str, object]]:
    if sync:
        return [sync_task_status(task) for task in tasks]
    return [read_task_status(task) for task in tasks]


def _kill_local_task(payload: Dict[str, object]) -> bool:
    pid_text = str(payload.get("pid", "")).strip()
    if not pid_text.isdigit():
        return False
    pid = int(pid_text)
    if not _local_pid_alive(pid):
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return False
    except Exception:
        return False
    time.sleep(1)
    if _local_pid_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    return True


def kill_task(cfg: RunConfig) -> bool:
    payload = sync_task_status(cfg)
    if _status_has_terminal_state(payload):
        return False

    backend = _dispatch_backend_from_payload(payload)
    host = _status_host_from_payload(payload)
    target_host = str(payload.get("target_host", "")).strip() or None
    killed = False
    dispatch_dir = _dispatch_dir(cfg)
    launch = None
    if backend in ("remote", "local"):
        dispatch_job_id = str(payload.get("dispatch_job_id", "")).strip()
        if dispatch_job_id:
            launch = remote.launch_from_job_id(dispatch_dir, dispatch_job_id)
        else:
            stage = str(payload.get("dispatch_stage", "")).strip() or None
            launch = remote.latest_remote_launch(dispatch_dir, stage=stage)
            if launch is None:
                launch = remote.latest_remote_launch(dispatch_dir, stage="task")
            if launch is None:
                launch = remote.latest_remote_launch(dispatch_dir, stage="eval")
            if launch is None:
                launch = remote.latest_remote_launch(dispatch_dir, stage="run")

    if backend == "remote" and host and launch is not None:
        killed = remote.kill_remote_launch(host, launch, rc=143)
    elif backend == "local" and launch is not None:
        killed = remote.kill_local_launch(launch, rc=143)
    else:
        killed = _kill_local_task(payload)

    write_task_status(
        cfg,
        status="failed",
        phase=str(payload.get("phase", "unknown")),
        message="[manual] terminated by run_experiments.py --kill-running",
        pid=int(payload.get("pid"))
        if str(payload.get("pid", "")).isdigit() else None,
        extra={
            "dispatch_dir": str(_dispatch_dir(cfg)),
            "dispatch_backend": backend,
            "dispatch_job_id": payload.get("dispatch_job_id"),
            "dispatch_stage": payload.get("dispatch_stage"),
            "dispatch_state": "failed",
            "dispatch_phase": payload.get("dispatch_phase",
                                          payload.get("phase", "unknown")),
            "dispatch_rc": 143,
            "dispatch_pid": payload.get("dispatch_pid"),
            "dispatch_pid_alive": False,
            "manual_kill": True,
            "manual_kill_ok": killed,
        },
        target_host=target_host,
    )
    return killed


def submit_one(cfg: RunConfig) -> str:
    _load_env_from_script(cfg.repo_root / "env.sh")
    run_script, eval_script = _script_paths(cfg.repo_root, cfg.flow, cfg.tech,
                                            cfg.case)
    run_log, eval_log = _log_paths(cfg.flow, cfg.tech, cfg.case)
    local_host = socket.gethostname()
    exec_host = _target_label(cfg, local_host)
    if cfg.do_run and not run_script.exists():
        return f"[submit] ERROR: run.sh not found: {run_script}"
    if cfg.do_eval and not eval_script.exists():
        return f"[submit] ERROR: eval.sh not found: {eval_script}"

    current = sync_task_status(cfg)
    active_status = str(current.get("status", "unknown"))
    has_live_binding = bool(str(current.get("dispatch_job_id", "")).strip())
    if str(current.get("pid", "")).isdigit() and active_status in ("queued",
                                                                   "running"):
        has_live_binding = True
    if active_status in ("queued", "running") and has_live_binding:
        return (
            f"[submit] SKIP: active job already exists for "
            f"{cfg.flow}/{cfg.tech}/{cfg.case} "
            f"job={current.get('dispatch_job_id', '')}"
        )

    if cfg.host:
        backend = "remote"
        launch = remote.submit_remote_task(
            repo_root=cfg.repo_root,
            host=cfg.host,
            dispatch_dir=_dispatch_dir(cfg),
            run_script=run_script,
            eval_script=eval_script,
            run_log=run_log,
            eval_log=eval_log,
            do_run=cfg.do_run,
            do_eval=cfg.do_eval,
        )
        snapshot = remote.snapshot_remote_launch(cfg.host, launch)
    else:
        backend = "local"
        launch = remote.submit_local_task(
            repo_root=cfg.repo_root,
            dispatch_dir=_dispatch_dir(cfg),
            run_script=run_script,
            eval_script=eval_script,
            run_log=run_log,
            eval_log=eval_log,
            do_run=cfg.do_run,
            do_eval=cfg.do_eval,
            env=os.environ.copy(),
        )
        snapshot = remote.snapshot_local_launch(launch)
    deadline = time.time() + 3
    while time.time() < deadline and not snapshot.state:
        time.sleep(0.2)
        snapshot = (
            remote.snapshot_remote_launch(cfg.host, launch)
            if backend == "remote"
            else remote.snapshot_local_launch(launch)
        )
    if snapshot.state == "failed":
        status = "failed"
    elif snapshot.state == "ok":
        status = "ok"
    elif snapshot.state == "starting":
        status = "queued"
    else:
        status = "running"
    phase = snapshot.phase or "starting"
    write_task_status(
        cfg,
        status=status,
        phase=phase,
        message=f"[dispatch] submitted detached {backend} task",
        pid=snapshot.pid,
        extra=_dispatch_metadata(cfg, snapshot, backend),
        target_host=exec_host,
    )
    return (
        f"[submit] {exec_host} {cfg.flow}/{cfg.tech}/{cfg.case} "
        f"job={launch.job_id} status={status} phase={phase}"
    )


# ==============================================================================
# CLI + orchestration
# ==============================================================================


def _dedup_keep_order(xs: Iterable[str]) -> List[str]:
    seen = set()
    out = []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def build_tasks(
    flows: List[str],
    techs: List[str],
    cases: List[str],
    repo_root: Path,
    do_run: bool,
    do_eval: bool,
) -> List[RunConfig]:
    flow_set = set(flows)
    tech_set = set(techs)
    case_set = set(cases)
    tasks: List[RunConfig] = []
    for flow, tech, case in discover_available_tasks(repo_root):
        if flow not in flow_set or tech not in tech_set or case not in case_set:
            continue

        run_script, eval_script = _script_paths(repo_root, flow, tech, case)
        if do_run and not run_script.exists():
            continue
        if do_eval and not eval_script.exists():
            continue

        tasks.append(
            RunConfig(
                flow=flow,
                tech=tech,
                case=case,
                repo_root=repo_root,
                do_run=do_run,
                do_eval=do_eval,
            ))
    return tasks


def shard_tasks(tasks: Sequence[RunConfig], num_shards: int,
                shard_index: int) -> List[RunConfig]:
    if num_shards <= 1:
        return list(tasks)
    return [task for idx, task in enumerate(tasks) if idx % num_shards == shard_index]


def assign_hosts(tasks: Sequence[RunConfig], hosts: Sequence[str],
                 max_jobs_per_host: int) -> List[RunConfig]:
    if not hosts:
        return list(tasks)
    slots = [(host, slot) for host in hosts for slot in range(max_jobs_per_host)]
    out: List[RunConfig] = []
    for idx, task in enumerate(tasks):
        host, host_slot = slots[idx % len(slots)]
        out.append(replace(task, host=host, host_slot=host_slot))
    return out


def _slot_key(task: RunConfig) -> Optional[Tuple[str, int]]:
    if task.host:
        return (task.host, task.host_slot)
    return None


def _active_dispatch_count(task_payloads: Sequence[Tuple[RunConfig, Dict[str, object]]]) -> int:
    count = 0
    for _, payload in task_payloads:
        if not str(payload.get("dispatch_job_id", "")).strip():
            continue
        if str(payload.get("status", "unknown")) in ("queued", "running"):
            count += 1
    return count


def _active_slots(task_payloads: Sequence[Tuple[RunConfig, Dict[str, object]]]) -> set:
    active = set()
    for task, payload in task_payloads:
        if str(payload.get("status", "unknown")) not in ("queued", "running"):
            continue
        if not str(payload.get("dispatch_job_id", "")).strip():
            continue
        slot = _slot_key(task)
        if slot is not None:
            active.add(slot)
    return active


def run_detached_scheduler(tasks: Sequence[RunConfig], jobs: int,
                           status_interval: int) -> int:
    init_task_statuses(tasks)
    initial_payloads = collect_task_statuses(tasks, sync=True)
    pending = [
        task for task, payload in zip(tasks, initial_payloads)
        # A previous failure must be retryable by running the same command
        # again.  Only successful tasks are complete for submission purposes;
        # failed remains terminal for --show-status/--monitor.
        if str(payload.get("status", "unknown")) != "ok"
        and not (
            str(payload.get("dispatch_job_id", "")).strip()
            and str(payload.get("status", "unknown")) in ("queued", "running")
        )
    ]

    while True:
        payloads = collect_task_statuses(tasks, sync=True)
        task_payloads = list(zip(tasks, payloads))
        active_slots = _active_slots(task_payloads)
        active_count = _active_dispatch_count(task_payloads)

        made_progress = True
        while pending and made_progress:
            made_progress = False
            if active_count >= jobs:
                break

            for idx, task in enumerate(pending):
                slot = _slot_key(task)
                if slot is not None and slot in active_slots:
                    continue
                msg = submit_one(task)
                print(msg)
                pending.pop(idx)
                payload = sync_task_status(task)
                if str(payload.get("dispatch_job_id", "")).strip() and str(
                        payload.get("status", "unknown")) in ("queued", "running"):
                    active_count += 1
                    if slot is not None:
                        active_slots.add(slot)
                made_progress = True
                break

        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads, only_active=True)
        if all(_status_has_terminal_state(p) for p in payloads):
            return 0
        time.sleep(status_interval)


def parse_args(default_repo_root: Optional[str], ) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=
        "Run ORFS experiments (ORD/CDS) in parallel with per-task logs.")
    p.add_argument(
        "--flow",
        choices=["ord", "cds", "all"],
        default="all",
        help="Which flow to run (default: all).",
    )
    p.add_argument(
        "--tech",
        action="append",
        default=[],
        help="Tech name. Repeatable. Default: run all preset techs.",
    )
    p.add_argument(
        "--case",
        action="append",
        default=[],
        help="Case/design name. Repeatable. Default: run all preset cases.",
    )
    p.add_argument(
        "--jobs",
        type=int,
        default=9,
        help="Parallel workers for local mode.",
    )
    p.add_argument(
        "--host-list",
        "--host_list",
        dest="host_list",
        nargs="+",
        default=None,
        help="Dispatch tasks over SSH using an inline host list only.",
    )
    p.add_argument(
        "--max-jobs-per-host",
        type=int,
        default=1,
        help="Maximum concurrent task queues per host in --host-list mode.",
    )
    p.add_argument(
        "--status-interval",
        type=int,
        default=30,
        help="Seconds between status summary prints.",
    )
    action_group = p.add_mutually_exclusive_group()
    action_group.add_argument(
        "--list",
        action="store_true",
        help="List matched tasks and exit.",
    )
    action_group.add_argument(
        "--show-status",
        action="store_true",
        help="Sync and print current status of matched tasks, then exit.",
    )
    action_group.add_argument(
        "--monitor",
        action="store_true",
        help="Sync and monitor matched tasks until all are terminal.",
    )
    action_group.add_argument(
        "--kill-running",
        action="store_true",
        help="Terminate matched running or queued tasks, then exit.",
    )
    action_group.add_argument(
        "--kill-job",
        action="append",
        default=[],
        help="Terminate the specified dispatch job id(s), then exit.",
    )
    p.add_argument(
        "--num-shards",
        type=int,
        default=1,
        help="Split matched tasks into N deterministic shards.",
    )
    p.add_argument(
        "--shard-index",
        type=int,
        default=0,
        help="0-based shard index to run.",
    )
    stage_group = p.add_mutually_exclusive_group()
    stage_group.add_argument(
        "--eval-only",
        action="store_true",
        help="Only run eval.sh for each task.",
    )
    stage_group.add_argument(
        "--run-only",
        action="store_true",
        help="Only run run.sh for each task.",
    )

    p.add_argument(
        "--repo-root",
        default=default_repo_root,
        help="Local repo root path (default: env FLOW_HOME or script parent).",
    )
    p.add_argument(
        "--all-status",
        action="store_true",
        help="In --show-status/--monitor, print terminal tasks too.",
    )
    return p.parse_args()


def main() -> int:
    remote.install_signal_handlers()
    script_root = Path(__file__).resolve().parent
    _load_env_from_script(script_root / "env.sh")

    default_repo_root = os.environ.get("FLOW_HOME", str(script_root))
    args = parse_args(default_repo_root=default_repo_root, )

    repo_root = Path(args.repo_root).resolve() if args.repo_root else Path(
        __file__).resolve().parent

    if args.num_shards < 1:
        print("[MAIN] ERROR: --num-shards must be >= 1", file=sys.stderr)
        return 2
    if args.max_jobs_per_host < 1:
        print("[MAIN] ERROR: --max-jobs-per-host must be >= 1", file=sys.stderr)
        return 2
    if args.status_interval < 1:
        print("[MAIN] ERROR: --status-interval must be >= 1", file=sys.stderr)
        return 2
    if args.shard_index < 0 or args.shard_index >= args.num_shards:
        print("[MAIN] ERROR: --shard-index must satisfy 0 <= shard-index < num-shards",
              file=sys.stderr)
        return 2

    available = discover_available_tasks(repo_root)
    if not available:
        print(f"[MAIN] ERROR: no runnable tasks found under {repo_root / 'test'}",
              file=sys.stderr)
        return 2

    default_techs = _dedup_keep_order([tech for _, tech, _ in available])
    default_cases = _dedup_keep_order([case for _, _, case in available])

    techs = _dedup_keep_order(args.tech) if args.tech else default_techs
    cases = _dedup_keep_order(args.case) if args.case else default_cases

    if args.flow == "all":
        flows = ["ord", "cds"]
    else:
        flows = [args.flow]

    do_run = not args.eval_only
    do_eval = not args.run_only

    tasks = build_tasks(
        flows=flows,
        techs=techs,
        cases=cases,
        repo_root=repo_root,
        do_run=do_run,
        do_eval=do_eval,
    )
    tasks = shard_tasks(tasks, args.num_shards, args.shard_index)

    hosts: List[str] = []
    management_mode = (
        args.show_status or args.monitor or args.kill_running
        or bool(args.kill_job)
    )

    if args.host_list and not management_mode:
        hosts = parse_host_list(args.host_list)
        if not hosts:
            print("[MAIN] ERROR: no hosts parsed from --host-list",
                  file=sys.stderr)
            return 2
        tasks = assign_hosts(tasks, hosts, args.max_jobs_per_host)
    elif args.host_list and management_mode:
        print(
            "[MAIN] management mode ignores --host-list and uses existing status/dispatch metadata."
        )

    print(f"[MAIN] repo_root={repo_root}")
    print(f"[MAIN] flows={flows} techs={techs} cases={cases} jobs={args.jobs}")
    print(f"[MAIN] stages: run={do_run} eval={do_eval}")
    print(f"[MAIN] shard={args.shard_index}/{args.num_shards}")
    if hosts:
        print(
            f"[MAIN] host_dispatch=ssh host_count={len(hosts)} max_jobs_per_host={args.max_jobs_per_host}"
        )
    print(
        f"[MAIN] total_tasks={len(tasks)} logs under run_logs/<tech>/<flow>/..."
    )

    if args.list:
        for idx, task in enumerate(tasks):
            if task.host:
                print(
                    f"{idx:03d} {_target_label(task)} {task.flow} {task.tech} {task.case}"
                )
            else:
                print(f"{idx:03d} {task.flow} {task.tech} {task.case}")
        return 0

    if not tasks:
        print("[MAIN] No tasks matched the requested filters.")
        return 0

    if args.show_status:
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads, only_active=not args.all_status)
        return 0

    if args.monitor:
        while True:
            payloads = collect_task_statuses(tasks, sync=True)
            print_status_summary_from_payloads(payloads)
            print_status_details(payloads, only_active=not args.all_status)
            if all(_status_has_terminal_state(p) for p in payloads):
                print("[MAIN] Monitor completed: all matched tasks are terminal.")
                return 0
            time.sleep(args.status_interval)

    if args.kill_job:
        payloads = collect_task_statuses(tasks, sync=True)
        job_to_task = {}
        for task, payload in zip(tasks, payloads):
            job_id = str(payload.get("dispatch_job_id", "")).strip()
            if job_id:
                job_to_task[job_id] = task
        killed = 0
        missing = 0
        for job_id in args.kill_job:
            task = job_to_task.get(job_id)
            if task is None:
                print(f"[MAIN] kill_job: no matched active task for job={job_id}")
                missing += 1
                continue
            if kill_task(task):
                killed += 1
            else:
                missing += 1
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads, only_active=not args.all_status)
        print(f"[MAIN] kill_job: killed={killed} missing_or_terminal={missing}")
        return 0

    if args.kill_running:
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        killed = 0
        skipped = 0
        for task, payload in zip(tasks, payloads):
            if _status_has_terminal_state(payload):
                skipped += 1
                continue
            if kill_task(task):
                killed += 1
            else:
                skipped += 1
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads, only_active=not args.all_status)
        print(f"[MAIN] kill_running: killed={killed} skipped={skipped}")
        return 0

    print(f"[MAIN] live status files under {_status_dir(repo_root)}")

    # Run
    try:
        run_detached_scheduler(tasks, jobs=args.jobs, status_interval=args.status_interval)
    except KeyboardInterrupt:
        print("[MAIN] KeyboardInterrupt received, leaving detached jobs running.")
        payloads = collect_task_statuses(tasks, sync=True)
        print_status_summary_from_payloads(payloads)
        print_status_details(payloads, only_active=True)
        print("[MAIN] Re-run with --monitor to continue watching or --kill-running to terminate active jobs.")
        return 130

    print("[MAIN] All experiments completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
