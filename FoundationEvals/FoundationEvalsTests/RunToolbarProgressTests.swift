import AppKit
import SwiftUI
import Testing
#if canImport(FoundationEvalsUIComponents)
@testable import FoundationEvalsUIComponents
#else
@testable import FoundationEvals
#endif

/// Native control layout without creating a window, activating the app, or recording the screen.
@MainActor
struct RunToolbarProgressTests {
    @Test func progressTrackStaysInsideTheToolbarCapsuleAtEveryStage() throws {
        for (completed, total) in [(0, 1), (1, 2), (1, 1), (99, 100), (999, 1_000), (0, 0)] {
            let host = makeHost(completed: completed, total: total)
            let indicator = try #require(findIndicator(in: host), "Native progress control missing: \(host.subviews)")
            let rect = indicator.convert(indicator.bounds, to: host)
            #expect(rect.minX >= 11.9)
            #expect(rect.maxX <= host.bounds.maxX - 11.9)
            #expect(abs(rect.width - 90) < 0.1)
            #expect(rect.minY >= 0)
            #expect(rect.maxY <= host.bounds.maxY)
            #expect(!indicator.isIndeterminate)
            let fraction = (indicator.doubleValue - indicator.minValue) / (indicator.maxValue - indicator.minValue)
            #expect(abs(fraction - Double(completed) / Double(max(total, 1))) < 0.001)
        }
    }

    @Test func longerCountsGrowTheCapsuleInsteadOfCompressingTheBar() throws {
        let short = makeHost(completed: 0, total: 1)
        let long = makeHost(completed: 999, total: 1_000)
        #expect(long.bounds.width > short.bounds.width + 20)
        let shortBar = try #require(findIndicator(in: short))
        let longBar = try #require(findIndicator(in: long))
        #expect(shortBar.bounds.width == longBar.bounds.width)
        #expect(longBar.convert(longBar.bounds, to: long).minX >= 11.9)
    }

    @Test func counterGlyphsStayClearOfTheTrailingRoundedEnd() throws {
        for (completed, total) in [(0, 1), (999, 1_000)] {
            let host = makeHost(completed: completed, total: total)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var rightmostInk = -1
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                        rightmostInk = max(rightmostInk, x)
                    }
                }
            }
            #expect(rightmostInk >= 0, "The counter must actually render")
            let pixelsPerPoint = Double(bitmap.pixelsWide) / host.bounds.width
            #expect(Double(bitmap.pixelsWide - 1 - rightmostInk) / pixelsPerPoint >= 11)
        }
    }

    @Test func updatingProgressPreservesInsetsAndTrackWidth() throws {
        let host = makeHost(completed: 0, total: 100)
        for completed in [1, 50, 100] {
            host.rootView = RunToolbarProgress(completed: completed, total: 100)
            host.frame.size = NSSize(width: host.fittingSize.width, height: 32)
            host.layoutSubtreeIfNeeded()
            let indicator = try #require(findIndicator(in: host))
            let rect = indicator.convert(indicator.bounds, to: host)
            #expect(rect.minX >= 11.9)
            #expect(abs(rect.width - 90) < 0.1)
            #expect(rect.maxX <= host.bounds.maxX - 11.9)
        }
    }

    private func makeHost(completed: Int, total: Int) -> NSHostingView<RunToolbarProgress> {
        let host = NSHostingView(rootView: RunToolbarProgress(completed: completed, total: total))
        host.frame.size = NSSize(width: host.fittingSize.width, height: 32)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func findIndicator(in view: NSView) -> NSProgressIndicator? {
        if let indicator = view as? NSProgressIndicator { return indicator }
        for child in view.subviews {
            if let indicator = findIndicator(in: child) { return indicator }
        }
        return nil
    }
}
