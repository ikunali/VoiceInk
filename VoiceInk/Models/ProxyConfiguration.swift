import Foundation
import SystemConfiguration

// MARK: - Proxy Type

enum ProxyType: String, Codable, CaseIterable, Identifiable {
    case http = "HTTP"
    case https = "HTTPS"
    case socks5 = "SOCKS5"

    var id: String { rawValue }

    var systemConfigurationKey: String {
        switch self {
        case .http:  kSCPropNetProxiesHTTPEnable as String
        case .https: kSCPropNetProxiesHTTPSEnable as String
        case .socks5: kSCPropNetProxiesSOCKSEnable as String
        }
    }

    var systemConfigurationHostKey: String {
        switch self {
        case .http:  kSCPropNetProxiesHTTPProxy as String
        case .https: kSCPropNetProxiesHTTPSProxy as String
        case .socks5: kSCPropNetProxiesSOCKSProxy as String
        }
    }

    var systemConfigurationPortKey: String {
        switch self {
        case .http:  kSCPropNetProxiesHTTPPort as String
        case .https: kSCPropNetProxiesHTTPSPort as String
        case .socks5: kSCPropNetProxiesSOCKSPort as String
        }
    }
}

// MARK: - ProxyConfiguration

struct ProxyConfiguration: Codable, Equatable {
    var type: ProxyType = .http
    var host: String = ""
    var port: UInt16 = 8080
    var username: String = ""
    var password: String = ""
    /// Skip all TLS certificate validation. Use only on trusted networks (e.g. local MITM proxy).
    var ignoreSslErrors: Bool = false
    /// DER-encoded CA certificate to trust instead of system roots. Takes priority over ignoreSslErrors.
    var customCACertificateData: Data? = nil

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0
    }

    /// Provides the `connectionProxyDictionary` value for `URLSessionConfiguration`.
    var proxyDictionary: [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [:]

        switch type {
        case .http:
            dict[kCFNetworkProxiesHTTPEnable as String] = true
            dict[kCFNetworkProxiesHTTPProxy as String] = host
            dict[kCFNetworkProxiesHTTPPort as String] = port
        case .https:
            dict[kCFNetworkProxiesHTTPSEnable as String] = true
            dict[kCFNetworkProxiesHTTPSProxy as String] = host
            dict[kCFNetworkProxiesHTTPSPort as String] = port
        case .socks5:
            dict[kCFNetworkProxiesSOCKSEnable as String] = true
            dict[kCFNetworkProxiesSOCKSProxy as String] = host
            dict[kCFNetworkProxiesSOCKSPort as String] = port
        }

        // Add authentication if provided
        if !username.isEmpty {
            dict[kCFProxyUsernameKey as String] = username
            dict[kCFProxyPasswordKey as String] = password
        }

        return dict
    }
}
