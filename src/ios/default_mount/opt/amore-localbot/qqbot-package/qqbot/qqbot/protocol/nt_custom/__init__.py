"""自研 QQ NT 协议后端。

模块结构（每一层都可独立自测）：
    crypto/    QQ TEA、secp256k1 / ECDH        —— 标准向量已验证
    packet/    protobuf 线格式、TCP 分帧        —— 往返已验证
    re/        PE 导出表解析等逆向工具
    signing    签名服务抽象（mock / http）      —— 协议生死闸门，见下
    session    设备指纹与会话票据持久化
    login      登录状态机（连接→握手→认证→在线）

===== 当前进度与阻塞点（诚实记录）=====

一、已完成且可验证
    - TEA：通过标准 TEA 32 轮已知向量 41ea3a0a94baa940；QQ 16 轮变体往返正确
    - ECDH：secp256k1 曲线运算通过 G / 2G 已知向量，协商对称性正确
    - protobuf：varint 边界、嵌套消息、fixed32/64 往返正确
    - 分帧：多帧、分片重组、半包、伪起始标记均已覆盖
    - 登录状态机：连接→ECDH 握手→认证→在线的编排逻辑可完整跑通

二、GO/NO-GO 取证结论（对 9.9.33 原生库的实测，工具见 re/pe.py）
    - QQNT.dll      204.6MB，3385 个导出：**它本身就是一个完整的 Node.js 运行时**
                    （导出 node::Start(int,char**) / node::CreateEnvironment /
                     153 个 NAPI 符号），且只依赖系统 DLL + ffmpeg.dll，
                    不依赖 QQ 业务 DLL 或 Electron 外壳
    - wrapper.node  109.8MB，66 个导出且**全部具名、0 个序号导出**，
                    因此**没有 napi_register_module_v1**；只依赖系统 DLL +
                    QQNT.dll（99 个符号，含 napi_* / v8::Isolate::GetCurrent）
    - 关键导出
                    nt::wrapper::INTSessionShell::CreateNTSessionShell(std::string const&)
                    连同虚表符号 ??_7INTSessionShell@wrapper@nt@@6B@ 都是具名导出，
                    虚表可直接定位
    - 实测：把 QQ 目录加入 DLL 搜索路径后，wrapper.node 及其全部依赖
                    （含 204MB 的 QQNT.dll）能被系统 Node.exe 成功加载，
                    但 Node 报 "Module did not self-register"
    => 结论：require 路线（系统 Node + wrapper.node）**已被证伪**；
       唯一的入口是直接调用导出的工厂函数 CreateNTSessionShell
       （但实测它还需要宿主环境，见第三节）。
       注意返回类型用的是 QQ 私有 STL 命名空间（__qq@std），跨模块
       调用 shared_ptr 的 ABI 需要小心处理。

三、路线 B 探针实测结果（工具 re/probe_shell.py，纯 ctypes，无需 C++ 编译器）
    加载 wrapper.node 成功（基址 0x7FF9A5990000，SizeOfImage 116.1MB），
    工厂符号可解析（RVA 0x275FA），但：

      [2.5] 工厂函数前 384 字节内没有任何指向 IAT 的调用（1108 个槽位已正确
            映射）——真正逻辑在更深的内部函数里
      [2.6] v8::Isolate::GetCurrent() -> NULL   <- 进程内没有 V8 运行时
      [3]   调用工厂 -> access violation reading 0x0000000000000002

    => **裁决：路线 B 的「轻量形态」不成立（NO-GO）。**
       CreateNTSessionShell 依赖 QQ 自己启动的 Node/V8 宿主环境；
       没有该环境，它一进去就解引用空指针。
       wrapper.node 从 QQNT.dll 导入 99 个符号（含 napi_* / v8 接口），
       QQNT.dll 又是完整的 Node 运行时（导出 node::Start），
       两者必须由 QQ 的宿主一起引导——这已经不是「调用一个导出」的量级。

四、若仍要走路线 B，只剩「重量形态」
    需要自己写宿主：引导 QQNT.dll 的 Node 运行时（node::Start /
    CreateEnvironment）-> 在其中注册我们自己的 napi 绑定 ->
    由该绑定去调 CreateNTSessionShell。属于多周的 C++ / 逆向工程，
    且 QQNT.dll 的 node::Start 会接管进程，等价于自研一个 Electron 宿主。

五、仍然无法在本环境完成的
    - 包布局逆向：字段号、TLV、TEA 密钥来源，需真机抓包比对
      （清单见 login.Handshake.PENDING）
    - 真机登录：依赖上面第三/四步的成果

六、寄生注入路线调研结论（NapCat.Shell v4.18.38 实解包取证）
    思路转变：不再「脱离 QQ 进程自建宿主」，而是「寄生进 QQ 进程」，
    让 QQ 自己算签名、自己封包——绕开第三节撞到的墙。

    NapCat.Shell 的注入链（解包后可见）：
        launcher.bat -> NapCatWinBootMain.exe(34KB) + NapCatWinBootHook.dll(21KB)
        -> 让 QQ 启动时加载 loadNapCat.js -> napcat.mjs(3MB)
        -> 在 QQ 进程内调 NodeIKernel* API
    它自带 native\napi2native\*.node 与 native\packet\MoeHoo.*.node，
    即「原生桥接 + 封包」这两个难点它已经自己解决了。
    config/napcat.json 里有 packetBackend(auto) / packetServer(外部签名服务兜底)。

    登录/二维码 API 面（从 napcat.mjs 实测提取，可直接照写）：
        NodeIKernelLoginService + addKernelLoginListener
        getQQLoginQrcodeURL / GetQQLoginQrcode / getQRCodePicture
        pngBase64QrcodeData            <- 二维码图片（base64 PNG），可直接给 WebUI 渲染
        回调：onQRCodeGetPicture / onQRCodeSessionUserScaned /
              onQRCodeLoginSucceed / onQRCodeSessionFailed /
              onQRCodeLoginPollingStarted / onRefreshQRCode / RefreshQRcode
        免密：GetQuickLoginList / GetQuickLoginQQ / SetQuickLoginQQ / getLoginList
        新设备：GetNewDeviceQRCode / PollNewDeviceQR / newDevicePullQrCodeSig

    战略判断：注入 + 原生桥接 + 封包三件事 NapCat 已开源解决，
    重造无意义。可自研的价值集中在「桥接层与我们的框架」——
    框架侧（事件总线/插件/WebUI/托盘）已完成，只需对接。
"""

