import SwiftUI

struct DocumentEvidenceReview: View {
    @Binding var evaluationCase: EvaluationCase
    var availablePassages: [EvaluationDocumentPassage] = []
    var acceptAction: (() -> Void)? = nil
    var acceptanceReady: Bool = true
    @State private var selectedPassageID: String?

    private var evidence: EvaluationDocumentEvidence? { evaluationCase.documentEvidence }
    private var criteria: Binding<String> {
        Binding(get: { (evaluationCase.criteriaOverride ?? []).joined(separator: "\n") }, set: {
            evaluationCase.criteriaOverride = $0.components(separatedBy: "\n")
        })
    }

    var body: some View {
        if let evidence {
            VStack(alignment: .leading, spacing: 14) {
                Label(evaluationCase.hasReviewedDocument && acceptanceReady ? "Source review accepted" :
                    !acceptanceReady && acceptAction != nil ? "Needs semantic check" : "Needs source review",
                    systemImage: evaluationCase.hasReviewedDocument && acceptanceReady ? "checkmark.circle" : "doc.text.magnifyingglass")
                    .font(.headline)
                Text("Scoring criteria for this case").font(.subheadline.weight(.semibold))
                TextEditor(text: criteria).frame(minHeight: 90).font(.body)
                    .accessibilityLabel("Case scoring criteria, one requirement per line")
                    .border(.separator)
                Text("One to four requirements. These replace the shared suite rubric. Each must score at least 3 of 4 to pass.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Supporting quotes · \(evidence.sourceName)").font(.subheadline.weight(.semibold))
                ForEach(evidence.citations) { citation in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Picker("Source passage", selection: Binding(
                                get: { evaluationCase.documentEvidence?.citations.first(where: { $0.id == citation.id })?.passageID ?? citation.passageID },
                                set: { passageID in
                                    if let index = evaluationCase.documentEvidence?.citations.firstIndex(where: { $0.id == citation.id }) {
                                        evaluationCase.documentEvidence?.citations[index].passageID = passageID
                                    }
                                }
                            )) {
                                ForEach(evidence.passages) { passage in
                                    Text(passage.location + " · " + passage.id).tag(passage.id)
                                }
                            }
                            Button("Remove quote", systemImage: "minus.circle", role: .destructive) {
                                evaluationCase.documentEvidence?.citations.removeAll { $0.id == citation.id }
                            }.labelStyle(.iconOnly).help("Remove this supporting quote")
                        }
                        Button("Show \(citation.passageID)") { selectedPassageID = citation.passageID }
                            .buttonStyle(.link)
                        TextField("Exact supporting quote", text: Binding(
                            get: { evaluationCase.documentEvidence?.citations.first(where: { $0.id == citation.id })?.quote ?? "" },
                            set: { text in
                                if let index = evaluationCase.documentEvidence?.citations.firstIndex(where: { $0.id == citation.id }) {
                                    evaluationCase.documentEvidence?.citations[index].quote = text
                                }
                            }
                        ), axis: .vertical).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Supporting quote from \(citation.passageID)")
                        let found = evidence.passages.contains { $0.id == citation.passageID && !citation.quote.isEmpty && $0.text.contains(citation.quote) }
                        Text(found ? "Quote found — check that it supports the answer." : "Quote does not match its source.")
                            .font(.caption).foregroundStyle(found ? Color.secondary : Color.orange)
                    }
                }
                Button("Add supporting quote", systemImage: "plus") {
                    if let passage = evidence.passages.first {
                        evaluationCase.documentEvidence?.citations.append(.init(passageID: passage.id, quote: ""))
                    }
                }.disabled(evidence.citations.count >= 8 || evidence.passages.isEmpty)
                HStack {
                    Text("Complete context sent to the answering model").font(.subheadline.weight(.semibold))
                    Spacer()
                    if !availablePassages.isEmpty {
                        Menu("Add context") {
                            ForEach(availablePassages.filter { passage in !evidence.passages.contains(where: { $0.id == passage.id }) }) { passage in
                                Button(passage.location + " · " + passage.id) {
                                    evaluationCase.documentEvidence?.passages.append(passage)
                                }
                            }
                        }
                    }
                }
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(evidence.passages) { passage in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(passage.location).font(.caption.weight(.semibold))
                                    Spacer()
                                    if !evidence.citations.contains(where: { $0.passageID == passage.id }) {
                                        Button("Remove context") { evaluationCase.documentEvidence?.passages.removeAll { $0.id == passage.id } }
                                            .font(.caption)
                                    }
                                }
                                Text(highlighted(passage, quotes: evidence.citations.filter { $0.passageID == passage.id }.map(\.quote)))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .id(passage.id)
                        }
                    }
                    .onChange(of: selectedPassageID) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
                }
                if let issue = evaluationCase.documentValidationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                Button(evaluationCase.hasReviewedDocument && acceptanceReady ? "Source review accepted" : acceptAction != nil ? "Check and accept draft" : "Accept source review") {
                    if let acceptAction { acceptAction() } else { evaluationCase.acceptDocumentReview() }
                }
                .disabled(evaluationCase.documentValidationIssue != nil || (evaluationCase.hasReviewedDocument && acceptanceReady))
                .accessibilityIdentifier("Accept document source review")
                Text("Check that the source supports the question, answer, and criteria, including conditions and exceptions. A matching quote alone does not establish correctness.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func highlighted(_ passage: EvaluationDocumentPassage, quotes: [String]) -> AttributedString {
        var text = AttributedString(passage.text)
        for quote in quotes where !quote.isEmpty {
            if let range = text.range(of: quote) { text[range].backgroundColor = .yellow.opacity(0.25) }
        }
        return text
    }
}
