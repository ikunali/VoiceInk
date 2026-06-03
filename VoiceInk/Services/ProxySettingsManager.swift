import Atomics
import Foundation
import Network
import SystemConfiguration
import os

// MARK: - ProxySettingsManager

/// Manages proxy configuration for model downloads.
///
/// Supports auto-detecting macOS system-wide proxy settings via `SystemConfiguration`,
/// as well as manual proxy configuration stored in `UserDefaults`.
@MainActor
class ProxySettingsManager: ObservableObject {
    static let shared = ProxySettingsManager()

    // MARK: - Published State

    @Published var isProxyEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isProxyEnabled, forKey: Self.proxyEnabledKey)
            syncProxyEnvVars()
        }
    }

    @Published var autoDetectProxy: Bool = true {
        didSet {
            UserDefaults.standard.set(autoDetectProxy, forKey: Self.autoDetectKey)
            syncProxyEnvVars()
        }
    }

    @Published var manualConfig: ProxyConfiguration = .init() {
        didSet {
            saveManualConfig()
            syncProxyEnvVars()
        }
    }

    // MARK: - Derived State

    /// The effective proxy configuration currently in use (either auto-detected or manual).
    var effectiveConfiguration: ProxyConfiguration? {
        guard isProxyEnabled else { return nil }

        if autoDetectProxy, let system = detectSystemProxy() {
            return system
        }

        return manualConfig.isValid ? manualConfig : nil
    }

    /// Whether the effective proxy appears reachable.
    @Published var isProxyReachable: Bool = false

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ProxySettingsManager")

    // MARK: - UserDefaults Keys

    private static let proxyEnabledKey = "proxyEnabled"
    private static let autoDetectKey = "proxyAutoDetect"
    private static let manualConfigKey = "proxyManualConfig"

    // MARK: - Init

    private init() {
        loadPersistedState()
    }

    // MARK: - Environment Variable Proxy Sync

    /// Syncs the current proxy configuration to https_proxy / http_proxy environment variables
    /// so that third-party SDKs (e.g. FluidAudio) that read env vars pick up proxy settings.
    func syncProxyEnvVars() {
        if let proxy = effectiveConfiguration {
            let scheme = proxy.type == .socks5 ? "socks5" : "http"
            let proxyURL = "\(scheme)://\(proxy.host):\(proxy.port)"
            setenv("https_proxy", proxyURL, 1)
            setenv("http_proxy", proxyURL, 1)
            logger.notice("Proxy env vars synced: \(proxyURL, privacy: .public)")
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("Proxy env vars synced: \(proxyURL)", category: "ProxySettingsManager")
            #endif
        } else {
            unsetenv("https_proxy")
            unsetenv("http_proxy")
        }
    }

    // MARK: - URLSessionConfiguration Factory

    /// Returns a `URLSessionConfiguration` with proxy settings applied, or the default ephemeral
    /// configuration when proxy is disabled.
    func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral

        if let proxy = effectiveConfiguration {
            config.connectionProxyDictionary = proxy.proxyDictionary
            logger.notice("Proxy configured: \(proxy.type.rawValue) \(proxy.host):\(proxy.port)")
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("URLSession proxy configured: \(proxy.type.rawValue) \(proxy.host):\(proxy.port)", category: "ProxySettingsManager")
            #endif
        } else {
            logger.notice("No proxy configured, using direct connection")
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("URLSession: no proxy, direct connection", category: "ProxySettingsManager")
            #endif
        }

        // Increase timeouts for potentially slower proxy connections
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600

        return config
    }

    /// Creates a `URLSession` configured with the current proxy settings.
    /// Automatically attaches an SSL delegate when the config has SSL overrides.
    func makeSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let config = makeSessionConfiguration()
        let effectiveDelegate = delegate ?? ProxySSLDelegate.make(for: effectiveConfiguration)
        return effectiveDelegate.map { URLSession(configuration: config, delegate: $0, delegateQueue: nil) }
            ?? URLSession(configuration: config)
    }

    // MARK: - System Proxy Detection

    /// Detects system-wide proxy settings using `SystemConfiguration` framework.
    func detectSystemProxy() -> ProxyConfiguration? {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            logger.notice("System proxy detection: no proxy settings found")
            return nil
        }

        // Try HTTPS proxy first, then HTTP, then SOCKS5
        if let httpsEnabled = proxies[kSCPropNetProxiesHTTPSEnable as String] as? Bool, httpsEnabled,
           let host = proxies[kSCPropNetProxiesHTTPSProxy as String] as? String,
           let port = proxies[kSCPropNetProxiesHTTPSPort as String] as? Int, port > 0 {
            logger.notice("System proxy detected: HTTPS \(host):\(port)")
            return ProxyConfiguration(type: .https, host: host, port: UInt16(port))
        }

        if let httpEnabled = proxies[kSCPropNetProxiesHTTPEnable as String] as? Bool, httpEnabled,
           let host = proxies[kSCPropNetProxiesHTTPProxy as String] as? String,
           let port = proxies[kSCPropNetProxiesHTTPPort as String] as? Int, port > 0 {
            logger.notice("System proxy detected: HTTP \(host):\(port)")
            return ProxyConfiguration(type: .http, host: host, port: UInt16(port))
        }

        if let socksEnabled = proxies[kSCPropNetProxiesSOCKSEnable as String] as? Bool, socksEnabled,
           let host = proxies[kSCPropNetProxiesSOCKSProxy as String] as? String,
           let port = proxies[kSCPropNetProxiesSOCKSPort as String] as? Int, port > 0 {
            logger.notice("System proxy detected: SOCKS5 \(host):\(port)")
            return ProxyConfiguration(type: .socks5, host: host, port: UInt16(port))
        }

        logger.notice("System proxy detection: no enabled proxy found")
        #if LOCAL_BUILD
        DebugFileLogger.shared.write("System proxy detection: no enabled proxy found", category: "ProxySettingsManager")
        #endif
        return nil
    }

    /// Checks reachability of the configured proxy by attempting a TCP connection.
    func checkProxyReachability() async {
        guard let config = effectiveConfiguration else {
            isProxyReachable = false
            return
        }

        let host = config.host
        let port = config.port

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 8080,
            using: .tcp
        )

        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finished = ManagedAtomic(false)

            func resumeOnce(_ value: Bool) {
                if finished.exchange(true, ordering: .acquiring) == false {
                    continuation.resume(returning: value)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    resumeOnce(true)
                case .failed:
                    resumeOnce(false)
                default:
                    break
                }
            }

            let queue = DispatchQueue(label: "com.voiceink.proxy-reachability")
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 5) {
                connection.cancel()
                resumeOnce(false)
            }
        }

        isProxyReachable = reachable
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        isProxyEnabled = UserDefaults.standard.bool(forKey: Self.proxyEnabledKey)
        autoDetectProxy = UserDefaults.standard.bool(forKey: Self.autoDetectKey)

        if let data = UserDefaults.standard.data(forKey: Self.manualConfigKey),
           let config = try? JSONDecoder().decode(ProxyConfiguration.self, from: data) {
            manualConfig = config
        }
    }

    private func saveManualConfig() {
        if let data = try? JSONEncoder().encode(manualConfig) {
            UserDefaults.standard.set(data, forKey: Self.manualConfigKey)
        }
    }
}

