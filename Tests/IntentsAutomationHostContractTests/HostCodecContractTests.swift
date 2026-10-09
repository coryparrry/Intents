import Foundation
import XCTest
@testable import IntentsAutomationHostContracts
@testable import IntentsAutomationCore

final class HostCodecContractTests: XCTestCase {
    func testActualHostDateCodecPreservesAbsoluteInstantAndRejectsMissingZoneOrWrongPayload() throws {
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        let app = AppIdentity(logicalID: "app", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        for text in ["2026-10-25T01:30:00+01:00", "2026-10-25T00:30:00Z", "2026-10-25T00:30:00.000Z"] {
            let value = AutomationValue.date(text, timeZone: "Europe/London")
            let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["date": value])])
            let host = try JSONDecoder().decode(HostPlan.self, from: program.payload(scope: scope, app: app, route: .systemIntent, phase: .subject))
            let input = try XCTUnwrap(host.operations[0].parameters["date"])
            XCTAssertEqual(input.timeZone, "Europe/London")
            let formatter = ISO8601DateFormatter()
            XCTAssertEqual(try HostDateCodec.decode(input), formatter.date(from: "2026-10-25T00:30:00Z"))
        }
        let precise = try JSONDecoder().decode(HostInput.self, from: Data(#"{"kind":"date","value":"2026-10-25T00:30:00.123Z","timeZone":"UTC"}"#.utf8))
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z"))
        XCTAssertEqual(try HostDateCodec.decode(precise).timeIntervalSince(base), 0.123, accuracy: 0.000001)
        for timestamp in ["2026-10-25T00:30:00.123456Z", "2026-02-30T00:30:00Z", "2026-10-25T24:30:00Z", "2026-10-25T00:30:60Z", "2026-10-25T00:30:00Ztrailing", "2026-10-25T00:30:00", "2026-10-25T00:30:00-00:00"] {
            let raw: [String: String] = ["kind": "date", "value": timestamp, "timeZone": "UTC"]
            let input = try JSONDecoder().decode(HostInput.self, from: JSONEncoder().encode(raw))
            XCTAssertThrowsError(try HostDateCodec.decode(input), timestamp)
            XCTAssertThrowsError(try AutomationDateInput(value: timestamp, timeZone: "UTC").encoded(), timestamp)
        }
        for raw in [#"{"kind":"date","value":"2026-10-25T00:30:00Z"}"#, #"{"kind":"date","value":"2026-10-25T00:30:00Z","timeZone":"Unknown/Zone"}"#, #"{"kind":"date","value":"2026-10-25","timeZone":"UTC"}"#, #"{"kind":"date","value":"2026-10-25T00:30:00Z","timeZone":"UTC","boolValue":true}"#] {
            let input = try JSONDecoder().decode(HostInput.self, from: Data(raw.utf8))
            XCTAssertThrowsError(try HostDateCodec.decode(input))
        }
    }
    private func imported(_ hostValue: HostValue, codec: String = "decimal") throws -> AutomationValue? {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hostValue))
        let receipt: [String: Any] = ["schemaVersion": 2, "runner": ["pid": 123, "startIdentity": "123456:100", "executablePath": "/owned/Host.app/Host"],
            "runID": "run", "attemptID": "attempt", "segmentID": "subject", "leaseGeneration": 2, "bundleID": app.bundleID, "productDigest": app.productDigest!,
            "complete": true, "operations": [["operationID": "invoke", "dispatched": true, "value": value]]]
        let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", resultCodec: codec)])
        return try AutomationHostReceiptImporter.importReceipt(JSONSerialization.data(withJSONObject: receipt), scope: scope, app: app, program: program).values["invoke"]
    }
    func testRealHostDecimalEncodingRoundTripsThroughCoreForExponentValuesAndNegativeZero() throws {
        for value in [1e-9, -1e-9, 1e20, -1e20, 1.25, -0.0, 1e-250, 1e250] {
            let wire = try HostDecimalCodec.encode(value)
            XCTAssertFalse(wire.lowercased().contains("e")); XCTAssertEqual(Double(wire), value)
            XCTAssertEqual(try imported(.init(kind: "decimal", value: wire)), .decimal(wire))
        }
        XCTAssertEqual(try HostDecimalCodec.encode(-0.0), "-0.0")
        for value in [Double.infinity, -Double.infinity, Double.nan, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try HostDecimalCodec.encode(value))
        }
        XCTAssertThrowsError(try imported(.init(kind: "decimal", value: "1e-9")))
        XCTAssertThrowsError(try imported(.init(kind: "text", value: "1.25")))
    }
    func testActualHostInputModelDecodesCoreTypedArrayPayloadWithoutStringifying() throws {
        let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["names": .array([.text("alpha"), .text("beta")]), "count": .integer("9007199254740993")], resultCodec: "noValue")])
        let data = try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2),
            app: .init(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64)), route: .systemIntent, phase: .subject)
        let host = try JSONDecoder().decode(HostPlan.self, from: data)
        XCTAssertEqual(host.operations[0].parameters["names"]?.items?.map(\.value), ["alpha", "beta"])
        XCTAssertEqual(host.operations[0].parameters["names"]?.items?.map(\.kind), ["text", "text"])
        XCTAssertEqual(host.operations[0].parameters["count"]?.value, "9007199254740993")
        XCTAssertNil(host.productDigestVersion)
        var linked = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: String(repeating: "a", count: 64))
        linked.productDigestVersion = 2
        let linkedData = try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2), app: linked, route: .systemIntent, phase: .subject)
        XCTAssertEqual(try JSONDecoder().decode(HostPlan.self, from: linkedData).productDigestVersion, 2)
    }
    func testFrozenResultCodecRejectsMixedArraysAndOverflowedInteger() throws {
        XCTAssertThrowsError(try imported(.init(kind: "array", items: [.init(kind: "integer", value: "1")]), codec: "textArray"))
        XCTAssertThrowsError(try imported(.init(kind: "integer", value: "9223372036854775808"), codec: "integer"))
        XCTAssertEqual(try imported(.init(kind: "array", items: [.init(kind: "text", value: "a")]), codec: "textArray"), .array([.text("a")]))
    }
}

