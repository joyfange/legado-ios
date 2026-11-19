import SwiftUI
import UIKit

enum ThemeEditorFonts {
    static func choices(_ manager: ReadingFontManager) -> [ReadingFontChoice] {
        var seen = Set<String>()
        return (manager.builtInFonts + manager.importedFonts.flatMap(\.faces))
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
    static func isAvailable(_ name: String, manager: ReadingFontManager) -> Bool {
        name.isEmpty || (choices(manager).contains { $0.id == name } && UIFont(name: name, size: 17) != nil)
    }
    static func name(_ selection: String?, manager: ReadingFontManager) -> String {
        guard let selection else { return "跟随全局字体" }
        if selection.isEmpty { return "系统默认" }
        guard let choice = choices(manager).first(where: { $0.id == selection }) else {
            return "字体不可用 · 系统默认"
        }
        return isAvailable(selection, manager: manager) ? choice.name : "\(choice.name) · 不可用"
    }
    static func resolved(_ selection: String?, manager: ReadingFontManager) -> String {
        let name = selection ?? manager.selectedPostScriptName
        return isAvailable(name, manager: manager) ? name : ""
    }
}