// MARK: - ProxySSLDelegate

/// URLSessionDelegate that handles SSL challenges for MITM proxies.
/// Used automatically by ProxySettingsManager.makeSession() when the proxy config
/// has ignoreSslErrors or a custom CA certificate set.
final class ProxySSLDelegate: NSObject, URLSessionDelegate {
    private let ignoreSslErrors: Bool
    private let customCACertData: Data?

    private init(ignoreSslErrors: Bool, customCACertData: Data?) {
        self.ignoreSslErrors = ignoreSslErrors
        self.customCACertData = customCACertData
    }

    /// Returns a delegate only when SSL overrides are actually needed.
    static func make(for config: ProxyConfiguration?) -> ProxySSLDelegate? {
        guard let config, config.ignoreSslErrors || config.customCACertificateData != nil else { return nil }
        return ProxySSLDelegate(ignoreSslErrors: config.ignoreSslErrors, customCACertData: config.customCACertificateData)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Custom CA cert takes priority: trust only that cert.
        if let certData = customCACertData,
           let cert = SecCertificateCreateWithData(nil, certData as CFData) {
            SecTrustSetAnchorCertificates(serverTrust, [cert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
            var error: CFError?
            if SecTrustEvaluateWithError(serverTrust, &error) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // Fallback: bypass all cert validation (only when no custom CA is set).
        if ignoreSslErrors {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
