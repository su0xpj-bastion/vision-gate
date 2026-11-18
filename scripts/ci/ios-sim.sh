#!/bin/bash
# The same gates on the iOS Simulator: SwiftPM packages test directly with xcodebuild, no project needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/reports
udid=$(xcrun simctl list devices available -j | python3 -c '
import json,re,sys
best=None
for rt,ds in json.load(sys.stdin)["devices"].items():
    m=re.search(r"iOS-(\d+)-(\d+)",rt)
    for d in ds if m else []:
        if d["name"].startswith("iPhone") and " SE" not in d["name"]:
            k=((int(m.group(1)),int(m.group(2))),d["name"])
            best=max(best,(k,d["udid"])) if best else (k,d["udid"])
print(best[1])')
rm -rf build/reports/ios-sim.xcresult
xcodebuild test -scheme vision-gate-Package -destination "id=$udid" -resultBundlePath build/reports/ios-sim.xcresult \
  -skip-testing:VisionGateTests/FeaturePerformanceTests \
  | tee build/reports/ios-sim.log | grep -E "Test Case|error:|\*\* TEST|Executed"
