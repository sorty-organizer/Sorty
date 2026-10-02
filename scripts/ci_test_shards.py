#!/usr/bin/env python3
"""Run every discovered XCTest in class batches, avoiding per-test process startup."""

import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import subprocess
import sys
import time


def run(inventory, workers, command):
    tests = {line.strip() for line in inventory.read_text().splitlines()
             if re.fullmatch(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+/\S+", line.strip())}
    if not tests:
        raise ValueError("No XCTest identifiers found in inventory")
    classes = defaultdict(list)
    for test in tests:
        classes[test.rsplit("/", 1)[0]].append(test)
    shards = [[] for _ in range(min(workers, len(classes)))]
    counts = [0] * len(shards)
    for name in sorted(classes, key=lambda name: (-len(classes[name]), name)):
        index = min(range(len(shards)), key=lambda index: counts[index])
        shards[index].append(name)
        counts[index] += len(classes[name])
    logs = Path(".build/logs")
    logs.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()

    def execute(index):
        pattern = "^(" + "|".join(re.escape(name) for name in shards[index]) + ")/"
        result = subprocess.run([*command, "--filter", pattern], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (logs / f"ci-shard-{index + 1}.log").write_text(result.stdout)
        # XCTest emits an aggregate count after the selected suite. Fail closed
        # if discovery and execution disagree, even when the process exits zero.
        executed = re.findall(r"Executed (\d+) tests?,", result.stdout)
        actual = int(executed[-1]) if executed else 0
        complete = actual == counts[index]
        print(f"Shard {index + 1}: {actual}/{counts[index]} tests, exit {result.returncode}")
        if result.returncode or not complete:
            print(result.stdout)
        return result.returncode == 0 and complete

    with ThreadPoolExecutor(max_workers=len(shards)) as executor:
        results = list(executor.map(execute, range(len(shards))))
    print(f"Executed {len(tests)} discovered tests in {len(shards)} batches ({time.monotonic() - started:.1f}s)")
    return all(results)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.workers < 1 or not command:
        parser.error("A positive worker count and test command are required")
    try:
        success = run(args.inventory, args.workers, command)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + "\n")
    sys.exit(0 if success else 1)
