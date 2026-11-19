# vision-gate

<!-- plain-english:begin -->
[![ci](https://github.com/su0xpj-bastion/vision-gate/actions/workflows/ci.yml/badge.svg)](https://github.com/su0xpj-bastion/vision-gate/actions/workflows/ci.yml)

Report cards for the AI features in a photo and video app. Each feature gets a
passing grade, a set of test pictures where the right answer is already known, and planted
mistakes that prove the grading works:
- straighten a crooked horizon
- crop around the subject
- follow a moving subject
- spot shot changes
- read on-screen titles
- find duplicate photos
- apply a colour "look" made with Core ML

AI features fail quietly. A smaller, faster model can shift colours a
little, and a missed setting can make the app forget a photo is sideways. A quick look won't
catch either. Measured gates will, before a release reaches customers.

- Seeded test images with exact answers (no downloads), run on Apple's on-device Vision and Core ML.
- My own Core ML colour model in three builds: full, compact (int8), and a deliberately bad 2-bit one. The compact build is checked against the full one and against a plain Swift copy of the same maths.
- 19 gates, including CPU-vs-accelerator agreement, same-answer-every-time, speed, and a build-to-build regression check.
- 9 planted integration bugs, each proven caught.

Along the way, the tests turned up:
- The same code built with a newer Apple toolkit silently switched the duplicate-photo model version. Distances shrank about 16 times, and everything looked like a duplicate. The fix is to pin model versions.
- The horizon detector ignores a photo's "this is sideways" flag.
- A red/blue channel swap passes a naive check. Only a known-colour test exposes it.

Swift, Vision, Core ML, coremltools, XCTest, Python, GitHub Actions; macOS
and iOS Simulator runs.

[Test plan](TEST_PLAN.md) · [Bugs found](BUGS.md) · [Test strategy](https://github.com/su0xpj-bastion/proof-sheet/blob/main/docs/TEST_STRATEGY.md)

---

## Technical detail
<!-- plain-english:end -->

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
| Duplicate grouping | `VNGenerateImageFeaturePrintRequest` (revision pinned) | re-encoded, resized and regraded copies grouped; another shot of the same place kept apart |
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
- **Feature-print distances changed about 16x between builds.** Vision uses the newest request revision of the SDK the app was *built* with. Built with an older SDK, the code ran revision 1; built with Xcode 26, it ran revision 2. A fixed duplicate threshold of 7 merged all 20 images into one group on CI (same-photo pairs up to 0.58, different photos down to 0.37). The fix pins the revision. Any threshold applied to model output needs its model revision pinned.
- OCR read 59 of 60 titles exactly. The miss, every time, is "Chapter 2: The Coast" read as "Chapter 2:The Coast".
- A model and its reference agree even when both are fed BGR. Only a known-colour contract catches a channel swap.
- Measured locally:
  - int8 against float32: 43.2 dB.
  - CPU against GPU/Neural Engine: 66.4 dB (fp16 on the accelerators).
  - The 2-bit build: 4.9 dB.
- On the CI VM the CPU and "all units" outputs are identical: there is no GPU or Neural Engine, so Core ML falls back to CPU. The parity gate only means something on real hardware.

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
- On the iOS Simulator, Core ML has no Neural Engine, and some Vision requests run on different code paths. If simulator and Mac results disagree, that is a finding, not a pass. CI found exactly that: saliency crops, tracking and duplicate detection give different answers on the Simulator. Those 5 gates are marked device-only there (`Gates.deviceOnly`). They still run, and their numbers are attached to the test result, but they are skipped rather than failed (VG-8).
