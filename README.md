# vision-gate

Quality gates for **on-device ML and AI features in a photo and video app**: the kind a creative app
ships on Vision and Core ML. Each feature gets a gate with a measured bar, a golden set with known
answers, and a fault matrix that proves the gate catches the bugs that really ship.

| Feature | Built on | Gates |
|---|---|---|
| Auto-straighten | `VNDetectHorizonRequest` | accuracy ≤ 0.3°, closed loop (straighten then re-measure: level), robustness (JPEG 60, half size, +0.7 EV), EXIF-rotated photos, leaves a level photo alone |
| Smart crop / reframe (9:16, 1:1, 2.39:1) | attention saliency heatmap | crop keeps ≥ 98% of the subject; EXIF-rotated photos |
| Shot detection | colour histograms | exact cut frames, no false cuts |
| Subject tracking for reframing | `VNTrackObjectRequest` + re-acquire at cuts | ≥ 90% of frames within 0.06 of the subject, including after a cut |
| Title OCR (search, captions, legibility) | `VNRecognizeTextRequest` | ≥ 98% exact titles across fonts, backgrounds, sizes and JPEG 50; no text invented on text-free frames |
| Duplicate grouping | `VNGenerateImageFeaturePrintRequest` | re-encoded, resized and regraded copies grouped, distinct shots kept apart |
| "Look" model (colour grade + sharpen) | Core ML, float32 + int8 | float vs a Swift reference ≥ 60 dB; app's pixel→tensor path checked with known colours; int8 vs float ≥ 40 dB; CPU vs GPU / Neural Engine ≥ 60 dB |
| All features | | CPU vs accelerated parity, identical answers on repeat, latency budgets, XCTest CPU/memory metrics |

The golden set is drawn from seeds and needs no downloads:
- horizons at known tilts
- one vivid subject at a known place
- a two-shot clip with a moving subject and a known cut
- title cards in five fonts
- copies of images with known edits

The Core ML models are authored with coremltools (`tools/make_models.py`) and committed. The same
weights drive a plain-Swift reference that the shipped model is checked against.

## Fault matrix

`VG_FAULTS=<name>` switches on an **integration** bug, a mistake an app makes around Vision or
Core ML. These are not bugs in the frameworks. Each must fail exactly its pinned gates
(`tools/fault_matrix.py`, and `FaultMatrixTests` in XCTest):

| Fault | Caught by |
|---|---|
| ignoresOrientation (EXIF orientation not passed to Vision) | crop.orientation |
| horizonSignFlipped (rotate by +tilt) | straighten.closed-loop |
| saliencyRowsFlipped (heatmap read bottom-up) | crop.subject-kept, video.tracking |
| visionBoxNotFlipped (bottom-left boxes used as top-left) | video.tracking |
| trackerNotResetAtCut | video.tracking |
| ocrFastPath (`.fast` recognition for titles) | titles.exact |
| duplicateThresholdLoose | library.duplicates |
| int2ModelShipped (the 2-bit build went out) | look.int8-drift |
| modelInputBGR | look.color-contract |

## Findings while calibrating

- `VNHorizonObservation.angle` has the opposite sign to the "obvious" drawing convention. I drew the first golden set backwards and every angle came back negated, which is exactly the bug `horizonSignFlipped` represents.
- Vision does not report tilts under about 1°. So "straighten" is split into an accuracy gate (tilts of 2° and more) and a "leave a level photo alone" gate.
- The horizon detector returns the same tilt for a sideways-stored photo even when EXIF orientation is ignored. Only the crop gate exposes `ignoresOrientation`, which is why every feature needs its own orientation gate.
- Attention saliency's bounding boxes are too loose to crop on (about half the frame). The heatmap peak lands within 0.03 of the subject, so the crop uses the peak.
- The tracker loses the subject at a shot cut (confidence 0.01) and then stays put. The pipeline re-acquires the subject from saliency at cuts.
- OCR read 59 of 60 titles exactly. The miss, every time, is "Chapter 2: The Coast" read as "Chapter 2:The Coast".
- A model and its reference agree even when both are fed BGR. Only a known-colour contract catches a channel swap.
- Measured locally:
  - int8 against float32: 43.2 dB.
  - CPU against GPU/Neural Engine: 66.4 dB (fp16 on the accelerators).
  - The 2-bit build: 4.9 dB.

## Regression gate across builds

`tools/baseline.py` compares every gate metric with `Models/baseline.json`, direction-aware with
tolerances. A slide in accuracy fails the build even while the absolute bars still pass.
`--update` accepts a new baseline. Timings are left out of this comparison, because they belong
to the machine; `perf.budgets` already gates them.

## Run it

```bash
scripts/build-local.sh && .build/local/gate     # 19 gates (Command Line Tools only)
python3 tools/fault_matrix.py                   # 9 faults
python3 tools/baseline.py                       # regression vs baseline
swift test -c release -Xswiftc -enable-testing  # XCTest (needs Xcode)
scripts/ci/ios-sim.sh                           # the same gates on the iOS Simulator
```

Verified locally on macOS 26 (Apple silicon, Command Line Tools only):
- 19/19 gates pass.
- The fault matrix catches all 9 faults.
- The baseline comparison shows 0 regressions.

XCTest and the iOS Simulator run in CI (`.github/workflows/ci.yml`). The `Jenkinsfile` runs the
same scripts, and has not been run on a Jenkins server.

## Limits

- The golden set is synthetic, with exact answers by construction. It shows that the integration and the gates are right. It does not show accuracy on real photos, which needs a licensed, labelled set run through the same gates.
- The Look model is a small fixed network that stands in for a production model's integration surface: loading, quantization, compute units and the input contract.
- On the iOS Simulator, Core ML has no Neural Engine, and some Vision requests run on different code paths. If simulator and Mac results disagree, that is a finding, not a pass.
