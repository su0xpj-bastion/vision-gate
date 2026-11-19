# Bugs and findings while building vision-gate

Severity: S1 (data loss or privacy), S2 (wrong output), S3 (broken interaction), S4 (cosmetic).

### VG-1 · Duplicate grouping merges every photo into one group on CI, but works locally
**S2 / P0** · found by `library.duplicates` on the first CI run

- **Expected.** 5 groups of 4 (each photo plus its re-encoded, resized and regraded copies).
- **Actual.** On CI: 1 group of 20. Locally: correct.
- **Isolation.**
  1. I added the measured distances to the gate's output.
  2. Locally, the worst same-photo distance was 9.18 and the closest different-photo distance was 8.31. On CI they were 0.58 and 0.37, about 16× smaller.
  3. Same code, different build: CI builds with the Xcode 26 SDK, locally with an older one.
  4. `VNGenerateImageFeaturePrintRequest` defaults to the newest *revision* in the SDK the app was built against.
- **Root cause.** The model revision wasn't pinned, so a fixed distance threshold silently changed meaning.
- **Fix.** Pin `revision = VNGenerateImageFeaturePrintRequestRevision1`. A threshold on model output always needs its model revision pinned.
- **Guard.** `library.duplicates` reports both distances, and the build-to-build baseline would show the jump.

### VG-2 · Horizon angle has the opposite sign to the drawing convention
**S2 / P0** · found while calibrating the golden set

- **Actual.** Every measured tilt came back negated (truth −8°, measured +8.13°).
- **Isolation.** The magnitude was right and only the sign was wrong, so the cause was a convention between top-left drawing and Vision's angle.
- **Fix.** Golden images are drawn in Vision's convention. The app rotates by `-tilt`.
- **Guard.** The `straighten.closed-loop` gate (correct, then re-measure: must be level), and the pinned fault `horizonSignFlipped`.

### VG-3 · The horizon detector gives the same answer whether or not EXIF orientation is passed
**Finding (S2 risk)**

- **What happened.** A sideways-stored photo measured the same tilt with orientation `.left` and with `.up`.
- **Impact.** A test of straightening alone would miss an app that forgets the orientation. Only the crop gate (`crop.orientation`) exposes that bug.
- **Lesson.** Each feature needs its own orientation test.

### VG-4 · A red/blue channel swap passes the model-vs-reference check
**Test gap (S2 risk)** · found by the fault matrix (`modelInputBGR` caught by nothing)

- **Isolation.** The app's pixel-to-tensor conversion feeds both the model and the reference implementation. If the conversion swaps channels, both receive the same wrong input and agree.
- **Fix.** New `look.color-contract` gate: solid known colours through the app's input path, compared with tensors built by hand. Under the fault it reads 3.4 dB, against 143 dB clean.

### VG-5 · Tilts under about 1° are not reported
**Finding**

- **What happened.** `VNDetectHorizonRequest` returns nothing for ±0.5° and returned nothing for ±1° in this set.
- **Response.** Split the feature into "accuracy for 2° and more" and "leave a level photo alone". A nil result after correcting means the photo is level.

### VG-6 · The tracker freezes at a shot cut
**S2 / P1** · found while calibrating `video.tracking`

- **What happened.** At the cut, `VNTrackObjectRequest` confidence drops to 0.01, and the box stays where the subject *was*.
- **Fix.** On a detected cut, or low confidence, re-acquire the subject from the saliency peak.
- **Guard.** `video.tracking` checks error after the cut; fault `trackerNotResetAtCut`.

### VG-7 · Speed gate trips during fault runs on a loaded CI machine
**Test-infrastructure**

- **What happened.** `perf.budgets` failed once under `ignoresOrientation` on CI. That fault doesn't touch timing.
- **Fix.** The fault matrix compares correctness gates only. Speed is gated on the clean run.

### VG-8 · The iOS Simulator gives different answers for saliency, tracking and duplicates
**Finding (platform)**

- **What happened.** The first full CI run on the iOS Simulator failed 5 gates that pass on the Mac:
  - `crop.subject-kept`: 20 of 36 crops kept the subject (worst 0.00).
  - `crop.orientation`: 1 of 6 rotated photos was cropped onto the subject.
  - `video.tracking`: 50% of frames were on target.
  - `library.duplicates`: same-photo distance went up to 5.18 and different-photo distance down to 2.77, so no threshold separates them.
  - `perf.budgets`: OCR took 2,035 ms.

  The fault matrix also broke, because these gates now failed under every fault.
- **Why.** The Simulator has no Neural Engine, and these Vision requests run on a different code path there. The Simulator is not a valid oracle for them.
- **Fix.** `Gates.deviceOnly` lists the 5 gates. On the Simulator they still run and their results are attached, but they are skipped, and the fault matrix compares only the gates the Simulator can judge. On a Mac (and on a device) all 19 are gated as before.
- **What it means for release.** Shipping these features needs a real-device pass. Simulator green is not enough, and CI now says so instead of hiding it.
