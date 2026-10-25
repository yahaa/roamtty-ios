import XCTest
@testable import RoamttyCore

@MainActor final class BoundedImagePoolTests: XCTestCase {
    // Removing admission accounting would let C start while A and B still own the budget.
    func testActiveConsumersHoldBudgetUntilLastRelease() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 32, reservationBytes: 16, concurrencyLimit: 2)
        let a = ImageJob(), b = ImageJob(), c = ImageJob()
        var first: TestImage?, duplicate: TestImage?, third: TestImage?
        let a1 = pool.request("a", load: a.load) { first = $0 }
        let a2 = pool.request("a", load: a.load) { duplicate = $0 }
        let b1 = pool.request("b", load: b.load) { _ in }
        let c1 = pool.request("c", load: c.load) { third = $0 }
        await settle()
        XCTAssertEqual(a.starts, 1)
        XCTAssertEqual(b.starts, 1)
        XCTAssertEqual(c.starts, 0)
        let aImage = TestImage(bytes: 16), bImage = TestImage(bytes: 16)
        a.succeed(aImage); b.succeed(bImage)
        await settle()
        XCTAssertTrue(first === duplicate)
        pool.release(a1)
        await settle()
        XCTAssertFalse(aImage.discarded)
        XCTAssertEqual(c.starts, 0)
        pool.release(a2)
        await settle()
        XCTAssertTrue(aImage.discarded, "Even retained display-handle copies must be cleared before budget reuse")
        XCTAssertEqual(c.starts, 1)
        c.succeed(TestImage(bytes: 16)); await settle()
        XCTAssertNotNil(third)
        pool.release(b1); pool.release(c1)
        XCTAssertTrue(bImage.discarded)
        XCTAssertTrue(third!.discarded)
    }

    // Releasing cancelled work's slot early breaks this when decode ignores cancellation.
    func testCancellationKeepsSlotUntilNonCooperativeWorkFinishesAndDoesNotDeliverStaleImage() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 64, reservationBytes: 16, concurrencyLimit: 2)
        let old = ImageJob(), b = ImageJob(), replacement = ImageJob()
        var oldDelivered = false, newImage: TestImage?
        let oldToken = pool.request("same", load: old.load) { _ in oldDelivered = true }
        let bToken = pool.request("b", load: b.load) { _ in }
        await settle()
        pool.release(oldToken)
        let replacementToken = pool.request("same", load: replacement.load) { newImage = $0 }
        await settle()
        XCTAssertEqual(replacement.starts, 0)
        let stale = TestImage(bytes: 16)
        old.succeed(stale); await settle()
        XCTAssertTrue(stale.discarded)
        XCTAssertFalse(oldDelivered)
        XCTAssertEqual(replacement.starts, 1)
        replacement.succeed(TestImage(bytes: 16)); b.succeed(TestImage(bytes: 16)); await settle()
        XCTAssertNotNil(newImage)
        pool.release(bToken); pool.release(replacementToken)
    }

    func testQueuedCancellationNeverStartsAndFailureFreesPermit() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 32, reservationBytes: 16, concurrencyLimit: 1)
        let failing = ImageJob(), cancelled = ImageJob(), next = ImageJob()
        var receivedFailure = false
        _ = pool.request("failed", load: failing.load) { receivedFailure = $0 == nil }
        let cancelToken = pool.request("cancelled", load: cancelled.load) { _ in XCTFail("Cancelled request delivered") }
        let nextToken = pool.request("next", load: next.load) { _ in }
        pool.release(cancelToken)
        await settle(); failing.fail(); await settle()
        XCTAssertTrue(receivedFailure)
        XCTAssertEqual(cancelled.starts, 0)
        XCTAssertEqual(next.starts, 1)
        next.succeed(TestImage(bytes: 4)); await settle(); pool.release(nextToken)
    }

    func testUsesRealCostAndRejectsResourceBeyondReservation() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 24, reservationBytes: 16, concurrencyLimit: 2)
        let a = ImageJob(), b = ImageJob()
        var rejected = false
        let aToken = pool.request("a", load: a.load) { _ in }
        _ = pool.request("b", load: b.load) { rejected = $0 == nil }
        await settle(); XCTAssertEqual(b.starts, 0)
        a.succeed(TestImage(bytes: 8)); await settle()
        XCTAssertEqual(b.starts, 1, "Actual 8-byte residency leaves room for a 16-byte reservation")
        let oversized = TestImage(bytes: 17)
        b.succeed(oversized); await settle()
        XCTAssertTrue(rejected)
        XCTAssertTrue(oversized.discarded)
        pool.release(aToken)
    }

    func testCompletedHitSharesHandleAndDropsLoaderCaptures() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 32, reservationBytes: 16, concurrencyLimit: 2)
        let job = ImageJob()
        var owner: LoaderOwner? = LoaderOwner()
        weak let weakOwner = owner
        var first: TestImage?, second: TestImage?
        let firstToken = pool.request("image", load: { [captured = owner!] in
            _ = captured
            return try await job.load()
        }) { first = $0 }
        owner = nil
        await settle()
        XCTAssertNotNil(weakOwner)
        job.succeed(TestImage(bytes: 4)); await settle()
        XCTAssertNil(weakOwner, "A completed image must not keep a loader's connection/model alive")
        let secondToken = pool.request("image", load: { XCTFail("Loaded duplicate refetched"); return TestImage(bytes: 4) }) { second = $0 }
        XCTAssertTrue(first === second)
        pool.release(firstToken)
        XCTAssertFalse(first!.discarded)
        pool.release(secondToken)
        XCTAssertTrue(first!.discarded)
    }

    func testReplacementWaitsForCancelledIdenticalWorkEvenWithSpareSlot() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 64, reservationBytes: 16, concurrencyLimit: 2)
        let old = ImageJob(), replacement = ImageJob(), independent = ImageJob()
        let oldToken = pool.request("same", load: old.load) { _ in XCTFail("Stale delivery") }
        await settle(); pool.release(oldToken)
        let replacementToken = pool.request("same", load: replacement.load) { _ in }
        let independentToken = pool.request("other", load: independent.load) { _ in }
        await settle()
        XCTAssertEqual(replacement.starts, 0, "A fullscreen transition must not overlap identical fetch/decode work")
        XCTAssertEqual(independent.starts, 1, "An unrelated image can use the spare slot")
        old.succeed(TestImage(bytes: 16)); await settle()
        XCTAssertEqual(replacement.starts, 1)
        replacement.succeed(TestImage(bytes: 16)); independent.succeed(TestImage(bytes: 16)); await settle()
        pool.release(replacementToken); pool.release(independentToken)
    }

    func testCompletedEntryDropsDeliveredCallbackCaptures() async {
        let pool = BoundedImagePool<String, TestImage>()
        let job = ImageJob()
        var owner: LoaderOwner? = LoaderOwner()
        weak let weakOwner = owner
        let token = pool.request("image", load: job.load) { [captured = owner!] _ in _ = captured }
        owner = nil
        await settle(); XCTAssertNotNil(weakOwner)
        job.succeed(TestImage(bytes: 4)); await settle()
        XCTAssertNil(weakOwner, "A ready entry needs lease IDs, not a callback's authorization context")
        pool.release(token)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor private final class TestImage: BudgetedImageResource {
    let decodedByteCount: Int
    var discarded = false
    init(bytes: Int) { decodedByteCount = bytes }
    func discard() { discarded = true }
}

@MainActor private final class ImageJob {
    var starts = 0
    var continuation: CheckedContinuation<TestImage, Error>?
    func load() async throws -> TestImage {
        starts += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed(_ image: TestImage) { continuation!.resume(returning: image); continuation = nil }
    func fail() { continuation!.resume(throwing: NSError(domain: "TestDecode", code: 1)); continuation = nil }
}

private final class LoaderOwner {}
