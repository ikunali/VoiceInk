import AppKit
import SwiftUI

struct ProxySettingsView: View {
    @ObservedObject private var proxyManager = ProxySettingsManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $proxyManager.isProxyEnabled) {
                    Text("Use Proxy")
                }
                .toggleStyle(.switch)

                if proxyManager.isProxyEnabled {
                    Toggle(isOn: $proxyManager.autoDetectProxy) {
                        Text("Auto-Detect System Proxy")
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                Text("Proxy")
            } footer: {
                if proxyManager.isProxyEnabled {
                    Text("Route model downloads through a proxy server")
                }
            }

            if proxyManager.isProxyEnabled && !proxyManager.autoDetectProxy {
                Section {
                    Picker("Type", selection: $proxyManager.manualConfig.type) {
                        ForEach(ProxyType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Host", text: $proxyManager.manualConfig.host,
                              prompt: Text("proxy.example.com"))

                    TextField("Port", text: portString,
                              prompt: Text("8080"))

                    TextField("Username", text: $proxyManager.manualConfig.username,
                              prompt: Text("Optional"))

                    SecureField("Password", text: $proxyManager.manualConfig.password,
                                prompt: Text("Optional"))
                } header: {
                    Text("Manual Configuration")
                }

                Section {
                    caCertRow

                    if proxyManager.manualConfig.customCACertificateData == nil {
                        Toggle(isOn: $proxyManager.manualConfig.ignoreSslErrors) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ignore SSL Errors")
                                Text("Disables certificate validation. Only use on trusted networks.")
                                    .font(.caption)
                                    .foregroundColor(proxyManager.manualConfig.ignoreSslErrors ? .orange : .secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                } header: {
                    Text("Security")
                }

                Section {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(proxyManager.isProxyReachable ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)

                        Text(proxyManager.isProxyReachable ? "Proxy reachable" : "Proxy status unknown")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Spacer()

                        Button("Check") {
                            Task { await proxyManager.checkProxyReachability() }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                    }
                } header: {
                    Text("Status")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .animation(.smooth(duration: 0.25), value: proxyManager.isProxyEnabled)
        .animation(.smooth(duration: 0.25), value: proxyManager.autoDetectProxy)
    }

    // MARK: - Port binding

    private var portString: Binding<String> {
        Binding(
            get: { String(proxyManager.manualConfig.port) },
            set: { if let v = UInt16($0), v <= 65535 { proxyManager.manualConfig.port = v } }
        )
    }

    // MARK: - CA Certificate Row

    private var caCertRow: some View {
        if proxyManager.manualConfig.customCACertificateData != nil {
            return AnyView(loadedCertRow)
        } else {
            return AnyView(
                Button("CA Certificate: Choose…") { pickCACertificate() }
                    .buttonStyle(.borderless)
            )
        }
    }

    private var loadedCertRow: some View {
        let summary: String = {
            guard let data = proxyManager.manualConfig.customCACertificateData,
                  let cert = SecCertificateCreateWithData(nil, data as CFData) else { return "Certificate" }
            return (SecCertificateCopySubjectSummary(cert) as String?) ?? "Certificate"
        }()
        return HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.green)
            Text(summary)
                .lineLimit(1)
            Spacer()
            Button {
                proxyManager.manualConfig.customCACertificateData = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func pickCACertificate() {
        let panel = NSOpenPanel()
        panel.title = "Choose CA Certificate"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Select a DER (.cer, .der) or PEM (.pem, .crt) certificate file"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return }

        let derData: Data
        if let pem = String(data: data, encoding: .utf8),
           pem.contains("-----BEGIN CERTIFICATE-----") {
            derData = pemToDer(pem) ?? data
        } else {
            derData = data
        }

        guard SecCertificateCreateWithData(nil, derData as CFData) != nil else { return }
        proxyManager.manualConfig.customCACertificateData = derData
    }

    private func pemToDer(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        return Data(base64Encoded: lines.joined())
    }
}
