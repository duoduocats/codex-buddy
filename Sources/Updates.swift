import AppKit
import Combine
import Network

private final class UpdateRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", let host = url.host, hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum UpdateCheckIssue: String, Equatable {
    case network, server, rateLimited, releaseInvalid, policyUnavailable, policyInvalid, withdrawn
    var message: String {
        switch self {
        case .network: return L("无法连接更新服务，将自动重试。", "Could not connect to the update service. We will retry automatically.")
        case .server: return L("更新服务暂时不可用，将稍后重试。", "The update service is temporarily unavailable. We will retry later.")
        case .rateLimited: return L("更新服务要求稍后再检查。", "The update service has asked us to check again later.")
        case .releaseInvalid: return L("版本信息暂时无法核实，将稍后重试。", "Release information could not be verified. We will retry later.")
        case .policyUnavailable: return L("无法读取更新方式，将自动重试。", "Could not read the update policy. We will retry automatically.")
        case .policyInvalid: return L("更新方式校验失败，未自动安装。", "The update policy could not be verified. No automatic installation was started.")
        case .withdrawn: return L("该版本已撤回或发布内容已变化，请重新检查更新。", "This release was withdrawn or changed. Check for updates again.")
        }
    }
}

enum UpdateStatus: Equatable {
    case idle, checking, current, noRelease, available, deferred, ignored
    case failed(UpdateCheckIssue), downloading, verifying, restarting, installationFailed(String), restored
}

