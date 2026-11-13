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

    /// Completion buzz for finished actions (imports, saves).
    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
