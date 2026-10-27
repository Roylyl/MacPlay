import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        guard let range = text.range(of: #"(?<![0-9])\d+\.\d+\.\d+(?![0-9.])"#, options: .regularExpression) else { return nil }
        parts = text[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    func installer(arm64: Bool) -> URL? {
        let architecture = arm64 ? ["arm64", "aarch64", "apple-silicon"] : ["x86_64", "x64", "intel", "amd64"]
        let images = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let asset = images.first { item in architecture.contains { item.name.lowercased().contains($0) } }
            ?? images.first { $0.name.lowercased().contains("universal") }
        guard let asset, let url = URL(string: asset.browser_download_url), url.scheme == "https",
              url.host == "github.com", url.path.hasPrefix("/Roylyl/MacPlay/releases/download/") else { return nil }
        return url
    }
}

@MainActor final class MacPlayUpdates: ObservableObject {
    @Published var checking = false
    @Published var status = "尚未检查更新"
    @Published var detail = ""
    @Published var release: GitHubRelease?
    @Published var showPrompt = false
    @Published var exportStatus = ""
    @Published var exportDetail = ""
    @Published var automatic = UserDefaults.standard.object(forKey: "MacPlay.automaticUpdates") as? Bool ?? true
    private var automaticTimer:Timer?
    private var didStartupCheck=false
    func startAutomaticChecks() {
        guard !didStartupCheck else {return};didStartupCheck=true
        if automatic {check(automatic:true);scheduleChecks()}
    }
    private func scheduleChecks() {
        automaticTimer?.invalidate()
        automaticTimer=Timer.scheduledTimer(withTimeInterval:7200,repeats:true){[weak self] _ in
            MainActor.assumeIsolated {self?.check(automatic:true,silent:true)}
        }
    }
    private let defaults = UserDefaults.standard
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.4" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    var architecture: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
    var nativeArm64: Bool {
        #if arch(arm64)
        return true
        #else
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #endif
    }
    var installer: URL? { release?.installer(arm64: nativeArm64) }
    func setAutomatic(_ enabled: Bool) {
        automatic = enabled; defaults.set(enabled, forKey: "MacPlay.automaticUpdates")
        if enabled { check(automatic: true);scheduleChecks() } else {automaticTimer?.invalidate();automaticTimer=nil;showPrompt=false}
    }
    func check(automatic isAutomatic: Bool = false,silent:Bool=false) {
        guard !checking, !isAutomatic || automatic else { return }
        let now = Date().timeIntervalSince1970
        if isAutomatic { defaults.set(now, forKey: "MacPlay.lastUpdateCheck") }
        checking = true; status = "正在检查更新…"; detail = ""
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/Roylyl/MacPlay/releases?per_page=100")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("MacPlay/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard http.statusCode == 200 else {
                    status = "检查更新失败"; detail = "GitHub HTTP \(http.statusCode)"; return
                }
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                    .filter { !$0.draft && !$0.prerelease && $0.version != nil }
                guard let newest = releases.max(by: { $0.version! < $1.version! }), let latest = newest.version,
                      let current = ReleaseVersion(currentVersion) else { status = "未找到正式发行版"; return }
                defaults.set(now, forKey: "MacPlay.lastUpdateCheck")
                guard latest > current else { release = nil; status = "当前已是最新版本"; return }
                let arm = nativeArm64
                release = releases.first { $0.version == latest && $0.installer(arm64: arm) != nil } ?? newest
                status = "发现新版本"; detail = latest.description
                if !silent && (!isAutomatic || automatic && defaults.string(forKey: "MacPlay.notifiedVersion") != latest.description) { showPrompt = true }
            } catch {
                status = "检查更新失败"; detail = error.localizedDescription
            }
        }
    }
    func dismissPrompt() {
        showPrompt = false
        if let version = release?.version { defaults.set(version.description, forKey: "MacPlay.notifiedVersion") }
    }
    func openDownload() {
        if let url = installer { NSWorkspace.shared.open(url) }
        else { openRelease() }
        dismissPrompt()
    }
    func openRelease() {
        if let url = URL(string: release?.html_url ?? "https://github.com/Roylyl/MacPlay/releases"), url.scheme == "https", url.host == "github.com" { NSWorkspace.shared.open(url) }
    }
    func exportLogs(_ model: PlayModel) {
        exportDetail = ""
        let raw = (try? String(contentsOf: model.logURL, encoding: .utf8)) ?? model.logs
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { exportStatus = "暂无日志可导出"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MacPlay-\(currentVersion)-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-"))-logs.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let safe = Self.redactedLog(raw)
            try "MacPlay \(currentVersion) (\(build)) · \(architecture)\n\(Date().ISO8601Format())\n\n\(safe)".write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "日志已导出"
        } catch { exportStatus = "日志导出失败"; exportDetail = error.localizedDescription }
    }
    func exportDiagnostics(_ model: PlayModel) {
        exportDetail = ""
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "MacPlay-\(currentVersion)-\(stamp)-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let raw = (try? String(contentsOf: model.logURL, encoding: .utf8)) ?? model.logs
            // Deliberately omit settings, discovered phones and authentication
            // data. Neither a network password nor a device UID is diagnostic.
            let snapshot: [String: Any] = [
                "schemaVersion": 1,
                "application": "MacPlay",
                "version": currentVersion,
                "build": build,
                "platform": "macOS",
                "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": architecture,
                "date": Date().ISO8601Format(),
                "authenticationReady": model.credentialsReady,
                "connection": ["running": model.running, "receivingOrWaiting": model.receivingOrWaiting,
                               "mode": model.settings.wireless ? "wireless" : "USB", "status": model.status],
                "metrics": model.mediaStatistics,
                "messages": DiagnosticRedactor.redact(raw).components(separatedBy: .newlines)
            ]
            let safe = DiagnosticRedactor.redactValue(snapshot)
            let data = try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            exportStatus = "诊断快照已导出"
        } catch { exportStatus = "诊断快照导出失败"; exportDetail = error.localizedDescription }
    }
    static func redactedLog(_ raw: String) -> String { DiagnosticRedactor.redact(raw) }

}

