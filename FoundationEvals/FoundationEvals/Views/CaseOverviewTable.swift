import SwiftUI

struct CaseOverviewTable: View {
    let cases: [EvaluationCase]
    @Binding var selection: UUID?
    @State private var searchText = ""

    private var visibleCases: [EvaluationCase] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return cases.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select a case to edit")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search cases", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("Search cases")
                }
                .padding(7)
                .frame(width: 240)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            }
            .padding(.bottom, 12)

            Table(visibleCases, selection: $selection) {
                TableColumn("Case name") { item in
                    Label(item.name.isEmpty ? "Untitled case" : item.name, systemImage: "text.bubble")
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 220)
                TableColumn("Prompt") { item in
                    Text(item.prompt.isEmpty ? "No prompt" : item.prompt)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 220, ideal: 440)
                TableColumn("Expected response") { item in
                    Text(item.expected.isEmpty ? "—" : item.expected)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 200)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: CGFloat(min(max(visibleCases.count, 2), 6) * 30 + 32))
            .overlay {
                if visibleCases.isEmpty {
                    Text("No matching cases")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityIdentifier("Test cases table")
        }
        .onChange(of: searchText) { _, _ in
            if !visibleCases.contains(where: { $0.id == selection }) {
                selection = visibleCases.first?.id
            }
        }
        .onChange(of: cases) { _, _ in
            if let selection, !visibleCases.contains(where: { $0.id == selection }) {
                searchText = ""
            }
        }
        .onChange(of: selection) { _, selectedID in
            if let selectedID, !visibleCases.contains(where: { $0.id == selectedID }) {
                searchText = ""
            }
        }
    }
}
