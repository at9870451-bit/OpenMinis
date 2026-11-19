import SwiftUI

/// Put this page inside the host's SessionLockStore gate. No new navigation root.
@MainActor
public struct AmoreDeviceStatusView: View {
    private let store = AmoreDeviceServices.statusStore
    public init() {}
    public var body: some View {
        let status = store.snapshot
        List {
            Section("本机状态") {
                LabeledContent("连接状态", value: status.title)
                LabeledContent("对象", value: "当前这台 iPhone / iPad")
                LabeledContent("自动化会话", value: status.sessionOn ? "已开启（不等于已连接）" : "未开启")
                LabeledContent("Runner", value: status.runnerState)
                LabeledContent("进程内会话", value: status.inProcessOpen ? "已打开" : "未打开")
                LabeledContent("外部回环探测", value: status.loopbackText)
                LabeledContent("配对记录", value: status.pairingPresent ? "存在（不等于已验证）" : "缺少")
                if let at = status.pairingVerifiedAt {
                    LabeledContent("最近配对验证") { Text(at, style: .date) + Text(" ") + Text(at, style: .time) }
                }
                LabeledContent("DeveloperMode", value: status.developerModeConfirmed ? "已确认（上次状态）" : "等待用户开启")
                LabeledContent("本机开发镜像", value: status.localDDIMounted ? "已挂载" : "未挂载 / 不可访问")
                if let problem = status.pairingProblem ?? status.problem { Text(problem).foregroundStyle(.orange) }
            }
            Section("内置连接路径") {
                ForEach(AmoreDeviceStatus.Transport.allCases) { transport in
                    Button {
                        _ = store.selectTransport(transport)
                    } label: {
                        HStack {
                            Text(transport.title)
                            Spacer()
                            if status.transport == transport { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(!store.canChangeTransport)
                    .accessibilityIdentifier("amore.transport.\(transport.rawValue)")
                }
                Text("选择只保存路径，不会启动 VPN、安装配对/证书、上传设备信息或声称已连接。请在连接页明确开启自动化。运行中或配对时不可更改。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("无需外部 VPN 的真实限制") {
                Text("进程内路径调用已有 PKInProcess / XCTest，不走系统 VPN。但要求您已明确配对、开启 Developer Mode，并在本次开机后挂载兼容的开发镜像；仍需 iOS 授权和支持的签名。没有这些条件不会伪造成功。")
                LabeledContent("原生 VPN 扩展", value: status.nativeTunnelAvailable ? "内置扩展已打包；仍需匹配签名与 iOS 授权" : "此构建未找到内置扩展")
                Text("原生 PacketTunnel 必须有 appex 和 Apple 允许的 NetworkExtension entitlement、匹配的签名与用户许可。普通重签不能凭空获得能力；不会自动启用，也不会替换已有 VPN。外部连接回退保留。")
            }.font(.footnote)
            Section {
                Button("刷新本机状态", systemImage: "arrow.clockwise") { store.refresh() }
                    .accessibilityIdentifier("amore.deviceStatus.refresh")
            }
        }
        .navigationTitle("本机连接状态")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
    }
}

/// The Amore host MUST wrap this page with SessionLockStore (like the existing
/// AmoreDevicePrompts). This library cannot decide whether the host app is locked.
@MainActor
public struct AmoreApprovalsPage: View {
    private let store = AmoreDeviceServices.statusStore
    @State private var now = Date()
    public init() {}
    public var body: some View {
        List {
            Section {
                Text("敏感操作默认需要您明确批准。这里使用原 PendingApproval → AppModel.resolve → PokiCore 规则；拒绝、过期和已结束的请求不会变成授权。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("待审批") {
                if store.pendingApprovals.isEmpty { Text("暂无待审批操作").foregroundStyle(.secondary) }
                ForEach(store.pendingApprovals) { approval in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(approval.action).font(.headline)
                        LabeledContent("应用", value: approval.app)
                        Text("原因：\(approval.reason)").font(.subheadline)
                        LabeledContent("有效期至") { Text(approval.expires, style: .time) }
                        Text("ID：\(approval.id)").font(.caption).foregroundStyle(.secondary)
                        if approval.submitted { Text("已提交，等待 Core 确认").foregroundStyle(.secondary) }
                        else if approval.expires <= now { Text("已过期，不可批准").foregroundStyle(.orange) }
                        HStack {
                            Button("拒绝", role: .destructive) { decide(approval.id, approved: false) }
                            Spacer()
                            Button("批准") { decide(approval.id, approved: true) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!approval.canResolve(at: now))
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("amore.approval.\(approval.id)")
                }
            }
            Section("最近审批历史（最多 100 条）") {
                if store.recentApprovalHistory.isEmpty { Text("暂无审批历史").foregroundStyle(.secondary) }
                ForEach(store.recentApprovalHistory) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.action).font(.headline)
                        if let app = entry.app { Text(app).font(.subheadline) }
                        if let reason = entry.reason { Text("原因：\(reason)").font(.subheadline) }
                        Text(entry.detail ?? (entry.approved ? "已批准" : "未获批准 / 已过期"))
                            .foregroundStyle(entry.approved ? Color.green : Color.secondary)
                        Text(entry.at, style: .date) + Text(" ") + Text(entry.at, style: .time)
                    }
                }
                Text("历史沿用本机 ActionLog；上游旧记录不保存请求 ID/有效期，故不伪造，也不能从历史再次批准。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("刷新") { now = Date(); store.refresh() }
        }
        .navigationTitle("设备操作审批")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { now = Date(); store.refresh() }
        // Exactly one local deadline wake per nearest expiry, not a network poll.
        .task(id: store.pendingApprovals.filter { !$0.submitted && $0.expires > now }.map(\.expires).min()) {
            guard let next = store.pendingApprovals.filter({ !$0.submitted && $0.expires > now }).map(\.expires).min() else { return }
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05)) }
            catch { return }
            now = Date()
        }
    }
    private func decide(_ id: String, approved: Bool) {
        now = Date()
        AmoreDeviceServices.resolveApproval(id: id, approved: approved)
    }
}