extension HostCodecContractTests {
    func testURLReferenceRoundTripsThroughFrozenHostPayloadAndStrictReceiptImporter() throws {
        for text in ["https://example.invalid", "http://example.invalid:8080/a%2Fb?q=one#two"] {
            let value = AutomationValue.object(["url": .text(text)])
            let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["url": value], resultCodec: "url", parameterCodecs: ["url": "url"])])
            let bytes = try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2),
                app: .init(logicalID: "app", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64)), route: .systemIntent, phase: .subject)
            let host = try JSONDecoder().decode(HostPlan.self, from: bytes), input = try XCTUnwrap(host.operations[0].parameters["url"])
            let url = try HostURLCodec.decode(input)
            XCTAssertEqual(url.absoluteString, text)
            let output = try HostURLCodec.encode(url)
            XCTAssertEqual(try imported(output, codec: "url"), value)
            for codec in ["text", "duration", "calendarComponents"] { XCTAssertThrowsError(try imported(output, codec: codec)) }
        }
    }
    func testURLHostCodecRejectsWrongShapeFilesCredentialsAndMalformedResults() throws {
        for text in ["relative", "file:///private/tmp/customer.txt", "https://user:secret@example.invalid", "https://example.invalid/a b", "https://example.invalid/%zz", "https://example.invalid/" + String(repeating: "x", count: 4096)] {
            let raw: [String: Any] = ["kind": "object", "properties": ["url": ["kind": "text", "value": text]]]
            let input = try JSONDecoder().decode(HostInput.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertThrowsError(try HostURLCodec.decode(input))
            XCTAssertThrowsError(try imported(.init(kind: "object", properties: ["url": .init(kind: "text", value: text)]), codec: "url"))
        }
        for raw in [#"{"kind":"text","value":"https://example.invalid"}"#, #"{"kind":"object","properties":{"url":{"kind":"text","value":"https://example.invalid"},"bookmark":{"kind":"text","value":"private"}}}"#, #"{"kind":"object","properties":{"url":{"kind":"text","value":"https://example.invalid","boolValue":true}}}"#] {
            XCTAssertThrowsError(try HostURLCodec.decode(JSONDecoder().decode(HostInput.self, from: Data(raw.utf8))))
        }
        XCTAssertThrowsError(try HostURLCodec.encode(URL(fileURLWithPath: "/private/tmp/customer.txt")))
        XCTAssertThrowsError(try imported(.init(kind: "text", value: "https://example.invalid"), codec: "url"))
    }
    func testNativeIntegerResultsPreserveBoundariesAndCollectionLimits() throws {
        let values: [Int] = [Int.min, -1, 0, 9_007_199_254_740_993, Int.max]
        let encoded = try HostArrayCodec.encodeIntegers(values)
        let wire = try JSONEncoder().encode(encoded)
        let decoded = try JSONDecoder().decode(HostInput.self, from: wire)
        XCTAssertEqual(try HostArrayCodec.integers(decoded), values.map { Int64($0) })
        XCTAssertEqual(try HostArrayCodec.encodeIntegers([]).items?.count, 0)
        XCTAssertEqual(try HostArrayCodec.encodeIntegers(Array(repeating: 1, count: 1000)).items?.count, 1000)
        XCTAssertThrowsError(try HostArrayCodec.encodeIntegers(Array(repeating: 1, count: 1001)))
    }
    func testFrozenCollectionsRoundTripThroughActualHostInputConvertersIncludingEmptyTypes() throws {
        let samples: [(String, AutomationValue)] = [
            ("textArray", .array([.text("alpha")])), ("boolArray", .array([.bool(true), .bool(false)])),
            ("integerArray", .array([.integer("9007199254740993"), .integer("-9223372036854775808")])),
            ("decimalArray", .array([.decimal("0.000000001"), .decimal("-0.0")])),
            ("dateArray", .array([.date("2026-10-25T00:30:00Z", timeZone: "Europe/London")]))]
        for (family, sample) in samples {
            for value in [sample, .array([])] {
                let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["values": value], parameterCodecs: ["values": family])])
                let payload = try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2),
                    app: .init(logicalID: "app", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64)), route: .systemIntent, phase: .subject)
                let operation = try JSONDecoder().decode(HostPlan.self, from: payload).operations[0]
                XCTAssertEqual(operation.parameterCodecs?["values"], family)
                let input = try XCTUnwrap(operation.parameters["values"])
                switch family {
                case "textArray": XCTAssertEqual(try HostArrayCodec.texts(input).count, input.items?.count)
                case "boolArray": XCTAssertEqual(try HostArrayCodec.bools(input), value == sample ? [true, false] : [])
                case "integerArray": XCTAssertEqual(try HostArrayCodec.integers(input), value == sample ? [9007199254740993, Int64.min] : [])
                case "decimalArray":
                    let numbers = try HostArrayCodec.decimals(input)
                    XCTAssertEqual(numbers.count, input.items?.count)
                    if !numbers.isEmpty { XCTAssertEqual(numbers[0], 1e-9); XCTAssertEqual(numbers[1].sign, .minus) }
                case "dateArray": XCTAssertEqual(try HostArrayCodec.dates(input).count, input.items?.count)
                default: XCTFail("Unexpected family")
                }
            }
        }
    }
    func testActualHostCollectionConvertersRejectWrongElementShapeAndRange() throws {
        let bad: [(String, String)] = [
            (#"{"kind":"array","items":[{"kind":"integer","value":"9223372036854775808"}]}"#, "integer"),
            (#"{"kind":"array","items":[{"kind":"integer","value":"01"}]}"#, "integer"),
            (#"{"kind":"array","items":[{"kind":"decimal","value":"1e3"}]}"#, "decimal"),
            (#"{"kind":"array","items":[{"kind":"decimal","value":"NaN"}]}"#, "decimal"),
            (#"{"kind":"array","items":[{"kind":"bool","boolValue":true,"value":"true"}]}"#, "bool"),
            (#"{"kind":"array","items":[{"kind":"array","items":[]}]}"#, "text"),
            (#"{"kind":"array","items":[{"kind":"date","value":"2026-02-30T00:00:00Z","timeZone":"UTC"}]}"#, "date")]
        for (wire, family) in bad {
            let input = try JSONDecoder().decode(HostInput.self, from: Data(wire.utf8))
            switch family {
            case "integer": XCTAssertThrowsError(try HostArrayCodec.integers(input))
            case "decimal": XCTAssertThrowsError(try HostArrayCodec.decimals(input))
            case "bool": XCTAssertThrowsError(try HostArrayCodec.bools(input))
            case "date": XCTAssertThrowsError(try HostArrayCodec.dates(input))
            default: XCTAssertThrowsError(try HostArrayCodec.texts(input))
            }
        }
    }
    func testCollectionResultsAreCorrelatedWithFrozenElementType() throws {
        let results: [(String, HostValue, AutomationValue)] = [
            ("boolArray", .init(kind: "bool", boolValue: true), .bool(true)),
            ("integerArray", .init(kind: "integer", value: "9007199254740993"), .integer("9007199254740993")),
            ("decimalArray", .init(kind: "decimal", value: "0.000000001"), .decimal("0.000000001"))]
        for (family, host, expected) in results {
            XCTAssertEqual(try imported(.init(kind: "array", items: [host]), codec: family), .array([expected]))
            XCTAssertEqual(try imported(.init(kind: "array", items: []), codec: family), .array([]))
            XCTAssertThrowsError(try imported(.init(kind: "array", items: [.init(kind: "text", value: "wrong")]), codec: family))
            XCTAssertThrowsError(try imported(.init(kind: "array", items: [.init(kind: "array", items: [host])]), codec: family))
        }
    }
}

extension HostCodecContractTests {
    func testResultBudgetRejectsOversizedEscapedAndAccumulatedOutputBeforeEncoding() throws {
        let huge = HostValue(kind: "array", items: [.init(kind: "text", value: String(repeating: "x", count: 32769))])
        XCTAssertThrowsError(try HostValueBudget.validate([huge]))
        let escaped = HostValue(kind: "array", items: Array(repeating: .init(kind: "text", value: String(repeating: "\u{0001}", count: 30000)), count: 5))
        XCTAssertThrowsError(try HostValueBudget.validate([escaped]))
        let one = HostValue(kind: "array", items: [.init(kind: "text", value: String(repeating: "x", count: 30000))])
        XCTAssertNoThrow(try HostValueBudget.validate([one]))
        XCTAssertThrowsError(try HostValueBudget.validate(Array(repeating: one, count: 5)))
        XCTAssertNoThrow(try HostValueBudget.validate([.init(kind: "array", items: Array(repeating: .init(kind: "bool", boolValue: true), count: 1000))]))
        XCTAssertThrowsError(try HostValueBudget.validate([.init(kind: "array", items: Array(repeating: .init(kind: "bool", boolValue: true), count: 1001))]))
    }
}

extension HostCodecContractTests {
    func testErrorEvidenceBudgetCountsBytesEvenForOneHugeGraphemeCluster() throws {
        let combining = "a" + String(repeating: "\u{0301}", count: 100000)
        XCTAssertEqual(combining.count, 1)
        for text in [combining, String(repeating: "🙂", count: 10000), String(repeating: "界", count: 10000)] {
            let bounded = HostValueBudget.boundedErrorDescription(text)
            XCTAssertLessThanOrEqual(bounded.utf8.count, 4098)
            XCTAssertLessThan(try JSONEncoder().encode(bounded).count, 25000)
        }
        XCTAssertEqual(HostValueBudget.boundedErrorDescription("Known failure"), "Known failure")
    }
}

extension HostCodecContractTests {
    func testDateResultsPreserveExactStoredInstantAndUTCThroughOriginalImporter() throws {
        for text in ["2026-10-25T01:30:00+01:00", "2026-10-25T00:30:00.123Z", "1969-12-31T23:59:59.125Z", "2001-01-01T00:00:00.001Z"] {
            let input = try JSONDecoder().decode(HostInput.self, from: JSONSerialization.data(withJSONObject: ["kind":"date", "value":text, "timeZone":"Europe/London"]))
            let date = try HostDateCodec.decode(input)
            let host = try HostDateCodec.encode(date)
            XCTAssertEqual(host.timeZone, "UTC")
            let roundTripInput = try JSONDecoder().decode(HostInput.self, from: JSONEncoder().encode(host))
            XCTAssertEqual(try HostDateCodec.decode(roundTripInput), date)
            XCTAssertEqual(try imported(host, codec: "date"), .date(try XCTUnwrap(host.value), timeZone: "UTC"))
            XCTAssertEqual(try imported(.init(kind: "array", items: [host]), codec: "dateArray"), .array([.date(try XCTUnwrap(host.value), timeZone: "UTC")]))
        }
    }
    func testDateResultRejectsPrecisionLossInvalidOrUnboundTimeZone() throws {
        for date in [Date(timeIntervalSince1970: 1700000000.0001), Date(timeIntervalSince1970: -.infinity), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 253402300800)] {
            XCTAssertThrowsError(try HostDateCodec.encode(date))
        }
        XCTAssertThrowsError(try imported(.init(kind: "date", value: "2026-02-30T00:00:00Z", timeZone: "UTC"), codec: "date"))
        XCTAssertThrowsError(try imported(.init(kind: "date", value: "2026-01-01T00:00:00.123456Z", timeZone: "UTC"), codec: "date"))
        XCTAssertThrowsError(try imported(.init(kind: "date", value: "2026-01-01T00:00:00Z", timeZone: "Europe/London"), codec: "date"))
        XCTAssertThrowsError(try imported(.init(kind: "text", value: "2026-01-01T00:00:00Z"), codec: "date"))
        XCTAssertThrowsError(try imported(.init(kind: "array", items: [.init(kind: "date", value: "2026-01-01T00:00:00Z", timeZone: "Europe/London")]), codec: "dateArray"))
    }
}

extension HostCodecContractTests {
    func testDateResultsRequireCanonicalUTCOutputWithoutChangingHistoricalInputs() throws {
        for text in ["2026-01-01T01:00:00+01:00", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00.1Z", "2026-01-01T00:00:00.12Z"] {
            let value = HostValue(kind: "date", value: text, timeZone: "UTC")
            XCTAssertThrowsError(try imported(value, codec: "date"))
            XCTAssertThrowsError(try imported(.init(kind: "array", items: [value]), codec: "dateArray"))
            let input = try JSONDecoder().decode(HostInput.self, from: JSONEncoder().encode(value))
            XCTAssertNoThrow(try HostDateCodec.decode(input))
        }
    }
    func testDateOutputRepresentsEveryMillisecondAcceptedByInputCodec() throws {
        for milliseconds in 0..<1000 {
            let text = String(format: "2026-10-25T00:30:00.%03dZ", milliseconds)
            let input = try JSONDecoder().decode(HostInput.self, from: JSONSerialization.data(withJSONObject: ["kind":"date", "value":text, "timeZone":"UTC"]))
            let date = try HostDateCodec.decode(input)
            XCTAssertEqual(try HostDateCodec.encode(date).value, text)
        }
    }
}

extension HostCodecContractTests {
    func testDurationComponentsRoundTripExactlyThroughFrozenPayloadAndOriginalImporter() throws {
        for (seconds, fraction) in [(Int64(0),Int64(0)), (0,-1), (1,999999999999999999), (-1,-999999999999999999), (9007199254740993,123456789012345678), (Int64.max,999999999999999999), (Int64.min,-999999999999999999)] {
            let value = AutomationValue.object(["seconds": .integer(String(seconds)), "attoseconds": .integer(String(fraction))])
            let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["duration": value], resultCodec: "duration", parameterCodecs: ["duration":"duration"])])
            let bytes = try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2),
                app: .init(logicalID: "app", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64)), route: .systemIntent, phase: .subject)
            let host = try JSONDecoder().decode(HostPlan.self, from: bytes), input = try XCTUnwrap(host.operations[0].parameters["duration"])
            let duration = try HostDurationCodec.decode(input)
            XCTAssertEqual(duration, Duration(secondsComponent: seconds, attosecondsComponent: fraction))
            let output = try HostDurationCodec.encode(duration)
            XCTAssertEqual(try imported(output, codec: "duration"), value)
        }
    }
    func testDurationOutputRejectsUnrepresentableNativeRangeAndMalformedComponents() throws {
        XCTAssertThrowsError(try HostDurationCodec.encode(Duration(attoseconds: Int128.max)))
        XCTAssertThrowsError(try HostDurationCodec.encode(Duration(attoseconds: Int128.min)))
        let malformed: [[String: HostValue]] = [
            ["seconds":.init(kind:"integer",value:"1"),"attoseconds":.init(kind:"integer",value:"-1")],
            ["seconds":.init(kind:"integer",value:"0"),"attoseconds":.init(kind:"integer",value:"1000000000000000000")],
            ["seconds":.init(kind:"text",value:"1"),"attoseconds":.init(kind:"integer",value:"0")],
            ["seconds":.init(kind:"integer",value:"1")]]
        for properties in malformed {
            let output = HostValue(kind:"object",properties:properties)
            XCTAssertThrowsError(try imported(output,codec:"duration"))
            let input = try JSONDecoder().decode(HostInput.self,from:JSONEncoder().encode(output))
            XCTAssertThrowsError(try HostDurationCodec.decode(input))
        }
    }
}

