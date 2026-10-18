import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationCaseImporterNewlineTests {
    private let mapping = EvaluationCaseImportMapping(nameColumn: "name", promptColumn: "prompt", expectedColumn: "expected")

    @Test(arguments: ["\n", "\r\n", "\r"])
    func csvSeparatesRecordsAndPreservesQuotedNewlines(newline: String) throws {
        let source = ["name,prompt,expected", "First,\"Ask" + newline + "about apple\",apple", "Second,Banana,banana", ""].joined(separator: newline)
        let data = Data(source.utf8)
        #expect(try EvaluationCaseImporter.columns(in: data, format: .csv) == ["name", "prompt", "expected"])
        let preview = try EvaluationCaseImporter.preview(data: data, format: .csv, mapping: mapping)
        #expect(preview.canImport)
        #expect(preview.totalValidRowCount == 2)
        #expect(preview.rows.map(\.sourceLine) == [2, 4])
        #expect(preview.rows.map(\.prompt) == ["Ask" + newline + "about apple", "Banana"])
        #expect(preview.rows.map(\.expected) == ["apple", "banana"])
        let cases = try EvaluationCaseImporter.cases(data: data, format: .csv, mapping: mapping, maximumCases: 10)
        #expect(cases.map(\.prompt) == preview.rows.map(\.prompt))
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func jsonLinesSeparatesRecordsAndCountsBlankLines(newline: String) throws {
        let source = [#"{"name":"First","prompt":"Apple","expected":"apple"}"#, "", #"{"name":"Second","prompt":"Banana","expected":"banana"}"#, ""].joined(separator: newline)
        let data = Data(source.utf8)
        #expect(try EvaluationCaseImporter.columns(in: data, format: .jsonLines) == ["expected", "name", "prompt"])
        let preview = try EvaluationCaseImporter.preview(data: data, format: .jsonLines, mapping: mapping)
        #expect(preview.canImport)
        #expect(preview.rows.map(\.sourceLine) == [1, 3])
        #expect(preview.rows.map(\.prompt) == ["Apple", "Banana"])
        let cases = try EvaluationCaseImporter.cases(data: data, format: .jsonLines, mapping: mapping, maximumCases: 10)
        #expect(cases.count == 2)
    }

    @Test func windowsCSVReportsTheActualInvalidRow() throws {
        let data = Data("name,prompt,expected\r\nFirst,Apple,apple\r\nSecond,,banana\r\n".utf8)
        let preview = try EvaluationCaseImporter.preview(data: data, format: .csv, mapping: mapping)
        #expect(!preview.canImport)
        #expect(preview.issues.map(\.line) == [3])
        #expect(throws: EvaluationCaseImportError.self) {
            try EvaluationCaseImporter.cases(data: data, format: .csv, mapping: mapping, maximumCases: 10)
        }
    }
}
