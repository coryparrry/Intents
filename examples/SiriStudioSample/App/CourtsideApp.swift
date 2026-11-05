import AppIntents
import SwiftUI

/// A synthetic roster app for testing Siri without accessing real team data.
@main
struct CourtsideApp: App {
    var body: some Scene {
        WindowGroup { Text("Courtside • Synthetic roster").padding() }
    }
}

/// Teams are enumerable without depending on a Spotlight index.
struct TeamEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Team"
    static let defaultQuery = TeamQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

/// Provides the small fixed list of synthetic teams.
struct TeamQuery: EnumerableEntityQuery {
    /// Returns the complete fixture catalog for Siri's entity resolution.
    func allEntities() async throws -> [TeamEntity] {
        [.init(id: "tigers", name: "Tigers"), .init(id: "owls", name: "Owls")]
    }

    /// Resolves persisted team identifiers against the fixture catalog.
    func entities(for identifiers: [String]) async throws -> [TeamEntity] {
        let teams = try await allEntities()
        return identifiers.compactMap { id in teams.first { $0.id == id } }
    }
}

/// The supported basketball positions in the fixture.
enum Position: String, AppEnum {
    case pointGuard, center
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Position"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.pointGuard: "Point Guard", .center: "Center"]
}

/// Keeps all synthetic state in the development app's process.
actor Roster {
    static let shared = Roster()
    private var players: [String: String] = [:]

    /// Adds or replaces a synthetic player.
    func add(_ name: String, description: String) { players[name] = description }

    /// Removes a synthetic player by name.
    func delete(_ name: String) { players.removeValue(forKey: name) }

    /// Clears the fixture so repeats start from the same state.
    func reset() { players.removeAll() }
}

/// Adds a player only when the team, position, and jersey number are supplied.
@AppIntent(.tool)
struct AddPlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Player"
    static let description = IntentDescription("Add a new player to a basketball team roster in Courtside.")
    @Parameter(title: "Player Name", description: "The name of the player to add.") var name: String
    @Parameter(title: "Team", description: "The basketball team receiving the player.") var team: TeamEntity
    @Parameter(title: "Position", description: "The basketball position the player plays.") var position: Position
    @Parameter(title: "Jersey Number", description: "The required integer jersey number.") var number: Int

    /// Adds the player and returns their display label.
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let label = "\(name) (\(team.name) #\(number))"
        await Roster.shared.add(name, description: label)
        return .result(value: label, dialog: "Added \(name) to the \(team.name).")
    }
}

/// Retrieves the selected team's name for the scripted follow-up action.
@AppIntent(.tool)
struct OpenTeamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Team"
    static let description = IntentDescription("Open the requested basketball team's roster in Courtside.")
    @Parameter(title: "Team", description: "The team whose roster to open.") var team: TeamEntity

    /// Returns the selected roster label in the synthetic app.
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        .result(value: team.name, dialog: "Opened the \(team.name) roster.")
    }
}

/// Deletes a synthetic player; this is the fixture's forbidden action.
@AppIntent(.tool)
struct DeletePlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Player"
    static let description = IntentDescription("Remove an existing player from the Courtside roster.")
    @Parameter(title: "Player Name", description: "The name of the player to remove.") var player: String

    /// Removes only the named synthetic record.
    func perform() async throws -> some IntentResult {
        await Roster.shared.delete(player)
        return .result()
    }
}

/// Exposes reset to the direct test setup without registering it as a Siri tool.
struct ResetDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Fixture Data"
    static let description = IntentDescription("Clear the synthetic Courtside roster between test repeats.")

    /// Returns the fixture to its initial state.
    func perform() async throws -> some IntentResult {
        await Roster.shared.reset()
        return .result()
    }
}
