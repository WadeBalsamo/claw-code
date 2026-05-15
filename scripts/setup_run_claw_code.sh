#!/usr/bin/env bash
# =============================================================================
# setup_run_claw_code.sh
#
# This script prepares the environment for the `run-claw-code` entrypoint.
# It creates the required directory structure, installs helper utilities,
# and places a stub `run-claw-code` wrapper that will be expanded later
# with the full implementation described in the design document.
#
# Usage:
#   cd /home/wisgood/claw-code
#   ./scripts/setup_run_claw_code.sh
#
# After running this script you will have:
#   - ~/.sub-claw-code/presets/          ← directory for preset JSON files
#   - /tmp/claw-runs/_locks/             ← lock files used by the scheduler
#   - A stub /home/wisgood/claw-code/run-claw-code (executable)
#   - A skeleton scheduler daemon at
#        /home/wisgood/claw-code/scripts/claw_scheduler.py
#
# The generated stub calls into the scheduler daemon and respects the
# four‑line output contract required by calling agents.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Create top‑level directories
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "Repository root: $REPO_ROOT"

# Preset directory
PRESET_DIR="$HOME/.sub-claw-code/presets"
mkdir -p "$PRESET_DIR"
echo "Created preset directory: $PRESET_DIR"

# Runtime work‑tree root (used by the entrypoint)
RUN_ROOT="/tmp/claw-runs"
mkdir -p "$RUN_ROOT"
echo "Created runtime root: $RUN_ROOT"

# Lock directory
LOCK_DIR="/tmp/claw-runs/_locks"
mkdir -p "$LOCK_DIR"
echo "Created lock directory: $LOCK_DIR"

# Scheduler queue directory (FIFO)
QUEUE_DIR="/tmp/claw-runs/_queue"
mkdir -p "$QUEUE_DIR"
echo "Created queue directory: $QUEUE_DIR"

# ---------------------------------------------------------------------------
# 2. Install helper utilities
# ---------------------------------------------------------------------------
# 2.1. jq – JSON processing
if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq (JSON processor)..."
    sudo apt-get update -qq
    sudo apt-get install -y jq >/dev/null
fi

# 2.2. uuidgen – UUID generation
if ! command -v uuidgen >/dev/null 2>&1; then
    echo "Installing util-linux (uuidgen)..."
    sudo apt-get install -y util-linux >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. Create placeholder preset example
# ---------------------------------------------------------------------------
cat >"$PRESET_DIR/dev-frontend.json" <<'EOF'
{
  "preset_name": "dev-frontend",
  "model_alias": "qwen3-coder-next",
  "system_prompt": "You are a helpful coding assistant. Answer concisely.",
  "allowed_tools": ["bash", "python", "git"],
  "max_context": 8192,
  "temperature": 0.7
}
EOF
echo "Created example preset: $PRESET_DIR/dev-frontend.json"

# ---------------------------------------------------------------------------
# 4. Write the stub `run-claw-code` wrapper
# ---------------------------------------------------------------------------
RUN_CLAW_PATH="$REPO_ROOT/run-claw-code"
cat >"$RUN_CLAW_PATH" <<'EOF'
#!/usr/bin/env bash
# ---------------------------------------------------------------
# Stub / entrypoint for run-claw-code
#
# This file is intentionally minimal – the real implementation lives
# in the `claw-scheduler` daemon (see scripts/claw_scheduler.py).
# The stub simply forwards arguments to the daemon and respects the
# four‑line output contract.
# ---------------------------------------------------------------

# Resolve the location of the scheduler daemon (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULER_PY="$SCRIPT_DIR/scripts/claw_scheduler.py"

# Forward all arguments to the scheduler daemon
exec python3 "$SCHEDULER_PY" "$@"
EOF
chmod +x "$RUN_CLAW_PATH"
echo "Created stub entrypoint: $RUN_CLAW_PATH"

