#!/bin/bash
# macOS: XCTest (one test per gate + fault matrix + XCTest metrics), gate CLI, regression vs baseline.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/reports
swift build -c release --product gate
.build/release/gate run --json > build/reports/gates-macos.json || true
.build/release/gate run
swift test -c release -Xswiftc -enable-testing 2>&1 | tee build/reports/swift-test.log
python3 tools/fault_matrix.py .build/release/gate
python3 tools/baseline.py .build/release/gate
