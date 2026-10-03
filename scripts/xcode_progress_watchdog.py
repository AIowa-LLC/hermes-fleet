#!/usr/bin/env python3
"""Run one owned Xcode invocation; fail when test progress stops.

Keep the original log/result bundle and exit status. No retries or simulator
resets: an interrupted invocation is failure, never acceptance evidence.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time


PROGRESS = re.compile(r"(?:Test (?:Case|Suite) .*(?:started|passed|failed)|"
                      r"^\s*t\s*=\s*\d+(?:\.\d+)?s?\s|Executed \d+ test)", re.M)


def stop(process: subprocess.Popen, grace: float = 5) -> None:
    # The child owns a new process group. Never signal other Xcode lanes.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(command: list[str], log: Path, report: Path, timeout: float,
        poll: float = 1) -> int:
    started = last_progress = time.monotonic()
    offset = 0
    tail = ""
    timed_out = False
    with log.open("wb") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            while process.poll() is None:
                with log.open("rb") as reader:
                    reader.seek(offset)
                    chunk = reader.read(1024 * 1024)
                    offset += len(chunk)
                text = tail + chunk.decode("utf-8", errors="replace")
                complete, _, tail = text.rpartition("\n")
                if chunk and PROGRESS.search(complete):
                    last_progress = time.monotonic()
                # Retain only the incomplete line, so a previous progress
                # marker cannot keep refreshing the deadline via startup noise.
                tail = tail[-4096:]
                if time.monotonic() - last_progress >= timeout:
                    timed_out = True
                    stop(process)
                    break
                time.sleep(poll)
        except BaseException:
            stop(process)
            raise
    code = 124 if timed_out else process.returncode
    if code < 0:
        code = 128 - code
    report.write_text(json.dumps({
        "schema": 1, "timed_out": timed_out, "exit_code": code,
        "elapsed_seconds": round(time.monotonic() - started, 2),
        "seconds_without_test_progress": round(time.monotonic() - last_progress, 2),
        "timeout_seconds": timeout,
    }, indent=2) + "\n")
    if timed_out:
        with log.open("a") as output:
            output.write("\nXCODE-WATCHDOG: no test progress; invocation stopped. "
                         "Partial results are diagnostic evidence only.\n")
        print("XCODE-WATCHDOG: stalled invocation failed; retained log and partial results.", flush=True)
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("a command and finite positive progress timeout are required")
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return run(command, args.log, args.report, args.timeout)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
