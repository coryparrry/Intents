import AppKit
import SwiftUI
import Testing
@testable import FoundationEvals

@MainActor
struct ResultCardHeaderLayoutTests {
    @Test(arguments: [280.0, 400.0, 600.0])
    func longScorerDoesNotDrawOverTheScoreOrStatus(width: Double) throws {
        let short = try render(width: width, scorer: "Local")
        let long = try render(width: width,
            scorer: "Same model as subject · On-device · AFM 3 Core Advanced · onDevice")
        #expect(short.pixelsWide == long.pixelsWide && short.pixelsHigh == long.pixelsHigh)
        // The trailing score/status column must render identically regardless of
        // the wrapping identity beside it. Include a few points of its gutter.
        let scale = Double(short.pixelsWide) / width
        let firstColumn = short.pixelsWide - Int(48 * scale)
        var visiblePixels = 0
        var maximumDifference = 0.0
        for x in firstColumn..<short.pixelsWide {
            for y in 0..<short.pixelsHigh {
                let baseline = try #require(short.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let candidate = try #require(long.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if baseline.alphaComponent > 0.1 { visiblePixels += 1 }
                maximumDifference = max(maximumDifference,
                    abs(baseline.alphaComponent - candidate.alphaComponent),
                    abs(baseline.redComponent - candidate.redComponent),
                    abs(baseline.greenComponent - candidate.greenComponent),
                    abs(baseline.blueComponent - candidate.blueComponent))
            }
        }
        #expect(maximumDifference < 0.01, "Scorer text changed the trailing score/status column")
        #expect(visiblePixels > 20, "The score/status column must actually render")
    }

    private func render(width: Double, scorer: String) throws -> NSBitmapImageRep {
        let result = EvaluationSampleResult(caseID: UUID(), caseName: "One case", repetition: 1,
            prompt: "Say apple", effectivePrompt: nil, expected: "apple", response: "apple", status: .passed,
            score: 3, rationale: nil, durationMilliseconds: 1, usage: .init(),
            judgeDurationMilliseconds: 1, judgeUsage: nil, errorCategory: nil, errorMessage: nil,
            judgeErrorCategory: nil, judgeErrorMessage: nil, toolCalls: nil)
        let host = NSHostingView(rootView: ResultCardHeader(result: result, repetitions: 1,
            scorerSummary: scorer, judgedByModel: true)
            .textSelection(.enabled)
            .frame(width: width, height: 120, alignment: .topLeading)
            .environment(\.colorScheme, .light))
        host.frame.size = NSSize(width: width, height: 120)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
