#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    var sourceRecipeRoot: URL? {
        guard let root = selectedSourceRoot, !["app", "ipa", "xcarchive"].contains(root.pathExtension.lowercased()) else { return nil }
        return root
    }
    var hasXcodeGenSpecification: Bool {
        guard let root = sourceRecipeRoot else { return false }
        return ["project.yml", "project.yaml", "project.json"].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    var hasSwiftPackage: Bool {
        guard let root = sourceRecipeRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    }
    var hasTuistSpecification: Bool {
        guard let root = sourceRecipeRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Project.swift").path)
    }
    func runSourceRecipe(_ recipe: AutomationSourceRecipe) {
        guard !busy, sourceRecipeRoot == recipe.source else { return }
        advanceSelection()
        message = nil; progress = recipe.kind == .swiftPMPackaging ? "Running the app packaging recipe in a private source copy…" : "Generating the project in a private source copy…"
        let support = support, developer = developerDirectory
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let result = try await recipe.run(supportRoot: support, developerDirectory: developer)
                try Task.checkCancellation()
                progress = nil
                select(result.selection)
                let selection = task
                await withTaskCancellationHandler { await selection?.value } onCancel: { selection?.cancel() }
                try Task.checkCancellation()
                if selection?.isCancelled == true { throw CancellationError() }
            } catch is CancellationError { message = "Source preparation cancelled." }
            catch { message = errorText(error) }
        }
    }
    func importRepository(_ address: String) {
        guard !busy else { return }
        do { _ = try AutomationRepositoryCheckout.validatedURL(address) }
        catch { message = errorText(error); return }
        advanceSelection()
        message = nil; progress = "Fetching a private source checkout…"
        let support = support
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let checkout = try await AutomationRepositoryCheckout.fetch(address, supportRoot: support)
                try Task.checkCancellation()
                progress = nil
                select(checkout.directory)
                let selection = task
                await withTaskCancellationHandler { await selection?.value } onCancel: { selection?.cancel() }
                try Task.checkCancellation()
                if selection?.isCancelled == true { throw CancellationError() }
            } catch is CancellationError { message = "Repository import cancelled." }
            catch { message = errorText(error) }
        }
    }
    func importIPA(_ url: URL) {
        guard !busy else { return }
        advanceSelection()
        message = nil; progress = "Inspecting and extracting the app archive…"
        let access = url.startAccessingSecurityScopedResource(), support = support
        task = Task {
            defer { if access { url.stopAccessingSecurityScopedResource() }; progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                // Archive work stays off the main actor; cancellation propagates to extraction.
                let extraction = Task.detached { try AutomationIPAArchive.extract(url, supportRoot: support) }
                let app = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                try Task.checkCancellation()
                progress = nil
                select(app, rememberHistory: false)
                let selection = task
                await withTaskCancellationHandler { await selection?.value } onCancel: { selection?.cancel() }
                try Task.checkCancellation()
                if selection?.isCancelled == true { throw CancellationError() }
                if candidate != nil { rememberApplication(url) }
            } catch is CancellationError { message = "App import cancelled." }
            catch { message = errorText(error) }
        }
    }
}
#endif
