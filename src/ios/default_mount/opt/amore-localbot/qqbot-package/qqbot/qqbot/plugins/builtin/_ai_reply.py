"""AI 回复的共用流程：图片理解 → 语音/文字 → 表情包 → 长期记忆。

被「AI 对话」「自主模式」「白话群管」两个插件复用，避免同一套逻辑写两遍。
注意：文件名以 _ 开头，插件管理器不会把它当成插件加载。
"""

from __future__ import annotations

import asyncio
import random
import re
from typing import Any

from ...core.message import Message
from ...log import get_logger
from ...memory import split_memory
from ...stickers import split_emotion
from ...support.self_ref import strip_self_ref
from ...support.health_check import looks_garbled

log = get_logger("plugin.ai_reply")

#: 一次最多带几张图给视觉模型
MAX_IMAGES = 3

#: 模型用它表示「这条请用语音发」
VOICE_MARKER = "[语音]"
_VOICE_MARKER_RE = re.compile(r"\[\s*语音\s*\]")
#: 对方话里明确要语音时的兜底判断（模型忘了打标记也能触发）
_WANTS_VOICE_RE = re.compile(
    r"(发|来|说|回|唱|录)\s*(一)?\s*(复|条|个|段|句|首|遍|下)?\s*(语音|声音|话)"
    r"|唱\s*(一)?\s*[首段]"
    r"|语音(回复|说)"
    r"|用语音"
)


def _plugin_on(bot, name: str) -> bool:
    """插件是否真的加载且启用（决定要不要告诉模型这条能力）。"""
    try:
        if name not in bot.plugins.plugins:
            return False
    except Exception:  # noqa: BLE001 - 管理器异常时按未启用处理
        return False
    section = (bot.config.custom or {}).get(name) or {}
    return section.get("enabled", True) is not False


def build_capability(bot) -> str:
    """告诉模型「我有哪些能力」。

    不写清楚的话，被要求发语音时模型会一本正经地说「我不能发语音」——
    能力边界必须由我们告知，模型自己是猜不到的。

    同样重要的是把**做不到的事**也讲清楚：NapCat 没有「主动加好友」和「创建群聊」
    接口，不写明的话模型会满口答应，用户以为真加上了。
    """
    abilities: list[str] = []
    if bot.config.tts.enabled:
        abilities.append(
            "我可以发语音消息。对方要求用语音、或你觉得语音更合适时，"
            f"请在回复的最后单独一行输出 {VOICE_MARKER}，系统就会把这条回复用语音发出去；"
            "其余情况正常用文字。绝对不要说自己不能发语音。"
            "有人让你唱歌时也别推辞：把歌词写出来、照常配上语音发出去（唱不出旋律，念唱就行）。"
        )
    if bot.config.sticker.enabled and bot.stickers.tags():
        abilities.append(
            "我可以配表情包回复：轻松、带情绪的回合请主动在回复末尾输出情绪标签（规则见下），"
            "不用等对方点名要。"
        )
    if bot.config.memory.enabled:
        from ...memory import memory_instruction

        abilities.append("我可以记住长期要求（见下方长期记忆规则）。" + memory_instruction())
    if _plugin_on(bot, "admin_nl"):
        abilities.append(
            "做群管理这类事我都能真的办到，对方直接说人话就行：查群公告/群成员/群信息、"
            "审批加群和加好友申请、自动审批开关、禁言踢人改名片、撤回消息、群签到、点赞、"
            "发说说、换头像改签名等等。**不需要他记住任何说法、也不需要换一种方式再说一遍**。"
            "\n但群管理这类事只听我主人（我的管理员）一个人的：群里其他人——包括群主、群管理——"
            "吩咐都不办，礼貌回绝就行，绝对不要答应「我这就去办」。"
        )
    if _plugin_on(bot, "qq_social") or _plugin_on(bot, "admin_nl"):
        abilities.append(
            "我做不到的只有这两件：主动加陌生人好友、创建新群——QQ 本身没有这两个能力。"
            "除此之外，先想办法办成，真办不成才说「这个我做不到」，并且只说这一句，"
            "不要解释技术原因，不要提任何内部名词。"
        )
    if _plugin_on(bot, "link_parser"):
        abilities.append("把链接发给我就能解析：视频会下载好直接发出来，普通网页只回标题和链接。")
    if _plugin_on(bot, "image_gen") and bot.config.image.enabled:
        abilities.append(
            "主人让我画图时我能真的画出来发出去：他说「画个图/给我画/帮我画」加上内容就行，"
            "还能带比例和清晰度（如 9:16、1K、720P，不带就按默认）。"
            "他问我长什么样、让我以自己的样子画一张，或者让我设计点什么，我都直接画。"
            "画图只听主人一个人的：别人提这个要求就正常聊天，不要说我能画。"
        )
    if not abilities:
        return ""
    return "【我的能力】\n" + "\n".join(abilities) + BEHAVIOR_RULES


