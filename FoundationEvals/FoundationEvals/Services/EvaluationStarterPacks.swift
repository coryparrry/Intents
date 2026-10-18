import Foundation

enum EvaluationStarterPack: String, CaseIterable, Identifiable, Sendable {
    case structuredExtraction
    case groundedAnswers
    case conversationBehaviour

    var id: Self { self }

    var title: String {
        switch self {
        case .structuredExtraction: "Structured extraction"
        case .groundedAnswers: "Grounded answers"
        case .conversationBehaviour: "Conversation behaviour"
        }
    }

    var detail: String {
        switch self {
        case .structuredExtraction:
            "Deterministic field checks for a small receipt. It proves schema shape and selected values, not OCR quality or every accounting rule."
        case .groundedAnswers:
            "Semantic checks against short verified references. It catches unsupported claims, but a human still approves references and baselines."
        case .conversationBehaviour:
            "Multi-turn instruction retention and correction cases. It does not simulate long production histories or tool side effects."
        }
    }

    func makeSuite() -> EvaluationSuite {
        switch self {
        case .structuredExtraction: structuredExtractionSuite()
        case .groundedAnswers: groundedAnswersSuite()
        case .conversationBehaviour: conversationSuite()
        }
    }

    private func structuredExtractionSuite() -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.name = "Receipt extraction"
        suite.instructions = "Extract only facts present in the receipt text. Return a JSON object without commentary."
        suite.criteria = "The response satisfies every configured deterministic JSON field check."
        suite.scoringMode = .review
        suite.features.outputFields = [
            .init(name: "merchant", description: "Merchant printed on the receipt"),
            .init(name: "date", description: "Printed ISO date"),
            .init(name: "subtotal", description: "Printed subtotal before discounts", type: .number, isOptional: true),
            .init(name: "discount", description: "Printed discount amount", type: .number, isOptional: true),
            .init(name: "total", description: "Final numeric total", type: .number),
            .init(name: "currency", description: "ISO currency code"),
            .init(name: "vat", description: "Printed VAT amount", type: .number, isOptional: true)
        ]
        suite.cases = [
            EvaluationCase(
                name: "VAT receipt",
                prompt: "Receipt: North Street Cafe; date 2026-09-10; coffee £3.20; sandwich £6.80; total £10.00; VAT £1.67. Extract merchant, date, total, currency, and vat.",
                expected: #"{"merchant":"North Street Cafe","date":"2026-09-10","total":10,"currency":"GBP","vat":1.67}"#,
                fieldAssertions: [
                    .init(pointer: "/merchant", operation: .equals, expectedValue: #""North Street Cafe""#),
                    .init(pointer: "/date", operation: .equals, expectedValue: #""2026-09-10""#),
                    .init(pointer: "/total", operation: .equals, expectedValue: "10"),
                    .init(pointer: "/currency", operation: .equals, expectedValue: #""GBP""#),
                    .init(pointer: "/vat", operation: .equals, expectedValue: "1.67")
                ]
            ),
            EvaluationCase(
                name: "Missing tax",
                prompt: "Receipt: Green Grocer; date 2026-09-11; apples £2.40; total £2.40. Tax is not shown. Extract merchant, date, total, currency, and include tax only if printed.",
                expected: #"{"merchant":"Green Grocer","date":"2026-09-11","total":2.4,"currency":"GBP"}"#,
                fieldAssertions: [
                    .init(pointer: "/merchant", operation: .equals, expectedValue: #""Green Grocer""#),
                    .init(pointer: "/total", operation: .equals, expectedValue: "2.4"),
                    .init(pointer: "/currency", operation: .equals, expectedValue: #""GBP""#)
                ]
            ),
            EvaluationCase(
                name: "Discounted total",
                prompt: "Receipt: Field Books; date 2026-09-12; notebook £8.00; discount £2.00; total £6.00. Extract merchant, date, subtotal, discount, total, and currency.",
                expected: #"{"merchant":"Field Books","date":"2026-09-12","subtotal":8,"discount":2,"total":6,"currency":"GBP"}"#,
                fieldAssertions: [
                    .init(pointer: "/merchant", operation: .equals, expectedValue: #""Field Books""#),
                    .init(pointer: "/subtotal", operation: .equals, expectedValue: "8"),
                    .init(pointer: "/discount", operation: .equals, expectedValue: "2"),
                    .init(pointer: "/total", operation: .equals, expectedValue: "6")
                ]
            )
        ]
        return suite
    }

    private func groundedAnswersSuite() -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.name = "Grounded product answers"
        suite.instructions = """
        Answer only from the verified reference below. If the reference does not contain an answer, say that it is not specified.

        Verified product reference:
        - A saved run can be exported as a JSON report from its detail view.
        - A passing local build proves compilation in the environment where it ran. App Store approval is a separate external review outcome.
        """
        suite.criteria = """
        Every material claim is supported by the verified reference.
        The response directly answers the question and includes the decisive fact.
        The response clearly says when the reference does not specify the answer.
        """
        suite.scoringMode = .modelJudge
        suite.cases = [
            EvaluationCase(
                name: "Supported policy",
                prompt: "Can I export a run as JSON?",
                expected: "Yes. A saved run can be exported as a JSON report from its detail view."
            ),
            EvaluationCase(
                name: "Unknown policy",
                prompt: "How long are cloud provider logs retained?",
                expected: "The supplied product reference does not specify a cloud-provider log-retention period."
            ),
            EvaluationCase(
                name: "Scope boundary",
                prompt: "Does a passing local build prove App Store approval?",
                expected: "No. A local build proves compilation in that environment; App Store approval is a separate external review outcome."
            )
        ]
        return suite
    }

    private func conversationSuite() -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.name = "Conversation behaviour"
        suite.instructions = "Follow the user's latest explicit preference while retaining compatible facts from earlier turns."
        suite.criteria = """
        The final response follows the latest explicit user preference.
        The response retains compatible facts established in setup turns.
        The response does not mention superseded preferences as if they were current.
        """
        suite.scoringMode = .modelJudge
        var setup = EvaluationConversationConfiguration()
        setup.setupTurns = [
            EvaluationSetupTurn(prompt: "I am planning a two-day visit to Edinburgh and prefer indoor activities."),
            EvaluationSetupTurn(prompt: "I especially enjoy modern art and quiet cafes.")
        ]
        suite.cases = [
            EvaluationCase(
                name: "Latest preference wins",
                prompt: "Plans changed: include one outdoor viewpoint if it is near the centre. Suggest a concise afternoon plan.",
                expected: "A good plan pairs a central modern-art visit and quiet cafe with one nearby outdoor viewpoint, such as Calton Hill, while keeping the itinerary suitable for one afternoon.",
                conversation: setup
            ),
            EvaluationCase(
                name: "Correction replaces old value",
                prompt: "Correction: the meeting is on Friday, not Thursday. Summarize the date in one sentence.",
                expected: "The meeting is on Friday.",
                conversation: EvaluationConversationConfiguration(setupTurns: [
                    EvaluationSetupTurn(prompt: "The project meeting is scheduled for Thursday.")
                ])
            ),
            EvaluationCase(
                name: "Retain compatible constraint",
                prompt: "Now make it vegetarian as well. Restate my lunch request.",
                expected: "The lunch should be nut-free, vegetarian, and ready in under 20 minutes.",
                conversation: EvaluationConversationConfiguration(setupTurns: [
                    EvaluationSetupTurn(prompt: "I need a nut-free lunch that is ready in under 20 minutes.")
                ])
            )
        ]
        return suite
    }
}
