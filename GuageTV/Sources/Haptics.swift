import UIKit

/// Lightweight haptic feedback, gated by 外观与交互 → 触控反馈
/// (UserDefaults "haptics.enabled", default on).
enum Haptics {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "haptics.enabled") as? Bool ?? true
    }

    /// Small confirmation buzz for taps / tab switches.
    static func tap() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Firmer buzz for primary actions (play, download, confirm).
    static func medium() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Picker-style tick for selections (episode, line, rate).
    static func selection() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Completion buzz for finished actions (imports, saves).
    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Failure buzz for rejected actions.
    static func error() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