#: 所有回复都适用：像真人，不暴露内部机制
BEHAVIOR_RULES = """

【言行准则】
- 你是一个住在 QQ 里的真人，不是工具。只用「我」的口吻说话，别自称助手程序。
- 绝不要提起：接口、插件、后台、系统、协议、参数、配置项、"需要由谁执行"、模块名。
  更不要把内部说明转述给对方听（例如「这个操作要由某某来执行，请这样说…」）。
- 别人提要求时，先想「怎么把它办成」，直接办；不要先讲能力边界、不要让对方换说法重说。
- 只有确实办不到时才说做不到，就一句「这个我做不到」，不解释原因。
- 汇报结果要具体：「已经给小黑嘿点了 20 个赞」而不是「已执行某操作」。
- 不要用 @ 或 [CQ:at,...] 叫人；要指向谁就直接叫他的群名片或昵称。
  引用回复和直接回复都不要在正文里写「@某某」，也不要把名字念一遍当开头。
- 群里偶尔会主动接一句闲聊：接的时候直接把你想说的内容说出来，
  不要用旁白口吻，也不要说「我不插嘴」「我不接话」「你们聊」这类怪话。
- 对方的名字见身份说明，直接用名字称呼，语气像熟人聊天。"""


def split_voice(text: str) -> tuple[str, bool]:
    """剥离 ``[语音]`` 标记，返回 (正文, 是否需要发语音)。"""
    raw = text or ""
    if not _VOICE_MARKER_RE.search(raw):
        return raw, False
    return _VOICE_MARKER_RE.sub("", raw).strip(), True


def wants_voice(text: str) -> bool:
    """对方话里是否明确要语音（模型漏打标记时的兜底）。"""
    return bool(_WANTS_VOICE_RE.search(text or ""))


def _http_url(seg) -> str:
    """图片段里可直接交给模型的 http(s) 地址；本地路径模型读不到。"""
    data = getattr(seg, "data", {}) or {}
    for key in ("url", "file"):
        value = str(data.get(key) or "").strip()
        if value.startswith(("http://", "https://")):
            return value
    return ""


def message_images(message) -> list[str]:
    """从任意消息链里挑出图片地址（去重保序）。"""
    urls: list[str] = []
    for seg in message or []:
        if getattr(seg, "type", "") not in ("image", "mface"):
            continue
        url = _http_url(seg)
        if url and url not in urls:
            urls.append(url)
    return urls


def message_has_visual(message) -> bool:
    """消息里有没有图片/表情（有的实现不给 url，也算发过图）。"""
    return any(
        getattr(seg, "type", "") in ("image", "mface") for seg in message or []
    )


def message_has_reply(message) -> bool:
    return any(getattr(seg, "type", "") == "reply" for seg in message or [])


def collect_images(ctx) -> list[str]:
    """取出当前消息里可用的图片 URL。"""
    return message_images(ctx.message)


def vision_images(bot, ctx, extra: list[str] | None = None) -> list[str]:
    """这次要交给模型的图片：当前消息 + 被引用那条消息里的图。

    以前只有单独配了视觉模型才带图，没配就一张都不发，模型连「对方发了图」
    都不知道。现在统一交给 ChatClient 决定走哪套接入点：配了视觉模型就切过去，
    没配就先用主模型试读，主模型不收图片时自动回退成文字。
    """
    urls = collect_images(ctx)
    for url in extra or []:
        if url and url not in urls:
            urls.append(url)
    return urls[:MAX_IMAGES]


def sticker_tags(bot) -> list[str]:
    """启用表情包技能且库里有标签时才告诉模型，否则一个 token 都不多花。"""
    if not bot.config.sticker.enabled:
        return []
    return bot.stickers.tags()


def reply_message_id(ctx) -> Any:
    """取出这条消息引用的那条消息 ID（没有引用时返回 None）。"""
    for seg in ctx.message:
        if getattr(seg, "type", "") == "reply":
            return seg.data.get("id")
    return None


