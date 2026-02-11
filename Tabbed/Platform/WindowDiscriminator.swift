import ApplicationServices
import Foundation

enum WindowDiscriminator {

    enum QualificationProfile {
        case windowDiscovery
        case autoJoin
    }

    /// Determines whether a window should be shown in the switcher.
    ///
    /// Applies universal filters first (valid ID, minimum size), then checks
    /// app-specific overrides, falling back to the default subrole check.
    static func isActualWindow(
        cgWindowID: CGWindowID,
        subrole: String?,
        role: String?,
        title: String?,
        size: CGSize?,
        level: Int?,
        bundleIdentifier: String?,
        localizedName: String?,
        executableURL: URL?,
        qualification: QualificationProfile = .windowDiscovery
    ) -> Bool {
        // Universal: must have valid window ID
        guard cgWindowID != 0 else { return false }

        // Universal: minimum size 100x50
        if let size = size {
            guard size.width > 100 && size.height > 50 else { return false }
        }

        // App-specific overrides (by bundle ID)
        if let bundleID = bundleIdentifier, !bundleID.isEmpty {
            return evaluateBundledApp(
                bundleID: bundleID,
                subrole: subrole,
                role: role,
                title: title,
                size: size,
                qualification: qualification
            )
        }

        // No-bundle apps (CrossOver/Wine, scrcpy, Android Emulator)
        let name = localizedName ?? ""
        let path = executableURL?.path ?? ""

        if name == "wine64-preloader" || path.contains("/winetemp-") {
            return role == "AXWindow" && subrole == "AXUnknown" && level == 0
        }

        if name == "scrcpy" {
            return subrole == "AXStandardWindow"
        }

        if path.contains("qemu-system") {
            if qualification == .autoJoin {
                return role == "AXWindow" &&
                    !isUtilitySubroleForAutoJoin(subrole) &&
                    title?.isEmpty == false
            }
            return title?.isEmpty == false
        }

        return defaultDecision(subrole: subrole, role: role, qualification: qualification)
    }

    // MARK: - Private

    private static let acceptAllBundleIDs: Set<String> = [
        "com.apple.iBooksX",
        "com.apple.iWork.Keynote",
        "com.colliderli.iina",
        "com.image-line.flstudio",
        "org.oe-f.OpenBoard",
        "SanGuoShaAirWD",
        "com.goland.dvdfab.macos",
        "com.ssworks.drbetotte",
    ]

