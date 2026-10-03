import SwiftUI

/// Render recorded JSON as fields; preserve the full raw evidence alongside it.
struct ReviewOutputView: View {
    let text: String
    private var fields: [ReviewJSONField]? { ReviewJSONField.fields(text: text) }
    var body: some View {
        if let fields {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Text(field.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(field.value).font(.callout).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("Recorded JSON") { Text(text).font(.caption.monospaced()).textSelection(.enabled) }
            }.padding(10).workspaceInset()
        } else {
            Text(text.isEmpty ? "No output was captured." : text).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).workspaceInset()
        }
    }
}

struct ReviewJSONField: Identifiable {
    var path: String
    var value: String
    var id: String { path }
    static func fields(text: String) -> [Self]? {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data),
              root is [String: Any] || root is [Any] else { return nil }
        var result: [Self] = []
        func visit(_ value: Any, path: String, depth: Int) {
            guard result.count < 100 else { return }
            if depth < 8, let object = value as? [String: Any], !object.isEmpty {
                for key in object.keys.sorted() {
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    visit(object[key]!, path: path + "/" + escaped, depth: depth + 1)
                }
            } else if depth < 8, let array = value as? [Any], !array.isEmpty {
                for (index, item) in array.enumerated() { visit(item, path: path + "/\(index)", depth: depth + 1) }
            } else {
                let label: String
                if let string = value as? String { label = string }
                else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                        let encoded = String(data: data, encoding: .utf8) { label = encoded }
                else { label = String(describing: value) }
                result.append(.init(path: path.isEmpty ? "/" : path, value: label))
            }
        }
        visit(root, path: "", depth: 0)
        if result.count == 100 { result.append(.init(path: "…", value: "Field preview limited to 100 values. Full JSON is available below.")) }
        return result
    }
}
