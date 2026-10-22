import SwiftUI
import UIKit

@main
struct StudioApp: App {
    @StateObject private var state = AppState()

    init() {
        UISegmentedControl.appearance().selectedSegmentTintColor = .white
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        UISegmentedControl.appearance().backgroundColor = UIColor(white: 0.133, alpha: 1)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .onAppear {
                    WebStore.shared.app = state
                    if state.isLoggedIn { WebStore.shared.attach(server: state.server, token: state.token) }
                    // launch arguments used by the CI screenshot job: -ui_password <pw> -ui_tab <tab>
                    let d = UserDefaults.standard
                    if let t = d.string(forKey: "ui_tab"), let tab = DockTab(rawValue: t) { state.tab = tab }
                    if !state.isLoggedIn, let pw = d.string(forKey: "ui_password"), !pw.isEmpty {
                        Task { @MainActor in
                            do { try await state.login(server: state.server, password: pw) } catch {
                                state.notice = "Автовход: " + error.localizedDescription
                            }
                        }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var web = WebStore.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if state.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
            if let text = state.notice {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 110)
                        .onTapGesture { state.notice = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if state.notice == text { withAnimation { state.notice = nil } }
                    }
                }
            }
            if let busy = web.busyText {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text(busy).foregroundColor(.white).font(.system(size: 15, weight: .semibold))
                }
                .padding(28)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.notice)
    }
}

// MARK: - Main (dock + screens)

struct MainView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var web = WebStore.shared

    private var showsWeb: Bool { state.webTab != nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 0) {
                    webTopBar
                    ZStack {
                        WebContainer(store: web)
                        if web.failed { OfflineView { web.loadPanel() } }
                    }
                }
                .opacity(showsWeb ? 1 : 0)
                .allowsHitTesting(showsWeb)

                if state.tab == .home { DashboardView().transition(.opacity) }
                if state.tab == .more && state.moreWeb == nil { MoreView().transition(.opacity) }
            }
            DockBar()
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: state.webTab) { tab in
            if let tab = tab { web.show(tab) }
        }
    }

    @ViewBuilder private var webTopBar: some View {
        HStack(spacing: 10) {
            if state.tab == .more {
                Button {
                    Haptics.tap()
                    state.moreWeb = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        Text("Ещё").font(.system(size: 17))
                    }.foregroundColor(.white)
                }
            }
            if state.tab == .accounts {
                Picker("", selection: $state.accounts) {
                    ForEach(AccountsSection.allCases, id: \.self) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
            } else {
                Text(title)
                    .font(.system(size: 20, weight: .heavy))
                    .textCase(.uppercase)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
            }
            if web.isLoading {
                ProgressView().tint(.white).frame(width: 28)
            } else {
                Button {
                    Haptics.tap()
                    web.loadPanel()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Theme.pill)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    private var title: String {
        switch state.webTab {
        case "crosspost": return "Кросспостинг"
        case "aivideo": return "AI-видео"
        case "videos": return "Медиатека"
        case "logs": return "Логи"
        default: return "Studio"
        }
    }
}

struct DockBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases, id: \.self) { tab in
                let active = state.tab == tab
                Button {
                    if state.tab != tab { Haptics.tap() }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if tab == .more && state.tab == .more { state.moreWeb = nil }
                        state.tab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 18, weight: .semibold))
                        Text(tab.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundColor(active ? .white : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(active ? Theme.pill : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Theme.bg.ignoresSafeArea(edges: .bottom))
    }
}

struct OfflineView: View {
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44, weight: .semibold)).foregroundColor(Theme.muted)
            Text("Нет связи с сервером").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
            Text("Проверьте интернет или адрес сервера в разделе «Ещё».")
                .font(.system(size: 15)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
            Button("Повторить") { retry() }.buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 260)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject var state: AppState
    @State private var server = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var showServer = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 70)
                LogoBadge(size: 80).padding(.bottom, 22)
                Text("LitEnergy\nAutomation Studio")
                    .font(.system(size: 26, weight: .heavy))
                    .textCase(.uppercase)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                Text("Введите пароль панели")
                    .font(.system(size: 15)).foregroundColor(Theme.muted)
                    .padding(.top, 10).padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 10) {
                    if showServer {
                        Text("Сервер").font(.system(size: 13)).foregroundColor(Theme.muted).padding(.leading, 4)
                        TextField("http://адрес:8585", text: $server)
                            .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                            .fieldBox()
                    }
                    Text("Пароль").font(.system(size: 13)).foregroundColor(Theme.muted).padding(.leading, 4)
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                        .fieldBox()
                    Button(action: submit) {
                        if busy { ProgressView().tint(.black) } else { Text("Войти") }
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: !password.isEmpty && !busy))
                    .disabled(password.isEmpty || busy)
                    .padding(.top, 6)
                    if let error = error {
                        Text(error).font(.system(size: 14)).foregroundColor(Theme.red)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    }
                }
                .padding(18)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button(showServer ? "Скрыть адрес сервера" : "Изменить адрес сервера") {
                    withAnimation { showServer.toggle() }
                }
                .font(.system(size: 14)).foregroundColor(Theme.muted).padding(.top, 18)

                if let n = state.notice {
                    Text(n).font(.system(size: 14)).foregroundColor(Theme.orange).padding(.top, 10)
                }
                Text("TikTok · Telegram · VK · Instagram · YouTube")
                    .font(.system(size: 12)).foregroundColor(Theme.dim).padding(.top, 26)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { server = state.server }
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await state.login(server: server, password: password)
                Haptics.success()
                password = ""
                state.notice = nil
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
