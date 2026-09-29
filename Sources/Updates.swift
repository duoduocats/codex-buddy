import AppKit
import Combine

private final class UpdateRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", let host = url.host, hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { completionHandler(nil); return }
        completionHandler(request)
    }
}

@MainActor final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var message = ""
    @Published private(set) var available: GitHubRelease?
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var started = false
    private var lastAttempt: Date?
    private var presenting = false
    private let repository: String
    // Injectable boundaries keep policy integration tests away from installed apps and modal UI.
    private let installOperation: ((GitHubRelease, Bool) async throws -> Void)?
    private let presentation: ((GitHubRelease) -> Void)?
    let currentVersion: String
    var configured: Bool { UpdatePolicy.validRepository(repository) }
    var beforePresent: (() -> Void)?
    var beforeInstall: (() -> Void)?

    init(defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral,
         repository: String = Bundle.main.object(forInfoDictionaryKey:"GitHubRepository") as? String ?? "",
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.0",
         installOperation: ((GitHubRelease, Bool) async throws -> Void)? = nil,
         presentation: ((GitHubRelease) -> Void)? = nil) {
        self.defaults=defaults;self.repository=repository;self.currentVersion=currentVersion
        self.installOperation=installOperation;self.presentation=presentation
        configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=20
        configuration.urlCache=nil;configuration.httpCookieStorage=nil
        session=URLSession(configuration:configuration,delegate:UpdateRedirectDelegate(),delegateQueue:nil)
        if !UpdatePolicy.validRepository(repository) { message=L("尚未配置 GitHub 发布仓库。", "No GitHub release repository is configured.") }
    }
    func start() {
        guard !started, configured else { return };started=true
        DispatchQueue.main.asyncAfter(deadline:.now()+15) { [weak self] in self?.check(manual:false) }
        timer=Timer.scheduledTimer(withTimeInterval:6*3600,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.check(manual:false) }
        }
        timer?.tolerance=300
    }
    func check(manual: Bool) {
        guard !checking, !presenting, !installing else { return }
        guard configured else { message=L("尚未配置 GitHub 发布仓库。", "No GitHub release repository is configured.");return }
        let last = lastAttempt ?? defaults.object(forKey:"updates.lastAttempt") as? Date
        if !manual, let last, Date().timeIntervalSince(last) < 6*3600 { return }
        lastAttempt=Date();defaults.set(lastAttempt,forKey:"updates.lastAttempt")
        checking=true
        Task {
            defer { checking=false }
            do {
                var request=URLRequest(url:URL(string:"https://api.github.com/repos/\(repository)/releases/latest")!)
                request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
                request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version")
                request.setValue("Codex-Buddy/\(currentVersion)",forHTTPHeaderField:"User-Agent")
                let (data,response)=try await session.data(for:request)
                guard let http=response as? HTTPURLResponse else { throw CheckFailure.invalid }
                if http.statusCode == 404 { message=L("暂未找到公开的正式版本。", "No public stable release is available yet.");return }
                guard http.statusCode == 200, data.count < 2_000_000 else { throw CheckFailure.invalid }
                let release=try JSONDecoder().decode(GitHubRelease.self,from:data)
                guard release.publishedURL(repository:repository) != nil,
                      let latest=AppVersion(release.tagName),let current=AppVersion(currentVersion) else { throw CheckFailure.invalid }
                guard latest > current else {
                    available=nil;message=L("当前已是最新版本（\(currentVersion)）。", "You are up to date (\(currentVersion)).")
                    return
                }
                available=release;message=L("发现新版本 \(release.tagName)。", "Update available: \(release.tagName).")
                let ignored=defaults.stringArray(forKey:"updates.ignored") ?? []
                let announced=defaults.stringArray(forKey:"updates.announced") ?? []
                let mode = await mode(for:release)
                switch UpdatePolicy.action(release:release,mode:mode,current:currentVersion,manual:manual,ignored:ignored,announced:announced) {
                case .install: installAvailable(silent:true)
                case .notify: present(release,manual:manual)
                case .none: break
                }
            } catch { if manual { message=L("检查失败，请稍后重试。", "Could not check for updates. Try again later.") } }
        }
    }
    private func mode(for release: GitHubRelease) async -> ReleaseUpdateMode {
        // Missing metadata preserves older important releases. Invalid metadata never installs.
        guard release.assets.contains(where:{ $0.name == "update-policy.json" }) else {
            return release.isImportant ? .notify : .none
        }
        guard let asset = release.policyAsset(repository:repository),
              let url = URL(string:asset.browserDownloadURL ?? "") else { return .none }
        do {
            let (data,response) = try await session.data(from:url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .none }
            return UpdatePolicy.verifiedMode(data:data,asset:asset,tag:release.tagName) ?? .none
        } catch { return .none }
    }
    func installAvailable(silent: Bool = false) {
        guard !installing,let release=available else { return }
        installing=true
        if !silent { beforeInstall?() }
        Task {
            do {
                if let installOperation {
                    try await installOperation(release,silent)
                    installing=false
                    return
                }
                let target=Bundle.main.bundleURL
                let work=try await UpdateInstaller.stage(release:release,repository:repository,target:target) { status in self.message=status }
                message=L("正在安装，应用即将重新启动…", "Installing. The app will restart shortly…")
                try UpdateInstaller.replaceAndRelaunch(staged:work,target:target,background:silent)
            } catch { message=(error as? UpdateInstallFailure)?.localizedDescription ?? L("更新失败，当前版本未被替换。", "Update failed. Your current version has not been replaced.");installing=false }
        }
    }
    func openRelease() {
        guard let url=available?.publishedURL(repository:repository) else { return }
        NSWorkspace.shared.open(url)
    }
    private func present(_ release: GitHubRelease, manual: Bool) {
        guard !presenting else { return };presenting=true;defer { presenting=false }
        // Record before presentation so a relaunch or repeated timer never nags for the same release.
        do {
            var versions=defaults.stringArray(forKey:"updates.announced") ?? []
            if !versions.contains(release.tagName) { versions.append(release.tagName) }
            defaults.set(versions,forKey:"updates.announced")
        }
        if let presentation { presentation(release); return }
        beforePresent?();NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert()
        alert.messageText=release.isImportant ? L("Codex Buddy 有重大更新", "Important Codex Buddy update") : L("Codex Buddy 有新版本", "Codex Buddy update available")
        alert.informativeText=L("\(currentVersion) → \(release.tagName)\n更新将从 GitHub 自动下载、校验并替换，完成后重新启动。你也可以忽略此版本，继续使用。", "\(currentVersion) → \(release.tagName)\nThe update will be downloaded from GitHub, verified, and installed. The app will restart afterward. You can also ignore this version and keep using the app.")
        alert.addButton(withTitle:L("下载并更新", "Download and update"))
        alert.addButton(withTitle:L("稍后", "Later"))
        alert.addButton(withTitle:L("忽略此版本", "Ignore this version"))
        let choice=alert.runModal()
        if choice == .alertFirstButtonReturn { installAvailable() }
        if choice == .alertThirdButtonReturn {
            var versions=defaults.stringArray(forKey:"updates.ignored") ?? []
            if !versions.contains(release.tagName) { versions.append(release.tagName) }
            defaults.set(versions,forKey:"updates.ignored")
            message=L("已忽略 \(release.tagName)，仍可手动检查或下载。", "Ignored \(release.tagName). You can still check or download manually.")
        }
    }
    private enum CheckFailure: Error { case invalid }
}
