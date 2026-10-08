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
    @Published private(set) var includesBeta: Bool
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var installFailed = false
    @Published private(set) var message = ""
    @Published private(set) var available: GitHubRelease?
    @Published private(set) var showsPanelUpdate = false
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var started = false
    private var lastAttempt: Date?
    private var presenting = false
    private var ignoreRevision = 0
    private var channelRevision = 0
    private let repository: String
    // Injectable boundaries keep policy integration tests away from installed apps and modal UI.
    private let installOperation: ((GitHubRelease, Bool) async throws -> Void)?
    private let presentation: ((GitHubRelease) -> Void)?
    private let releaseOpener: ((URL) -> Void)?
    private let now: () -> Date
    let currentVersion: String
    var configured: Bool { UpdatePolicy.validRepository(repository) }
    var beforePresent: (() -> Void)?
    var beforeInstall: (() -> Void)?

    init(defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral,
         repository: String = Bundle.main.object(forInfoDictionaryKey:"GitHubRepository") as? String ?? "",
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.0",
         installOperation: ((GitHubRelease, Bool) async throws -> Void)? = nil,
         presentation: ((GitHubRelease) -> Void)? = nil,
         releaseOpener: ((URL) -> Void)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults=defaults;self.repository=repository;self.currentVersion=currentVersion
        includesBeta = defaults.bool(forKey:"updates.includesBeta")
        self.installOperation=installOperation;self.presentation=presentation
        self.releaseOpener=releaseOpener
        self.now=now
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
    func setIncludesBeta(_ value: Bool) {
        guard !installing, value != includesBeta else { return }
        includesBeta = value;defaults.set(value,forKey:"updates.includesBeta")
        channelRevision += 1
        if !value, available?.isBeta == true {
            available = nil;showsPanelUpdate = false;installFailed = false;message = ""
            defaults.set(false,forKey:"updates.restorePanelOffer")
        }
        lastAttempt = nil;defaults.removeObject(forKey:"updates.lastAttempt")
        if !checking, configured { check(manual:false) }
    }
    private func releases(includeBeta: Bool) async throws -> [GitHubRelease] {
        let path = includeBeta ? "releases?per_page=100" : "releases/latest"
        var request = URLRequest(url:URL(string:"https://api.github.com/repos/\(repository)/\(path)")!)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version")
        request.setValue("Codex-Buddy/\(currentVersion)",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw CheckFailure.invalid }
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200, data.count < 2_000_000 else { throw CheckFailure.invalid }
        if includeBeta {
            var values = try JSONDecoder().decode([GitHubRelease].self,from:data)
            guard values.count <= 100 else { throw CheckFailure.invalid }
            // Even a full page of betas must not hide the stable fallback.
            if !values.contains(where:{ $0.publishedURL(repository:repository) != nil }) {
                values += try await releases(includeBeta:false)
            }
            return values
        }
        return [try JSONDecoder().decode(GitHubRelease.self,from:data)]
    }
    func check(manual: Bool) {
        guard !checking, !presenting, !installing else { return }
        guard configured else { message=L("尚未配置 GitHub 发布仓库。", "No GitHub release repository is configured.");return }
        let last = lastAttempt ?? defaults.object(forKey:"updates.lastAttempt") as? Date
        // A major offer that was visible before quitting needs one startup check
        // to restore it. Subsequent checks still observe the six-hour cadence.
        let restoreOffer = lastAttempt == nil && defaults.bool(forKey:"updates.restorePanelOffer")
        if !manual, !restoreOffer, let last, now().timeIntervalSince(last) < 6*3600 { return }
        lastAttempt=now();defaults.set(lastAttempt,forKey:"updates.lastAttempt")
        checking=true
        let ignoreTicket = ignoreRevision, channelTicket = channelRevision, includeBeta = includesBeta
        Task {
            defer {
                checking = false
                if channelTicket != channelRevision { check(manual:false) }
            }
            do {
                let values = try await releases(includeBeta:includeBeta)
                guard !installing, channelTicket == channelRevision else { return }
                guard let release = UpdatePolicy.latestRelease(values,repository:repository,includeBeta:includeBeta) else {
                    available=nil;showsPanelUpdate=false;defaults.set(false,forKey:"updates.restorePanelOffer")
                    message = includeBeta
                        ? L("暂未找到公开版本。", "No public release is available yet.")
                        : L("暂未找到公开的正式版本。", "No public stable release is available yet.")
                    return
                }
                guard let latest=AppVersion(release.tagName),let current=AppVersion(currentVersion) else { throw CheckFailure.invalid }
                guard latest > current else {
                    available=nil;showsPanelUpdate=false;defaults.set(false,forKey:"updates.restorePanelOffer");message=L("当前已是最新版本（\(currentVersion)）。", "You are up to date (\(currentVersion)).")
                    return
                }
                let mode = await mode(for:release)
                guard !installing, channelTicket == channelRevision else { return }
                let ignored=defaults.stringArray(forKey:"updates.ignored") ?? []
                let announced=defaults.stringArray(forKey:"updates.announced") ?? []
                // A dismiss click during the request takes precedence over even
                // a manual check that began before that click.
                let manualOffer = manual && !(ignoreTicket != ignoreRevision && ignored.contains(release.tagName))
                if available?.tagName != release.tagName { installFailed = false }
                available=release;message=L("发现新版本 \(release.tagName)。", "Update available: \(release.tagName).")
                // An inline offer remains visible across launches until ignored or installed.
                // The legacy announcement record only deduplicates policy callbacks.
                showsPanelUpdate = (manualOffer || mode == .notify) && (manualOffer || !ignored.contains(release.tagName)) && mode != .silent
                defaults.set(showsPanelUpdate && mode == .notify,forKey:"updates.restorePanelOffer")
                switch UpdatePolicy.action(release:release,mode:mode,current:currentVersion,manual:manualOffer,ignored:ignored,announced:announced,includeBeta:includeBeta) {
                case .install: installAvailable(silent:true)
                case .notify: present(release,manual:manual)
                case .none: break
                }
            } catch { if manual && !installing && channelTicket == channelRevision { message=L("检查失败，请稍后重试。", "Could not check for updates. Try again later.") } }
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
        guard !installing,let release=available,
              release.publishedURL(repository:repository,includeBeta:includesBeta) != nil else { return }
        installing=true
        installFailed=false
        message=L("正在下载并校验更新…", "Downloading and verifying the update…")
        if !silent { beforeInstall?() }
        let includeBeta = includesBeta
        Task {
            do {
                if let installOperation {
                    try await installOperation(release,silent)
                    installing=false
                    return
                }
                let target=Bundle.main.bundleURL
                let work=try await UpdateInstaller.stage(release:release,repository:repository,target:target,includeBeta:includeBeta) { status in self.message=status }
                message=L("正在安装，应用即将重新启动…", "Installing. The app will restart shortly…")
                try UpdateInstaller.replaceAndRelaunch(staged:work,target:target,background:silent)
            } catch { message=(error as? UpdateInstallFailure)?.localizedDescription ?? L("更新失败，当前版本未被替换。", "Update failed. Your current version has not been replaced.");installing=false;installFailed=true }
        }
    }
    func openRelease() {
        guard let url=available?.publishedURL(repository:repository,includeBeta:includesBeta) else { return }
        if let releaseOpener { releaseOpener(url);return }
        NSWorkspace.shared.open(url)
    }
    func ignoreAvailable() {
        guard let release = available else { return }
        ignoreRevision += 1
        var versions = defaults.stringArray(forKey:"updates.ignored") ?? []
        if !versions.contains(release.tagName) { versions.append(release.tagName) }
        defaults.set(Array(versions.suffix(100)),forKey:"updates.ignored")
        showsPanelUpdate = false
        defaults.set(false,forKey:"updates.restorePanelOffer")
        message = L("已忽略 \(release.tagName)。", "Ignored \(release.tagName).")
    }
    private func present(_ release: GitHubRelease, manual: Bool) {
        guard !presenting else { return };presenting=true;defer { presenting=false }
        showsPanelUpdate = true
        // Retain old announcement records for compatibility; presentation is now inline.
        do {
            var versions=defaults.stringArray(forKey:"updates.announced") ?? []
            if !versions.contains(release.tagName) { versions.append(release.tagName) }
            defaults.set(versions,forKey:"updates.announced")
        }
        presentation?(release)
    }
    private enum CheckFailure: Error { case invalid }
}