struct MacPlayAboutView: View {
    @ObservedObject var model: PlayModel
    @ObservedObject var updates: MacPlayUpdates
    var body: some View {
        Section(L("关于")) {
            LabeledContent("MacPlay", value: updates.currentVersion)
            LabeledContent(L("构建版本"), value: updates.build)
            LabeledContent(L("运行架构"), value: updates.architecture)
            LabeledContent(L("开源许可"), value: "GPL-3.0-or-later")
            Link(L("项目主页"), destination: URL(string: "https://github.com/Roylyl/MacPlay")!)
        }
        Section(L("软件更新")) {
            Toggle(L("自动检查更新"), isOn: Binding(get: { updates.automatic }, set: { updates.setAutomatic($0) }))
            HStack { Button(L(updates.checking ? "正在检查更新…" : "检查更新")) { updates.check() }.disabled(updates.checking); Button(L("查看发行说明")) { updates.openRelease() } }
            Text(L(updates.status)).foregroundStyle(.secondary)
            if !updates.detail.isEmpty { Text(updates.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if updates.release != nil {
                if updates.installer != nil { Button(L("下载更新")) { updates.openDownload() } }
                if updates.installer == nil { Text(L("最新发行版暂无适合当前芯片的安装包，请查看发行说明。")).font(.callout).foregroundStyle(.secondary) }
            }
        }
        Section(L("日志")) {
            HStack {
                Button(L("打开日志")) { NSWorkspace.shared.open(model.logURL) }.disabled(!FileManager.default.fileExists(atPath: model.logURL.path))
                Button(L("导出日志")) { updates.exportLogs(model) }
                Button(L("导出诊断快照")) { updates.exportDiagnostics(model) }
            }
            DisclosureGroup(L("最近日志")) {
                ScrollView {
                    Text(model.logs.isEmpty ? L("暂无日志") : model.logs)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }
            if !updates.exportStatus.isEmpty { Text(L(updates.exportStatus)).foregroundStyle(.secondary) }
            if !updates.exportDetail.isEmpty { Text(updates.exportDetail).font(.callout).foregroundStyle(.secondary) }
        }
        Section {
            DisclosureGroup(L("认证文件")) {
                LabeledContent(L("状态"), value: L(model.credentialsReady ? "文件已就绪，等待iPhone验证" : "缺少文件"))
                HStack {
                    Button(L("导入认证文件")) { model.importCredentials() }
                    Button(L("打开认证目录")) { NSWorkspace.shared.open(model.authDirectory) }
                    Button(L("刷新状态")) { model.inspectCredentials() }
                }
            }
        }
    }
}
