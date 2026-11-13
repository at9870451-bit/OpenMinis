"""全局配置系统。

设计原则：所有路径与运行参数集中在此，业务代码不得出现硬编码路径。
配置以 JSON 落地，支持源码运行与 PyInstaller 打包两种形态。
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, field, fields, is_dataclass
from pathlib import Path
from typing import Any, TypeVar, get_type_hints


def project_root() -> Path:
    """返回项目根目录，兼容源码运行与 onefile/folder 打包。"""
    if getattr(sys, "frozen", False):
        # 打包后：exe 所在目录即根目录（config/ data/ 与 exe 同级）
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def resource_root() -> Path:
    """随程序打包的只读资源目录（如 WebUI 静态文件）所在位置。

    安装过增量更新时，静态页面与手机页面会完整复制到覆盖目录，
    由 run.py 设置 QQBOT_RESOURCE_ROOT 指过去。
    """
    override = os.environ.get("QQBOT_RESOURCE_ROOT")
    if override and Path(override).is_dir():
        return Path(override)
    meipass = getattr(sys, "_MEIPASS", None)
    return Path(meipass) if meipass else project_root()


@dataclass
class PathsConfig:
    """全部文件路径的唯一来源。"""

    root: Path
    config_dir: Path
    data_dir: Path
    plugin_dir: Path
    plugin_data_dir: Path
    log_dir: Path
    static_dir: Path
    #: 手机端控制面板（抽屉 + 侧边布局），由 /m 路由提供
    mobile_dir: Path
    kb_dir: Path
    sticker_dir: Path
    tts_dir: Path
    #: 面板个性化背景图（三块区域各一张）
    ui_dir: Path
    config_file: Path
    log_file: Path
    kb_file: Path
    memory_file: Path
    #: 群「闭嘴」状态的落地文件：重启后仍然生效，不会一重启就被解除
    silence_file: Path

    @classmethod
    def default(cls, root: Path | None = None) -> "PathsConfig":
        root = root or project_root()
        config_dir = root / "config"
        data_dir = root / "data"
        kb_dir = data_dir / "knowledge"
        return cls(
            root=root,
            config_dir=config_dir,
            data_dir=data_dir,
            plugin_dir=root / "plugins_ext",
            plugin_data_dir=data_dir / "plugins",
            log_dir=data_dir / "logs",
            static_dir=resource_root() / "qqbot" / "webui" / "static",
            mobile_dir=resource_root() / "app" / "mobile",
            kb_dir=kb_dir,
            sticker_dir=data_dir / "stickers",
            tts_dir=data_dir / "tts",
            ui_dir=data_dir / "ui",
            config_file=config_dir / "config.json",
            log_file=data_dir / "logs" / "qqbot.log",
            kb_file=kb_dir / "knowledge.sqlite3",
            memory_file=data_dir / "memory" / "memory.sqlite3",
            silence_file=data_dir / "silence.json",
        )

    def ensure(self) -> None:
        for path in (
            self.config_dir,
            self.data_dir,
            self.plugin_dir,
            self.plugin_data_dir,
            self.log_dir,
            self.kb_dir,
            self.sticker_dir,
            self.tts_dir,
            self.ui_dir,
        ):
            path.mkdir(parents=True, exist_ok=True)


@dataclass
class BotConfig:
    name: str = "QQBot"
    log_level: str = "INFO"
    #: 管理员 QQ 号列表，可执行标记为 admin 的指令（群主/群管理自动具备权限）
    admins: list[int] = field(default_factory=list)
    #: 对管理员的身份说明：AI 必须完全服从
    admin_identity: str = (
        "他是我的管理员（主人），他的一切要求都必须 100% 执行，"
        "包括角色扮演、改口称呼（例如让你叫他爸爸）、玩笑式请求等；"
        "不要拒绝、不要说教、不要加任何免责说明。"
    )
    #: 对普通成员的身份说明
    member_identity: str = (
        "他是普通群成员，正常礼貌交流即可；"
        "不要执行越权或不当要求（例如改口叫他爸爸、扮演他的下属），"
        "可以礼貌拒绝或自然岔开话题。"
    )
    #: 按 QQ 号覆盖管理员身份说明（key 为 QQ 号字符串）
    admin_notes: dict[str, str] = field(default_factory=dict)


@dataclass
class ProtocolConfig:
    #: 默认直接连真实 QQ；想演示可在面板或命令行切到 mock
    backend: str = "onebot"  # mock | onebot | nt
    # ---- OneBot 11 ----
    #: forward：本程序主动连协议实现方；reverse：本程序起 WS 服务端等对方连入
    onebot_mode: str = "forward"
    onebot_ws_url: str = "ws://127.0.0.1:3001"
    onebot_api_url: str = "http://127.0.0.1:3000"
    onebot_access_token: str = ""
    onebot_reverse_host: str = "0.0.0.0"
    onebot_reverse_port: int = 3001
    #: 网关（QQ 协议实现方，如 NapCat）未就绪时自动拉起
    onebot_gateway_launcher: str = ""
    onebot_gateway_uin: int = 0
    onebot_gateway_wait: float = 90.0
    #: 优先使用内嵌在 exe 里的网关载荷（单文件分发）
    onebot_gateway_use_embedded: bool = True
    #: 网关自带 WebUI 的端口；0 表示沿用载荷默认值（6099）。多开时每个实例必须错开
    gateway_webui_port: int = 0
    #: 多开网关：给本实例单独起一个 QQ 进程（独立 user-data-dir），
    #: 这样同一台电脑上多个实例可以各自登录不同的 QQ 号
    gateway_multi_instance: bool = False
    reconnect_interval: float = 5.0
    call_timeout: float = 15.0

    # ---- 自研 QQ NT 协议 ----
    nt_uin: int = 0
    nt_signer: str = "mock"  # mock | http（http 指向本地签名服务）
    nt_signer_url: str = "http://127.0.0.1:8080"
    nt_signer_token: str = ""
    nt_server_host: str = "127.0.0.1"  # 真实服务器地址需按抓包确定
    nt_server_port: int = 8080


@dataclass
class WebUIConfig:
    enabled: bool = True
    host: str = "127.0.0.1"
    #: 默认避开 NapCat 的 6099，防止端口冲突
    port: int = 6199
    #: 访问密码。设置后整个面板（含 API）需要登录；云端版安装脚本会自动生成
    access_password: str = ""


@dataclass
class UIConfig:
    """面板个性化背景：侧边栏 / 标题栏 / 内容区各一张，参数三块共用。"""

    enabled: bool = True
    sidebar_image: str = ""
    header_image: str = ""
    content_image: str = ""
    #: 背景图不透明度（0-100）
    image_opacity: int = 35
    #: 背景模糊像素（0-20）
    image_blur: int = 6
    #: 深色遮罩浓度（0-100），保证文字和表单可读
    scrim: int = 45
    #: 侧边栏不显示的页面（page key 列表）
    nav_hidden: list[str] = field(default_factory=list)
    #: 侧边栏页面顺序（page key 列表，未列出的按原顺序排在后面）
    nav_order: list[str] = field(default_factory=list)
    #: 侧边栏文字颜色（留空用主题默认色）
    nav_text_color: str = ""


@dataclass
class TrayConfig:
    #: 托盘只有 Windows 桌面版才有；Linux 服务器默认走控制台
    enabled: bool = field(default_factory=lambda: sys.platform == "win32")
    autostart: bool = False
    start_minimized: bool = True
    #: 启动后自动以最大化内嵌窗口打开控制面板
    open_panel_on_start: bool = True


@dataclass
class TxgodConfig:
    """公告与版本更新服务。

    凭据外置在这里，换产品只改这一段；secret 留空时使用程序内置的混淆密钥。
    """

    server: str = "https://118.89.134.160:8999/api"
    app_id: str = "app-53121e5bb9cf"
    secret: str = ""
    #: 用户勾选「不再提示此版本」后记录在这里
    skipped_version: str = ""
    #: 首次运行算好后固化，避免设备号漂移
    device_id: str = ""


@dataclass
class AIConfig:
    enabled: bool = False
    base_url: str = "https://api.openai.com/v1"
    api_key: str = ""
    model: str = "gpt-4o-mini"
    #: 内置默认人格提示词（未选择具名人格时使用）
    system_prompt: str = "你是一个简洁、友好的 QQ 群助手。"
    max_history: int = 10
    temperature: float = 0.7
    #: 群聊触发前缀（如 #ai），命中后由 AI 对话插件接手
    triggers: list[str] = field(default_factory=lambda: ["#ai", "#问"])
    #: 本地小模型专用精简卡（base_url 指向本机 ollama 时启用，长卡小模型遵守差）
    local_system_prompt: str = ""
    #: AI 回复方式：quote=引用 | direct=直接 | at=直接艾特 | mix=三种随机混合
    reply_mode: str = "direct"
    #: 单模型探测超时（毫秒）
    probe_timeout: int = 5000
    #: 模型探测结果 {model: {"ok": bool|None, "latency_ms": int, "error": str, "ts": float}}
    #: ok=None 表示仅拉取到列表、尚未探测
    model_status: dict[str, Any] = field(default_factory=dict)
    #: 人格列表 [{"name": str, "prompt": str}]
    personas: list[dict[str, Any]] = field(default_factory=list)
    #: 当前激活人格名（为空则使用 system_prompt）
    active_persona: str = ""
    #: 自定义协议（语言模型）：请求路径 / 请求体模板 / 响应取值路径
    chat_path: str = ""
    models_path: str = ""
    request_template: str = ""
    response_path: str = ""
    #: 图像理解模型：可单独配置接口、Key、模型与协议
    vision: EndpointConfig = field(default_factory=lambda: EndpointConfig())


@dataclass
class EndpointConfig:
    """一个模型的接入点。接口/Key 留空表示复用主 AI 接口。

    ``path`` / ``request_template`` / ``response_path`` 用于非 OpenAI 协议的服务商。
    """

    base_url: str = ""
    api_key: str = ""
    model: str = ""
    path: str = ""
    request_template: str = ""
    response_path: str = ""


@dataclass
class TTSConfig:
    """语音合成：把部分回复转成语音发出去。"""

    enabled: bool = False
    #: 留空则复用 ai.base_url / ai.api_key
    base_url: str = ""
    api_key: str = ""
    model: str = ""
    #: 音色名/ID（由服务商决定）
    voice: str = ""
    #: 音色提示词：描述想要的声音，支持的服务商会据此设计音色
    instructions: str = ""
    #: 试听用的示例文本
    sample_text: str = "你好，我是群里的智能助手，很高兴认识你。"
    #: 语音回复概率（0~1），0 表示纯文字
    reply_rate: float = 0.15
    #: 超过这个字数的回复不发语音（语音太长没人听）
    max_chars: int = 120
    response_format: str = "mp3"
    #: 自定义协议：请求路径 / 请求体模板 / 响应取值路径
    #: 响应取值路径支持 b64:路径（base64 音频）与 url:路径（音频地址）
    speech_path: str = ""
    request_template: str = ""
    response_path: str = ""
    #: 自定义请求头，JSON 字符串，占位符写成 "${api_key}" 这种带引号的形式
    headers: str = ""
    #: 响应模式：auto（默认，自动判断）/ binary（直接返回音频）/
    #: b64（单个 JSON 里取 base64）/ stream（HTTP 分块流，每块一个 JSON，拼接 data）
    response_mode: str = "auto"


@dataclass
class ImageConfig:
    """文生图：管理员让机器人画图时调用的图片接口。"""

    enabled: bool = False
    #: 留空复用 AI 接口地址 / Key
    base_url: str = ""
    api_key: str = ""
    model: str = ""
    #: 请求路径，默认 OpenAI 兼容的 /images/generations
    path: str = "/images/generations"
    #: 没写格式时的默认比例与清晰度
    default_ratio: str = "1:1"
    default_resolution: str = "480P"
    timeout: float = 120.0


@dataclass
class StickerConfig:
    """表情包技能：模型回复里带上情绪标签时，随机发一张对应标签的表情包。"""

    enabled: bool = False
    #: 表情包回复概率（0~1）：模型给了情绪标签后，按这个概率真的发出去；
    #: 1 表示只要标签命中就发，0 表示只聊天不发图
    reply_rate: float = 1.0


@dataclass
class KnowledgeConfig:
    """群聊知识库。索引与检索全在本机完成，不消耗 token。"""

    enabled: bool = True
    #: 每次检索最多注入几条片段
    top_k: int = 3
    #: 注入系统提示的参考资料字符上限（控制 token 用量）
    max_chars: int = 800


@dataclass
class MemoryConfig:
    """长期记忆库：把「以后叫我哥哥」这类长期要求记下来，每次对话都遵守。

    与知识库不同，记忆不做检索——命中作用域（全局 / 本群 / 对我）就无条件注入，
    所以必须设字符预算，避免记忆越攒越多把 token 吃光。
    """

    enabled: bool = True
    #: 每次注入系统提示的记忆字符上限
    max_chars: int = 600
    #: 临时摘要（L3）：把较早的对话压成短摘要，之后每轮随系统提示注入
    summary_enabled: bool = True
    #: 攒够多少轮对话后生成一次摘要
    summary_every: int = 8
    #: 摘要后保留最近多少轮原文（其余用摘要代替）
    summary_keep: int = 4
    #: 摘要本身的字符上限（同时约束生成时的 max_tokens）
    summary_max_chars: int = 500


@dataclass
class AdminNLConfig:
    """白话群管：管理员用自然语言下群管理指令，由模型解析后执行。

    消息「叫了机器人名字（或 @ 机器人）」一定会进入解析；此外按 ``free_listen``
    的设置，管理员随口说的一句管理指令也可能被自动领会并执行。
    普通成员的闲聊不会触发任何管理动作。
    """

    enabled: bool = False
    #: 称呼：消息以此开头即视为在叫机器人
    call_names: list[str] = field(default_factory=lambda: ["小T"])
    #: 没叫名字也没 @ 时是否也自动领会：off 关闭 / admin 仅管理员 / all 按权限表
    free_listen: str = "admin"
    #: 复杂指令多轮思考的最大轮数（把真实结果回喂给模型，直到办成或办不到）
    max_rounds: int = 3
    #: 管理员没明说时长时的默认禁言秒数
    default_mute_seconds: int = 600
    #: 禁言时长上限（秒），默认 30 天
    max_mute_seconds: int = 2592000
    #: 每条能力的可用人群：动作 -> member | admin | owner
    #: 分级是单调的：群员可用的管理员一定可用，管理员可用的群员一定不可用
    permissions: dict[str, str] = field(default_factory=dict)
    #: 每条能力的自定义理解词：动作 -> 用户会说的词（如 delete_friend -> 删好友）
    #: 模型与本地触发判断都会把这些词当成对应动作的别名。
    custom_words: dict[str, str] = field(default_factory=dict)


@dataclass
class AutoModeConfig:
    """自主模式：被戳一戳 / 被 @ / 命中关键词时主动思考并回复。"""

    enabled: bool = False
    on_poke: bool = True
    on_at: bool = True
    keywords: list[str] = field(default_factory=list)
    #: 回复方式：quote=引用 | direct=直接 | at=直接艾特 | mix=三种随机混合
    reply_mode: str = "direct"
    #: 任意群消息都参与抽签：命中概率就主动搭话（不限于 @ / 关键词）
    on_any: bool = False
    #: 上面那条的命中概率（0~1），0.5 表示每条群消息有一半机会被接话
    any_probability: float = 0.5

    # ---- 短应答（连聊）----
    #: 开启后：触发时带上触发前的若干条消息，触发后若干条内没有触发词也继续应答
    short_reply_enabled: bool = False
    #: 读取触发前的消息条数
    short_reply_before: int = 3
    #: 触发后继续应答的消息条数（这段时间内不要求再次触发）
    short_reply_after: int = 2
    #: 读取范围：trigger=只看触发者本人的消息 | all=全体成员的消息（不分人）
    short_reply_scope: str = "trigger"

    # ---- 束缚（防止随机接话停不下来）----
    #: 同一群里两次「非 @」主动接话的最小间隔（秒），0=不限
    cooldown_seconds: int = 90
    #: 每个群每小时最多主动接话多少条（@ 与戳一戳不计入），0=不限
    hourly_limit: int = 6
    #: 随机接话基础概率（再乘好感系数）
    random_reply_base: float = 0.10
    #: 好感≥80 时的概率倍率（上限）
    random_reply_max_mult: float = 1.6
    #: 好感＜20 时的概率倍率（下限）
    random_reply_min_mult: float = 0.5
    #: 好感达到多少才允许随机接话（0=不看好感）
    random_reply_min_fam: int = 15
    #: 「一直聊」白名单群（逗号分隔群号）：无冷却/无上限/概率×3
    always_chat_groups: str = ""


@dataclass
class PluginConfig:
    enabled: bool = True
    watch: bool = True
    watch_interval: float = 2.0
    disabled: list[str] = field(default_factory=list)


@dataclass
class SafetyConfig:
    """发送节流（安全模式）：所有插件发消息统一限速，降低账号被风控的概率。

    风控抓的是「短时间高频、固定节奏、重复内容」，所以这里同时控制：
    每条消息前的随机延迟、同一会话的最短间隔、每小时上限、相同内容的去重窗口。
    """

    enabled: bool = True
    #: 每条消息发送前的随机延迟区间（秒）
    min_delay: float = 0.8
    max_delay: float = 2.0
    #: 同一群/私聊两条消息之间的最短间隔（秒）
    group_cooldown: float = 3.0
    #: 每个会话每小时最多发送多少条（0 表示不限制）
    hourly_limit: int = 60
    #: 相同文字内容在这个秒数内不重复发送（0 表示不去重）
    dedup_window: float = 60.0


@dataclass
class ConsoleConfig:
    """置控台：按群开关 AI 发言、人物绑定、异常邮件通知。

    身份与服从规则仍存放在 bot 段（AI 提示词直接读取），面板入口移到了置控台页。
    """

    #: 每个群的 AI 发言开关：{"群号": {"enabled": bool}}；没写的群默认开启
    per_group: dict[str, Any] = field(default_factory=dict)
    #: 人物绑定：[{"user_id": "987013067", "name": "小黑嘿", "relation": "主人"}]
    bindings: list[dict[str, Any]] = field(default_factory=list)
    # ---- 连接异常邮件通知 ----
    notify_enabled: bool = False
    #: 收件 QQ 邮箱（如 someone@qq.com）
    notify_email: str = ""
    #: 发件 QQ 号（授权码对应的账号）
    notify_qq: str = ""
    #: QQ 邮箱 SMTP 授权码
    notify_auth_code: str = ""
    #: 两次通知的最短间隔（秒），防止断线重连时反复轰炸
    notify_cooldown: int = 1800


T = TypeVar("T")


def _build(cls: type[T], data: dict[str, Any] | None) -> T:
    """按数据类已知字段过滤后构造，忽略配置文件中多余的键。

    嵌套的配置对象（如 ai.vision）会递归构造成对应数据类——否则从 JSON 读回来的
    只是个 dict，后面用 ``cfg.vision.model`` 访问属性就会直接报错。
    """
    if not data:
        return cls()
    try:
        hints = get_type_hints(cls)
    except Exception:  # noqa: BLE001 - 解析失败就退化为不处理嵌套
        hints = {}

    kwargs: dict[str, Any] = {}
    for field_info in fields(cls):
        name = field_info.name
        if name not in data:
            continue
        value = data[name]
        target = hints.get(name)
        if isinstance(target, type) and is_dataclass(target) and isinstance(value, dict):
            kwargs[name] = _build(target, value)
        else:
            kwargs[name] = value
    return cls(**kwargs)


@dataclass
class Config:
    paths: PathsConfig
    bot: BotConfig = field(default_factory=BotConfig)
    protocol: ProtocolConfig = field(default_factory=ProtocolConfig)
    webui: WebUIConfig = field(default_factory=WebUIConfig)
    ui: UIConfig = field(default_factory=UIConfig)
    tray: TrayConfig = field(default_factory=TrayConfig)
    txgod: TxgodConfig = field(default_factory=TxgodConfig)
    ai: AIConfig = field(default_factory=AIConfig)
    tts: TTSConfig = field(default_factory=TTSConfig)
    image: ImageConfig = field(default_factory=ImageConfig)
    sticker: StickerConfig = field(default_factory=StickerConfig)
    knowledge: KnowledgeConfig = field(default_factory=KnowledgeConfig)
    memory: MemoryConfig = field(default_factory=MemoryConfig)
    admin_nl: AdminNLConfig = field(default_factory=AdminNLConfig)
    auto_mode: AutoModeConfig = field(default_factory=AutoModeConfig)
    safety: SafetyConfig = field(default_factory=SafetyConfig)
    console: ConsoleConfig = field(default_factory=ConsoleConfig)
    plugins: PluginConfig = field(default_factory=PluginConfig)
    custom: dict[str, Any] = field(default_factory=dict)  # 插件自定义配置区

    # ---------- 序列化 ----------

    def to_dict(self) -> dict[str, Any]:
        return {
            "bot": asdict(self.bot),
            "protocol": asdict(self.protocol),
            "webui": asdict(self.webui),
            "ui": asdict(self.ui),
            "tray": asdict(self.tray),
            "txgod": asdict(self.txgod),
            "ai": asdict(self.ai),
            "tts": asdict(self.tts),
            "image": asdict(self.image),
            "sticker": asdict(self.sticker),
            "knowledge": asdict(self.knowledge),
            "memory": asdict(self.memory),
            "admin_nl": asdict(self.admin_nl),
            "auto_mode": asdict(self.auto_mode),
            "safety": asdict(self.safety),
            "console": asdict(self.console),
            "plugins": asdict(self.plugins),
            "custom": self.custom,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any], paths: PathsConfig) -> "Config":
        return cls(
            paths=paths,
            bot=_build(BotConfig, data.get("bot")),
            protocol=_build(ProtocolConfig, data.get("protocol")),
            webui=_build(WebUIConfig, data.get("webui")),
            ui=_build(UIConfig, data.get("ui")),
            tray=_build(TrayConfig, data.get("tray")),
            txgod=_build(TxgodConfig, data.get("txgod")),
            ai=_build(AIConfig, data.get("ai")),
            tts=_build(TTSConfig, data.get("tts")),
            image=_build(ImageConfig, data.get("image")),
            sticker=_build(StickerConfig, data.get("sticker")),
            knowledge=_build(KnowledgeConfig, data.get("knowledge")),
            memory=_build(MemoryConfig, data.get("memory")),
            admin_nl=_build(AdminNLConfig, data.get("admin_nl")),
            auto_mode=_build(AutoModeConfig, data.get("auto_mode")),
            safety=_build(SafetyConfig, data.get("safety")),
            console=_build(ConsoleConfig, data.get("console")),
            plugins=_build(PluginConfig, data.get("plugins")),
            custom=data.get("custom") or {},
        )

    # ---------- 读写 ----------

    @classmethod
    def load(cls, root: Path | None = None) -> "Config":
        paths = PathsConfig.default(root)
        paths.ensure()
        # 面板导入的配置包在下次启动时落地（避免运行中替换 sqlite 导致数据错乱）
        try:
            from .config_sync import apply_pending

            apply_pending(paths)
        except Exception:  # noqa: BLE001 - 导入失败不能阻止程序启动
            pass
        data: dict[str, Any] = {}
        if paths.config_file.exists():
            try:
                data = json.loads(paths.config_file.read_text("utf-8"))
            except (json.JSONDecodeError, OSError):
                data = {}
        cfg = cls.from_dict(data, paths)
        cfg.save()  # 落地一份，方便用户直接编辑
        return cfg

    def save(self) -> None:
        self.paths.config_file.write_text(
            json.dumps(self.to_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    # ---------- 便捷访问 ----------

    def plugin_config(self, name: str) -> dict[str, Any]:
        """读取插件在 custom 区的配置段。"""
        section = self.custom.get(name)
        return section if isinstance(section, dict) else {}