# Test plan: vision-gate

Follows the shared [test strategy](https://github.com/su0xpj-bastion/proof-sheet/blob/main/docs/TEST_STRATEGY.md). Real bugs from building it are in [BUGS.md](BUGS.md).

**In scope:** on-device AI features of a photo and video app: straighten, smart crop, shot cuts, subject tracking, title OCR, duplicate grouping, and a Core ML colour model in float32 and int8.

**Out of scope:** accuracy on real photos (needs a licensed labelled set); camera capture; real-device Neural Engine timing.

## What must be true, and how it's checked

| Requirement | Priority | How it is checked |
|---|---|---|
| Features give the right answer | P0 | golden sets with exact answers: tilt ≤ 0.3°, crop keeps ≥ 98% of the subject, OCR ≥ 98% exact |
| Features are robust to everyday changes | P0 | the same answer after JPEG 60, half size, +0.7 EV, EXIF rotation |
| The shipped model matches what was designed | P0 | float vs Swift reference ≥ 60 dB; known-colour input contract; int8 vs float ≥ 40 dB |
| The same answer on CPU, GPU and Neural Engine, every time | P1 | parity and repeat-run gates |
| No silent slide between builds | P1 | metrics compared with the last release's baseline, with tolerances |

## How it runs

- **Every push (CI):** all checks, then the fault matrix (each planted bug switched on alone must fail exactly its pinned checks).
- **Locally:** the same checks through the command-line tool (`scripts/build-local.sh`), on a Mac with only the Command Line Tools.

## Exit criteria

19/19 gates pass on macOS and the iOS Simulator; the fault matrix is exact (9/9); 0 baseline regressions. CI is green on the default branch.

## Risks

- Test media is generated, so every answer is exact. Real-world media needs licensed sets run through the same checks.
- Simulators and CI machines are not real devices. Timing and hardware behaviour need a real-device pass before release.
