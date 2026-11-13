"""QQ 接口目录：把可以交给 AI 调用的 OneBot / NapCat 接口集中登记在这里。

设计要点：
  - **单一事实来源**：白话群管的提示词、动作白名单、权限表全部由本目录生成，
    新增接口只改这一处，提示词不会和代码走散。
  - **参数白名单**：每个接口声明允许哪些参数（params）。模型给的参数只有落在白名单里
    才会被转发出去，写错参数名不会把乱七八糟的东西透传给协议层。
  - **默认不放危险接口**：包含凭证的（get_cookies / get_credentials / get_csrf_token）、
    会退出进程的（bot_exit / set_restart）一律不登记，模型再怎么说也调不到。

等级（level）：member 群员可用 / admin 群管理可用 / owner 群主可用。
本文件里的接口默认都是 admin 起步——真正生效的下限还会被面板里的权限表覆盖。
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace


@dataclass(frozen=True)
class ApiSpec:
    name: str                     # OneBot 动作名（同时是动作白名单的键）
    label: str                    # 中文名（面板与提示词用）
    desc: str                     # 一句话说明
    params: dict[str, str] = field(default_factory=dict)  # 参数名 -> 中文说明
    level: str = "admin"         # member | admin | owner
    read_only: bool = False      # 只查不改（面板上会标注，方便判断安全性）
    required: tuple[str, ...] = ()  # 必填参数：缺了就直接问，不发请求


#: 需要群号的接口统一用这个参数说明，免得每处重写
_G = {"group_id": "群号"}

_RAW_CATALOG: list[ApiSpec] = [
    # ---------- 群组：查询 ----------
    ApiSpec("get_group_info", "查询群信息", "看群名、人数、上限", _G, "admin", True),
    ApiSpec("get_group_info_ex", "查询群详细信息", "看群人数上限、建群时间等更多字段", _G, "admin", True),
    ApiSpec("get_group_list", "查询我的群列表", "列出机器人加入的所有群", {}, "admin", True),
    ApiSpec("get_group_member_info", "查询群成员信息", "看某个成员的昵称、等级、入群时间",
            {"group_id": "群号", "user_id": "成员QQ", "no_cache": "是否不走缓存"}, "admin", True),
    ApiSpec("get_group_member_list", "查询群成员列表", "拉取全群成员",
            {"group_id": "群号"}, "admin", True),
    ApiSpec("get_group_honor_info", "查询群荣誉", "看龙王、群聊之火等荣誉",
            {"group_id": "群号", "type": "荣誉类型：talkative/performer/legend/strong_newbie/emotion/all"},
            "admin", True),
    ApiSpec("get_group_shut_list", "查询被禁言成员", "列出当前正在禁言中的成员", _G, "admin", True),
    ApiSpec("get_group_at_all_remain", "查询@全体剩余次数", "还剩几次可以@全体成员", _G, "admin", True),
    ApiSpec("get_group_system_msg", "查询群系统消息", "拉取未处理的加群请求/邀请", {}, "admin", True),
    ApiSpec("get_essence_msg_list", "查询精华消息列表", "列出本群已有的精华消息", _G, "admin", True),
    ApiSpec("_get_group_notice", "拉取群公告", "读取本群当前的全部群公告", _G, "admin", True),
    ApiSpec("get_group_root_files", "查询群根目录文件", "列出群文件", _G, "admin", True),
    ApiSpec("get_group_file_url", "取群文件下载地址", "拿某个群文件的下载地址",
            {"group_id": "群号", "file_id": "文件ID"}, "admin", True),

    # ---------- 群组：管理 ----------
    ApiSpec("set_group_leave", "退出/解散群", "退出本群；is_dismiss 为真时群主可解散该群",
            {"group_id": "群号", "is_dismiss": "是否解散（仅群主可用）"}, "owner"),
    ApiSpec("_del_group_notice", "删除群公告", "删掉一条已发布的群公告",
            {"group_id": "群号", "notice_id": "公告ID（来自拉取群公告）"}, "admin"),
    ApiSpec("set_group_add_request", "处理加群请求/邀请", "同意或拒绝别人加群、或回应拉人邀请",
            {"flag": "请求标识（来自群系统消息/上报）",
             "approve": "是否同意（true/false）",
             "reason": "拒绝理由"}, "admin"),
    ApiSpec("set_group_sign", "群签到", "帮机器人本群签到", _G, "admin"),
    ApiSpec("set_group_member_permissions", "设置群成员功能权限", "放开/收紧成员发临时会话、建新群等权限",
            {"group_id": "群号",
             "allow_member_create_group": "允许成员发起新群聊",
             "allow_member_temporary_session": "允许成员发起临时会话"}, "owner"),

    # ---------- 好友 / 用户 ----------
    ApiSpec("get_friend_list", "查询好友列表", "列出机器人的全部好友", {}, "admin", True),
    ApiSpec("get_stranger_info", "查询陌生人信息", "看非好友的昵称、性别、等级",
            {"user_id": "对方QQ", "no_cache": "是否不走缓存"}, "admin", True),
    ApiSpec("get_profile_like", "查询谁赞了我", "看机器人名片收到的点赞",
            {"user_id": "指定QQ（留空看自己）", "start": "起始位置", "count": "数量"}, "admin", True),
    ApiSpec("delete_friend", "删除好友", "把某人从好友列表删除",
            {"user_id": "对方QQ", "temp_block": "是否顺带拉黑", "temp_both_del": "是否双向删除"}, "admin"),
    ApiSpec("set_friend_remark", "设置好友备注", "改某个好友的备注名",
            {"user_id": "对方QQ", "remark": "备注内容"}, "admin"),
    ApiSpec("set_friend_add_request", "处理好友申请", "同意或拒绝别人的加好友请求",
            {"flag": "请求标识（来自好友申请上报）",
             "approve": "是否同意（true/false）",
             "remark": "同意后设置的备注"}, "admin"),
    ApiSpec("group_poke", "群内戳一戳", "在群里戳某人",
            {"group_id": "群号", "user_id": "对方QQ"}, "admin"),
    ApiSpec("friend_poke", "私聊戳一戳", "在私聊里戳对方", {"user_id": "对方QQ"}, "admin"),
    ApiSpec("get_friend_msg_history", "拉取私聊聊天记录", "读与某人的私聊历史",
            {"user_id": "对方QQ", "message_seq": "起始消息序号", "count": "条数",
             "reverseOrder": "是否倒序"}, "admin", True),

    # ---------- QQ 空间（朋友圈） ----------
    ApiSpec("send_qzone_msg", "发空间说说", "在 QQ 空间发一条说说，可带图、可设可见范围",
            {"content": "说说正文", "images": "配图（路径或URL的数组）",
             "ugc_right": "可见范围：1 所有人 / 4 好友 / 16 部分好友 / 64 仅自己 / 128 部分好友不可见",
             "target_uins": "可见范围是 16 或 128 时的目标QQ"}, "admin"),
    ApiSpec("delete_qzone_msg", "删除空间说说", "按 tid 删掉一条已发的说说",
            {"tid": "说说ID"}, "admin"),

    # ---------- 消息 ----------
    ApiSpec("delete_msg", "撤回消息", "撤回指定消息", {"message_id": "消息ID"}, "admin"),
    ApiSpec("get_msg", "获取单条消息", "按消息ID读出消息内容", {"message_id": "消息ID"}, "admin", True),
    ApiSpec("set_msg_emoji_like", "给消息加表情回应", "给某条消息贴一个表情表情回应",
            {"message_id": "消息ID", "emoji_id": "表情ID"}, "admin"),
    ApiSpec("forward_group_single_msg", "转发消息到群", "把某条消息转发到指定群",
            {"message_id": "消息ID", "group_id": "目标群号"}, "admin"),
    ApiSpec("forward_friend_single_msg", "转发消息到私聊", "把某条消息转发给某人",
            {"message_id": "消息ID", "user_id": "目标QQ"}, "admin"),
    ApiSpec("ocr_image", "图片文字识别", "对图片做 OCR 取文字", {"image": "图片（URL 或本地路径）"}, "admin", True),
    ApiSpec("translate_en2zh", "英文翻译成中文", "把英文单词/句子翻成中文",
            {"words": "英文数组，如 [\"hello\"]"}, "admin", True),
    ApiSpec("check_url_safely", "检查链接安全性", "查一个网址是否安全", {"url": "网址"}, "admin", True),
    ApiSpec("upload_group_file", "上传文件到群", "把本地文件发到群文件",
            {"group_id": "群号", "file": "文件路径或URL", "name": "文件名", "folder": "目标文件夹ID"}, "admin"),
    ApiSpec("upload_private_file", "上传文件到私聊", "把本地文件发给某人",
            {"user_id": "对方QQ", "file": "文件路径或URL", "name": "文件名"}, "admin"),
    ApiSpec("mark_group_msg_as_read", "把群消息标记已读", "清掉本群未读", _G, "admin"),
    ApiSpec("mark_private_msg_as_read", "把私聊消息标记已读", "清掉与某人的未读",
            {"user_id": "对方QQ"}, "admin"),
    ApiSpec("_mark_all_as_read", "全部标记已读", "一次性清掉所有未读", {}, "admin"),

    # ---------- 账号 ----------
    ApiSpec("set_online_status", "设置在线状态", "改机器人的在线状态",
            {"status": "状态编号", "ext_status": "扩展状态", "battery_status": "电量"}, "admin"),
    ApiSpec("set_qq_avatar", "更换QQ头像", "换机器人自己的头像",
            {"file": "图片路径或URL"}, "admin"),
    ApiSpec("set_qq_profile", "修改QQ昵称与资料", "改机器人账号本身的昵称（QQ昵称）、签名、性别",
            {"nickname": "新昵称", "personal_note": "个性签名",
             "sex": "性别：0 未知 / 1 男 / 2 女"}, "admin"),
    ApiSpec("set_self_longnick", "修改个性签名", "改机器人自己的签名",
            {"longNick": "新签名"}, "admin"),
    ApiSpec("ArkSharePeer", "生成推荐好友名片", "生成一张可直接加好友的名片（不是主动加好友）",
            {"user_id": "对方QQ", "group_id": "或群号", "phoneNumber": "对方手机号"}, "admin", True),
    ApiSpec("ArkShareGroup", "生成推荐群名片", "生成一张可分享的群名片",
            {"group_id": "群号"}, "admin", True),
    ApiSpec("get_recent_contact", "查询最近会话", "列出最近的私聊会话",
            {"count": "数量"}, "admin", True),
    ApiSpec("fetch_custom_face", "获取收藏表情", "拉取机器人收藏的表情",
            {"count": "数量"}, "admin", True),
    ApiSpec("fetch_emoji_like", "拉取消息的表情回应", "看某条消息上有哪些表情回应",
            {"message_id": "消息ID", "emojiId": "表情ID", "count": "数量"}, "admin", True),
]

#: 必填参数。缺了就向用户追问，绝不发请求——
#: 否则「当前群号自动补上」会把「缺 file 的上传文件」误判成参数齐全。
_REQUIRED: dict[str, tuple[str, ...]] = {
    "delete_msg": ("message_id",),
    "get_msg": ("message_id",),
    "set_msg_emoji_like": ("message_id",),
    "forward_group_single_msg": ("message_id",),
    "forward_friend_single_msg": ("message_id",),
    "fetch_emoji_like": ("message_id",),
    "get_stranger_info": ("user_id",),
    "delete_friend": ("user_id",),
    "set_friend_remark": ("user_id", "remark"),
    "set_friend_add_request": ("flag",),
    "set_group_add_request": ("flag",),
    "group_poke": ("user_id",),
    "friend_poke": ("user_id",),
    "get_friend_msg_history": ("user_id",),
    "get_group_member_info": ("user_id",),
    "get_group_file_url": ("file_id",),
    "_del_group_notice": ("notice_id",),
    "upload_group_file": ("file",),
    "upload_private_file": ("file",),
    "mark_private_msg_as_read": ("user_id",),
    "ocr_image": ("image",),
    "translate_en2zh": ("words",),
    "check_url_safely": ("url",),
    "set_qq_avatar": ("file",),
    "set_qq_profile": ("nickname",),
    "set_self_longnick": ("longNick",),
    "set_online_status": ("status",),
    "send_qzone_msg": ("content",),
    "delete_qzone_msg": ("tid",),
    "ArkShareGroup": ("group_id",),
}

CATALOG: list[ApiSpec] = [
    replace(spec, required=_REQUIRED.get(spec.name, spec.required)) for spec in _RAW_CATALOG
]

#: 动作名 -> 规格，便于执行器做白名单与参数校验
BY_NAME: dict[str, ApiSpec] = {spec.name: spec for spec in CATALOG}

#: 分类 -> 该分类下的接口名（面板与提示词都按这个分组）。
#: 用显式名单而不是前缀过滤：新增接口漏了归类，uncategorized() 会直接指出来。
_CATEGORY_NAMES: list[tuple[str, tuple[str, ...]]] = [
    ("群组查询", (
        "get_group_info", "get_group_info_ex", "get_group_list", "get_group_member_info",
        "get_group_member_list", "get_group_honor_info", "get_group_shut_list",
        "get_group_at_all_remain", "get_group_system_msg", "get_essence_msg_list",
        "_get_group_notice", "get_group_root_files", "get_group_file_url",
    )),
    ("群组管理", (
        "set_group_leave", "_del_group_notice", "set_group_add_request", "set_group_sign",
        "set_group_member_permissions",
    )),
    ("好友与用户", (
        "get_friend_list", "get_stranger_info", "get_profile_like",
        "delete_friend", "set_friend_remark", "set_friend_add_request", "group_poke",
        "friend_poke", "get_friend_msg_history",
    )),
    ("空间与动态", (
        "send_qzone_msg", "delete_qzone_msg",
    )),
    ("消息处理", (
        "delete_msg", "get_msg", "set_msg_emoji_like", "forward_group_single_msg",
        "forward_friend_single_msg", "ocr_image", "translate_en2zh", "check_url_safely",
        "upload_group_file", "upload_private_file", "mark_group_msg_as_read",
        "mark_private_msg_as_read", "_mark_all_as_read",
    )),
    ("账号相关", (
        "set_online_status", "set_qq_avatar", "set_qq_profile", "set_self_longnick",
        "ArkSharePeer", "ArkShareGroup", "get_recent_contact", "fetch_custom_face",
        "fetch_emoji_like",
    )),
]

CATEGORIES: list[tuple[str, list[ApiSpec]]] = [
    (title, [BY_NAME[name] for name in names if name in BY_NAME])
    for title, names in _CATEGORY_NAMES
]


def uncategorized() -> list[str]:
    """还没归类的接口名（新增接口忘了归类时，这里会暴露出来）。"""
    grouped = {spec.name for _t, specs in CATEGORIES for spec in specs}
    return [spec.name for spec in CATALOG if spec.name not in grouped]


def prompt_lines(only: set[str] | None = None) -> list[str]:
    """给模型的接口清单（按分类分组，只列名称、说明与允许的参数）。

    ``only`` 传入动作名集合时只保留其中的接口——白话群管据此按发送者的权限
    裁剪清单，模型就不会提出对方没有的能力。为 ``None`` 时列出全部。
    """
    lines: list[str] = []
    for title, specs in CATEGORIES:
        picked = [spec for spec in specs if only is None or spec.name in only]
        if not picked:
            continue
        lines.append(f"【{title}】")
        for spec in picked:
            items = []
            for key, desc in spec.params.items():
                mark = "必填 " if key in spec.required else ""
                items.append(f"{key}（{mark}{desc}）")
            params = "、".join(items) or "无"
            tag = "（只读）" if spec.read_only else ""
            lines.append(f"- {spec.name} {spec.label}{tag}：{spec.desc}；参数：{params}")
        lines.append("")
    return lines


def describe_params(name: str, given: dict) -> tuple[dict, list[str]]:
    """按白名单过滤并粗校验参数，返回 (可执行参数, 被丢弃的参数名)。

    模型偶尔会多塞字段（比如把 remark 写成 note），这里丢弃并让上层如实回一句，
    而不是把未知字段透传给协议端。
    """
    spec = BY_NAME.get(name)
    if spec is None:
        return {}, list(given or {})
    allowed = set(spec.params)
    keep: dict = {}
    dropped: list[str] = []
    for key, value in (given or {}).items():
        if key not in allowed or value is None or value == "":
            if key not in allowed:
                dropped.append(str(key))
            continue
        keep[key] = value
    return keep, dropped
