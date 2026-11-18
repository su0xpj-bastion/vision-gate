"""Regression gate across builds: compare this build's gate metrics with Models/baseline.json.

A metric may not get worse than its baseline by more than its tolerance (direction-aware), even
while every absolute gate still passes, so a slow slide in accuracy or speed is caught early.

  python tools/baseline.py [gate-binary]            compare
  python tools/baseline.py [gate-binary] --update   accept this build as the new baseline
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Models" / "baseline.json"
ENCODING = "utf-8"

# metric suffix -> (direction, absolute tolerance). "lower" = smaller is better.
RULES = {
    "_deg": ("lower", 0.15),
    "_rate": ("higher", 0.02),
    "_coverage": ("higher", 0.02),
    "_db": ("higher", 3.0),
    "mean_error": ("lower", 0.01),
    "worst_after_cut": ("lower", 0.015),
    "_delta": ("lower", 0.02),
}
# Timings (*_ms) are not compared: they belong to the machine, and perf.budgets already gates them.
TIMING_SLACK = 2.0


def rule(metric: str):
    for suffix, r in RULES.items():
        if metric.endswith(suffix):
            return r
    return None


def current(gate_bin: str) -> dict[str, float]:
    out = subprocess.run([gate_bin, "run", "--json"], capture_output=True, text=True).stdout
    return {f"{r['name']}:{k}": v for r in json.loads(out) for k, v in r["metrics"].items()}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    gate_bin = args[0] if args else str(ROOT / ".build" / "local" / "gate")
    now = current(gate_bin)
    if "--update" in sys.argv or not BASELINE.exists():
        with BASELINE.open("w", encoding=ENCODING) as f:
            json.dump(now, f, indent=2, sort_keys=True)
        print(f"baseline written: {len(now)} metrics")
        return 0
    with BASELINE.open("r", encoding=ENCODING) as f:
        base = json.load(f)
    bad = 0
    for key in sorted(base):
        r = rule(key.split(":")[1])
        if r is None or key not in now:
            continue
        direction, tol = r
        b, n = base[key], now[key]
        if tol is None:
            worse = n > max(b, 1.0) * TIMING_SLACK
            budget = f"<= {max(b, 1.0) * TIMING_SLACK:.0f}"
        elif direction == "lower":
            worse = n > b + tol
            budget = f"<= {b + tol:.3f}"
        else:
            worse = n < b - tol
            budget = f">= {b - tol:.3f}"
        bad += worse
        print(f"{'REGRESSED' if worse else 'ok':9} {key:48} baseline {b:9.3f}  now {n:9.3f}  ({budget})")
    missing = sorted(set(base) - set(now))
    for k in missing:
        print(f"MISSING   {k}")
    print(f"\n{bad + len(missing)} regressions against {BASELINE.name}")
    return 1 if bad or missing else 0


if __name__ == "__main__":
    sys.exit(main())
