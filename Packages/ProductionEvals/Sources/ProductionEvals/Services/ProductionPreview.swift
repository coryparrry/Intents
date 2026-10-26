import Foundation

extension ProductionStorage {
    /// Reads only a bounded prefix; full validation still happens at import.
    /// - Parameter limit: Maximum number of examples to return, from 1 through 10.
    /// - Throws: An invalid limit, empty source, malformed/oversized example, or file-read error.
    public static func previewExamples(from file: URL, limit: Int = 3) throws -> [ProductionExample] {
        guard (1...10).contains(limit) else { throw ProductionFailure.invalid("Preview limit must be 1–10.") }
        enum Complete: Error { case prefix }
        var examples: [ProductionExample] = []
        do {
            try ProductionLineReader.forEach(file) { line in
                guard line.count <= 262_144 else { throw ProductionFailure.invalid("Encoded example exceeds 256 KB.") }
                let example = try ProductionCodec.decode(ProductionExample.self, line); try validate(example)
                examples.append(example)
                if examples.count == limit { throw Complete.prefix }
            }
        } catch Complete.prefix { }
        guard !examples.isEmpty else { throw ProductionFailure.invalid("File contains no examples.") }
        return examples
    }
}
