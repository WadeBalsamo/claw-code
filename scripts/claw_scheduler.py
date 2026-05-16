#!/usr/bin/env python3
"""
claw-scheduler — Named resource scheduler daemon for claw-code.

Maintains a named-resource registry with FIFO queuing for contended resources.
Designed to run as a systemd service or standalone process.

Resources are named strings (e.g. "3090-vram", "cpu", "tpu") that tasks request
via --resource. Each resource has a max_parallel cap (default: 1). When all slots
are full, new jobs queue in FIFO order. Jobs that never specify --resource bypass
the scheduler entirely.

Directory layout:
  /tmp/claw-runs/
    _locks/           ← resource lock files (flock-based)
    _queue/           ← FIFO queue (JSONL per resource)
      <resource>.queue
    _leases/          ← active lease files
      <task_id>.lease
    _ledger/          ← scheduler state (for external monitoring)
      scheduler.json

Protocol:
  run-claw-code calls the scheduler as a library function when --resource is
  specified. The scheduler blocks until the resource is available or returns
  immediately if slots are free.

Usage:
  python3 -m claw_scheduler [--daemon] [--state-dir /tmp/claw-runs]
  # or import and use schedule_task() directly
"""

import fcntl
import json
import logging
import os
import select
import signal
import sys
import threading
import time
import uuid
from collections import OrderedDict, defaultdict
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

logger = logging.getLogger("claw-scheduler")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DEFAULT_STATE_DIR = Path("/tmp/claw-runs")
DEFAULT_MAX_PARALLEL = 1
DEFAULT_POLL_INTERVAL = 5  # seconds
DEFAULT_QUEUE_MAX_AGE = 86400  # 24 hours; expire stale queue entries


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------
@dataclass
class TaskRequest:
    """A task requesting a named resource."""
    task_id: str
    resource: str
    agent_preset: str
    dir: str
    plan: str
    remote: bool
    timeout: int
    max_parallel: int
    queued_at: str = ""
    claimed_at: str = ""
    status: str = "queued"  # queued | claimed | running | done | timeout | failed


@dataclass
class ResourceSlot:
    """A slot in a resource's parallel capacity."""
    slot_id: int
    task_id: str
    pid: int
    claimed_at: str


@dataclass
class ResourceState:
    """State for one named resource."""
    name: str
    max_parallel: int = DEFAULT_MAX_PARALLEL
    slots: List[ResourceSlot] = field(default_factory=list)
    queue: List[TaskRequest] = field(default_factory=list)

    @property
    def available_slots(self) -> int:
        return self.max_parallel - len(self.slots)

    @property
    def is_saturated(self) -> bool:
        return self.available_slots <= 0


