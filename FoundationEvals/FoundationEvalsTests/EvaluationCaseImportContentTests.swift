import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationCaseImportContentTests {
    private let mapping = EvaluationCaseImportMapping(nameColumn: nil, promptColumn: "prompt", expectedColumn: "expected")

    @Test(arguments: [EvaluationCaseImportFormat.csv, .jsonLines])
    func mappedPromptPreservesSignificantWhitespace(format: EvaluationCaseImportFormat) throws {
        let prompt = "\t  print(\"READY\")  \n"
        let data = try source(prompt: prompt, format: format)
        let preview = try EvaluationCaseImporter.preview(data: data, format: format, mapping: mapping)
        #expect(preview.canImport)
        #expect(preview.rows.first?.prompt == prompt)
        let imported = try EvaluationCaseImporter.cases(data: data, format: format, mapping: mapping, maximumCases: 1)
        #expect(imported.first?.prompt == prompt)
    }

    @Test(arguments: ["\n", "\r\n", "\r", ""])
    func quotedExpectedCarriageReturnsAreContent(terminator: String) throws {
        let expected = "\rReference answer\r"
        let separator = terminator.isEmpty ? "\n" : terminator
        let data = Data(("prompt,expected" + separator + "Ask," + quoted(expected) + terminator).utf8)
        let preview = try EvaluationCaseImporter.preview(data: data, format: .csv, mapping: mapping)
        #expect(preview.canImport)
        #expect(preview.rows.first?.expected == expected)
        let imported = try EvaluationCaseImporter.cases(data: data, format: .csv, mapping: mapping, maximumCases: 1)
        #expect(imported.first?.expected == expected)
    }

    @Test(arguments: [EvaluationCaseImportFormat.csv, .jsonLines])
    func promptValidationUsesThePreservedValue(format: EvaluationCaseImportFormat) throws {
        for prompt in [" \t\r\n ", String(repeating: " ", count: EvaluationStore.maximumFieldCharacters) + "x"] {
            let data = try source(prompt: prompt, format: format)
            let preview = try EvaluationCaseImporter.preview(data: data, format: format, mapping: mapping)
            #expect(!preview.canImport)
            #expect(preview.rows.isEmpty)
            #expect(preview.issues.count == 1)
            #expect(throws: EvaluationCaseImportError.self) {
                try EvaluationCaseImporter.cases(data: data, format: format, mapping: mapping, maximumCases: 1)
            }
        }
    }

    private func source(prompt: String, format: EvaluationCaseImportFormat) throws -> Data {
        switch format {
        case .csv: Data(("prompt,expected\n" + quoted(prompt) + ",READY\n").utf8)
        case .jsonLines: try JSONSerialization.data(withJSONObject: ["prompt": prompt, "expected": "READY"])
        }
    }

    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