extension HostCodecContractTests {
    func testCalendarComponentsRoundTripWithoutInventingMissingCalendarOrTimeZone() throws {
        let fields = ["era":"1","year":"2026","month":"10","day":"6","hour":"23","minute":"59","second":"58","nanosecond":"123456789", "weekday":"3","weekdayOrdinal":"-1","quarter":"4","weekOfMonth":"1","weekOfYear":"41","yearForWeekOfYear":"2026","dayOfYear":"279"]
        for components in [[:], ["month":"-2"], fields] {
            let value = AutomationValue.object(["components":.object(components.mapValues(AutomationValue.integer))])
            let program = AutomationHostProgram(operations:[.init(id:"invoke",kind:.invoke,typeID:"Intent",parameters:["calendar":value],parameterCodecs:["calendar":"calendarComponents"])])
            let data = try program.payload(scope:.init(runID:"run",attemptID:"attempt",segmentID:"subject",leaseGeneration:2),app:.init(logicalID:"app",bundleID:"example.Subject",platform:"ios",productDigest:String(repeating:"a",count:64)),route:.systemIntent,phase:.subject)
            let input = try XCTUnwrap(JSONDecoder().decode(HostPlan.self,from:data).operations[0].parameters["calendar"])
            let decoded = try HostCalendarCodec.decode(input)
            XCTAssertNil(decoded.calendar); XCTAssertNil(decoded.timeZone); XCTAssertNil(decoded.isLeapMonth)
            if let month = components["month"] { XCTAssertEqual(decoded.month,Int(month)) }
            let output = try HostCalendarCodec.encode(decoded)
            XCTAssertEqual(try imported(output,codec:"calendarComponents"),value)
            XCTAssertEqual(try HostCalendarCodec.decode(JSONDecoder().decode(HostInput.self,from:JSONEncoder().encode(output))),decoded)
        }
    }
    func testCalendarExplicitContextPreservesStoredWeekRulesLocaleLeapFlagAndZone() throws {
        var calendar = Calendar(identifier:.iso8601); calendar.locale = nil
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier:"Europe/London")); calendar.firstWeekday = 3; calendar.minimumDaysInFirstWeek = 5
        var value = DateComponents(); value.year = 2026; value.month = 10; value.day = 6; value.calendar = calendar
        value.timeZone = try XCTUnwrap(TimeZone(identifier:"America/New_York")); value.isLeapMonth = false
        let output = try HostCalendarCodec.encode(value)
        let decoded = try HostCalendarCodec.decode(JSONDecoder().decode(HostInput.self,from:JSONEncoder().encode(output)))
        XCTAssertEqual(decoded,value); XCTAssertEqual(decoded.calendar?.firstWeekday,3); XCTAssertEqual(decoded.calendar?.minimumDaysInFirstWeek,5)
        XCTAssertEqual(decoded.calendar?.timeZone.identifier,value.calendar?.timeZone.identifier); XCTAssertEqual(decoded.timeZone?.identifier,"America/New_York")
        XCTAssertEqual(decoded.isLeapMonth,false); XCTAssertNotNil(try imported(output,codec:"calendarComponents"))
        var localized = value; localized.calendar?.locale = Locale(identifier:"en_GB")
        let localizedOutput = try HostCalendarCodec.encode(localized)
        XCTAssertEqual(try HostCalendarCodec.decode(JSONDecoder().decode(HostInput.self, from: JSONEncoder().encode(localizedOutput))), localized)
        XCTAssertNotNil(try imported(localizedOutput, codec: "calendarComponents"))
        value.calendar = Calendar(identifier:.buddhist)
        XCTAssertThrowsError(try HostCalendarCodec.encode(value))
    }
    func testCalendarOutputRejectsWrongComponentTagsAndUndeclaredFields() throws {
        let malformed: [[String:HostValue]] = [
            ["components":.init(kind:"object",properties:["day":.init(kind:"text",value:"1")])],
            ["components":.init(kind:"object",properties:["unknown":.init(kind:"integer",value:"1")])],
            ["components":.init(kind:"object",properties:[:]),"extra":.init(kind:"bool",boolValue:true)]]
        for fields in malformed {
            let output = HostValue(kind:"object",properties:fields)
            XCTAssertThrowsError(try imported(output,codec:"calendarComponents"))
            XCTAssertThrowsError(try HostCalendarCodec.decode(JSONDecoder().decode(HostInput.self,from:JSONEncoder().encode(output))))
        }
    }
}