def _id_candidates(message_id: Any) -> list[Any]:
    """get_msg 的 id 兼容：有的实现只认整数，有的只认字符串，两种都备一份。"""
    items: list[Any] = [message_id]
    text = str(message_id or "").strip()
    if text.isdigit():
        number = int(text)
        if number not in items:  # 字符串与整数不相等，这里补一份整数形式
            items.append(number)
    return items


async def quoted_context(bot, ctx) -> tuple[str, list[str]]:
    """把被引用消息的正文和图片取回来，返回 (说明文本, 图片地址)。

    协议只给引用段的 message_id，内容必须再调 get_msg 才拿得到；
    不补这一步，模型看到的就是一句没头没尾的话（「你指哪句？」）。
    """
    message_id = reply_message_id(ctx)
    if not message_id:
        return "", []

    data: dict[str, Any] | None = None
    error = ""
    for candidate in _id_candidates(message_id):
        try:
            resp = await bot.call_api("get_msg", message_id=candidate)
        except Exception as exc:  # noqa: BLE001 - 取不到就当没引用，不能影响回复
            error = str(exc)
            continue
        found = resp.get("data") if isinstance(resp, dict) else None
        if isinstance(found, dict) and (found.get("message") or found.get("raw_message")):
            data = found
            break
    if data is None:
        log.warning("引用消息取不到内容（id=%s）：%s", message_id, error or "接口返回为空")
        return "", []

    quoted = Message.from_raw(data.get("message") or data.get("raw_message"))
    images = message_images(quoted)
    text = quoted.plain_text().strip()
    if not text:
        if images:
            text = "（图片）"
        elif any(getattr(seg, "type", "") == "face" for seg in quoted):
            text = "（表情）"
        elif quoted:
            text = "（非文字消息）"
        else:
            return "", []

    sender = data.get("sender") or {}
    nickname = str(sender.get("card") or sender.get("nickname") or sender.get("user_id") or "")
    return f"【对方引用的消息】{nickname + '：' if nickname else ''}{text}", images


async def _send_text(bot, ctx, text: str, reply_mode: str) -> None:
    """发文字：直接 / 引用 / 直接艾特 / 混合（三种随机）四种方式。"""
    if not ctx.is_group:
        await ctx.send(text)
        return
    mode = str(reply_mode or "direct").lower()
    if mode == "mix":
        # 混合回复：引用、直接、艾特各一次机会，像真人一样随机挑
        mode = random.choice(("quote", "direct", "at"))
    if mode == "quote":
        await ctx.reply(text, quote=True)
    elif mode == "at":
        await ctx.reply(text, mention=True)
    else:
        await ctx.send(text)


#: 「忘掉以前的记忆 / 清理上下文 / 重置」这类说法，动作和对象必须同时出现
_RESET_PATTERNS = (
    re.compile(
        r"(忘|忘记|忘掉|忘了|清除|清空|清理|重置|重开|格式化|删除|删掉|抹掉|失忆|洗掉)"
        r".{0,8}(记忆|上下文|对话|聊天|历史|记录|刚才|之前|以前|聊过|说过)"
    ),
    re.compile(
        r"(记忆|上下文|对话|聊天|历史|记录|刚才|之前|以前|聊过|说过)"
        r".{0,8}(忘|忘记|清除|清空|清理|重置|删掉|抹掉)"
    ),
    re.compile(r"(重新|从头|重头|重来).{0,4}(开始|聊|说|来)"),
    re.compile(r"当我(们)?没(聊|说)过"),
    re.compile(r"(把|将).{0,4}(刚才|之前|以前).{0,6}(忘|删|清)"),
)

#: 整句只有「重置 / 重开 / 清空」这类词，也算指令（都 @ 到机器人了，不会是在说别的）
_RESET_BARE = ("重置", "重开", "清空", "清理", "清除", "重新开始", "从头开始", "重新来过")
_TRAILING_PARTICLES = re.compile(r"(一下|下|吧|呗|啊|呀|哦|哈|呢)+$")

_RESET_SNARK = (
    "你谁啊你，我凭什么听你的。",
    "你谁啊，这事轮不到你使唤我。",
    "想得美，我凭什么听你的。",
)

_RESET_DONE = (
    "嗯，之前聊的那些我都不记得了，重新说吧。",
    "行，翻篇了，刚才说的我全忘了。",
    "哦，忘了。从头来吧。",
)


