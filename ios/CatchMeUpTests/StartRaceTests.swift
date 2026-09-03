import XCTest
@testable import CatchMeUp

/// The recorder gives the microphone a fixed window and abandons it after that,
/// because a mic that hasn't started in eight seconds — another app holding the
/// input, a route that never answers — doesn't start on the ninth. `StartRace`
/// is what makes abandoning it safe, and both of its jobs are the kind that
/// fail in front of a user rather than in a build: resuming the continuation
/// twice is a crash, and dropping the late arrival silently leaves the mic held
/// open for the rest of the session.
final class StartRaceTests: XCTestCase {

    /// The value returned is the one that arrived first.
    func testTheFirstResultIsTheOneDelivered() async throws {
        let won = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            let race = StartRace(c) { _ in }
            race.settle(.success(1))
            race.settle(.success(2))
        }
        XCTAssertEqual(won, 1)
    }

    /// The timeout losing to the hardware is the ordinary case: the mic came
    /// live, so the deadline must not overwrite it with a failure.
    func testALateFailureCannotOverturnASuccess() async throws {
        struct TooSlow: Error {}
        let won = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            let race = StartRace(c) { _ in }
            race.settle(.success(7))
            race.settle(.failure(TooSlow()))
        }
        XCTAssertEqual(won, 7)
    }

    /// The case the timeout exists for: the caller has already been told the
    /// mic didn't start, and the recorder turns up afterwards. Nothing holds a
    /// reference to it, so if it isn't handed to `discard` it keeps the input
    /// and writes a file nobody will ever stop or find.
    func testARecorderArrivingAfterTheTimeoutIsDiscarded() async {
        struct TimedOut: Error {}
        let discarded = Discarded()

        do {
            _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                let race = StartRace(c) { discarded.add($0) }
                race.settle(.failure(TimedOut()))
                race.settle(.success(99))
            }
            XCTFail("the timeout should have surfaced as an error")
        } catch {
            XCTAssertTrue(error is TimedOut)
        }

        XCTAssertEqual(discarded.values, [99])
    }

    /// A loser that is itself a failure has nothing to clean up.
    func testALateFailureIsNotHandedToDiscard() async {
        struct First: Error {}
        struct Second: Error {}
        let discarded = Discarded()

        do {
            _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                let race = StartRace(c) { discarded.add($0) }
                race.settle(.failure(First()))
                race.settle(.failure(Second()))
            }
            XCTFail("the first failure should have surfaced")
        } catch {
            XCTAssertTrue(error is First)
        }

        XCTAssertTrue(discarded.values.isEmpty)
    }

    /// Settling races for real — the hardware resumes on a global queue while
    /// the deadline resumes on a Task — so the win has to be decided under the
    /// lock. Resuming a continuation twice traps, meaning the failure this
    /// guards against is a crash rather than a wrong answer.
    func testConcurrentSettlesResumeExactlyOnce() async {
        struct Lost: Error {}
        for _ in 0..<200 {
            let discarded = Discarded()
            let delivered: Int? = try? await withCheckedThrowingContinuation {
                (c: CheckedContinuation<Int, Error>) in
                let race = StartRace(c) { discarded.add($0) }
                DispatchQueue.concurrentPerform(iterations: 8) { i in
                    race.settle(i.isMultiple(of: 2) ? .success(i) : .failure(Lost()))
                }
            }
            // Four successes were offered; whichever didn't win the lock must
            // all have gone to `discard` rather than to a second resume.
            let kept = delivered.map { [$0] } ?? []
            XCTAssertEqual(Set(kept + discarded.values), [0, 2, 4, 6])
        }
    }

    private final class Discarded: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
        func add(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
    }
}
