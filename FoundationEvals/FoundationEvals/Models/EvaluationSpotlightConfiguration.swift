import Foundation

struct EvaluationSpotlightSearchConfiguration: Codable, Equatable, Sendable {
    static let maximumResultCount = 50
    static let maximumFetchAttributes = 16
    static let maximumAttributeNameCharacters = 256
    static let maximumIdentityValuesPerKind = 8
    static let maximumIdentityValueCharacters = 256
    static let minimumResponseSize = 256
    static let maximumAllowedResponseSize = 4_096

    var enabled: Bool
    var fileSource: EvaluationSpotlightFileSourceConfiguration
    var coreSpotlightSource: EvaluationCoreSpotlightSourceConfiguration
    var guidance: EvaluationSpotlightGuidanceConfiguration
    var contactIdentity: EvaluationSpotlightContactIdentityConfiguration
    var pipeline: EvaluationSpotlightPipelineConfiguration
    var maximumResponseSize: Int

    init(
        enabled: Bool = false,
        fileSource: EvaluationSpotlightFileSourceConfiguration = .init(),
        coreSpotlightSource: EvaluationCoreSpotlightSourceConfiguration = .init(),
        guidance: EvaluationSpotlightGuidanceConfiguration = .init(),
        contactIdentity: EvaluationSpotlightContactIdentityConfiguration = .init(),
        pipeline: EvaluationSpotlightPipelineConfiguration = .init(),
        maximumResponseSize: Int = 1_024
    ) {
        self.enabled = enabled
        self.fileSource = fileSource
        self.coreSpotlightSource = coreSpotlightSource
        self.guidance = guidance
        self.contactIdentity = contactIdentity
        self.pipeline = pipeline
        self.maximumResponseSize = maximumResponseSize
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case fileSource
        case coreSpotlightSource
        case guidance
        case contactIdentity
        case pipeline
        case maximumResponseSize
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        fileSource = try container.decode(
            EvaluationSpotlightFileSourceConfiguration.self,
            forKey: .fileSource
        )
        coreSpotlightSource = try container.decode(
            EvaluationCoreSpotlightSourceConfiguration.self,
            forKey: .coreSpotlightSource
        )
        guidance = try container.decode(
            EvaluationSpotlightGuidanceConfiguration.self,
            forKey: .guidance
        )
        contactIdentity = try container.decodeIfPresent(
            EvaluationSpotlightContactIdentityConfiguration.self,
            forKey: .contactIdentity
        ) ?? .init()
        pipeline = try container.decodeIfPresent(
            EvaluationSpotlightPipelineConfiguration.self,
            forKey: .pipeline
        ) ?? .init()
        maximumResponseSize = try container.decode(Int.self, forKey: .maximumResponseSize)
    }

    var validationIssue: String? {
        guard enabled else { return nil }

        guard fileSource.enabled || coreSpotlightSource.enabled else {
            return "Spotlight search needs at least one source."
        }
        guard (Self.minimumResponseSize...Self.maximumAllowedResponseSize).contains(maximumResponseSize) else {
            return "Spotlight's maximum response size must be between \(Self.minimumResponseSize) and \(Self.maximumAllowedResponseSize)."
        }

        if fileSource.enabled {
            let trimmedPath = fileSource.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.hasPrefix("/") else {
                return "Choose one local folder for Spotlight file search."
            }
            let folderURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard !Self.isDisallowedFileScope(folderURL) else {
                return "Spotlight file search cannot use a broad system or user directory. Choose a narrower folder."
            }
            if let issue = fileSource.validationIssue {
                return issue
            }
        }

        if coreSpotlightSource.enabled, let issue = coreSpotlightSource.validationIssue {
            return issue
        }
        if let issue = guidance.validationIssue {
            return issue
        }
        if let issue = contactIdentity.validationIssue {
            return issue
        }
        return pipeline.validationIssue
    }

    /// Apple documents its native response-size limit without stating the units.
    /// Admission therefore relies only on the exact post-call token limit for every allowed call.
    func conservativeContextTokenReserve(maximumCalls: Int) -> Int {
        guard enabled else { return 0 }
        return EvaluationCustomTool.maximumOutputTokens
            * min(maximumCalls, EvaluationCustomToolRecorder.maximumCallsPerSample)
    }

    static func isDisallowedFileScope(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let broadPaths = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/Users",
            "/Volumes",
            FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path,
            FileManager.default.temporaryDirectory
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        ]
        return broadPaths.contains(path)
    }
}

struct EvaluationSpotlightContactIdentityConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var displayName: String
    var alternateNames: [String]
    var emailAddresses: [String]
    var phoneNumbers: [String]

    init(
        enabled: Bool = false,
        displayName: String = "",
        alternateNames: [String] = [],
        emailAddresses: [String] = [],
        phoneNumbers: [String] = []
    ) {
        self.enabled = enabled
        self.displayName = displayName
        self.alternateNames = alternateNames
        self.emailAddresses = emailAddresses
        self.phoneNumbers = phoneNumbers
    }

    var validationIssue: String? {
        guard enabled else { return nil }
        guard Self.isValidValue(displayName) else {
            return "The Spotlight contact identity needs a display name of 256 characters or fewer."
        }
        for (label, values) in [
            ("alternate names", alternateNames),
            ("email addresses", emailAddresses),
            ("phone numbers", phoneNumbers)
        ] {
            guard values.count <= EvaluationSpotlightSearchConfiguration.maximumIdentityValuesPerKind else {
                return "The Spotlight contact identity can contain at most 8 \(label)."
            }
            guard values.allSatisfy(Self.isValidValue) else {
                return "Spotlight contact \(label) must be nonempty, contain no control characters, and be 256 characters or fewer."
            }
        }
        return nil
    }

    var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalized(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isValidValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= EvaluationSpotlightSearchConfiguration.maximumIdentityValueCharacters
            && trimmed.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

struct EvaluationSpotlightPipelineConfiguration: Codable, Equatable, Sendable {
    var deduplicateItems: Bool

    init(deduplicateItems: Bool = false) {
        self.deduplicateItems = deduplicateItems
    }

    var validationIssue: String? { nil }
}

struct EvaluationSpotlightFileSourceConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var folderPath: String
    var maximumResults: Int
    var fetchedAttributes: EvaluationSpotlightAttributeSelection

    init(
        enabled: Bool = true,
        folderPath: String = "",
        maximumResults: Int = 8,
        fetchedAttributes: EvaluationSpotlightAttributeSelection = .init(
            presets: [.title, .contentDescription, .contentType, .contentModificationDate]
        )
    ) {
        self.enabled = enabled
        self.folderPath = folderPath
        self.maximumResults = maximumResults
        self.fetchedAttributes = fetchedAttributes
    }

    var validationIssue: String? {
        guard (1...EvaluationSpotlightSearchConfiguration.maximumResultCount).contains(maximumResults) else {
            return "Spotlight file results must be between 1 and \(EvaluationSpotlightSearchConfiguration.maximumResultCount)."
        }
        return fetchedAttributes.validationIssue(context: "Spotlight file source")
    }
}

struct EvaluationCoreSpotlightSourceConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var maximumResults: Int
    var fetchedAttributes: EvaluationSpotlightAttributeSelection
    var allowMail: Bool

    init(
        enabled: Bool = false,
        maximumResults: Int = 8,
        fetchedAttributes: EvaluationSpotlightAttributeSelection = .init(
            presets: [.title, .contentDescription, .contentType]
        ),
        allowMail: Bool = false
    ) {
        self.enabled = enabled
        self.maximumResults = maximumResults
        self.fetchedAttributes = fetchedAttributes
        self.allowMail = allowMail
    }

    var validationIssue: String? {
        guard (1...EvaluationSpotlightSearchConfiguration.maximumResultCount).contains(maximumResults) else {
            return "Core Spotlight results must be between 1 and \(EvaluationSpotlightSearchConfiguration.maximumResultCount)."
        }
        return fetchedAttributes.validationIssue(context: "Core Spotlight source")
    }
}

struct EvaluationSpotlightAttributeSelection: Codable, Equatable, Sendable {
    var presets: [EvaluationSpotlightAttributePreset]
    var customAttributeNames: [String]

    init(
        presets: [EvaluationSpotlightAttributePreset] = [],
        customAttributeNames: [String] = []
    ) {
        self.presets = presets
        self.customAttributeNames = customAttributeNames
    }

    var count: Int { presets.count + customAttributeNames.count }

    func validationIssue(context: String) -> String? {
        guard count <= EvaluationSpotlightSearchConfiguration.maximumFetchAttributes else {
            return "\(context) can fetch at most \(EvaluationSpotlightSearchConfiguration.maximumFetchAttributes) attributes."
        }
        guard Set(presets).count == presets.count else {
            return "\(context) contains duplicate preset attributes."
        }

        let trimmedCustomNames = customAttributeNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmedCustomNames.allSatisfy({ !$0.isEmpty }) else {
            return "\(context) custom attribute names cannot be empty."
        }
        guard trimmedCustomNames.allSatisfy({
            $0.count <= EvaluationSpotlightSearchConfiguration.maximumAttributeNameCharacters
        }) else {
            return "\(context) custom attribute names must be \(EvaluationSpotlightSearchConfiguration.maximumAttributeNameCharacters) characters or fewer."
        }
        guard trimmedCustomNames.allSatisfy({ name in
            name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }) else {
            return "\(context) custom attribute names cannot contain control characters."
        }
        guard Set(trimmedCustomNames).count == trimmedCustomNames.count else {
            return "\(context) contains duplicate custom attributes."
        }
        return nil
    }
}

enum EvaluationSpotlightAttributePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case identifier
    case displayName
    case title
    case subject
    case contentDescription
    case textContent
    case keywords
    case contentType
    case path
    case contentURL
    case authorNames
    case recipientNames
    case creator
    case contentCreationDate
    case contentModificationDate
    case addedDate
    case lastUsedDate
    case fileSize
    case pageCount
    case duration

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .identifier: "Identifier"
        case .displayName: "Display name"
        case .title: "Title"
        case .subject: "Subject"
        case .contentDescription: "Description"
        case .textContent: "Text content"
        case .keywords: "Keywords"
        case .contentType: "Content type"
        case .path: "Path"
        case .contentURL: "Content URL"
        case .authorNames: "Author names"
        case .recipientNames: "Recipient names"
        case .creator: "Creator"
        case .contentCreationDate: "Created date"
        case .contentModificationDate: "Modified date"
        case .addedDate: "Added date"
        case .lastUsedDate: "Last used date"
        case .fileSize: "File size"
        case .pageCount: "Page count"
        case .duration: "Duration"
        }
    }
}

struct EvaluationSpotlightGuidanceConfiguration: Codable, Equatable, Sendable {
    var mode: EvaluationSpotlightGuidanceMode
    var focusedDomain: EvaluationSpotlightContentDomain
    var dynamicProfile: EvaluationSpotlightDynamicGuidanceProfile
    var outputFormat: EvaluationSpotlightOutputFormat

    init(
        mode: EvaluationSpotlightGuidanceMode = .focused,
        focusedDomain: EvaluationSpotlightContentDomain = .documents,
        dynamicProfile: EvaluationSpotlightDynamicGuidanceProfile = .init(),
        outputFormat: EvaluationSpotlightOutputFormat = .compact
    ) {
        self.mode = mode
        self.focusedDomain = focusedDomain
        self.dynamicProfile = dynamicProfile
        self.outputFormat = outputFormat
    }

    var validationIssue: String? {
        guard mode == .dynamic else { return nil }
        return dynamicProfile.validationIssue
    }
}

enum EvaluationSpotlightGuidanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case complete
    case focused
    case dynamic

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .complete: "Complete"
        case .focused: "Focused"
        case .dynamic: "Dynamic"
        }
    }
}

enum EvaluationSpotlightContentDomain: String, Codable, CaseIterable, Identifiable, Sendable {
    case items
    case documents
    case communications
    case calendar
    case audio
    case visualMedia

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .items: "Items"
        case .documents: "Documents"
        case .communications: "Communications"
        case .calendar: "Calendar"
        case .audio: "Audio"
        case .visualMedia: "Visual media"
        }
    }
}

enum EvaluationSpotlightOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case structured
    case compact

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .structured: "Structured"
        case .compact: "Compact"
        }
    }
}

enum EvaluationSpotlightGuidanceOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case unused
    case allowed
    case disallowed

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .unused: "Not used"
        case .allowed: "Allow"
        case .disallowed: "Disallow"
        }
    }

    var value: Bool? {
        switch self {
        case .unused: nil
        case .allowed: true
        case .disallowed: false
        }
    }
}

struct EvaluationSpotlightDynamicGuidanceProfile: Codable, Equatable, Sendable {
    var textMatch: EvaluationSpotlightGuidanceOption
    var similarityMatch: EvaluationSpotlightGuidanceOption
    var numericMatch: EvaluationSpotlightGuidanceOption
    var dates: EvaluationSpotlightGuidanceOption
    var people: EvaluationSpotlightGuidanceOption
    var contentType: EvaluationSpotlightGuidanceOption
    var attributes: EvaluationSpotlightAttributeSelection

    init(
        textMatch: EvaluationSpotlightGuidanceOption = .allowed,
        similarityMatch: EvaluationSpotlightGuidanceOption = .unused,
        numericMatch: EvaluationSpotlightGuidanceOption = .unused,
        dates: EvaluationSpotlightGuidanceOption = .unused,
        people: EvaluationSpotlightGuidanceOption = .unused,
        contentType: EvaluationSpotlightGuidanceOption = .unused,
        attributes: EvaluationSpotlightAttributeSelection = .init()
    ) {
        self.textMatch = textMatch
        self.similarityMatch = similarityMatch
        self.numericMatch = numericMatch
        self.dates = dates
        self.people = people
        self.contentType = contentType
        self.attributes = attributes
    }

    var validationIssue: String? {
        attributes.validationIssue(context: "Dynamic Spotlight guidance")
    }
}
