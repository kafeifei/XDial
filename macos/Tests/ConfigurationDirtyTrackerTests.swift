import XCTest

final class ConfigurationDirtyTrackerTests: XCTestCase {
    func testNoOpSaveDoesNotMarkConnectedConfigurationDirty() {
        var tracker = ConfigurationDirtyTracker<String>()
        tracker.load("profile-a")
        tracker.markApplied("profile-a")

        tracker.recordSave(
            "profile-a",
            markDirty: true,
            engineHoldsSnapshot: true
        )

        XCTAssertFalse(tracker.isDirty)
    }

    func testRealEditMarksDirtyAndRevertClearsIt() {
        var tracker = ConfigurationDirtyTracker<String>()
        tracker.load("profile-a")
        tracker.markApplied("profile-a")

        tracker.recordSave(
            "profile-b",
            markDirty: true,
            engineHoldsSnapshot: true
        )
        XCTAssertTrue(tracker.isDirty)

        tracker.recordSave(
            "profile-a",
            markDirty: true,
            engineHoldsSnapshot: true
        )
        XCTAssertFalse(tracker.isDirty)
    }

    func testFirstNoOpSaveAfterRelaunchDoesNotMarkDirty() {
        var tracker = ConfigurationDirtyTracker<String>()
        tracker.load("saved-profile")

        tracker.recordSave(
            "saved-profile",
            markDirty: true,
            engineHoldsSnapshot: true
        )

        XCTAssertFalse(tracker.isDirty)
    }

    func testInternalSaveDoesNotChangeExistingDirtyState() {
        var tracker = ConfigurationDirtyTracker<String>()
        tracker.markApplied("profile-a")
        tracker.recordSave(
            "profile-b",
            markDirty: true,
            engineHoldsSnapshot: true
        )
        XCTAssertTrue(tracker.isDirty)

        tracker.recordSave(
            "profile-c",
            markDirty: false,
            engineHoldsSnapshot: true
        )

        XCTAssertTrue(tracker.isDirty)
    }

    func testAdoptingRunningFingerprintPreservesLaterEdit() {
        var tracker = ConfigurationDirtyTracker<String>()
        tracker.load("runtime-a")
        tracker.recordSave(
            "runtime-b",
            markDirty: true,
            engineHoldsSnapshot: true
        )

        tracker.adoptApplied("runtime-a")

        XCTAssertTrue(tracker.isDirty)
    }

    func testAdoptingRunningFingerprintAfterRelaunchSupportsRevert() {
        var tracker =
            ConfigurationDirtyTracker<RuntimeConfigurationSignature>()
        tracker.load(.valid("runtime-a"))
        tracker.adoptApplied(.valid("runtime-a"))

        tracker.recordSave(
            .invalid,
            markDirty: true,
            engineHoldsSnapshot: true
        )
        XCTAssertTrue(tracker.isDirty)

        tracker.recordSave(
            .valid("runtime-a"),
            markDirty: true,
            engineHoldsSnapshot: true
        )
        XCTAssertFalse(tracker.isDirty)
    }
}
