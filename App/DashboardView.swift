import AVKit
import SwiftUI

@MainActor
final class DashboardModel: ObservableObject {
    @Published var status: JSON = [:]
    @Published var scheduler: JSON = [:]
    @Published var videogen: JSON = [:]
    @Published var loaded = false
    @Published var offline = false

    func refresh(_ app: AppState) async {
        guard app.isLoggedIn else { return }
        do {
            async let s = app.call("/api/status")
            async let sc = app.call("/api/scheduler/status")
            async let vg = app.call("/api/videogen/status")
            let (a, b, c) = try await (s, sc, vg)
            status = a
            scheduler = b
            videogen = c
            loaded = true
            offline = false
        } catch let e as APIError where e.unauthorized {
            return
        } catch {
            offline = true
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = DashboardModel()
    @State private var player: PlayerItem?
    @State private var confirmTrigger = false
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                if model.offline && !model.loaded {
                    OfflineView { Task { @MainActor in await model.refresh(state) } }.frame(height: 360)
                } else {
                    statsGrid
                    jobsCard
                    schedulerCard
                    aiCard
                    recentVideos
                    logsCard
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background(Theme.bg)
        .refreshable { await model.refresh(state) }
        .task {
            while !Task.isCancelled {
                await model.refresh(state)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(item: $player) { item in VideoSheet(item: item) }
        .alert("Запустить авто-выкладку сейчас?", isPresented: $confirmTrigger) {
            Button("Отмена", role: .cancel) {}
            Button("Запустить") { post("/api/scheduler/trigger") }
        } message: {
            Text("Видео будут загружены на все активные аккаунты по текущим настройкам.")
        }
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 14) {
            LogoBadge(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("LitEnergy Studio").font(.system(size: 22, weight: .heavy)).textCase(.uppercase).foregroundColor(.white)
                HStack(spacing: 6) {
                    Circle().fill(model.offline ? Theme.red : Theme.green).frame(width: 8, height: 8)
                    Text(model.offline ? "Нет связи с сервером" : "Сервер работает")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.muted)
                }
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private var statsGrid: some View {
        let s = model.status
        let items: [(String, String, Int)] = [
            ("TikTok", "music.note", s.int("accounts_count")),
            ("Telegram", "paperplane", s.int("tg_accounts_count")),
            ("ВКонтакте", "person.crop.square", s.int("vk_accounts_count")),
            ("Instagram", "camera", s.int("ig_accounts_count")),
            ("YouTube", "play.rectangle", s.int("yt_accounts_count")),
            ("Медиа", "film.stack", s.int("videos_count")),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: item.1).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.muted)
                    Text(model.loaded ? "\(item.2)" : "—").font(.system(size: 24, weight: .heavy)).foregroundColor(.white)
                    Text(item.0).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.muted).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    @ViewBuilder private var jobsCard: some View {
        let jobs: [(String, JSON)] = ([
            ("TikTok", model.status.obj("current_job")),
            ("Telegram", model.status.obj("current_tg_job")),
            ("ВКонтакте", model.status.obj("current_vk_job")),
            ("Кросспост", model.status.obj("current_crosspost_job")),
        ] as [(String, JSON?)]).compactMap { pair -> (String, JSON)? in
            guard let job = pair.1 else { return nil }
            return (pair.0, job)
        }
        if !jobs.isEmpty {
            Card {
                Text("Сейчас выполняется").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                ForEach(jobs.indices, id: \.self) { i in
                    let name = jobs[i].0
                    let job = jobs[i].1
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(name) · задание #\(job.int("id"))").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            let done = job.int("completed_items") + job.int("completed_chats") + job.int("completed_targets")
                            let total = job.int("total_items") + job.int("total_chats") + job.int("total_targets")
                            Text(total > 0 ? "Выполнено \(done) из \(total)" : "В работе")
                                .font(.system(size: 13)).foregroundColor(Theme.muted)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var schedulerCard: some View {
        let sc = model.scheduler
        let enabled = sc.bool("is_enabled")
        return Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Авто-выкладка").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    Text("TikTok · YouTube · \(sc.str("times").replacingOccurrences(of: ",", with: " · "))")
                        .font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { v in
                    Haptics.tap()
                    model.scheduler["is_enabled"] = v
                    post("/api/scheduler/toggle", form: ["enabled": v ? "true" : "false"])
                }))
                .labelsHidden()
                .tint(Theme.green)
            }
            if !sc.str("next_run").isEmpty {
                row("Следующий запуск", sc.str("next_run"))
            }
            if !sc.str("last_run").isEmpty {
                row("Последний запуск", sc.str("last_run"))
            }
            Button {
                Haptics.tap()
                confirmTrigger = true
            } label: { Label("Запустить сейчас", systemImage: "play.fill") }
            .buttonStyle(PillButtonStyle())
            .disabled(working)
        }
    }

    private var aiCard: some View {
        let vg = model.videogen
        let st = vg.obj("state") ?? [:]
        let cfg = vg.obj("config") ?? [:]
        let cast = vg.obj("cast") ?? [:]
        let quota = vg.arr("quota")
        let freeQuota = quota.filter { $0.bool("available") }.count
        let models = ((vg["models"] as? [String]) ?? []).filter { !$0.isEmpty }
        let waits = quota.filter { !$0.bool("available") }.map { $0.int("resets_in_min") }.filter { $0 > 0 }
        let running = st.bool("running")
        return Card {
            HStack {
                Text("AI-видео").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                Spacer()
                Text(running ? "ГЕНЕРАЦИЯ" : "ГОТОВО")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(running ? Theme.orange : Theme.green)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((running ? Theme.orange : Theme.green).opacity(0.14))
                    .clipShape(Capsule())
            }
            if running && !st.str("current").isEmpty {
                Text(st.str("current")).font(.system(size: 13)).foregroundColor(Theme.muted).lineLimit(3)
            }
            Group {
            row("Сегодня создано", "\(vg.int("today")) из \(cfg.int("daily_count"))")
            row("Модель", models.isEmpty ? "—" : models[0])
            if models.count > 1 {
                row("Запасные", models.dropFirst().joined(separator: ", "))
            }
            row("Квота GPU", quota.isEmpty ? "—" : quotaText(free: freeQuota, total: quota.count, waits: waits))
            row("Клипов в запасе", "\(vg.int("unused_clips"))")
            }
            row("Кастинг", "\(cast.int("characters")) персонажей · \(cast.int("places")) мест · \(cast.int("styles")) стилей")
            row("Режим", (cfg.str("variety_mode") == "mix") ? "смешанный" : "только новые персонажи и места")
            if !st.str("last_error").isEmpty {
                Text(st.str("last_error")).font(.system(size: 12.5)).foregroundColor(Theme.orange).lineLimit(3)
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    post("/api/videogen/generate", form: ["count": "1"])
                } label: { Label("Создать видео", systemImage: "sparkles") }
                .buttonStyle(PillButtonStyle())
                .disabled(running || working)
                Button {
                    Haptics.tap()
                    state.tab = .ai
                } label: { Text("Настройки") }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    @ViewBuilder private var recentVideos: some View {
        let vids = Array(model.videogen.arr("videos").prefix(6))
        if !vids.isEmpty {
            Card {
                Text("Последние AI-видео").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                ForEach(vids.indices, id: \.self) { i in
                    let v = vids[i]
                    let meta = (try? JSONSerialization.jsonObject(with: Data(v.str("gen_meta").utf8))) as? JSON ?? [:]
                    let title = meta.str("hook").isEmpty ? v.str("original_name") : meta.str("hook")
                    HStack(spacing: 12) {
                        Button {
                            if let url = state.mediaURL(v.str("filename")) {
                                player = PlayerItem(url: url, token: state.token, title: title)
                            }
                        } label: {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill)
                                .frame(width: 46, height: 64)
                                .overlay(Image(systemName: "play.fill").foregroundColor(.white))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                            Text("#\(v.int("id")) · \(v.str("duration")) с")
                                .font(.system(size: 12)).foregroundColor(Theme.muted)
                            if !v.str("cast_label").isEmpty {
                                Text(v.str("cast_label")).font(.system(size: 11)).foregroundColor(Theme.dim).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button {
                            Haptics.tap()
                            if let url = state.mediaURL(v.str("filename")) { WebStore.shared.saveMedia(url) }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                                .frame(width: 40, height: 40).background(Theme.pill).clipShape(Circle())
                        }
                    }
                }
            }
        }
    }

    private var logsCard: some View {
        let logs = Array(model.status.arr("logs").suffix(8).reversed())
        return Card {
            HStack {
                Text("Журнал").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button("Все логи") {
                    Haptics.tap()
                    state.moreWeb = "logs"
                    state.tab = .more
                }
                .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.muted)
            }
            if logs.isEmpty {
                Text("Пока пусто").font(.system(size: 13)).foregroundColor(Theme.muted)
            }
            ForEach(logs.indices, id: \.self) { i in
                let l = logs[i]
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color(l.str("level"))).frame(width: 6, height: 6).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.str("message")).font(.system(size: 13)).foregroundColor(.white).lineLimit(3)
                        Text(String(l.str("timestamp").prefix(19)).replacingOccurrences(of: "T", with: " "))
                            .font(.system(size: 11)).foregroundColor(Theme.dim)
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func quotaText(free: Int, total: Int, waits: [Int]) -> String {
        var t = "свободно \(free) из \(total)"
        if let m = waits.min() {
            t += m >= 60 ? " · сброс через \(m / 60) ч \(m % 60) мин" : " · сброс через \(m) мин"
        }
        return t
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 14)).foregroundColor(Theme.muted)
            Spacer(minLength: 10)
            Text(v).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).multilineTextAlignment(.trailing)
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return Theme.red
        case "warning": return Theme.orange
        case "success": return Theme.green
        default: return Theme.muted
        }
    }

    private func post(_ path: String, form: [String: String] = [:]) {
        working = true
        Task { @MainActor in
            do {
                let r = try await state.call(path, method: "POST", form: form)
                let msg = r.str("message")
                if r["ok"] as? Bool == false {
                    Haptics.error()
                    state.notice = msg.isEmpty ? "Не удалось" : msg
                } else if !msg.isEmpty {
                    Haptics.success()
                    state.notice = msg
                }
            } catch {
                state.notice = error.localizedDescription
            }
            working = false
            await model.refresh(state)
        }
    }
}

struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    let token: String?
    let title: String
}

struct VideoSheet: View {
    let item: PlayerItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player = player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            HStack(spacing: 10) {
                Button {
                    WebStore.shared.saveMedia(item.url)
                } label: {
                    Image(systemName: "square.and.arrow.down").foregroundColor(.white)
                        .frame(width: 40, height: 40).background(Theme.pill.opacity(0.9)).clipShape(Circle())
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundColor(.white)
                        .frame(width: 40, height: 40).background(Theme.pill.opacity(0.9)).clipShape(Circle())
                }
            }
            .padding(16)
        }
        .onAppear {
            var headers: [String: String] = [:]
            if let t = item.token { headers["Authorization"] = "Bearer " + t }
            let asset = AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
