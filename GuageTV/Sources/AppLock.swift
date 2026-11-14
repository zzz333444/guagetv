import LocalAuthentication
import SwiftUI

/// App lock (v1.41): when enabled, the app locks on launch and
/// whenever it goes to the background; device-owner auth
/// (Face ID / passcode) unlocks. If the device has no auth set
/// up at all, the lock waves through — locking the user out of
/// their own app would be the worse failure.
enum AppLock {
    static func authenticate(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "解锁呱壳") { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            }
        } else {
            completion(true)
        }
    }
}

struct AppLockView: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
                Text("呱壳已锁定")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Button {
                    AppLock.authenticate { if $0 { onUnlock() } }
                } label: {
                    Text("点按解锁")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            AppLock.authenticate { if $0 { onUnlock() } }
        }
    }
}

struct SecuritySettingsView: View {
    @AppStorage("appLock.enabled") private var appLockEnabled = false

    var body: some View {
        SettingsPage(title: "安全") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("App 锁").font(.headline).foregroundStyle(Theme.text)
                    Toggle("打开呱壳时需要面容 ID / 密码", isOn: $appLockEnabled)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("开启后：冷启动、从后台切回来都要先解锁。设备没设任何锁屏密码时自动放行。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}
