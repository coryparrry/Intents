import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalExecutableTests: XCTestCase {
    static func binary(platform: UInt32 = 2) -> Data {
        var data = Data(repeating: 0, count: 56)
        for (offset, value) in [(0, UInt32(0xfeedfacf)), (4, 0x0100000c), (12, 2), (16, 1), (20, 24),
                                (32, 0x32), (36, 24), (40, platform)] {
            write(value, at: offset, into: &data)
        }
        return data
    }
    static func write(_ value: UInt32, at offset: Int, into data: inout Data) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
    }
    func testPhysicalPlatformAndExecutableAreRequiredBeyondARM64() throws {
        try AutomationPhysicalExecutable.validate(Self.binary())
        for platform in [UInt32(1), 7, 3, 6] {
            XCTAssertThrowsError(try AutomationPhysicalExecutable.validate(Self.binary(platform: platform)))
        }
        for (offset, value) in [(4, UInt32(0x01000007)), (12, 6), (0, 0xcafebabe)] {
            var data = Self.binary(); Self.write(value, at: offset, into: &data)
            XCTAssertThrowsError(try AutomationPhysicalExecutable.validate(data))
        }
    }
    func testMalformedCommandTablesAndCountsFailClosed() {
        for (offset, value) in [(16, UInt32(0)), (16, 4097), (16, 2), (20, 0), (20, 1_048_577),
                                (20, 32), (36, 0), (36, 8), (36, 23), (36, 32), (52, 1), (52, UInt32.max)] {
            var data = Self.binary(); Self.write(value, at: offset, into: &data)
            XCTAssertThrowsError(try AutomationPhysicalExecutable.validate(data), "offset \(offset) value \(value)")
        }
        for count in [0, 12, 31, 32, 55] {
            XCTAssertThrowsError(try AutomationPhysicalExecutable.validate(Data(Self.binary().prefix(count))))
        }
    }
    func testMissingDuplicateAndLegacyPlatformCommandsFailClosed() {
        for command in [UInt32(1), 0x24, 0x25, 0x2f, 0x30] {
            var data = Self.binary(); Self.write(command, at: 32, into: &data)
            XCTAssertThrowsError(try AutomationPhysicalExecutable.validate(data))
        }
        var duplicate = Self.binary()
        duplicate.append(Self.binary().suffix(24))
        Self.write(2, at: 16, into: &duplicate); Self.write(48, at: 20, into: &duplicate)
        XCTAssertThrowsError(try AutomationPhysicalExecutable.validate(duplicate))
    }
    func testPhysicalTargetRequiresExactDeviceIdentifierRatherThanName() throws {
        for id in ["00008140-001049013EF3401C", String(repeating: "a", count: 40), UUID().uuidString] {
            try AutomationPhysicalExecutable.validateTarget(.init(id: id, kind: .physical))
        }
        for id in ["device", "My iPhone", "00008140-001049013EF3401C\n", "../device", "", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try AutomationPhysicalExecutable.validateTarget(.init(id: id, kind: .physical)))
        }
        XCTAssertThrowsError(try AutomationPhysicalExecutable.validateTarget(.init(id: UUID().uuidString, kind: .simulator)))
    }
}
