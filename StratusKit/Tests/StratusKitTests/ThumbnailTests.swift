import CoreGraphics
import Foundation
import Testing
@testable import StratusKit

@Suite struct ThumbnailTests {
    @Test func pixelSizeIsRoundedAndClamped() {
        #expect(Thumbnails.pixelSize(CGSize(width: 256, height: 128)) == Thumbnails.Size(width: 256, height: 128))
        #expect(Thumbnails.pixelSize(CGSize(width: 99.5, height: 10.4)) == Thumbnails.Size(width: 100, height: 16))
        #expect(Thumbnails.pixelSize(CGSize(width: 4000, height: 0)) == Thumbnails.Size(width: 1024, height: 16))
        #expect(Thumbnails.pixelSize(CGSize(width: -1, height: CGFloat.nan)) == Thumbnails.Size(width: 16, height: 16))
        #expect(Thumbnails.pixelSize(CGSize(width: CGFloat.infinity, height: 1024)) == Thumbnails.Size(width: 1024, height: 1024))
    }

    @Test func forEachBoundsConcurrencyAndRunsEverything() async {
        let tracker = ConcurrencyTracker()
        await Thumbnails.forEach(Array(0..<20), limit: 4) { n in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await tracker.leave(n)
        }
        #expect(await tracker.peak <= 4)
        #expect(await tracker.peak > 1)
        #expect(await tracker.done.sorted() == Array(0..<20))
    }

    @Test func forEachStillVisitsEveryItemWhenCancelled() async {
        let tracker = ConcurrencyTracker()
        let task = Task {
            await Thumbnails.forEach(Array(0..<10), limit: 2) { n in
                try? await Task.sleep(for: .seconds(5))
                await tracker.leave(n)
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value
        #expect(await tracker.done.sorted() == Array(0..<10))
    }
}

private actor ConcurrencyTracker {
    var running = 0, peak = 0
    var done: [Int] = []
    func enter() { running += 1; peak = max(peak, running) }
    func leave(_ n: Int) { running = max(0, running - 1); done.append(n) }
}