# ---------------------------------------------------------------------------
# Scheduler
# ---------------------------------------------------------------------------
class Scheduler:
    """
    Named-resource scheduler with FIFO queuing.

    Thread-safe: uses a single lock for all state mutations.
    """

    def __init__(self, state_dir: Path = DEFAULT_STATE_DIR):
        self.state_dir = state_dir
        self.locks_dir = state_dir / "_locks"
        self.queue_dir = state_dir / "_queue"
        self.leases_dir = state_dir / "_leases"
        self.ledger_dir = state_dir / "_ledger"

        # Ensure directories exist
        for d in [self.locks_dir, self.queue_dir, self.leases_dir, self.ledger_dir]:
            d.mkdir(parents=True, exist_ok=True)

        # In-memory state
        self._lock = threading.Lock()
        self._resources: Dict[str, ResourceState] = {}
        self._running = False
        self._stop_event = threading.Event()

        # Load persistent state
        self._load_state()

    # -----------------------------------------------------------------------
    # Public API
    # -----------------------------------------------------------------------

    def schedule(
        self,
        resource: str,
        task_id: str,
        agent_preset: str = "",
        dir: str = "",
        plan: str = "",
        remote: bool = False,
        timeout: int = 1800,
        max_parallel: int = DEFAULT_MAX_PARALLEL,
    ) -> str:
        """
        Schedule a task for a named resource.

        Returns immediately with status 'claimed' if a slot is available,
        or 'queued' if all slots are full. The caller should poll
        claim_status(task_id) to detect when the task gets promoted.
        """
        with self._lock:
            if resource not in self._resources:
                self._resources[resource] = ResourceState(
                    name=resource,
                    max_parallel=max_parallel,
                )

            res = self._resources[resource]
            now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

            request = TaskRequest(
                task_id=task_id,
                resource=resource,
                agent_preset=agent_preset,
                dir=dir,
                plan=plan,
                remote=remote,
                timeout=timeout,
                max_parallel=max_parallel,
                queued_at=now,
            )

            if res.available_slots > 0:
                # Claim immediately
                slot = ResourceSlot(
                    slot_id=self._next_slot_id(res),
                    task_id=task_id,
                    pid=0,
                    claimed_at=now,
                )
                res.slots.append(slot)
                request.status = "claimed"
                request.claimed_at = now
                self._write_lease(task_id, slot)
            else:
                # Queue
                res.queue.append(request)
                request.status = "queued"
                self._write_queue_entry(resource, request)

            self._save_state()
            self._write_ledger()
            return request.status

    def claim_status(self, task_id: str) -> Optional[str]:
        """Return the status of a resource claim: 'queued', 'claimed', or None if unknown."""
        with self._lock:
            for res in self._resources.values():
                for req in res.queue:
                    if req.task_id == task_id:
                        return "queued"
                for slot in res.slots:
                    if slot.task_id == task_id:
                        return "claimed"
        # Check lease file
        lease_file = self.leases_dir / f"{task_id}.lease"
        if lease_file.exists():
            return "claimed"
        return None

    def release(self, task_id: str):
        """Release all resources held by a task. Must be called on completion/failure."""
        with self._lock:
            for res in self._resources.values():
                # Remove from slots
                res.slots = [s for s in res.slots if s.task_id != task_id]
                # Remove from queue
                res.queue = [q for q in res.queue if q.task_id != task_id]

                # Promote queued tasks to fill empty slots
                while res.available_slots > 0 and res.queue:
                    next_req = res.queue.pop(0)
                    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    slot = ResourceSlot(
                        slot_id=self._next_slot_id(res),
                        task_id=next_req.task_id,
                        pid=0,
                        claimed_at=now,
                    )
                    res.slots.append(slot)
                    next_req.status = "claimed"
                    next_req.claimed_at = now
                    self._write_lease(next_req.task_id, slot)
                    logger.info(
                        "Promoted queued task %s to resource %s (slot %d)",
                        next_req.task_id, res.name, slot.slot_id,
                    )

            # Clean up lease file
            lease_file = self.leases_dir / f"{task_id}.lease"
            if lease_file.exists():
                lease_file.unlink(missing_ok=True)

            self._save_state()
            self._write_ledger()

    def cleanup_stale_leases(self, max_age_seconds: int = 3600):
        """Remove leases older than max_age_seconds that have no running process."""
        with self._lock:
            now = time.time()
            for lease_file in self.leases_dir.iterdir():
                if not lease_file.name.endswith(".lease"):
                    continue
                try:
                    mtime = lease_file.stat().st_mtime
                    if now - mtime > max_age_seconds:
                        task_id = lease_file.stem  # Remove .lease suffix
                        # Check if PID is still alive
                        lease_data = json.loads(lease_file.read_text())
                        pid = lease_data.get("pid", 0)
                        if pid > 0 and self._is_pid_alive(pid):
                            continue  # Still running
                        logger.info("Cleaning up stale lease: %s", task_id)
                        self.release(task_id)
                except (json.JSONDecodeError, OSError):
                    lease_file.unlink(missing_ok=True)

    def get_resource_summary(self) -> Dict:
        """Return a snapshot of all resources for monitoring."""
        with self._lock:
            summary = {}
            for name, res in self._resources.items():
                summary[name] = {
                    "max_parallel": res.max_parallel,
                    "slots_used": len(res.slots),
                    "slots_available": res.available_slots,
                    "queue_depth": len(res.queue),
                    "active_tasks": [s.task_id for s in res.slots],
                    "queued_tasks": [q.task_id for q in res.queue],
                }
            return summary

    def register_resource(self, name: str, max_parallel: int = 1):
        """Register a named resource (idempotent)."""
        with self._lock:
            if name not in self._resources:
                self._resources[name] = ResourceState(
                    name=name,
                    max_parallel=max_parallel,
                )
                logger.info("Registered resource '%s' (max %d)", name, max_parallel)
            else:
                self._resources[name].max_parallel = max_parallel

    # -----------------------------------------------------------------------
    # Daemon mode
    # -----------------------------------------------------------------------

    def run_daemon(self):
        """Run the scheduler daemon loop."""
        self._running = True
        logger.info("claw-scheduler daemon started (state_dir=%s)", self.state_dir)

        def _signal_handler(signum, frame):
            logger.info("Received signal %d, shutting down...", signum)
            self._running = False
            self._stop_event.set()

        signal.signal(signal.SIGTERM, _signal_handler)
        signal.signal(signal.SIGINT, _signal_handler)

        poll_interval = float(os.environ.get("CLAW_SCHEDULER_POLL_INTERVAL", str(DEFAULT_POLL_INTERVAL)))

        while self._running and not self._stop_event.is_set():
            try:
                self._process_queue_file()
                self.cleanup_stale_leases()
                self._write_ledger()
            except Exception as exc:
                logger.error("Error in daemon loop: %s", exc)

            self._stop_event.wait(poll_interval)

        logger.info("claw-scheduler daemon stopped")

    # -----------------------------------------------------------------------
    # Internal — queue file processing
    # -----------------------------------------------------------------------

    def _process_queue_file(self):
        """Scan queue directory for new job descriptors submitted by agents."""
        queue_dir = self.queue_dir
        if not queue_dir.exists():
            return

        for queue_file in queue_dir.iterdir():
            if not queue_file.name.endswith(".queue"):
                continue
            if not queue_file.is_file():
                continue

            try:
                content = queue_file.read_text().strip()
                if not content:
                    continue

                jobs = []
                for line in content.split("\n"):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        jobs.append(json.loads(line))
                    except json.JSONDecodeError:
                        logger.warning("Invalid JSON in queue file %s: %s", queue_file.name, line[:100])

                if not jobs:
                    continue

                resource = jobs[0].get("resource", "default")
                max_parallel = jobs[0].get("max_parallel", DEFAULT_MAX_PARALLEL)

                self.register_resource(resource, max_parallel)

                for job in jobs:
                    task_id = job.get("task_id", str(uuid.uuid4()))
                    status = self.schedule(
                        resource=resource,
                        task_id=task_id,
                        agent_preset=job.get("agent_preset", ""),
                        dir=job.get("dir", "."),
                        plan=job.get("plan", ""),
                        remote=job.get("remote", False),
                        timeout=job.get("timeout", 1800),
                        max_parallel=max_parallel,
                    )
                    logger.info("Job %s scheduled on '%s': %s", task_id, resource, status)

                # Clear processed queue file
                queue_file.write_text("")

            except Exception as exc:
                logger.error("Error processing queue file %s: %s", queue_file.name, exc)

    @staticmethod
    def _is_pid_alive(pid: int) -> bool:
        """Check if a process is alive."""
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    @staticmethod
    def _next_slot_id(res: ResourceState) -> int:
        """Generate the next available slot ID for a resource."""
        used = {s.slot_id for s in res.slots}
        candidate = 1
        while candidate in used:
            candidate += 1
        return candidate

    # -----------------------------------------------------------------------
    # Persistence
    # -----------------------------------------------------------------------

    def _save_state(self):
        """Persist scheduler state to disk."""
        state_file = self.ledger_dir / "scheduler.json"
        try:
            data = {
                "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "resources": self.get_resource_summary(),
            }
            state_file.write_text(json.dumps(data, indent=2))
        except OSError as exc:
            logger.error("Failed to save scheduler state: %s", exc)

    def _load_state(self):
        """Load persisted state from disk."""
        state_file = self.ledger_dir / "scheduler.json"
        if not state_file.exists():
            return
        try:
            data = json.loads(state_file.read_text())
            resource_data = data.get("resources", {})
            for name, info in resource_data.items():
                max_parallel = info.get("max_parallel", DEFAULT_MAX_PARALLEL)
                self.register_resource(name, max_parallel)
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Failed to load scheduler state: %s", exc)

    def _write_lease(self, task_id: str, slot: ResourceSlot):
        """Write a lease file for a claimed resource."""
        lease_file = self.leases_dir / f"{task_id}.lease"
        lease_file.write_text(json.dumps(asdict(slot), indent=2))

    def _write_queue_entry(self, resource: str, request: TaskRequest):
        """Append to a resource's queue file."""
        queue_file = self.queue_dir / f"{resource}.queue"
        with queue_file.open("a") as f:
            f.write(json.dumps(asdict(request)) + "\n")

    def _write_ledger(self):
        """Write the human-readable ledger for external monitoring."""
        state_file = self.ledger_dir / "scheduler.json"
        try:
            data = {
                "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "resources": self.get_resource_summary(),
                "daemon_running": self._running,
            }
            state_file.write_text(json.dumps(data, indent=2))
        except OSError as exc:
            logger.error("Failed to write ledger: %s", exc)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
