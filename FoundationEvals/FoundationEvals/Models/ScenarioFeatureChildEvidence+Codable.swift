import Foundation

extension ScenarioFeatureChildEvidence {
    static let omitExactTimestampMetadata = CodingUserInfoKey(rawValue: "omitExactFeatureTimestampMetadata")!

    private enum CodingKeys: String, CodingKey {
        case runID, sampleID, startedAt, completedAt, caseID, attempt, response
        case encodedOutput, encodedOutputTypeName, outputMetadata, errorCategory, errorMessage
        case appBundleIdentifier, featureID, featureVersion, checkedAppProductDigest, runnerBuildID
        case fixtureContractDigest, subjectInputDigest, digest, measurementImplementation
        case startedAtReferenceBits, completedAtReferenceBits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runID = try values.decode(UUID.self, forKey: .runID)
        sampleID = try values.decode(UUID.self, forKey: .sampleID)
        startedAt = try Self.exactDate(in: values, date: .startedAt, bits: .startedAtReferenceBits)
        completedAt = try Self.exactDate(in: values, date: .completedAt, bits: .completedAtReferenceBits)
        caseID = try values.decode(UUID.self, forKey: .caseID)
        attempt = try values.decode(Int.self, forKey: .attempt)
        response = try values.decode(String.self, forKey: .response)
        encodedOutput = try values.decodeIfPresent(Data.self, forKey: .encodedOutput)
        encodedOutputTypeName = try values.decodeIfPresent(String.self, forKey: .encodedOutputTypeName)
        outputMetadata = try values.decode([String: String].self, forKey: .outputMetadata)
        errorCategory = try values.decodeIfPresent(String.self, forKey: .errorCategory)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        appBundleIdentifier = try values.decode(String.self, forKey: .appBundleIdentifier)
        featureID = try values.decode(String.self, forKey: .featureID)
        featureVersion = try values.decode(String.self, forKey: .featureVersion)
        checkedAppProductDigest = try values.decode(String.self, forKey: .checkedAppProductDigest)
        runnerBuildID = try values.decode(String.self, forKey: .runnerBuildID)
        fixtureContractDigest = try values.decode(String.self, forKey: .fixtureContractDigest)
        subjectInputDigest = try values.decodeIfPresent(String.self, forKey: .subjectInputDigest)
        digest = try values.decode(String.self, forKey: .digest)
        measurementImplementation = try values.decodeIfPresent(ScenarioMeasurementImplementation.self, forKey: .measurementImplementation)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(runID, forKey: .runID)
        try values.encode(sampleID, forKey: .sampleID)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(completedAt, forKey: .completedAt)
        try values.encode(caseID, forKey: .caseID)
        try values.encode(attempt, forKey: .attempt)
        try values.encode(response, forKey: .response)
        try values.encodeIfPresent(encodedOutput, forKey: .encodedOutput)
        try values.encodeIfPresent(encodedOutputTypeName, forKey: .encodedOutputTypeName)
        try values.encode(outputMetadata, forKey: .outputMetadata)
        try values.encodeIfPresent(errorCategory, forKey: .errorCategory)
        try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try values.encode(appBundleIdentifier, forKey: .appBundleIdentifier)
        try values.encode(featureID, forKey: .featureID)
        try values.encode(featureVersion, forKey: .featureVersion)
        try values.encode(checkedAppProductDigest, forKey: .checkedAppProductDigest)
        try values.encode(runnerBuildID, forKey: .runnerBuildID)
        try values.encode(fixtureContractDigest, forKey: .fixtureContractDigest)
        try values.encodeIfPresent(subjectInputDigest, forKey: .subjectInputDigest)
        try values.encode(digest, forKey: .digest)
        try values.encodeIfPresent(measurementImplementation, forKey: .measurementImplementation)
        if encoder.userInfo[Self.omitExactTimestampMetadata] as? Bool != true {
            try Self.encodeExactDate(startedAt, in: &values, key: .startedAtReferenceBits)
            try Self.encodeExactDate(completedAt, in: &values, key: .completedAtReferenceBits)
        }
    }

    private static func encodeExactDate(_ date: Date, in values: inout KeyedEncodingContainer<CodingKeys>, key: CodingKeys) throws {
        let instant = date.timeIntervalSinceReferenceDate
        // Whole-second legacy payloads retain their original encoded bytes.
        if instant != instant.rounded(.down) {
            try values.encode(String(instant.bitPattern, radix: 16), forKey: key)
        }
    }

    private static func exactDate(in values: KeyedDecodingContainer<CodingKeys>, date: CodingKeys, bits: CodingKeys) throws -> Date {
        let displayed = try values.decode(Date.self, forKey: date)
        guard let text = try values.decodeIfPresent(String.self, forKey: bits) else { return displayed }
        guard let representation = UInt64(text, radix: 16), Double(bitPattern: representation).isFinite else {
            throw DecodingError.dataCorruptedError(forKey: bits, in: values, debugDescription: "Invalid exact Feature timestamp.")
        }
        let instant = Double(bitPattern: representation)
        let exact = Date(timeIntervalSinceReferenceDate: instant)
        guard displayed == exact || displayed == Date(timeIntervalSinceReferenceDate: instant.rounded(.down)) else {
            throw DecodingError.dataCorruptedError(forKey: bits, in: values, debugDescription: "Feature timestamp conflicts with its exact instant.")
        }
        return exact
    }
}