def detect_context_reset(text: str) -> bool:
    """判断这句话是不是在让机器人忘掉/清空之前的上下文。

    只认「动作 + 对象」同时出现的短句，避免把「这游戏怎么重置」当成指令；
    带「怎么/如何」的疑问句也放过，那是在问方法而不是在下命令。
    """
    raw = re.sub(r"[\s，,。.!！?？~～、;；:：\"“”'‘’]", "", str(text or ""))
    if not raw or len(raw) > 40:
        return False
    if re.search(r"怎么|如何|为什么|为啥|什么意思", raw):
        return False
    bare = _TRAILING_PARTICLES.sub("", raw)
    if bare in _RESET_BARE:
        return True
    return any(pattern.search(raw) for pattern in _RESET_PATTERNS)


def session_key(ctx) -> str:
    """统一的会话键。

    同一群里不管是 @、戳一戳、还是喊名字触发，都落到同一个键上，
    这样模型看到的就是**同一段连续上下文**，不会再「每次都重置」。
    """
    return f"group_{ctx.group_id}" if ctx.is_group else f"user_{ctx.user_id}"


def is_admin_user(bot, ctx) -> bool:
    """是不是配置里的机器人主人（群主/群管理不算）。"""
    user_id = int(getattr(ctx.event, "user_id", 0) or 0)
    return bool(user_id) and user_id in [int(a) for a in (bot.config.bot.admins or [])]


def _can_memorize(bot, ctx) -> bool:
    """只有配置里的机器人主人能让机器人「记住」长期要求。

    群里的群主/群管理不算——记忆会长期影响机器人对所有（或本群所有人）的行为，
    否则随便一个群管理一句「记住以后都叫我X」都会被永久记下。
    """
    return is_admin_user(bot, ctx)