extension HostCodecContractTests {
    func testImportedTypedProducerOutputsReachTheActualConsumerHostDecoders() throws {
        let samples: [(String, HostValue)] = [
            ("textArray", .init(kind: "array", items: [.init(kind: "text", value: "bound")])),
            ("boolArray", .init(kind: "array", items: [.init(kind: "bool", boolValue: true)])),
            ("integerArray", .init(kind: "array", items: [.init(kind: "integer", value: "9007199254740993")])),
            ("decimalArray", .init(kind: "array", items: [.init(kind: "decimal", value: "0.000000001")])),
            ("dateArray", .init(kind: "array", items: [.init(kind: "date", value: "2026-10-08T00:00:00.000Z", timeZone: "UTC")])),
            ("duration", .init(kind: "object", properties: ["seconds": .init(kind: "integer", value: "7"), "attoseconds": .init(kind: "integer", value: "123")])),
            ("calendarComponents", .init(kind: "object", properties: ["components": .init(kind: "object", properties: ["month": .init(kind: "integer", value: "-2")])]))
        ] + ["textArray", "boolArray", "integerArray", "decimalArray", "dateArray"].map { ($0, .init(kind: "array", items: [])) }
        for (family, output) in samples {
            let value = try XCTUnwrap(imported(output, codec: family))
            let app = AppIdentity(logicalID: "app", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
            var producer = AutomationSegment(id: "producer", kind: .systemIntent, phase: .setup, operation: "Produce", lifecycle: .persistedStateAcrossSegments)
            producer.hostProgram = .init(operations: [.init(id: "output", kind: .invoke, typeID: "Producer", resultCodec: family)])
            var consumer = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Consume", lifecycle: .persistedStateAcrossSegments)
            consumer.hostProgram = .init(operations: [.init(id: "consume", kind: .invoke, typeID: "Consumer", resultCodec: "noValue")])
            consumer.inputBindings = [.init(producerSegmentID: "producer", outputID: "output", destination: .hostParameter, operationID: "consume", name: "values", parameterCodec: family)]
            let plan = AutomationCase(id: "case", app: app, target: .init(id: "owned", kind: .simulator), environmentID: "fixture", execution: consumer, setup: [producer])
            try AutomationInputResolver.validate(plan: plan)
            let receipt = AutomationSegmentReceipt(scope: .init(runID: "run", attemptID: "attempt", segmentID: "producer", leaseGeneration: 1), app: app, target: plan.target,
                segmentID: "producer", route: .systemIntent, dispatched: true, completed: true, verifiedOutputs: ["output": value], environmentID: "fixture")
            let resolved = try AutomationInputResolver.resolve(segment: consumer, receipts: [receipt], plan: plan, runID: "run", attemptID: "attempt")
            let payload = try XCTUnwrap(resolved.hostProgram).payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2), app: app, route: .systemIntent, phase: .subject)
            let host = try JSONDecoder().decode(HostPlan.self, from: payload)
            XCTAssertEqual(host.operations[0].parameterCodecs?["values"], family)
            let input = try XCTUnwrap(host.operations[0].parameters["values"])
            let encoded: HostValue
            switch family {
            case "textArray": encoded = .init(kind: "array", items: try HostArrayCodec.texts(input).map { .init(kind: "text", value: $0) })
            case "boolArray": encoded = .init(kind: "array", items: try HostArrayCodec.bools(input).map { .init(kind: "bool", boolValue: $0) })
            case "integerArray": encoded = .init(kind: "array", items: try HostArrayCodec.integers(input).map { .init(kind: "integer", value: String($0)) })
            case "decimalArray": encoded = .init(kind: "array", items: try HostArrayCodec.decimals(input).map { .init(kind: "decimal", value: try HostDecimalCodec.encode($0)) })
            case "dateArray": encoded = .init(kind: "array", items: try HostArrayCodec.dates(input).map(HostDateCodec.encode))
            case "duration": encoded = try HostDurationCodec.encode(HostDurationCodec.decode(input))
            default: encoded = try HostCalendarCodec.encode(HostCalendarCodec.decode(input))
            }
            XCTAssertEqual(try imported(encoded, codec: family), value)
        }
    }
}