from __future__ import annotations

from typing import Any

from ...log import get_logger
from ..base import EventSink, ProtocolBackend
from .login import Handshake, LoginMachine, LoginState, TcpTransport
from .session import DeviceProfile, SessionStore
from .signing import Signer, create_signer

log = get_logger("protocol.nt")

__all__ = [
    "NTBackend",
    "Handshake",
    "LoginMachine",
    "LoginState",
    "TcpTransport",
    "DeviceProfile",
    "SessionStore",
    "Signer",
    "create_signer",
]


class NTBackend(ProtocolBackend):
    name = "nt"

    def __init__(self, config, on_event: EventSink) -> None:
        super().__init__(config, on_event)
        self.device: DeviceProfile | None = None
        self.signer: Signer | None = None
        self.store: SessionStore | None = None
        self.transport: TcpTransport | None = None
        self.machine: LoginMachine | None = None

    async def start(self) -> None:
        protocol = self.config.protocol
        paths = self.config.paths

        self.device = DeviceProfile.load_or_create(paths.data_dir / "nt_device.json")
        self.store = SessionStore(paths.data_dir / "nt_session.json")
        existing = self.store.load()
        if existing is not None:
            log.info("发现历史会话（uin=%s），本次仍执行完整登录以校验协议", existing.uin)

        self.signer = create_signer(
            protocol.nt_signer, url=protocol.nt_signer_url, token=protocol.nt_signer_token
        )
        self.transport = TcpTransport(protocol.nt_server_host, protocol.nt_server_port)
        self.machine = LoginMachine(
            uin=protocol.nt_uin,
            transport=self.transport,
            signer=self.signer,
            device=self.device,
            store=self.store,
        )

        result = await self.machine.run()
        self._connected = result.ok

        if result.ok:
            log.info("NT 后端进入在线状态（uin=%s）", result.uin)
            return

        log.error("NT 后端未能上线：%s", result.error)
        log.error("协议中尚未逆向确认的部分：")
        for item in result.pending_work:
            log.error("  - %s", item)
        log.error(
            "签名路线未定 + 包布局未逆向，是当前无法直连官方服务的根本原因（详见本模块文档）"
        )

    async def stop(self) -> None:
        if self.transport is not None:
            await self.transport.close()
        if self.signer is not None:
            await self.signer.close()
        self._connected = False

    async def call_api(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        if not self._connected:
            raise RuntimeError(
                "NT 后端未上线，无法调用 API。请先查看日志中的未完成自研项与签名路线。"
            )
        raise NotImplementedError(
            f"行动 {action} 尚未实现：需要先完成包布局逆向与签名服务接入"
        )