#!/bin/sh
# Build `gate` with plain swiftc (Command Line Tools only). With Xcode: swift build.
set -e
cd "$(dirname "$0")/.."
B=${BUILD_DIR:-.build/local}
mkdir -p "$B"
swiftc -O -parse-as-library -emit-library -static -module-name VisionGate -emit-module-path "$B/VisionGate.swiftmodule" \
  -o "$B/libVisionGate.a" Sources/VisionGate/*.swift
swiftc -O -I "$B" -L "$B" -lVisionGate -o "$B/gate" Sources/gate/main.swift
