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
}
