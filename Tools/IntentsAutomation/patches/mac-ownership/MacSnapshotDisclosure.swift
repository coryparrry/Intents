import Foundation

enum MacSnapshotDisclosure {
  static func content(suppressed: Bool, read: () -> String?) -> String? {
    suppressed ? nil : read()
  }
  static func requireSafeGraph(restrictedRevisit: Bool, truncated: Bool = false) throws {
    guard !restrictedRevisit, !truncated else { throw HelperError.commandFailed("snapshot protected ancestry is incomplete or conflicting") }
  }
  // Unknown text-input subroles are conservative: do not read their value. This
  // classification runs before AX value retrieval and before helper JSON/logs.
  static func suppressContent(role: String?, subrole: String?, inherited: Bool) -> Bool {
    if inherited || subrole == "AXSecureTextField" { return true }
    if role == "AXTextField" || role == "AXTextArea" {
      return subrole != "AXSearchField"
    }
    return false
  }
}
