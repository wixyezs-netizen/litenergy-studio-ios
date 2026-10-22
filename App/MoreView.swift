import SwiftUI
import UIKit

struct MoreView: View {
    @EnvironmentObject var state: AppState
    @State private var showPassword = false
    @State private var confirmLogout = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ещё").font(.system(size: 26, weight: .heavy)).textCase(.uppercase).foregroundColor(.white)
                    .padding(.top, 10)

                group {
                    item("Медиатека", "Загрузка и управление видео", "film.stack") { openWeb("videos") }
                    divider
                    item("Терминал и логи", "История заданий и журнал событий", "terminal") { openWeb("logs") }
                }

                group {
                    item("Сменить пароль", "Все остальные устройства выйдут", "key.fill") { showPassword = true }
                    divider
                    item("Открыть в Safari", state.server, "safari") {
                        if let url = URL(string: state.server) { UIApplication.shared.open(url) }
                    }
                }

                group {
                    item("Выйти", "Сервер: \(state.server)", "rectangle.portrait.and.arrow.right", tint: Theme.red) {
                        confirmLogout = true
                    }
                }

                Text("LE Studio \(version)\nLitEnergy Automation Studio")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 8)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background(Theme.bg)
        .sheet(isPresented: $showPassword) { PasswordSheet().environmentObject(state) }
        .alert("Выйти из студии?", isPresented: $confirmLogout) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) { state.logout() }
        }
    }

    private func openWeb(_ tab: String) {
        Haptics.tap()
        state.moreWeb = tab
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 62)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func item(_ title: String, _ subtitle: String, _ icon: String, tint: Color = .white,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 34, height: 34)
                    .background(Theme.pill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(tint)
                    Text(subtitle).font(.system(size: 12.5)).foregroundColor(Theme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PasswordSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Смена пароля").font(.system(size: 22, weight: .heavy)).foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundColor(.white)
                        .frame(width: 34, height: 34).background(Theme.pill).clipShape(Circle())
                }
            }
            .padding(.bottom, 6)
            Text("После смены пароля все остальные устройства выйдут из студии.")
                .font(.system(size: 14)).foregroundColor(Theme.muted)
            SecureField("Текущий пароль", text: $old).textContentType(.password).fieldBox()
            SecureField("Новый пароль (минимум 8 символов)", text: $new1).textContentType(.newPassword).fieldBox()
            SecureField("Повторите новый пароль", text: $new2).textContentType(.newPassword).fieldBox()
            if let error = error {
                Text(error).font(.system(size: 14)).foregroundColor(Theme.red)
            }
            Button(action: save) {
                if busy { ProgressView().tint(.black) } else { Text("Сохранить") }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !busy))
            .disabled(busy)
            .padding(.top, 4)
            Spacer()
        }
        .padding(20)
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard new1 == new2 else { error = "Новые пароли не совпадают"; return }
        guard new1.count >= 8 else { error = "Новый пароль — минимум 8 символов"; return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let r = try await state.call("/api/auth/password", method: "POST",
                                             json: ["old_password": old, "new_password": new1])
                let tok = r.str("token")
                if !tok.isEmpty { state.setToken(tok) }
                Haptics.success()
                state.notice = "Пароль изменён"
                dismiss()
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
