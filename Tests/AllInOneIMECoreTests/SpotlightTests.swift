import Foundation
import Testing
@testable import AllInOneIMECore

/// `Spotlight`'s process handling, with a shell standing in for mdfind.
struct SpotlightTests {
    let shell = URL(fileURLWithPath: "/bin/sh")

    /// `body` on a thread of its own (it blocks), awaited.
    func inBackground<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }

    @Test func stopsAtTheTimeLimitAndKeepsWhatWasPrinted() async {
        let spotlight = Spotlight(until: .now() + 0.5, executable: shell)
        let started = Date()
        let output = await inBackground { spotlight.mdfind(["-c", "echo first; exec sleep 10"]) }
        #expect(output.map { String(decoding: $0, as: UTF8.self) } == "first\n")
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(!spotlight.hasTimeLeft && !spotlight.isCancelled)
    }

    @Test func readsMoreThanAPipeHolds() async {
        // A pipe holds 64 KB: the output is read while the program runs, or neither would finish.
        let spotlight = Spotlight(until: .now() + 10, executable: shell)
        let output = await inBackground { spotlight.mdfind(["-c", "head -c 300000 /dev/zero | tr '\\0' x"]) }
        #expect(output?.count == 300_000 && output?.allSatisfy { $0 == UInt8(ascii: "x") } == true)
        let both = await inBackground { spotlight.mdfind(each: [["-c", "echo one"], ["-c", "sleep 0.2; echo two"], ["-c", "exit 3"]]) }
        #expect(both?.map { String(decoding: $0, as: UTF8.self) } == ["one\n", "two\n", ""])
    }

    @Test func cancellingStopsItAndDropsWhatWasPrinted() async throws {
        let spotlight = Spotlight(until: .now() + 10, executable: shell)
        let started = Date()
        let running = Task { await inBackground { spotlight.mdfind(["-c", "echo early; exec sleep 10"]) } }
        try await Task.sleep(for: .milliseconds(300))
        let cancelling = Date()
        spotlight.cancel()
        #expect(Date().timeIntervalSince(cancelling) < 0.1)  // never waits for a process
        #expect(await running.value == nil)
        #expect(Date().timeIntervalSince(started) < 3)
        // Nothing starts after that.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("SpotlightTests-\(UUID().uuidString)")
        let later = await inBackground { spotlight.mdfind(["-c", "touch '\(marker.path)'; echo late"]) }
        let each = await inBackground { spotlight.mdfind(each: [["-c", "touch '\(marker.path)'"]]) }
        #expect(later == nil && each == nil && !FileManager.default.fileExists(atPath: marker.path))
        #expect(spotlight.isCancelled && !spotlight.hasTimeLeft)
    }

    @Test func aProgramThatCantStartPrintsNothing() async {
        let spotlight = Spotlight(until: .now() + 5, executable: URL(fileURLWithPath: "/no/such/mdfind"))
        #expect(await inBackground { spotlight.mdfind(["-name", "x"]) } == Data())
    }
}
