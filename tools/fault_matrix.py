"""Run the gate binary once per fault (VG_FAULTS) and require exactly the pinned gates to fail."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def failing(gate_bin: str, fault: str) -> set[str]:
    out = subprocess.run([gate_bin, "run", "--json"], capture_output=True, text=True, env=dict(os.environ, VG_FAULTS=fault)).stdout
    return {r["name"] for r in json.loads(out) if not r["passed"]}


def main() -> int:
    gate_bin = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build" / "local" / "gate")
    expected = {k: set(v) for k, v in json.loads(subprocess.run([gate_bin, "expected"], capture_output=True, text=True).stdout).items()}
    ok = True
    for fault in [""] + sorted(expected):
        want = expected.get(fault, set())
        got = failing(gate_bin, fault)
        ok &= got == want
        print(f"{'ok ' if got == want else 'BAD'} {fault or '(no fault)':26} caught by {sorted(got) or '-'}")
        if got != want:
            print(f"      expected {sorted(want)}")
    print("\nfault matrix: " + ("every fault caught by exactly its pinned gates" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