@MainActor final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    @Published private(set) var includesBeta: Bool
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var lastSuccessfulCheckAt: Date?
    @Published private(set) var nextRetryAt: Date?
    @Published private(set) var available: GitHubRelease?
    @Published private(set) var showsPanelUpdate = false
    var installFailed: Bool { if case .installationFailed = status { return true }; return false }
    var message: String {
        switch status {
        case .idle: return ""
        case .checking: return L("正在检查更新…", "Checking for updates…")
        case .current: return L("已是最新版本", "You're up to date")
        case .noRelease: return includesBeta ? L("暂未找到公开版本。", "No public release is available yet.") : L("暂未找到公开的正式版本。", "No public stable release is available yet.")
        case .available: return available.map { L("发现新版本 \($0.tagName)。", "Update available: \($0.tagName).") } ?? ""
        case .deferred: return L("新版本正逐步开放，也可手动下载。", "The update is rolling out gradually. You can also download it manually.")
        case .ignored: return available.map { L("已忽略 \($0.tagName)。", "Ignored \($0.tagName).") } ?? ""
        case .failed(let issue): return issue.message
        case .downloading: return L("正在下载更新…", "Downloading update…")
        case .verifying: return L("正在校验更新包…", "Verifying update…")
        case .restarting: return L("正在安装，应用即将重新启动…", "Installing. The app will restart shortly…")
        case .installationFailed(let message): return message
        case .restored: return L("新版未能正常启动，已恢复之前的版本。", "The update could not start successfully. The previous version was restored.")
        }
    }
    var detailMessage: String? { status == .available || status == .idle ? nil : message }
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var started = false
    private var hasCheckedThisSession = false
    private var needsChannelCheck: Bool
    private var serverNotBefore: Date?
    private var failures: Int
    private var presenting = false
    private var ignoreRevision = 0
    private var channelRevision = 0
    private var availablePolicy: VerifiedUpdatePolicy?
    private let repository: String
    private struct CachedResponse { let data: Data; let etag: String?; let modified: String? }
    private var responses: [String:CachedResponse] = [:]
    private var pathMonitor: NWPathMonitor?
    private var pathWasUnavailable = false
    var onNetworkRecovery: (() -> Void)?
    // Injectable boundaries keep integration tests away from installed apps.
    private let installOperation: ((GitHubRelease, Bool) async throws -> Void)?
    private let stagingOperation: ((GitHubRelease, Bool) async throws -> URL)?
    private let replacementOperation: ((URL, Bool) throws -> Void)?
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
         stagingOperation: ((GitHubRelease, Bool) async throws -> URL)? = nil,
         replacementOperation: ((URL, Bool) throws -> Void)? = nil,
         presentation: ((GitHubRelease) -> Void)? = nil, releaseOpener: ((URL) -> Void)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults=defaults;self.repository=repository;self.currentVersion=currentVersion
        includesBeta = defaults.bool(forKey:"updates.includesBeta")
        self.installOperation=installOperation;self.stagingOperation=stagingOperation;self.replacementOperation=replacementOperation
        self.presentation=presentation;self.releaseOpener=releaseOpener;self.now=now
        lastSuccessfulCheckAt = defaults.object(forKey:"updates.lastSuccessfulCheck") as? Date
        nextRetryAt = defaults.object(forKey:"updates.nextRetry") as? Date
        serverNotBefore = defaults.object(forKey:"updates.serverNotBefore") as? Date
        failures = max(0,min(20,defaults.integer(forKey:"updates.failures")))
        needsChannelCheck = defaults.bool(forKey:"updates.channelNeedsCheck")
        if failures > 0 { status = .failed(UpdateCheckIssue(rawValue:defaults.string(forKey:"updates.lastIssue") ?? "") ?? .network) }
        configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=20
        configuration.urlCache=nil;configuration.httpCookieStorage=nil
        session=URLSession(configuration:configuration,delegate:UpdateRedirectDelegate(),delegateQueue:nil)
        if !UpdatePolicy.validRepository(repository) { status = .failed(.releaseInvalid) }
    }
    deinit { timer?.invalidate();pathMonitor?.cancel();session.invalidateAndCancel() }
    func start() {
        guard !started, configured else { return };started=true
        schedule(after:15)
        let monitor = NWPathMonitor();pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = reachable && (self.pathWasUnavailable || self.status == .failed(.network))
                self.pathWasUnavailable = !reachable
                if recovered { self.networkRecovered();self.onNetworkRecovery?() }
            }
        }
        monitor.start(queue:DispatchQueue(label:"com.duoduocat.codexbuddy.update-network",qos:.utility))
    }
    private func schedule(after interval: TimeInterval) {
        guard started else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:max(1,interval),repeats:false) { [weak self] _ in
            Task { @MainActor in self?.check(manual:false) }
        }
        timer?.tolerance = min(60,max(1,interval*0.05))
    }
    private func scheduleNext() {
        let due = max(needsChannelCheck ? now() : nextRetryAt ?? lastSuccessfulCheckAt?.addingTimeInterval(6*3600) ?? now(),serverNotBefore ?? now())
        schedule(after:due.timeIntervalSince(now()))
    }
    func networkRecovered() {
        guard case .failed(.network) = status, serverNotBefore == nil || serverNotBefore! <= now() else { return }
        nextRetryAt = now();defaults.set(nextRetryAt,forKey:"updates.nextRetry")
        if started { schedule(after:1) }
    }
    func setIncludesBeta(_ value: Bool) {
        guard !installing, value != includesBeta else { return }
        includesBeta = value;defaults.set(value,forKey:"updates.includesBeta");channelRevision += 1
        if !value, available?.isBeta == true { clearOffer();status = .idle }
        needsChannelCheck=true;defaults.set(true,forKey:"updates.channelNeedsCheck")
        nextRetryAt=nil;defaults.removeObject(forKey:"updates.nextRetry")
        if !checking, configured { check(manual:false) }
    }
    private struct CheckFailure: Error { let issue: UpdateCheckIssue; var notBefore: Date? = nil }
    static func retryDate(response: HTTPURLResponse, now: Date) -> Date? {
        if let value = response.value(forHTTPHeaderField:"Retry-After") {
            if let seconds=Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(min(seconds,604800)) }
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
            formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date=formatter.date(from:value), date > now { return date }
        }
        if response.value(forHTTPHeaderField:"X-RateLimit-Remaining") == "0",
           let raw=response.value(forHTTPHeaderField:"X-RateLimit-Reset"), let seconds=Double(raw), seconds.isFinite {
            return max(now,Date(timeIntervalSince1970:seconds))
        }
        return nil
    }
    private func fetch(_ url: URL, limit: Int, missingAllowed: Bool = false) async throws -> Data? {
        if let date=serverNotBefore, date > now() { throw CheckFailure(issue:.rateLimited,notBefore:date) }
        let key=url.absoluteString, cached=responses[url.absoluteString]
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version")
        request.setValue("Codex-Buddy/\(currentVersion)",forHTTPHeaderField:"User-Agent")
        if let etag=cached?.etag { request.setValue(etag,forHTTPHeaderField:"If-None-Match") }
        else if let modified=cached?.modified { request.setValue(modified,forHTTPHeaderField:"If-Modified-Since") }
        let data: Data, response: URLResponse
        do { (data,response)=try await session.data(for:request) }
        catch { throw CheckFailure(issue:.network) }
        guard let http=response as? HTTPURLResponse else { throw CheckFailure(issue:.releaseInvalid) }
        if http.statusCode == 304, let cached { return cached.data }
        if http.statusCode == 404, missingAllowed { responses.removeValue(forKey:key);return nil }
        if [403,429].contains(http.statusCode) { throw CheckFailure(issue:.rateLimited,notBefore:Self.retryDate(response:http,now:now()) ?? now().addingTimeInterval(60)) }
        if http.statusCode >= 500 { throw CheckFailure(issue:.server,notBefore:Self.retryDate(response:http,now:now())) }
        guard http.statusCode == 200, !data.isEmpty, data.count <= limit else { throw CheckFailure(issue:.releaseInvalid) }
        responses[key]=CachedResponse(data:data,etag:http.value(forHTTPHeaderField:"ETag"),modified:http.value(forHTTPHeaderField:"Last-Modified"))
        return data
    }
    private func releases(includeBeta: Bool) async throws -> [GitHubRelease] {
        let base="https://api.github.com/repos/\(repository)/releases"
        var values: [GitHubRelease] = []
        if let data=try await fetch(URL(string:base+"/latest")!,limit:2_000_000,missingAllowed:true) {
            guard let stable=try? JSONDecoder().decode(GitHubRelease.self,from:data), stable.publishedURL(repository:repository) != nil else { throw CheckFailure(issue:.releaseInvalid) }
            values.append(stable)
        }
        if includeBeta, let data=try await fetch(URL(string:base+"?per_page=100")!,limit:2_000_000,missingAllowed:true) {
            guard let listed=try? JSONDecoder().decode([GitHubRelease].self,from:data), listed.count <= 100 else { throw CheckFailure(issue:.releaseInvalid) }
            // Only the recommended stable release is eligible, even in Beta mode.
            values += listed.filter { $0.isBeta && $0.publishedURL(repository:repository,includeBeta:true) != nil }
        }
        return values
    }
    private func policy(for release: GitHubRelease) async throws -> VerifiedUpdatePolicy {
        guard release.assets.contains(where:{ $0.name == "update-policy.json" }) else {
            return VerifiedUpdatePolicy(mode:release.isImportant ? .notify : .none)
        }
        guard let asset=release.policyAsset(repository:repository), let url=URL(string:asset.browserDownloadURL ?? "") else { throw CheckFailure(issue:.policyInvalid) }
        let data: Data
        do {
            guard let value=try await fetch(url,limit:4096) else { throw CheckFailure(issue:.policyUnavailable) }
            data=value
        } catch let failure as CheckFailure {
            throw CheckFailure(issue:[.rateLimited,.network].contains(failure.issue) ? failure.issue : .policyUnavailable,notBefore:failure.notBefore)
        }
        guard let policy=UpdatePolicy.verified(data:data,asset:asset,tag:release.tagName) else { throw CheckFailure(issue:.policyInvalid) }
        return policy
    }
    private func installationID() -> String {
        if let value=defaults.string(forKey:"updates.rolloutID"), UUID(uuidString:value) != nil { return value }
        let value=UUID().uuidString;defaults.set(value,forKey:"updates.rolloutID");return value
    }
    private func eligible(_ policy: VerifiedUpdatePolicy) -> Bool {
        policy.rolloutPercentage == 100 || policy.permitsBackgroundUpdate(repository:repository,installationID:installationID())
    }
    private func succeeded() {
        lastSuccessfulCheckAt=now();defaults.set(lastSuccessfulCheckAt,forKey:"updates.lastSuccessfulCheck")
        failures=0;nextRetryAt=nil;serverNotBefore=nil
        for key in ["updates.failures","updates.nextRetry","updates.serverNotBefore","updates.lastAttempt","updates.lastIssue"] { defaults.removeObject(forKey:key) }
    }
    private func failed(_ error: Error) {
        let failure=error as? CheckFailure ?? CheckFailure(issue:.network)
        defaults.set(failure.issue.rawValue,forKey:"updates.lastIssue")
        failures=min(20,failures+1);defaults.set(failures,forKey:"updates.failures")
        let intervals: [TimeInterval]=[60,300,900,3600]
        serverNotBefore=failure.notBefore
        if let date=serverNotBefore { defaults.set(date,forKey:"updates.serverNotBefore") }
        else { defaults.removeObject(forKey:"updates.serverNotBefore") }
        nextRetryAt=max(now().addingTimeInterval(intervals[min(failures-1,3)]),serverNotBefore ?? now())
        defaults.set(nextRetryAt,forKey:"updates.nextRetry");status = .failed(failure.issue)
    }
    private func clearOffer() {
        available=nil;availablePolicy=nil;showsPanelUpdate=false;defaults.set(false,forKey:"updates.restorePanelOffer")
    }
    func check(manual: Bool) {
        guard !checking, !presenting, !installing, configured else { return }
        if let date=serverNotBefore, date > now() { status = .failed(.rateLimited);scheduleNext();return }
        let restoreOffer = !hasCheckedThisSession && defaults.bool(forKey:"updates.restorePanelOffer")
        if !manual, !restoreOffer, !needsChannelCheck {
            let due=nextRetryAt ?? lastSuccessfulCheckAt?.addingTimeInterval(6*3600)
            if let due, due > now() { scheduleNext();return }
        }
        hasCheckedThisSession=true;checking=true;status = .checking;timer?.invalidate()
        needsChannelCheck=false;defaults.removeObject(forKey:"updates.channelNeedsCheck")
        let ignoreTicket=ignoreRevision, channelTicket=channelRevision, includeBeta=includesBeta
        Task {
            defer {
                checking=false
                if channelTicket != channelRevision { check(manual:false) }
                else { scheduleNext() }
            }
            do {
                let values=try await releases(includeBeta:includeBeta)
                guard !installing, channelTicket == channelRevision else { return }
                guard let release=UpdatePolicy.latestRelease(values,repository:repository,includeBeta:includeBeta) else {
                    clearOffer();status = .noRelease;succeeded();return
                }
                guard let latest=AppVersion(release.tagName), let current=AppVersion(currentVersion) else { throw CheckFailure(issue:.releaseInvalid) }
                guard latest > current else { clearOffer();status = .current;succeeded();return }
                let policy=try await policy(for:release)
                guard !installing, channelTicket == channelRevision else { return }
                let ignored=defaults.stringArray(forKey:"updates.ignored") ?? []
                let announced=defaults.stringArray(forKey:"updates.announced") ?? []
                let manualOffer=manual && !(ignoreTicket != ignoreRevision && ignored.contains(release.tagName))
                available=release;availablePolicy=policy;status = .available;succeeded()
                let permitted=manualOffer || eligible(policy)
                showsPanelUpdate=permitted && (manualOffer || policy.mode == .notify) && (manualOffer || !ignored.contains(release.tagName)) && policy.mode != .silent
                defaults.set(showsPanelUpdate && policy.mode == .notify,forKey:"updates.restorePanelOffer")
                guard permitted else { status = .deferred;return }
                if !manualOffer, (defaults.stringArray(forKey:"updates.failedVersions") ?? []).contains(release.tagName) {
                    showsPanelUpdate=false;defaults.set(false,forKey:"updates.restorePanelOffer");status = .restored;return
                }
                switch UpdatePolicy.action(release:release,mode:policy.mode,current:currentVersion,manual:manualOffer,ignored:ignored,announced:announced,includeBeta:includeBeta) {
                case .install: installAvailable(silent:true,manual:manualOffer)
                case .notify: present(release)
                case .none: break
                }
            } catch { if !installing, channelTicket == channelRevision { failed(error) } }
        }
    }
    private func revalidate(_ release: GitHubRelease, silent: Bool, manual: Bool) async throws {
        let values=try await releases(includeBeta:includesBeta)
        guard let current=UpdatePolicy.latestRelease(values,repository:repository,includeBeta:includesBeta),
              current.tagName == release.tagName, current.assets == release.assets,
              current.publishedURL(repository:repository,includeBeta:includesBeta) != nil else { throw CheckFailure(issue:.withdrawn) }
        let fresh=try await policy(for:current)
        guard fresh == availablePolicy, !silent || fresh.mode == .silent else { throw CheckFailure(issue:.withdrawn) }
        if silent, !manual {
            guard !(defaults.stringArray(forKey:"updates.ignored") ?? []).contains(release.tagName), eligible(fresh) else { throw CheckFailure(issue:.withdrawn) }
        }
    }
    func installAvailable(silent: Bool = false, manual: Bool = true) {
        guard !installing, let release=available,
              release.publishedURL(repository:repository,includeBeta:includesBeta) != nil else { return }
        installing=true;status = .downloading
        if !silent { beforeInstall?() }
        Task {
            var staged: URL?
            do {
                try await revalidate(release,silent:silent,manual:manual)
                if let installOperation { try await installOperation(release,silent);installing=false;status = .available;return }
                let target=Bundle.main.bundleURL
                let work: URL
                if let stagingOperation { work=try await stagingOperation(release,includesBeta) }
                else {
                    work=try await UpdateInstaller.stage(release:release,repository:repository,target:target,includeBeta:includesBeta) { phase in
                        self.status = phase == .downloading ? .downloading : .verifying
                    }
                }
                staged=work
                // Verify eligibility again after download, immediately before replacing.
                try await revalidate(release,silent:silent,manual:manual)
                status = .restarting
                if let replacementOperation { try replacementOperation(work,silent);installing=false }
                else { try UpdateInstaller.replaceAndRelaunch(staged:work,target:target,background:silent) }
            } catch {
                if let staged, stagingOperation == nil { UpdateInstaller.discardStaged(staged,target:Bundle.main.bundleURL) }
                if let failure=error as? CheckFailure {
                    if failure.issue == .withdrawn { clearOffer() }
                    failed(failure)
                } else { status = .installationFailed((error as? UpdateInstallFailure)?.localizedDescription ?? L("更新失败，当前版本未被替换。", "Update failed. Your current version has not been replaced.")) }
                installing=false
                scheduleNext()
            }
        }
    }
    func openRelease() {
        guard let url=available?.publishedURL(repository:repository,includeBeta:includesBeta) else { return }
        if let releaseOpener { releaseOpener(url);return };NSWorkspace.shared.open(url)
    }
    func ignoreAvailable() {
        guard let release=available else { return };ignoreRevision += 1
        var versions=defaults.stringArray(forKey:"updates.ignored") ?? []
        if !versions.contains(release.tagName) { versions.append(release.tagName) }
        defaults.set(Array(versions.suffix(100)),forKey:"updates.ignored")
        showsPanelUpdate=false;defaults.set(false,forKey:"updates.restorePanelOffer");status = .ignored
    }
    private func present(_ release: GitHubRelease) {
        guard !presenting else { return };presenting=true;defer { presenting=false };showsPanelUpdate=true
        var versions=defaults.stringArray(forKey:"updates.announced") ?? []
        if !versions.contains(release.tagName) { versions.append(release.tagName) }
        defaults.set(versions,forKey:"updates.announced");presentation?(release)
    }
    func reportRestoredUpdate(failedVersion: String) {
        guard AppVersion(failedVersion) != nil else { return }
        let tag=failedVersion.hasPrefix("v") ? failedVersion : "v"+failedVersion
        var values=defaults.stringArray(forKey:"updates.failedVersions") ?? []
        if !values.contains(tag) { values.append(tag) }
        defaults.set(Array(values.suffix(20)),forKey:"updates.failedVersions");status = .restored
    }
}