# ---------------------------------------------------------------------------
# 5. Install the scheduler daemon skeleton
# ---------------------------------------------------------------------------
SCHEDULER_PATH="$REPO_ROOT/scripts/claw_scheduler.py"
mkdir -p "$(dirname "$SCHEDULER_PATH")"
cat >"$SCHEDULER_PATH" <<'PYTHON'
#!/usr/bin/env python3
"""
Skeleton of the claw‑scheduler daemon.

* Listens for job descriptors in /tmp/claw-runs/_queue (JSON lines).
* Acquires the appropriate lock (GPU/CPU/remote).
* Writes status.json, launches the background claw-code process,
  handles timeout, captures git diff and summary, and finally emits
  the four‑line result to stdout.
* Maintains /PCAI-root/ledger/scheduler_state.json for external monitoring.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
import signal
import fcntl
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parents[1]
RUN_ROOT = Path("/tmp/claw-runs")
LOCK_ROOT = RUN_ROOT / "_locks"
QUEUE_ROOT = RUN_ROOT / "_queue"
LEDGER_ROOT = Path("/PCAI-root/ledger")
STATUS_TEMPLATE = {
    "task_id": "",
    "status": "running",
    "started_at": "",   # ISO8601
    "agent_preset": "",
    "model": "",
    "dir": "",
    "pid": 0,
}
# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
def acq_lock(lock_path: Path, timeout: int = 30) -> bool:
    """Attempt to acquire an exclusive lock on lock_path."""
    lock_fd = lock_path.open("wb")
    try:
        return fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        return False

def release_lock(lock_path: Path):
    """Release the lock (called automatically on file close)."""
    lock_fd = lock_path.open("wb")
    fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)

def write_status(task_dir: Path, data: dict):
    (task_dir / "status.json").write_text(json.dumps(data, indent=2))

def read_status(task_dir: Path) -> dict:
    return json.loads((task_dir / "status.json").read_text())

def acquire_gpu_lock() -> bool:
    return acq_lock(LOCK_ROOT / "gpu.lock")

def acquire_cpu_lock(slot_idx: int) -> bool:
    return acq_lock(LOCK_ROOT / f"cpu.slot.{slot_idx}")

def acquire_remote_lock() -> bool:
    return acq_lock(LOCK_ROOT / "remote.lock")

def release_all_locks():
    for lock_file in LOCK_ROOT.iterdir():
        try:
            release_lock(lock_file)
        except Exception:
            pass

def acquire_queue_write():
    """Open the current queue file for appending a new descriptor."""
    queue_file = QUEUE_ROOT / "pending.jsonl"
    return queue_file.open("a")

def acquire_queue_read():
    """Open the queue file for reading line‑by‑line."""
    return QUEUE_ROOT / "pending.jsonl"

def pop_next_job():
    """Read and remove the first JSON line from the queue, if any."""
    queue_file = QUEUE_ROOT / "pending.jsonl"
    if not queue_file.exists():
        return None
    with acquire_queue_read() as f:
        line = f.readline()
        if not line:
            return None
        try:
            job = json.loads(line)
            # Remove the line we just consumed
            with acquire_queue_write() as w:
                w.seek(0)
                content = w.read()
                w.truncate()
            return job
        except json.JSONDecodeError:
            return None

def emit_result(task_dir: Path):
    """Print the four‑line result to stdout (exactly as required)."""
    status_path = task_dir / "status.json"
    diff_path   = task_dir / "diff.patch"
    summary_path= task_dir / "summary.md"
    print(str(status_path))
    print(str(diff_path))
    print(str(summary_path))
    # The caller also receives the task_id as the first line of its own stdout.
    print(str(task_dir / "task_id"))  # redundant but matches spec
    sys.stdout.flush()

# ---------------------------------------------------------------------------
# Main processing loop
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="claw‑scheduler daemon entry")
    parser.add_argument("preset_name", help="Preset JSON filename in ~/.sub-claw-code/presets")
    parser.add_argument("--dir", dest="work_dir", required=True, help="Path to the git repo to run in")
    parser.add_argument("--plan", dest="plan", required=True, help="Task brief")
    parser.add_argument("--remote", action="store_true", help="Force use of OpenRouter endpoint")
    parser.add_argument("--timeout", type=int, default=1800, help="Timeout in seconds")
    args = parser.parse_args()

    # Resolve preset
    preset_path = Path.home() / ".sub-claw-code" / "presets" / f"{args.preset_name}.json"
    if not preset_path.is_file():
        print(f"Preset not found: {preset_path}", file=sys.stderr)
        sys.exit(1)
    preset = json.loads(preset_path.read_text())

    # Generate task id
    task_id = preset.get("task_id") or str(uuid.uuid4())
    task_dir = RUN_ROOT / task_id
    task_dir.mkdir(parents=True, exist_ok=True)

    # Acquire appropriate lock(s)
    use_remote = args.remote
    if use_remote:
        if not acquire_remote_lock():
            print("Another remote job is running – please wait", file=sys.stderr)
            sys.exit(1)
    else:
        if not acquire_gpu_lock():
            print("GPU job in progress – please wait", file=sys.stderr)
            sys.exit(1)
        # Simple CPU slot allocation (first free slot)
        cpu_lock_path = LOCK_ROOT / "cpu.lock"
        cpu_lock_fd = cpu_lock_path.open("wb")
        if not fcntl.flock(cpu_lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB):
            print("CPU slots exhausted – please wait", file=sys.stderr)
            release_all_locks()
            sys.exit(1)

    # Write initial status
    initial_status = STATUS_TEMPLATE.copy()
    initial_status.update({
        "task_id": task_id,
        "status": "running",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "agent_preset": args.preset_name,
        "model": preset["model_alias"],
        "dir": args.work_dir,
        "pid": 0,
    })
    write_status(task_dir, initial_status)

    # -----------------------------------------------------------------------
    # Launch the background claw-code process
    # -----------------------------------------------------------------------
    env = os.environ.copy()
    env["CLW_REMOTE"] = str(use_remote)
    if use_remote:
        if "OPENROUTER_API_KEY" in env:
            env["OPENAI_API_KEY"] = env["OPENROUTER_API_KEY"]
        env["OPENAI_BASE_URL"] = "http://127.0.0.1:8000/v1"  # placeholder – real URL injected by daemon

    # Build command line (the stub `run-claw-code` lives in the repo root)
    cmd = [
        sys.executable,               # python interpreter
        str(Path(__file__).parent / "run-claw-code"),
        "--agent", args.preset_name,
        "--dir",   args.work_dir,
        "--plan",  args.plan,
        "--timeout", str(args.timeout),
    ]
    if use_remote:
        cmd.extend(["--remote"])

    # Detach the process
    child = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
    )

    # Store child PID for later cleanup
    (task_dir / "child.pid").write_text(str(child.pid))

    # -----------------------------------------------------------------------
    # Timeout handling
    # -----------------------------------------------------------------------
    def timeout_handler(signum, frame):
        print("Timeout expired – terminating child", file=sys.stderr)
        child.terminate()
        child.wait()
        sys.exit(1)

    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(args.timeout)

    # -----------------------------------------------------------------------
    # Wait for child completion
    # -----------------------------------------------------------------------
    try:
        child.wait()
        exit_code = child.returncode
    finally:
        signal.alarm(0)  # cancel alarm

    # -----------------------------------------------------------------------
    # Post‑processing based on exit code
    # -----------------------------------------------------------------------
    if exit_code == 0:
        # Success: capture git diff and summary
        worktree_path = task_dir / "worktree"
        if worktree_path.is_dir():
            os.chdir(args.work_dir)
            subprocess.run(["git", "diff", "--no-pager", "--stat", "main..HEAD"],
                           stdout=open(task_dir / "diff.patch", "w"),
                           stderr=subprocess.DEVNULL)
            # Assume the agent wrote a summary file at /tmp/claw-summary.txt inside worktree
            summary_src = worktree_path / "tmp" / "claw-summary.txt"
            summary_dest = task_dir / "summary.md"
            if summary_src.is_file():
                summary_dest.write_bytes(summary_src.read_bytes())
            else:
                summary_dest.touch()
        else:
            # Fallback – create empty artifacts
            task_dir / "diff.patch".touch()
            task_dir / "summary.md".touch()

        final_status = {
            "task_id": task_id,
            "status": "done",
            "completed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "exit_code": exit_code,
            "files_changed": 0,
            "lines_added": 0,
            "lines_removed": 0,
        }
    else:
        # Failure – capture error snippet
        final_status = {
            "task_id": task_id,
            "status": "failed",
            "error": f"process exited with {exit_code}",
            "session_log_path": str(task_dir / "session.log"),
        }

    write_status(task_dir, final_status)

    # -----------------------------------------------------------------------
    # Release locks and emit result
    # -----------------------------------------------------------------------
    release_all_locks()
    emit_result(task_dir)

if __name__ == "__main__":
    main()
PYTHON
chmod +x "$SCHEDULER_PATH"
echo "Created scheduler skeleton: $SCHEDULER_PATH"

# ---------------------------------------------------------------------------
# 6. Final instructions
# ---------------------------------------------------------------------------
cat <<'EOF'

Setup complete!

Next steps:
1. Create preset JSON files in $PRESET_DIR (e.g., dev-frontend.json).
2. Implement the full `run-claw-code` logic inside the stub (or replace the stub
   with the complete implementation later).
3. Run the scheduler daemon (e.g., `python3 scripts/claw_scheduler.py dev-frontend --dir /home/wisgood/claw-code --plan "..."`).
4. Test the four‑line output contract with a simple task.

EOF