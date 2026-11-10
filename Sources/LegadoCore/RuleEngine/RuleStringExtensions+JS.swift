import Foundation

extension String {
    /// True when a rule begins with a JavaScript step (`<js>` or `@js:`).
    var startsWithJavaScriptRule: Bool {
        let head = trimmingCharacters(in: .whitespacesAndNewlines).prefix(5).lowercased()
        return head.hasPrefix("<js>") || head.hasPrefix("@js:")
    }
}