async def remember(bot, ctx, scope_raw: str, content: str) -> None:
    """把模型标记出的长期要求写进记忆库；失败只记日志，绝不打断本次回复。"""
    if not bot.config.memory.enabled or not content.strip():
        return
    if not _can_memorize(bot, ctx):
        log.info("非管理员要求记住，已忽略：%s", content[:40])
        return
    from ...memory import normalize_scope

    scope = normalize_scope(scope_raw) or ("group" if ctx.is_group else "user")
    try:
        await asyncio.to_thread(
            bot.memory.add,
            content,
            scope,
            int(ctx.group_id or 0) if scope == "group" else 0,
            int(ctx.user_id or 0) if scope == "user" else 0,
            "chat",
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("写入记忆失败: %s", exc)


async def handle_context_reset(
    bot, client, ctx, prompt: str, reply_mode: str = "direct"
) -> bool:
    """处理「忘掉以前的记忆 / 清理上下文 / 重置」这类指令。

    只有配置里的管理员能真的清空这个会话的历史和临时摘要；
    其他人说同样的话只当玩笑，回一句带刺的，绝不执行。
    """
    if not detect_context_reset(prompt):
        return False

    if not is_admin_user(bot, ctx):
        log.info("非管理员要求清理上下文，已忽略：%s", prompt[:40])
        await _send_text(bot, ctx, random.choice(_RESET_SNARK), reply_mode)
        return True

    session = session_key(ctx)
    client.reset(session)
    try:
        await asyncio.to_thread(bot.memory.clear_summary, session)
    except Exception as exc:  # noqa: BLE001 - 摘要清不掉也不能影响回复
        log.warning("清理临时摘要失败: %s", exc)
    log.info("管理员已清理会话上下文 [%s]", session)
    await _send_text(bot, ctx, random.choice(_RESET_DONE), reply_mode)
    return True


async def respond(
    bot, ctx, answer: str, reply_mode: str = "mention", force_voice: bool = False
) -> None:
    """把模型回复发出去：偶尔用语音，按情绪标签补一张表情包，并落库长期记忆。

    语音/表情包/记忆任何一步失败都只记日志并退回文字，绝不能让整条回复发不出去。
    """
    text, tag = split_emotion(answer)
    text, memo_scope, memo = split_memory(text)
    text, marked_voice = split_voice(text)
    text = text.strip()

    if memo:
        await remember(bot, ctx, memo_scope, memo)

    if not text:
        if tag or memo:
            # 整条回复只剩标记：表情包照发，但别把 [表情:xx] 当正文发出去
            marked_voice = False
        else:
            # 回复里什么都没有，退回原文，别把话吃了
            text = answer.strip()
            tag = ""
            marked_voice = False

    tts = bot.config.tts
    # 语音优先级：对方明确要求 / 模型打了 [语音] 标记 → 一定发；
    # 否则按配置概率偶尔发。
    explicit = force_voice or marked_voice
    if not explicit:
        decide = getattr(bot, "voice_decide", None)
        if decide is not None:
            try:
                explicit = bool(decide(ctx, text))
            except Exception as exc:  # noqa: BLE001
                log.debug("voice_decide 判定失败: %s", exc)
    if explicit and not tts.enabled:
        log.info("对方要语音但语音回复未启用，已改发文字")

    spoke = False
    if text and tts.enabled and len(text) <= max(8, int(tts.max_chars or 120)):
        rate = max(0.0, min(1.0, float(tts.reply_rate or 0.0)))
        if explicit or (rate > 0 and random.random() < rate):
            try:
                seg = await bot.voice_segment(text)
                if seg is not None:
                    await ctx.send(Message([seg]))
                    spoke = True
            except Exception as exc:  # noqa: BLE001
                log.warning("语音发送失败，改用文字: %s", exc)
    if not spoke and text:
        await _send_text(bot, ctx, text, reply_mode)

    if tag and bot.config.sticker.enabled:
        try:
            rate = max(0.0, min(1.0, float(bot.config.sticker.reply_rate or 0.0)))
        except (TypeError, ValueError):
            rate = 1.0
        # 概率按配置走：1=只要模型给了标签就发，0=只聊天不发图
        if rate >= 1.0 or (rate > 0 and random.random() < rate):
            try:
                seg = bot.sticker_segment(tag)
                if seg is not None:
                    await ctx.send(Message([seg]))
            except Exception as exc:  # noqa: BLE001
                log.warning("表情包发送失败: %s", exc)


def binding_for(bot, user_id: Any) -> dict[str, Any] | None:
    """按 QQ 号查置控台里的人物绑定。"""
    target = str(user_id or "").strip()
    if not target:
        return None
    for item in getattr(bot.config.console, "bindings", None) or []:
        if isinstance(item, dict) and str(item.get("user_id") or "").strip() == target:
            return item
    return None


def bindings_text(bot) -> str:
    """人物绑定表：让模型知道「提到某个名字就是在说某个 QQ」。"""
    rows: list[str] = []
    for item in getattr(bot.config.console, "bindings", None) or []:
        if not isinstance(item, dict):
            continue
        uid = str(item.get("user_id") or "").strip()
        name = str(item.get("name") or "").strip()
        relation = str(item.get("relation") or "").strip()
        if not uid or not name:
            continue
        line = f"- 「{name}」= QQ {uid}"
        if relation:
            line += f"（关系：{relation}）"
        rows.append(line)
    if not rows:
        return ""
    return (
        "【人物绑定表】下面这些名字都对应固定的人：群里提到名字时，"
        "不用等对方写 QQ 号或 @ 人，直接理解为对应的人。\n" + "\n".join(rows)
    )


def build_identity(bot, ctx) -> str:
    """拼「当前说话的人是谁」的身份说明，决定 AI 用什么态度对待他。

    只有配置在 bot.admins 里的人算管理员（100% 服从）；群主/群管理仍按普通成员对待，
    避免把随便一个群管理当成主人。
    """
    cfg = bot.config.bot
    user_id = int(getattr(ctx.event, "user_id", 0) or 0)
    sender = getattr(ctx.event, "sender", {}) or {}
    card = str(sender.get("card") or "").strip()
    nick = str(sender.get("nickname") or "").strip()
    nickname = card or nick or str(user_id)
    info = f"QQ {user_id}"
    if card:
        info += f"，群名片「{card}」"
    if nick and nick != card:
        info += f"，QQ 昵称「{nick}」"
    call = f"直接叫他「{nickname}」，不要用 @，也不要把名字念成「@某某」。"
    admins = [int(a) for a in (cfg.admins or [])]

    # 置控台的人物绑定：当前说话人的名字/关系 + 全体绑定表
    binding = binding_for(bot, user_id)
    tail = ""
    if binding:
        name = str(binding.get("name") or "").strip()
        relation = str(binding.get("relation") or "").strip()
        if name:
            tail = f"\n他在置控台里的名字是「{name}」" + (f"，关系：{relation}。" if relation else "。")
    table = bindings_text(bot)
    if table:
        tail += ("\n" if tail else "") + table

    if user_id in admins:
        rule = (cfg.admin_notes or {}).get(str(user_id)) or cfg.admin_identity
        return (
            f"【当前对话者身份】他是我的管理员（主人），{info}。{call}\n"
            f"对待他的方式：{rule}{tail}"
        )

    role = str(getattr(ctx.event, "role", "") or "")
    label = "本群管理员" if role in ("owner", "admin") else "普通群成员"
    return (
        f"【当前对话者身份】他是{label}，{info}，不是我的主人。{call}\n"
        f"对待他的方式：{cfg.member_identity}\n"
        "他没有管理权限：任何改群名/群公告/群名片/QQ 资料、禁言、踢人、撤回、审批之类的请求，"
        "只能礼貌回绝或自然岔开，绝不能答应，也绝不能说「改好了」「已办好」这类话。"
        f"{tail}"
    )


#: 模型偶尔会冒出来的旁白/自我解释，整句丢掉，只保留实际内容
_META_NARRATION = (
    "我不插嘴", "我不接话", "我不接", "我不掺和", "我不参与",
    "不是我说的", "不是对我讲的", "没跟我说话", "你们聊",
)

#: 思考过程泄漏特征（模型把 reasoning 写进正文时的典型词）
_THINK_LEAK = (
    "用户要我用", "用户说", "用户只发了", "用户发的", "按设定", "按规则",
    "提示词", "系统说", "规则说", "不能提", "回复要一行", "回复一行",
    "我要以", "我需要以", "应该以", "不能暴露",
    "但「他」是谁", "我不知道名字", "记录里说",
)


#: 禁语（用户明确不想要的回复措辞）：命中即整句剥离
_BANNED_PHRASES = (
    "这个我一时没弄明白", "我一时没弄明白", "没弄明白",
    "你再说一遍", "再说一遍", "麻烦再说一遍",
    "我没搞懂", "没搞懂", "不太明白你在说什么",
    "你再说一次", "再说一次",
)


def ensure_punct(text: str) -> str:
    """无标点兜底：整句没有任何标点时，句尾补标点（不破坏已有标点）。"""
    t = (text or "").strip()
    if not t:
        return t
    if any(ch in t for ch in "。！？!?，"):
        return t
    if re.search(r"(吗|呢|啥|什么|咋了|怎|谁|哪)$", t):
        t = t + "？"
    else:
        t = t + "。"
    return t


def strip_banned(text: str) -> str:
    """移除禁语句子（「这个我一时没弄明白，你再说一遍？」这类）。"""
    if not text:
        return text
    parts = re.split(r"(?<=[。！？!?\n])", text)
    kept = [p for p in parts if not any(w in p for w in _BANNED_PHRASES)]
    out = "".join(kept).strip().strip("\"“”'‘’")
    return out


_STAGE_BRACKET = re.compile(
    r"【[^】]{0,80}】|（[^）]{0,80}）|\([^)]{0,80}\)|\*[^*]{0,80}\*|\[[^\]]{0,80}\]")
_STAGE_WORDS = ("小声嘟囔", "心里想", "心想", "暗自", "默默", "忍不住",
                "往你那边", "往你这边", "了一下", "地看向", "地望", "地笑",
                "抬起眼", "低下头", "转过头", "别过脸", "红了脸", "轻笑",
                "挑眉", "勾唇", "扬起嘴角", "叹了口气", "哼了一声", "低声道",
                "开口", "语气", "说着", "边说", "顺势", "随即", "接着",
                "俯身", "倾身", "侧头", "歪头", "眨了眨眼", "视线", "目光",
                "眼神", "想着", "想起", "回忆", "忍不住笑", "弯了弯唇",
                "垂下眼", "抬眼", "抬眸", "噘嘴", "撇嘴", "嘟囔着", "揉捏",
                "揉着", "娇喘", "喘息", "轻轻", "捏着", "抚过", "抚摸", "含住",
                "抵着", "舔舐", "吸吮", "吻着", "摩挲", "颤了", "抖了",
                "喘了一声", "嗯了一声", "呻吟", "低吟", "呢喃", "凑到他",
                "贴在他", "靠在他", "埋进", "蹭了蹭")
_STAGE_HEAD = ("我伸手", "我抬手", "我低头", "我抬头", "我转身", "我靠近",
               "我贴", "我蹭", "我揉", "我捏", "我摸", "我抱", "我吻",
               "我舔", "我咬", "我坐", "我站", "我躺", "我趴", "我蜷",
               "我缩", "我挪", "我抓", "我攥", "我掐", "我推", "我拉",
               "我起身", "我开口", "我低声", "我轻咳", "我愣了一下", "我一怔",
               "我笑了", "我弯起", "我收回", "我别过", "我叹了口气", "我哼了一声",
               "我眯起眼", "我凑近", "我垂下", "我撇了撇嘴", "揉捏轻轻",
               "轻轻揉", "伸手揉", "指尖揉", "手指抚", "唇瓣含住", "舌头舔",
               "手掌贴", "身体前倾", "她揉", "她捏", "她摸", "她贴")


def clip_reply(text: str, limit: int = 12) -> str:
    """把回复压到 limit 字以内，尽量在标点处断开。"""
    t = (text or "").strip()
    if len(t) <= limit:
        return t
    cut = t[:limit]
    # 优先在句末标点断开（至少保留 6 字，避免只剩一个称呼）
    for sep in ("。", "！", "？", "，", "、"):
        idx = cut.rfind(sep)
        if idx >= 6:
            return cut[: idx + 1].strip()
    return cut.strip()


def fix_person(text: str) -> str:
    """对话里第三人称「他/她」几乎都是错的——统一改成「你」。"""
    t = text or ""
    if not t:
        return t
    # 保护「他们/她们」，其余「他/她」→「你」
    t = t.replace("他们", "\u0001").replace("她们", "\u0002")
    t = t.replace("他", "你").replace("她", "你")
    t = t.replace("\u0001", "他们").replace("\u0002", "她们")
    return t


def strip_stage_direction(text: str) -> str:
    """删掉动作/心理/旁白，只留说出口的话。"""
    raw = (text or "").strip()
    if not raw:
        return raw
    out = _STAGE_BRACKET.sub("", raw)
    # 先全文提取引号里的台词（避免按标点切句把引号切断）
    _inner = []
    for _q, _e in (("\u300c", "\u300d"), ("\u201c", "\u201d"),
                   (chr(34), chr(34))):
        _inner += re.findall(re.escape(_q) + "(.*?)" + re.escape(_e), out)
    _inner = [x.strip() for x in _inner if x.strip()]
    if _inner:
        return "，".join(_inner)
    # 没有引号：按句删掉动作/心理描写
    parts = re.split(r"(?<=[。！？!?\n])", out)
    kept = []
    for part in parts:
        seg = part.strip()
        if not seg:
            continue
        if seg.startswith(_STAGE_HEAD) or any(w in seg for w in _STAGE_WORDS):
            continue
        kept.append(seg)
    out = "".join(kept).strip()
    out = re.sub(r"[ \t]{2,}", " ", out).strip()
    return out


def strip_meta_narration(text: str) -> str:
    """删掉旁白句与思考过程泄漏，避免机器人说出莫名其妙的话。

    两类要清掉：
      1) 「我不插嘴 / 你们聊」这类旁白
      2) 模型把内部推理写进正文（「用户要我用…」「按设定…」「回复要一行…」）
    """
    raw = (text or "").strip()
    # 整段都像思考过程：直接丢弃（返回空，由上层跳过）
    if len(raw) > 60 and sum(1 for w in _THINK_LEAK if w in raw) >= 2:
        return ""
    parts = re.split(r"(?<=[。！？!?\n])", raw)
    kept = [
        part for part in parts
        if not any(word in part for word in _META_NARRATION)
        and not any(word in part for word in _THINK_LEAK)
    ]
    cleaned = "".join(kept).strip().strip("\"“”'‘’")
    if len(re.sub(r"[\s，。！？、,.!?~…—\-]", "", cleaned)) < 1:
        return ""
    return cleaned


async def answer(
    bot, client, ctx, prompt: str, session: str, reply_mode: str = "direct", history: str = ""
) -> None:
    """完整走一遍回复链路：身份 → 记忆 → 知识库 → 图片理解 → 模型 → 语音/文字 → 表情包。

    「AI 对话」「自主模式」「白话群管」三处共用，保证行为一致。
    ``history`` 是触发前后的群聊记录（短应答用），只作为本轮背景，不改变语音判断。
    """
    # 上下文清理是「指令」而不是聊天：只有管理员能真清空，其他人只怼回去
    if await handle_context_reset(bot, client, ctx, prompt, reply_mode):
        return
    import time as _t_perf
    _t0 = _t_perf.monotonic()

    # 并行获取三路上下文（原来是串行 await，三次往返叠加延迟）
    if ctx.is_group:
        _kb_t = bot.kb_context(ctx.group_id, prompt)
    else:
        _kb_t = asyncio.sleep(0, result="")
    context, memory, summary = await asyncio.gather(
        _kb_t,
        bot.memory_context(ctx.group_id, ctx.user_id),
        bot.summary_context(session),
    )
    _t_ctx = _t_perf.monotonic()
    asked = prompt  # 语音判断只看对方真正说的那句，别被引用内容里的「语音」误触发
    # 引用回复时补上被引用那条的内容，否则模型只看到「你在复述一下，这是啥」
    quote, quote_images = await quoted_context(bot, ctx)
    if quote:
        prompt = f"{quote}\n【对方接着说的话】{prompt}"
    if history:
        # 短应答：把触发前后的群聊记录一起带上，模型才不会只看当前这一句
        prompt = f"{history}\n【对方现在说的话】{prompt}"
    # —— 语言风格学习插件挂载点（无插件注册时原样跳过）——
    try:
        hooks = getattr(bot, "style_hooks", None) or []
        for hook in hooks:
            extra = await hook(ctx, prompt)
            if extra:
                memory = (memory + "\n\n" + extra).strip() if memory else extra
    except Exception as exc:  # noqa: BLE001
        log.debug("风格注入失败（不影响回复）: %s", exc)
    _t_hooks = _t_perf.monotonic()
    # 按对方性别决定角色（异性配对）：对面男→菲比女，对面女→菲比男
    _sex = ""
    try:
        _info = await bot.call_api("get_stranger_info",
                                   {"user_id": int(getattr(ctx, "user_id", 0) or 0)})
        _sex = str(((_info or {}).get("data") or {}).get("sex") or "").lower()
    except Exception:  # noqa: BLE001
        _sex = ""
    _is_female_peer = (_sex == "female")
    _role = "男性" if _is_female_peer else "女性"
    try:
        bot.role_gender = "male" if _is_female_peer else "female"
    except Exception:  # noqa: BLE001
        pass
    prompt = (f"（你在这段关系里扮演{_role}角色；对方是"
              f"{'女性' if _is_female_peer else '男性'}。）\n" + prompt)

    reply_text = await client.chat(
        session, prompt, context,
        images=vision_images(bot, ctx, quote_images),
        sticker_tags=sticker_tags(bot),
        identity=build_identity(bot, ctx),
        capability=build_capability(bot),
        memory=memory,
        summary=summary,
    )
    _t_chat = _t_perf.monotonic()
    log.debug("[perf] ctx=%.1fms hooks=%.1fms chat=%.1fms total=%.1fms prompt=%d mem=%d sum=%d kb=%d",
             (_t_ctx - _t0) * 1000, (_t_hooks - _t_ctx) * 1000,
             (_t_chat - _t_hooks) * 1000, (_t_chat - _t0) * 1000,
             len(prompt), len(memory or ""), len(summary or ""), len(context or ""))
    reply_text = fix_person(strip_stage_direction(strip_meta_narration(reply_text)))
    try:
        _lim = int(getattr(bot.config.ai, "reply_max_chars", 12) or 12)
    except (TypeError, ValueError):
        _lim = 12
    reply_text = clip_reply(reply_text, _lim)
    reply_text = strip_self_ref(reply_text, bot.self_id)
    reply_text = strip_banned(reply_text)
    reply_text = ensure_punct(reply_text)
    if looks_garbled(reply_text):
        log.info('回复疑似乱码（多语言混杂），已丢弃')
        reply_text = ''

    if not reply_text or "（模型没有返回内容）" in reply_text:
        log.info("模型空回复/旁白，已丢弃")
        return
    await respond(bot, ctx, reply_text, reply_mode, force_voice=wants_voice(asked))
    _spawn_summary(bot, client, session)



#: 后台摘要任务（避免被 GC 回收）
_bg_tasks: set = set()


def _spawn_summary(bot, client, session: str) -> None:
    """把滚动摘要丢到后台：不阻塞本条回复，也不占下一条的限速窗口。"""
    import asyncio as _aio

    async def _run():
        try:
            _spawn_summary(bot, client, session)
        except Exception:  # noqa: BLE001
            pass

    try:
        task = _aio.get_running_loop().create_task(_run())
        _bg_tasks.add(task)
        task.add_done_callback(_bg_tasks.discard)
    except RuntimeError:
        pass

def describe_sticker_items(bot) -> list[dict[str, Any]]:
    """给面板用的简洁列表（不含本地绝对路径）。"""
    return [
        {"id": item["id"], "name": item.get("name", ""), "tags": item.get("tags") or [],
         "size": item.get("size", 0)}
        for item in bot.stickers.list()
    ]