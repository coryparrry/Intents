import Foundation

public struct MacIntentTestingError: LocalizedError, Sendable {
    /// Identifies actionable app-selection failures without inspecting localized message text.
    public enum Code: Sendable, Equatable { case notMacApplication, missingActions, unreadableActions, unsupportedActions }
    public let message: String
    public let code: Code?
    /// Retains the explanation presented for a native intent testing failure.
    public init(_ message: String, code: Code? = nil) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}

public struct MacIntentParameter: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var required: Bool
    public var enumIdentifier: String?
    public var enumCases: [String]
    public var entityIdentifier: String?
    /// Describes a discovered parameter, including whether input is required and any declared enum identifiers.
    public init(id: String, name: String, type: String, required: Bool,
                enumIdentifier: String? = nil, enumCases: [String] = [], entityIdentifier: String? = nil) {
        self.id = id; self.name = name; self.type = type; self.required = required
        self.enumIdentifier = enumIdentifier; self.enumCases = enumCases; self.entityIdentifier = entityIdentifier
    }
}

public struct MacIntentAction: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var parameters: [MacIntentParameter]
    public var outputType: String
    /// Describes a discovered action and its parameter/output types; omitted output type is marked unsupported.
    public init(id: String, title: String, parameters: [MacIntentParameter], outputType: String = "unsupported") {
        self.id = id; self.title = title; self.parameters = parameters; self.outputType = outputType
    }
}

public struct MacIntentCatalog: Codable, Sendable {
    public let bundleIdentifier: String
    public let appURL: URL
    public let actions: [MacIntentAction]
    public let productIdentity: MacIntentProductIdentity?
    /// Binds discovered actions to an application URL and optional captured build identity.
    public init(bundleIdentifier: String, appURL: URL, actions: [MacIntentAction], productIdentity: MacIntentProductIdentity? = nil) {
        self.bundleIdentifier = bundleIdentifier; self.appURL = appURL; self.actions = actions
        self.productIdentity = productIdentity
    }
}

public struct MacIntentTestCase: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var actionIdentifier: String
    public var inputsJSON: String
    /// A JSON scalar compared with the returned value. nil checks successful execution only.
    public var expectedValueJSON: String?
    /// Creates an authored case with JSON input text and an optional expected scalar.
    /// Omitting the expected value checks successful execution only.
    public init(id: UUID = UUID(), actionIdentifier: String, inputsJSON: String = "{}", expectedValueJSON: String? = nil) {
        self.id = id; self.actionIdentifier = actionIdentifier; self.inputsJSON = inputsJSON
        self.expectedValueJSON = expectedValueJSON
    }
}

public struct MacIntentRunConfiguration: Sendable {
    public var developerDirectory: URL
    public var signingIdentity: String
    public var teamIdentifier: String
    public var outputDirectory: URL
    public var timeoutSeconds: Double
    public var appLaunchArguments: [String]
    /// Selects Xcode, signing credentials, evidence destination, command timeout, and literal app launch arguments.
    /// The runner validates the environment and accepts timeouts from 1 through 3,600 seconds.
    public init(developerDirectory: URL, signingIdentity: String, teamIdentifier: String, outputDirectory: URL, timeoutSeconds: Double = 600, appLaunchArguments: [String] = []) {
        self.developerDirectory = developerDirectory; self.signingIdentity = signingIdentity
        self.teamIdentifier = teamIdentifier; self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.appLaunchArguments = appLaunchArguments
    }

    /// Bounds literal, nonempty single-line app arguments so the editor can preserve their exact values without a shell.
    public static func validatedAppLaunchArguments(_ arguments: [String]) throws -> [String] {
        guard arguments.count <= 64, arguments.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0 == "\0" || $0.isNewline }) && $0.utf8.count <= 4096 }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw MacIntentTestingError("Use at most 64 app launch arguments, each nonempty and up to 4 KiB, without null characters or line breaks (64 KiB total).")
        }
        return arguments
    }
}

public struct MacIntentRunResult: Sendable {
    public let succeeded: Bool
    public let resultBundleURL: URL?
    public let logURL: URL
    public let summary: String
    public let productIdentity: MacIntentProductIdentity?
    public let cases: [MacIntentTestCase]

    /// Packages the native run verdict with retained evidence paths and optional tested build identity and authored cases.
    public init(succeeded: Bool, resultBundleURL: URL?, logURL: URL, summary: String,
                productIdentity: MacIntentProductIdentity? = nil, cases: [MacIntentTestCase] = []) {
        self.succeeded = succeeded; self.resultBundleURL = resultBundleURL
        self.logURL = logURL; self.summary = summary
        self.productIdentity = productIdentity; self.cases = cases
    }
}
