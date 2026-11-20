#!/usr/bin/env python3
"""Summarize phase-aligned macOS host memory from isolated cold-anon A/B labs.

Usage:
  python3 summarize-libkrun-cold-anon.py /abs/cold-anon-default /abs/cold-anon-replace

This reports observed vmmap Physical footprint; it does not infer compressed
per-process bytes from global macOS compressor counters.
"""
import csv
import pathlib
import statistics
import sys

PHASES = ("ANON_ALLOCATED", "ANON_IDLE", "ANON_RESTORED", "ANON_FREED")


def as_mib(value: str) -> float:
    value = value.strip()
    factor = 1.0
    if value.endswith("K"):
        factor = 1 / 1024
    elif value.endswith("M"):
        factor = 1.0
    elif value.endswith("G"):
        factor = 1024.0
    else:
        raise ValueError(f"unexpected vmmap unit: {value!r}")
    return float(value[:-1]) * factor


def phase_means(directory: pathlib.Path) -> dict[str, float]:
    csv_path = directory / "host-memory.csv"
    log_path = directory / "guest.log"
    log = log_path.read_text(errors="replace")
    if "KIRI-LIBKRUN-MEMLAB ANON_SWAP_CONFIRMED" not in log:
        raise ValueError(f"{directory}: missing proof of Guest swap-out")
    if "KIRI-LIBKRUN-MEMLAB ANON_RESTORED" not in log:
        raise ValueError(f"{directory}: missing proof of restored Guest pages")
    values: dict[str, list[float]] = {phase: [] for phase in PHASES}
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            phase = row["phase"]
            if phase in values:
                values[phase].append(as_mib(row["physical_footprint"]))
    for phase, observations in values.items():
        if not observations:
            raise ValueError(f"{directory}: missing host samples for {phase}")
    return {phase: statistics.median(observations) for phase, observations in values.items()}


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: summarize-libkrun-cold-anon.py DEFAULT_DIR REPLACE_DIR", file=sys.stderr)
        return 2
    try:
        baseline = phase_means(pathlib.Path(sys.argv[1]))
        optimized = phase_means(pathlib.Path(sys.argv[2]))
    except (OSError, ValueError, KeyError) as exc:
        print(f"INVALID LAB RESULTS: {exc}", file=sys.stderr)
        return 1
    print("Host VM Physical footprint, phase median (MiB)")
    print(f"{'Phase':<19} {'Default':>11} {'Replace':>11} {'Difference':>12}")
    for phase in PHASES:
        left = baseline[phase]
        right = optimized[phase]
        print(f"{phase:<19} {left:>10.1f}M {right:>10.1f}M {left-right:>+11.1f}M")
    print()
    for name, samples in (("Default", baseline), ("Replace", optimized)):
        reclaimed = samples["ANON_ALLOCATED"] - samples["ANON_IDLE"]
        restored = samples["ANON_RESTORED"] - samples["ANON_IDLE"]
        print(f"{name}: idle vs allocated {reclaimed:+.1f} MiB, "
              f"restore vs idle {restored:+.1f} MiB")
    print("Interpretation: Guest swap-out and restore markers were present.")
    print("Caution: global macOS compressor metrics do not prove per-process compression.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
