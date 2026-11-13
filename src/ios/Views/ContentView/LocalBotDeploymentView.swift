import SwiftUI

/// Local-only SnowLuma + QQBot deployment wizard.
///
/// It deliberately opens the existing iSH terminal with a prefilled command
/// rather than executing a long-running install from the SwiftUI main actor.
/// The user must press Return in the terminal to start each operation.
struct LocalBotDeploymentView: View {
    @Binding var showTerminal: Bool
    @Binding var localBotCommand: String
    @State private var qqUin = ""

    private var normalizedUin: String {
        qqUin.filter(\.isNumber)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("本机部署", systemImage: "iphone.and.arrow.forward")
                        .font(.headline)
                    Text("SnowLuma + QQBot 只运行在这台 iPhone 的 iSH 沙盒中。不会连接共享协议端，也不会读取旧的远端配置。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("1. 安装本机组件") {
                Text("安装 ARM64 Python 依赖、SnowLuma 核心和 ARM64 go-cqhttp。安装脚本只生成本地回环配置，不会启动服务或登录 QQ。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    openTerminal(command: "sh /opt/amore-localbot/install-local.sh")
                } label: {
                    Label("打开 iSH 安装终端", systemImage: "terminal")
                }
                .accessibilityHint(Text("在终端中按回车执行安装"))
            }

            Section("2. QQ 登录") {
                TextField("QQ 号码（只保存到本机配置）", text: $qqUin)
                    .keyboardType(.numberPad)
                    .textContentType(.username)
                Text("登录使用本机二维码。QQ 号码不会发送到 Amore、SnowLuma 服务器或任何共享协议端。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    guard !normalizedUin.isEmpty else { return }
                    openTerminal(command: "sed -i 's/^  uin: .*/  uin: \(normalizedUin)/' /opt/snowluma-qqbot/protocol/config.yml && /opt/snowluma-qqbot/start-protocol.sh")
                } label: {
                    Label("启动本机 QQ 协议端并扫码", systemImage: "qrcode.viewfinder")
                }
                .disabled(normalizedUin.isEmpty)
                .accessibilityHint(Text("在终端中按回车后显示二维码"))
            }

            Section("3. 启动 SnowLuma") {
                Text("默认连接本机协议端：OneBot WebSocket 127.0.0.1:3001。AI、插件和自动回复默认关闭，需要你在本机配置后再启用。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    openTerminal(command: "/opt/snowluma-qqbot/start-bot.sh")
                } label: {
                    Label("启动本机 SnowLuma", systemImage: "power")
                }
            }

            Section("安全说明") {
                Label("不使用共享协议端", systemImage: "checkmark.shield")
                Label("不携带旧配置、数据库、日志或 token", systemImage: "checkmark.shield")
                Label("服务只监听本机回环地址", systemImage: "checkmark.shield")
                Label("iOS 退后台后，iSH 进程可能被系统暂停", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SnowLuma + QQBot")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openTerminal(command: String) {
        localBotCommand = command
        showTerminal = true
    }
}

