import SwiftUI

// Identifiable conformance for tab pickers; `LibraryTab.key` (the tabIcons
// dictionary key) is owned by the model layer.
extension LibraryTab: Identifiable {
    var id: Int { rawValue }
}