    private static func evaluateBundledApp(
        bundleID: String,
        subrole: String?,
        role: String?,
        title: String?,
        size: CGSize?,
        qualification: QualificationProfile
    ) -> Bool {
        // Accept-all apps (subrole glitches, non-standard windowing, etc.)
        if acceptAllBundleIDs.contains(bundleID) {
            if qualification == .windowDiscovery { return true }
            return strictAcceptAllFallback(subrole: subrole, role: role, title: title, size: size)
        }

        // Adobe: accept floating tool palettes
        if bundleID == "com.adobe.Audition" || bundleID == "com.adobe.AfterEffects" {
            if qualification == .autoJoin {
                return isStrictPrimaryWindow(subrole: subrole, role: role)
            }
            return subrole == "AXStandardWindow" || subrole == "AXDialog" || subrole == "AXFloatingWindow"
        }

        // Steam: all windows are AXUnknown; dropdowns have empty title or nil role
        if bundleID == "com.valvesoftware.steam" {
            if qualification == .autoJoin {
                return role == "AXWindow" &&
                    !isUtilitySubroleForAutoJoin(subrole) &&
                    title?.isEmpty == false
            }
            return title?.isEmpty == false && role != nil
        }

        // World of Warcraft: non-standard subrole
        if bundleID == "com.blizzard.worldofwarcraft" {
            return role == "AXWindow"
        }

        // Battle.net: AXUnknown subrole but proper AXWindow role
        if bundleID == "net.battle.bootstrapper" {
            return role == "AXWindow"
        }

        // Fusion 360: side panels have empty titles
        if bundleID == "com.autodesk.fusion360" {
            if qualification == .autoJoin {
                return title?.isEmpty == false &&
                    isStrictPrimaryWindow(subrole: subrole, role: role)
            }
            return title?.isEmpty == false && (subrole == "AXStandardWindow" || subrole == "AXDialog")
        }

        // ColorSlurp: exclude color picker popups
        if bundleID == "com.IdeaPunch.ColorSlurp" {
            return subrole == "AXStandardWindow"
        }

        // Firefox: fullscreen video = AXUnknown + large; tooltips = AXUnknown + small
        if bundleID.hasPrefix("org.mozilla.firefox") {
            if qualification == .autoJoin {
                guard isStrictPrimaryWindow(subrole: subrole, role: role),
                      let size else { return false }
                // Extension/tool popups are often much smaller than browser windows.
                return size.width >= 700 && size.height >= 450
            }
            return role == "AXWindow" && (size?.height ?? 0) > 400
        }

        // VLC: non-native fullscreen uses AXUnknown subrole
        if bundleID.hasPrefix("org.videolan.vlc") {
            return role == "AXWindow"
        }

        // AutoCAD: uses AXDocumentWindow for documents
        if bundleID.hasPrefix("com.autodesk.AutoCAD") {
            if qualification == .autoJoin {
                return isStrictPrimaryWindow(subrole: subrole, role: role)
            }
            return subrole == "AXStandardWindow" || subrole == "AXDialog" || subrole == "AXDocumentWindow"
        }

        // JetBrains IDEs / Android Studio: filter splash screens and tool windows
        if bundleID.hasPrefix("com.jetbrains.") || bundleID.hasPrefix("com.google.android.studio") {
            if qualification == .autoJoin {
                if isStrictPrimaryWindow(subrole: subrole, role: role) { return true }
                if let title = title, !title.isEmpty,
                   role == "AXWindow",
                   !isUtilitySubroleForAutoJoin(subrole),
                   let size = size {
                    return size.width >= 700 && size.height >= 400
                }
                return false
            }
            if subrole == "AXStandardWindow" || subrole == "AXDialog" { return true }
            if let title = title, !title.isEmpty {
                if let size = size {
                    return size.width >= 100 && size.height >= 100
                }
                return true
            }
            return false
        }

        return defaultDecision(subrole: subrole, role: role, qualification: qualification)
    }

    private static let autoJoinUtilitySubroles: Set<String> = [
        "AXDialog",
        "AXSystemDialog",
        "AXFloatingWindow",
        "AXSheet",
        "AXPopover",
    ]

    private static func isUtilitySubroleForAutoJoin(_ subrole: String?) -> Bool {
        guard let subrole else { return false }
        return autoJoinUtilitySubroles.contains(subrole)
    }

    private static func isStrictPrimaryWindow(subrole: String?, role: String?) -> Bool {
        guard subrole == "AXStandardWindow" || subrole == "AXDocumentWindow" else { return false }
        if let role, role != "AXWindow" { return false }
        return true
    }

    private static func strictAcceptAllFallback(
        subrole: String?,
        role: String?,
        title: String?,
        size: CGSize?
    ) -> Bool {
        if isStrictPrimaryWindow(subrole: subrole, role: role) {
            return true
        }

        guard role == "AXWindow",
              !isUtilitySubroleForAutoJoin(subrole),
              let title, !title.isEmpty,
              let size else {
            return false
        }
        return size.width >= 500 && size.height >= 300
    }

    private static func defaultDecision(
        subrole: String?,
        role: String?,
        qualification: QualificationProfile
    ) -> Bool {
        switch qualification {
        case .windowDiscovery:
            return subrole == "AXStandardWindow" || subrole == "AXDialog"
        case .autoJoin:
            return isStrictPrimaryWindow(subrole: subrole, role: role)
        }
    }
}
