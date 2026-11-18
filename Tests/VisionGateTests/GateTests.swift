import CoreML
import VisionGate
import XCTest

/// One XCTest per gate, so Xcode, Jenkins and Xcode Cloud list each feature's quality bar by name.
/// Runs on macOS and on the iOS Simulator (`xcodebuild test -scheme vision-gate -destination ...`).
final class GateTests: XCTestCase {
    func gate(_ name: String) {
        let r = Gates.run([name]).first!
        XCTAssertTrue(r.passed, "\(name): \(r.detail)")
        let a = XCTAttachment(string: "\(r.detail)\n\(r.metrics)")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func test_straighten_accuracy() { gate("straighten.accuracy") }
    func test_straighten_leaves_level_alone() { gate("straighten.leaves-level-alone") }
    func test_straighten_closed_loop() { gate("straighten.closed-loop") }
    func test_straighten_robustness() { gate("straighten.robustness") }
    func test_straighten_orientation() { gate("straighten.orientation") }
    func test_crop_subject_kept() { gate("crop.subject-kept") }
    func test_crop_orientation() { gate("crop.orientation") }
    func test_video_shot_cuts() { gate("video.shot-cuts") }
    func test_video_tracking() { gate("video.tracking") }
    func test_titles_exact() { gate("titles.exact") }
    func test_titles_no_hallucination() { gate("titles.no-hallucination") }
    func test_library_duplicates() { gate("library.duplicates") }
    func test_look_reference() { gate("look.reference") }
    func test_look_color_contract() { gate("look.color-contract") }
    func test_look_int8_drift() { gate("look.int8-drift") }
    func test_look_compute_units() { gate("look.compute-units") }
    func test_parity_cpu_vs_accelerated() { gate("parity.cpu-vs-accelerated") }
    func test_determinism_repeat() { gate("determinism.repeat") }
    func test_perf_budgets() { gate("perf.budgets") }
}

/// Client faults are in-process switches: each must fail exactly its pinned gates.
final class FaultMatrixTests: XCTestCase {
    func testEveryFaultIsCaughtByExactlyItsGates() {
        for fault in Fault.allCases {
            let saved = Fault.active
            Fault.active = [fault]
            defer { Fault.active = saved }
            // perf.budgets is timing, not correctness: on a loaded CI VM it can trip during any run.
            let failed = Set(Gates.run().filter { !$0.passed && $0.name != "perf.budgets" }.map { $0.name })
            XCTAssertEqual(failed, Gates.expectedFailures[fault], "\(fault)")
        }
    }
}

/// On-device cost per feature with XCTest metrics (baselines are recorded per device in Xcode).
final class FeaturePerformanceTests: XCTestCase {
    func testLookInferenceInt8() throws {
        let m = try Look.model(.int8)
        let x = Look.input(Golden.subject(seed: 1).0)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) { _ = try? Look.run(m, x) }
    }

    func testTitleOCR() {
        let img = Golden.title("Opening Night", font: "Georgia", size: 56, background: 1, seed: 1)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) { _ = try? Titles.read(img) }
    }
}
