import Foundation

enum SwitcherTextFormatter {
    private static let longDash = " — "

    static func appAndWindowText(appName: String, windowTitle: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if app.isEmpty { return title }
        if title.isEmpty || title == app { return app }
        return app + longDash + title
    }

    static func namedGroupLabel(
        groupName: String,
        appName: String,
        windowTitle: String,
        mode: NamedGroupLabelMode,
        style: SwitcherStyle
    ) -> String {
        let group = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .groupNameOnly:
            return group
        case .groupAppWindow:
            switch style {
            case .appIcons:
                if app.isEmpty { return group }
                return group + longDash + app
            case .titles:
                return group + namedGroupTitleSuffix(appName: app, windowTitle: title)
            }
        }
    }

    static func namedGroupTitleSuffix(appName: String, windowTitle: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if app.isEmpty && title.isEmpty { return "" }
        if app.isEmpty { return longDash + title }
        if title.isEmpty || title == app { return longDash + app }
        return longDash + app + longDash + title
    }
}
