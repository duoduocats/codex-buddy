import AppKit

enum PetLaunchError:Error,LocalizedError {
    case unavailable,invalidLink,failed
    var errorDescription:String? {
        switch self {
        case .unavailable:return L("未找到 Codex 桌面应用，请先安装或打开它，再重试。", "Codex desktop app could not be found. Install or open it, then retry.")
        case .invalidLink:return L("安装链接无效，请重新加载这个主题。", "The installation link is invalid. Reload this theme.")
        case .failed:return L("无法打开 Codex。请先手动打开桌面应用，再重试。", "Could not open Codex. Open the desktop app manually, then retry.")
        }
    }
}

// Opening the URL is only a handoff. It cannot confirm that Codex displayed or installed a pet.
@MainActor struct PetCodexLauncher {
    var applicationURL:() -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex")
    }
    var send:(URL,URL) async -> Bool = { link,application in
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([link],withApplicationAt:application,configuration:configuration) { running,error in
                continuation.resume(returning:running != nil && error == nil)
            }
        }
    }
    func open(_ url:URL) async -> Result<Void,PetLaunchError> {
        guard url.scheme == "codex",["pets","settings"].contains(url.host ?? "") else { return .failure(.invalidLink) }
        guard let application=applicationURL() else { return .failure(.unavailable) }
        return await send(url,application) ? .success(()) : .failure(.failed)
    }
}
