import SwiftUI
import IntentsAutomationCore

struct AutomationSiriSearchControls: View {
    @Bindable var model: AppAutomationStore
    @State private var review: AutomationNativeSiriSearchReview?
    @State private var showingReview = false
    @State private var conversionReview: AutomationNativeSiriConversionReview?
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
                Text("Each exact request must complete two safe live submission-channel checks on this device before search. Wording changes preserve the selected record, initial state, expected state and observer. All qualification and search attempts share one bounded allowance.")
                    .font(.callout).foregroundStyle(.secondary)
                if let gap = model.siriSearchConversionGap {
                    Text(gap).font(.callout).foregroundStyle(.secondary)
                }
                Text("Complete business failures can receive five confirmation trials after submission, record restoration and release are verified. A missing or uncertain submission stops the campaign.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review read-only physical conversion check…") {
                    do { conversionReview = try model.reviewSiriResetConversion(); review = nil; showingReview = true }
                    catch { model.message = model.errorText(error) }
                }.disabled(!model.canQualifySiriResetConversion)
                Button("Review Siri failure search…") {
                    do { review = try model.reviewSiriFailureSearch(); conversionReview = nil; showingReview = true }
                    catch { model.message = model.errorText(error) }
                }.disabled(!model.canFindSiriFailures)
            }.padding(10)
        }.disabled(model.busy)
        .alert(conversionReview != nil ? "Run the read-only physical conversion check?" : "Run this approved Siri failure search?", isPresented: $showingReview) {
            if let converted = conversionReview {
                Button("Check physical conversion") {
                    conversionReview = nil
                    Task { await model.qualifySiriResetConversion(reviewed: converted) }
                }
            } else {
                Button("Run approved requests") {
                    guard let reviewed = review else { return }; review = nil
                    Task { await model.findSiriFailures(reviewed: reviewed) }
                }
            }
            Button("Cancel", role: .cancel) { review = nil; conversionReview = nil }
        } message: { Text(conversionReview?.message ?? review?.message ?? "Review the selected record and requests again.") }
    }
}