def main():
    """CLI entry for claw-scheduler."""
    import argparse

    parser = argparse.ArgumentParser(
        description="claw-scheduler — named resource scheduler for claw-code",
    )
    parser.add_argument(
        "--daemon",
        action="store_true",
        help="Run as a persistent daemon (otherwise exit after processing queue once)",
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=DEFAULT_STATE_DIR,
        help=f"State directory (default: {DEFAULT_STATE_DIR})",
    )
    parser.add_argument(
        "--register-resource",
        nargs=2,
        metavar=("NAME", "MAX_PARALLEL"),
        action="append",
        dest="register_resources",
        help="Register a named resource (e.g. --register-resource 3090-vram 1)",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Print resource status snapshot and exit",
    )
    parser.add_argument(
        "--release",
        metavar="TASK_ID",
        help="Release all resources held by a task",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable verbose logging",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        stream=sys.stderr,
    )

    scheduler = Scheduler(state_dir=args.state_dir)

    # Register resources
    if args.register_resources:
        for name, max_parallel in args.register_resources:
            scheduler.register_resource(name, int(max_parallel))

    # Release
    if args.release:
        scheduler.release(args.release)
        logger.info("Released resources for task: %s", args.release)
        return

    # Status
    if args.status:
        summary = scheduler.get_resource_summary()
        print(json.dumps(summary, indent=2))
        return

    # Daemon or one-shot
    if args.daemon:
        scheduler.run_daemon()
    else:
        # One-shot: process queue once
        scheduler._process_queue_file()
        scheduler.cleanup_stale_leases()
        scheduler._write_ledger()
        summary = scheduler.get_resource_summary()
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
