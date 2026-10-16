import SwiftUI
import IntentsAutomationCore

struct AutomationSiriSearchControls: View {
    @Bindable var model: AppAutomationStore
    @State private var review: AutomationNativeSiriSearchReview?
    @State private var showingReview = false
    var body: some View {
        GroupBox("Find failures in approved Siri wording") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enable the record state check above, then choose the action that restores only this disposable record to its initial state before every request.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Restore test record", selection: $model.siriResetActionID) {
                    Text("Choose a matching record and Boolean action").tag("")
                    ForEach(model.siriResetActions) { Text($0.title).tag($0.id) }
                }.accessibilityLabel("Siri search reset action")
                    .onChange(of: model.siriResetActionID) { model.workflowSelectionChanged() }
                TextField("Disposable account or session identifier", text: $model.siriAccountEnvironment)
                    .accessibilityLabel("Siri search disposable account or session")
                    .onChange(of: model.siriAccountEnvironment) { model.workflowSelectionChanged() }
                TextField("One or two requests with the same meaning, one per line", text: $model.siriAlternatePhrases, axis: .vertical)
                    .accessibilityLabel("Approved alternate Siri requests")
                    .onChange(of: model.siriAlternatePhrases) { model.workflowSelectionChanged() }
                Text("Every request restores the selected disposable record and checks its state before and after Siri. Missing evidence stops the campaign.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review Siri failure search…") {
                    do { review = try model.reviewSiriFailureSearch(); showingReview = true }
                    catch { model.message = model.errorText(error) }
                }.disabled(!model.canFindSiriFailures)
            }.padding(10)
        }.disabled(model.busy)
        .alert("Run this approved Siri failure search?", isPresented: $showingReview) {
            Button("Run approved requests") {
                guard let reviewed = review else { return }; review = nil
                Task { await model.findSiriFailures(reviewed: reviewed) }
            }
            Button("Cancel", role: .cancel) { review = nil }
        } message: { Text(review?.message ?? "Review the selected record and requests again.") }
    }
}
