"""白话群管：管理员用大白话指挥机器人做群管理。

触发条件（三者同时满足才进入解析，普通成员的闲聊完全不受影响）：
  1. 群消息，且发送者是配置里的管理员（config.bot.admins，即账号主人本人）；
  2. AI 能力已启用；
  3. 消息以「称呼」（config.admin_nl.call_names）开头，或 @ 了机器人。

解析由模型完成，但**执行前一律在本地做白名单校验**：动作必须在 ACTIONS 里，
目标必须是本地真实解析出的 QQ 号，禁言时长会被夹到配置上限内。
任何拿不准的情况都返回 none，交回普通对话流程，绝不让模型凭空乱执行。
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any

from ..base import Plugin

# 可交给 AI 调用的全部 QQ 接口都登记在目录里，动作白名单、权限表与提示词
# 全部由它生成——新增接口只改 qqbot/ai/api_catalog.py 一处。
from ...ai.api_catalog import BY_NAME, CATEGORIES, describe_params, prompt_lines

#: 允许执行的动作白名单：动作 -> 说明
ACTIONS: dict[str, str] = {
    "mute": "禁言指定成员",
    "unmute": "解除指定成员的禁言",
    "kick": "把指定成员踢出群",
    "whole_ban": "开启全员禁言",
    "whole_unban": "解除全员禁言",
    "recall": "撤回所回复的那条消息",
    "essence": "把所回复的消息设为精华",
    "unessence": "取消所回复消息的精华",
    "poke": "戳一戳指定成员",
    "set_card": "修改群名片（支持单人，也支持全体；text 里用 {name} 代表原昵称）",
    "set_special_title": "设置指定成员的专属头衔",
    "set_admin": "设置指定成员为群管理员",
    "unset_admin": "取消指定成员的管理员",
    "set_group_name": "修改本群群名称",
    "set_announcement": "发布群公告",
    "set_group_portrait": "更换群头像（用消息里的图片）",
    "set_welcome": "设置新人入群欢迎语",
    "ban_word": "添加群违禁词（text 是词，多个词用「、」隔开；seconds 是命中后的禁言时长）",
    "unban_word": "移除群违禁词",
    "add_keyword": "添加关键词自动回复",
    "del_keyword": "删除关键词自动回复",
    "remember": "记住一条长期要求（text 写成「范围|内容」，范围填 全局/本群/对我）",
    "forget": "忘掉一条长期要求（text 是关键片段）",
    "like": "给成员主页点赞（单个/多个/全体；次数写在 text 里，不写用默认值）",
    "auto_accept_join": "自动同意加群申请/邀请（以后不再问）",
    "auto_accept_friend": "自动同意好友申请（以后不再问）",
    "auto_reject_join": "自动拒绝加群申请/邀请",
    "auto_reject_friend": "自动拒绝好友申请",
    "auto_off": "关闭自动审批（text 填 加群/好友，不填表示全部）",
    "group_info": "查询本群信息",
    "silence": "让机器人本群闭嘴（带 seconds 时长则到点自动恢复；不带时长＝永久闭嘴，等喊它说话）",
    "wake": "立刻解除本群闭嘴，恢复说话",
    "none": "这不是一条管理指令",
}

#: 每条动作默认的最低权限。分级是单调的：member < admin < owner
ACTION_LEVELS: dict[str, str] = {
    "mute": "admin",
    "unmute": "admin",
    "kick": "admin",
    "whole_ban": "admin",
    "whole_unban": "admin",
    "recall": "admin",
    "essence": "admin",
    "unessence": "admin",
    "poke": "admin",
    "set_card": "admin",
    "set_special_title": "owner",
    "set_admin": "owner",
    "unset_admin": "owner",
    "set_group_name": "owner",
    "set_announcement": "admin",
    "set_group_portrait": "owner",
    "set_welcome": "admin",
    "ban_word": "admin",
    "unban_word": "admin",
    "add_keyword": "admin",
    "del_keyword": "admin",
    "remember": "admin",
    "forget": "admin",
    "like": "admin",
    "auto_accept_join": "admin",
    "auto_accept_friend": "admin",
    "auto_reject_join": "admin",
    "auto_reject_friend": "admin",
    "auto_off": "admin",
    "group_info": "admin",
    "silence": "admin",
    "wake": "admin",
}

LEVEL_VALUE = {"member": 0, "admin": 1, "owner": 2}
LEVEL_LABEL = {"member": "群员", "admin": "管理员", "owner": "群主"}

#: 目录里的通用 QQ 接口一并并入白名单与权限表，
#: 这样「拉取群公告」「审批入群申请」这类要求 AI 才真的调得到。
ACTIONS.update({spec.name: f"{spec.label}：{spec.desc}" for spec in BY_NAME.values()})
ACTION_LEVELS.update({spec.name: spec.level for spec in BY_NAME.values()})

#: 手写动作的中文名（接口目录里的动作自带 label，这两边合起来面板上就没有英文裸奔了）
ACTION_LABELS: dict[str, str] = {
    "mute": "禁言成员",
    "unmute": "解除禁言",
    "kick": "踢出成员",
    "whole_ban": "开启全员禁言",
    "whole_unban": "解除全员禁言",
    "recall": "撤回消息",
    "essence": "设为精华",
    "unessence": "取消精华",
    "poke": "戳一戳",
    "set_card": "修改群名片",
    "set_special_title": "设置专属头衔",
    "set_admin": "设为管理员",
    "unset_admin": "取消管理员",
    "set_group_name": "修改群名称",
    "set_announcement": "发布群公告",
    "set_group_portrait": "更换群头像",
    "set_welcome": "设置入群欢迎语",
    "ban_word": "添加违禁词",
    "unban_word": "移除违禁词",
    "add_keyword": "添加关键词回复",
    "del_keyword": "删除关键词回复",
    "remember": "记住长期要求",
    "forget": "忘掉长期要求",
    "like": "给成员主页点赞",
    "auto_accept_join": "自动同意加群申请",
    "auto_accept_friend": "自动同意好友申请",
    "auto_reject_join": "自动拒绝加群申请",
    "auto_reject_friend": "自动拒绝好友申请",
    "auto_off": "关闭自动审批",
    "group_info": "查询本群信息",
    "silence": "让机器人闭嘴",
    "wake": "解除闭嘴",
}

#: 每条能力在聊天里的「正确说法」：面板的 ? 提示与模型提示词共用这一份，
#: 用户看得到什么、模型学到的就是什么，避免两边对不上。
ACTION_USAGE: dict[str, str] = {
    # ---------- 手写动作 ----------
    "mute": "「小T，@张三 禁言10分钟」——不写时长就用默认时长",
    "unmute": "「小T，给张三解禁」",
    "kick": "「小T，把张三踢出去」",
    "whole_ban": "「小T，全员禁言」",
    "whole_unban": "「小T，解除全员禁言」",
    "recall": "先回复要撤回的那条消息，再说「小T，撤回」",
    "essence": "先回复那条消息，再说「小T，设为精华」",
    "unessence": "先回复那条消息，再说「小T，取消精华」",
    "poke": "「小T，戳一下张三」",
    "set_card": "「小T，把张三的群名片改成摸鱼王」；全体用「小T，全员名片前面加[测试]」，"
                "格式里的 {name} 代表原昵称",
    "set_special_title": "「小T，把张三的头衔改成摸鱼王」",
    "set_admin": "「小T，设张三为管理员」",
    "unset_admin": "「小T，取消张三的管理员」",
    "set_group_name": "「小T，群名改成小T粉丝后援会」",
    "set_announcement": "「小T，发公告：明天群里休息一天」",
    "set_group_portrait": "先发一张图片，再说「小T，群头像换成这张」",
    "set_welcome": "「小T，入群欢迎语改成：欢迎新朋友」",
    "ban_word": "「小T，把「代购」加入违禁词，违者禁言10分钟」",
    "unban_word": "「小T，把「代购」移出违禁词」",
    "add_keyword": "「小T，加关键词 你好=>在的」",
    "del_keyword": "「小T，删掉关键词 你好」",
    "remember": "「小T，记住 本群|有问题先看群公告」（范围可选 全局/本群/对我）",
    "forget": "「小T，忘掉 有问题先看群公告」",
    "like": "「小T，给张三点20个赞」；全体用「小T，给全体点10个赞」",
    "auto_accept_join": "「小T，以后有人申请加群直接同意」",
    "auto_accept_friend": "「小T，以后有人加好友直接同意」",
    "auto_reject_join": "「小T，以后有人申请加群直接拒绝」",
    "auto_reject_friend": "「小T，以后有人加好友直接拒绝」",
    "auto_off": "「小T，关闭自动审批」（可补「加群」或「好友」）",
    "group_info": "「小T，群里现在多少人」",
    "silence": "「小T，闭嘴10分钟」",
    "wake": "「小T，可以说话了」",
    # ---------- 接口目录：群组查询 ----------
    "get_group_info": "「小T，本群信息」",
    "get_group_info_ex": "「小T，本群详细信息」",
    "get_group_list": "「小T，你在哪些群」",
    "get_group_member_info": "「小T，查一下张三的资料」",
    "get_group_member_list": "「小T，列一下群成员」",
    "get_group_honor_info": "「小T，看看群荣誉」",
    "get_group_shut_list": "「小T，谁还在禁言中」",
    "get_group_at_all_remain": "「小T，还能@全体几次」",
    "get_group_system_msg": "「小T，看看有没有加群申请」",
    "get_essence_msg_list": "「小T，列一下精华消息」",
    "_get_group_notice": "「小T，把群公告念给我听」",
    "get_group_root_files": "「小T，看看群文件」",
    "get_group_file_url": "「小T，给我文件 123 的下载地址」",
    # ---------- 接口目录：群组管理 ----------
    "set_group_leave": "「小T，退掉这个群」（解散需要机器人是群主）",
    "_del_group_notice": "「小T，删掉公告 123」",
    "set_group_add_request": "先说「小T，看看加群申请」拿到请求标识，再说「小T，同意这个加群申请」",
    "set_group_sign": "「小T，群签到」",
    "set_group_member_permissions": "「小T，允许群员发起临时会话/建新群」",
    # ---------- 接口目录：好友与用户 ----------
    "get_friend_list": "「小T，你有多少好友」",
    "get_stranger_info": "「小T，查一下 123456 的资料」",
    "get_profile_like": "「小T，谁赞了我」",
    "delete_friend": "「小T，把 123456 删好友」",
    "set_friend_remark": "「小T，把 123456 的备注改成老王」",
    "set_friend_add_request": "先看好友申请拿到请求标识，再说「小T，同意这个好友申请」",
    "group_poke": "「小T，戳一下群里的张三」",
    "friend_poke": "「小T，私聊戳一下张三」",
    "get_friend_msg_history": "「小T，看看我和张三的聊天记录」",
    # ---------- 接口目录：空间与动态 ----------
    "send_qzone_msg": "「小T，发条说说：今天群里休息」",
    "delete_qzone_msg": "「小T，删掉说说 123」",
    # ---------- 接口目录：消息处理 ----------
    "delete_msg": "先回复要删的那条消息，再说「小T，删掉这条」",
    "get_msg": "「小T，看看消息 123 的内容」；回复某条消息也说「看看这条」",
    "set_msg_emoji_like": "先回复那条消息，再说「小T，给这条贴个表情」",
    "forward_group_single_msg": "先回复要转发的那条消息，再说「小T，把这条转发到群 123456」",
    "forward_friend_single_msg": "先回复要转发的那条消息，再说「小T，把这条转发给张三的私聊」",
    "ocr_image": "先发一张图片，再说「小T，识别这张图里的文字」",
    "translate_en2zh": "「小T，把 hello 翻译成中文」",
    "check_url_safely": "「小T，这个链接安全吗 https://example.com」",
    "upload_group_file": "「小T，把这个文件传到群文件 /path/to/file」",
    "upload_private_file": "「小T，把这个文件发给张三 /path/to/file」",
    "mark_group_msg_as_read": "「小T，本群消息都标为已读」",
    "mark_private_msg_as_read": "「小T，把和张三的私信标为已读」",
    "_mark_all_as_read": "「小T，所有消息标为已读」",
    # ---------- 接口目录：账号相关 ----------
    "set_online_status": "「小T，把在线状态改成 1」",
    "set_qq_avatar": "先发一张图片，再说「小T，换你的QQ头像」",
    "set_qq_profile": "「小T，把你的QQ昵称改成小助手」",
    "set_self_longnick": "「小T，把你的签名改成今天也在线」",
    "ArkSharePeer": "「小T，生成一个加好友名片」",
    "ArkShareGroup": "「小T，生成群名片」",
    "get_recent_contact": "「小T，最近的会话有哪些」",
    "fetch_custom_face": "「小T，看看你的收藏表情」",
    "fetch_emoji_like": "「小T，这条消息上有哪些表情回应」",
}


def action_usage(action: str) -> str:
    """该能力的正确说法；目录里没登记说法的接口给一个通用句式。"""
    if action in ACTION_USAGE:
        return ACTION_USAGE[action]
    spec = BY_NAME.get(action)
    if spec is not None:
        return f"「小T，{spec.label}」"
    return f"「小T，{ACTION_LABELS.get(action, action)}」"


#: 手写动作里需要指定对象的（自定义理解词要补一句目标）
_MANUAL_TARGET_ACTIONS = {
    "mute", "unmute", "kick", "poke", "set_card", "set_special_title",
    "set_admin", "unset_admin", "like",
}
#: 手写动作里需要先回复某条消息的
_MANUAL_REPLY_ACTIONS = {"recall", "essence", "unessence"}
#: 手写动作里需要先发图片的
_MANUAL_IMAGE_ACTIONS = {"set_group_portrait"}


def action_pattern(action: str, word: str = "") -> str:
    """面板上展示的「完整句式」：自定义理解词 + 目标/参数占位。

    没填自定义词时退回 ``action_usage``，保证这一栏永远有可读的例子。
    """
    word = (word or "").strip()
    if not word:
        return action_usage(action)
    spec = BY_NAME.get(action)
    if spec is None:
        if action in _MANUAL_REPLY_ACTIONS:
            return f"先回复那条消息，再说「小T，{word}」"
        if action in _MANUAL_IMAGE_ACTIONS:
            return f"先发图片，再说「小T，{word}」"
        if action in _MANUAL_TARGET_ACTIONS:
            return f"「小T，{word} [目标QQ号 / @ 他]」"
        return f"「小T，{word}」"
    if "message_id" in spec.params:
        return f"先回复那条消息，再说「小T，{word}」"
    if "file" in spec.params:
        target = " [目标QQ号]" if "user_id" in spec.params else (
            " [群号]" if "group_id" in spec.params else ""
        )
        return f"「小T，{word}{target} [文件路径]」"
    if "user_id" in spec.params:
        return f"「小T，{word} [目标QQ号]」（也可以 @ 他 / 回复他后说「{word}」）"
    if "group_id" in spec.params:
        return f"「小T，{word} [群号]」"
    return f"「小T，{word}」"


#: 这些手写动作离不开「当前群」，私聊里执行不了（要改群得先说清是哪个群）
_NEEDS_GROUP = {
    "mute", "unmute", "kick", "whole_ban", "whole_unban", "recall",
    "essence", "unessence", "poke", "set_card", "set_special_title",
    "set_admin", "unset_admin", "set_group_name", "set_group_portrait",
    "silence", "wake", "group_info",
}

#: 允许把机器人自己当成目标的动作：管理员说「改你自己的群昵称」时，
#: 目标必须能真正落到机器人自己的 QQ 号上；其余动作（禁言、踢人…）仍把自己排除在外。
_SELF_TARGET_ACTIONS = {"set_card"}

#: 批量改名片时的上限与间隔（秒），避免一次改太多被上游限流
MAX_BATCH = 200
BATCH_INTERVAL = 0.25

#: 批量点赞的上限与间隔（点赞接口对频率很敏感）
LIKE_MAX = 100
LIKE_INTERVAL = 0.35

SYSTEM_PROMPT = """你是一个住在 QQ 里的真人助手。管理员用大白话给你提要求，你要把它解析成一条 JSON。

只输出 JSON，不要解释、不要代码块。格式固定为（**永远用 actions 数组，哪怕只有一件事**）：
{"actions": [{"action": "动作", "targets": [目标QQ号...], "seconds": 秒数或null, "text": "文字参数或null", "params": {接口参数}}]}

一条消息里要求做多件事时，就返回多个元素，**按对方说的顺序排列**，例如
「把 A、B 的昵称改成 X，把 C 改成 Y」要返回两个 set_card。
不要自己编 reply 之类的字段。

【最重要的原则】
- 你的任务是把对方想要的事**办成**，而不是解释你能做什么、不能做什么。
- 「给本群所有人点赞」「把公告念给我听」「以后有人申请加群直接同意」这类要求，
  都要自己拆成能执行的动作去做，不要反问、不要让他换个说法再说一遍。
- 只有**确实没有任何办法**做到时，才用 none 交给闲聊兜底；不要用 none 来逃避。
- 绝对不要在 JSON 里、也不要暗示任何内部名词：不提「接口」「插件」「后台」「系统」「协议」
  「需要由谁执行」这类说法。这些是你不该让人看见的东西。

【怎么选字段】
- 下面「可用动作」里带中文名的那种（mute、set_card…）：用 targets / seconds / text 填。
- 「接口清单」里的通用接口（如 _get_group_notice、set_group_add_request）：
  用 params 填它们的参数，键名必须和清单里列的一模一样，**不要自己造参数名**。
  参数值可以是字符串或数字；要填当前群号时直接用候选目标里给出的群号。
- 只读接口（标了「只读」的）只是查询，不会有副作用，放心调用。
- 群号没给且当前就在群里时，可以省略 group_id，系统会补上当前群。
- 用户说「这条消息」时，指的是**被回复的那条**（优先用「被回复消息ID」），
  没回复时才是当前这条；message_id 必须用下面给出的真实数字，**绝对不要编造**。

【用户常这么说 → 用哪个动作】
- 「把这条转发给张三的私聊 / 转给他」→ forward_friend_single_msg，
  params 填 {"message_id": 被回复或当前消息ID, "user_id": 张三的QQ}
- 「把这条转发到群 123456 / 转到隔壁群」→ forward_group_single_msg，
  params 填 {"message_id": 消息ID, "group_id": 目标群号}
- 「撤回 / 删掉这条消息」→ recall（被回复时）或 delete_msg（有消息ID时）
- 「把群公告念给我听 / 有什么公告」→ _get_group_notice
- 「删掉公告」→ _del_group_notice（需要 notice_id）
- 「看看有没有加群申请 / 好友申请」→ get_group_system_msg
- 「同意这个加群申请 / 好友申请」→ set_group_add_request / set_friend_add_request（需要 flag）
- 「私聊戳他一下」→ friend_poke；「在群里戳他」→ group_poke
- 「发条说说 / 发空间」→ send_qzone_msg；「把签名改成…」→ set_self_longnick
- 「你有多少好友 / 我的群列表 / 谁赞了我」→ get_friend_list / get_group_list / get_profile_like
- 「上传文件到群 / 发文件给他」→ upload_group_file / upload_private_file
- 只是问「你会不会 / 能不能做某件事」而是在确认能力时，也用对应动作真正去做，
  不要只回答「可以」却不给 actions。

可用动作：
- mute 禁言 / unmute 解除禁言 / kick 踢出成员
- whole_ban 全员禁言 / whole_unban 解除全员禁言
- recall 撤回消息 / essence 设为精华 / unessence 取消精华（都是对方回复的那条消息）
- poke 戳一戳某人
- set_card 改群昵称 / 群名片（text 是新名片；改全体时 targets 填 ["all"]；text 里用 {name} 代表对方原昵称）
- set_special_title 设置专属头衔（text 是头衔内容）
- set_admin 设为管理员 / unset_admin 取消管理员
- set_group_name 修改群名称（text 是新群名）
- set_announcement 发布群公告（text 是公告正文）
- set_group_portrait 更换群头像（用对方发来的那张图片）
- set_welcome 设置入群欢迎语（text 是欢迎语全文）
- ban_word 添加违禁词 / unban_word 移除违禁词（text 是词，多个词用「、」隔开；
  说「以后谁说脏话就禁言10分钟」这类要求时用 ban_word 并把 seconds 填 600，
  同时保存下命中后的禁言时长）
- add_keyword 添加关键词自动回复（text 写成「关键词=>回复内容」）/ del_keyword 删除关键词（text 是关键词）
- remember 记住长期要求（text 写成「范围|内容」，范围填 全局/本群/对我：
  全局=任何场合都生效，本群=只在当前群生效，对我=只针对发指令的人。
  例如「以后叫我哥哥」→ text 填「对我|以后叫发指令的人哥哥」）
- forget 忘掉长期要求（text 填要删除的记忆关键片段）
- like 给成员主页点赞（targets 填人；说「全体/所有人」就填 ["all"]；次数写在 text 里，例如
  「给我主页点20个赞」→ targets 填发指令的人本人、text 填 "20"）
- auto_accept_join 以后自动同意加群申请/邀请 / auto_accept_friend 以后自动同意好友申请
  （「以后有人申请加群直接同意」用 auto_accept_join；这是长期开关，说一次就永久生效）
- auto_reject_join 以后自动拒绝加群申请 / auto_reject_friend 以后自动拒绝好友申请
- auto_off 关闭自动审批（text 填「加群」或「好友」，不填表示全部关掉）
- group_info 查询本群信息
- silence 让机器人本群闭嘴（「闭嘴10分钟」填 seconds=600；「在这个群不许发言」不填 seconds＝永久）
- wake 立刻解除闭嘴（「可以说话了」「解除闭嘴」）
- none 这不是一条管理指令

规则：
- 禁言群成员且对方没说时长时，统一用 {default_mute} 秒；让机器人自己闭嘴（silence）没说时长则是永久。
- 对方说「我」「给我」「把我」时，targets 填他自己的 QQ 号（见候选目标里的「发指令的人本人」）。
- 候选目标里的「机器人本人（我自己）」就是你自己的号。对方说「你自己」「你」「机器人自己」时，
  targets 填你自己那个号，不要填成发指令的人——例如「改你自己的群昵称」就是改你自己的名片。
- 对方说「全体」「所有人」时，targets 填 ["all"]。
- 「群昵称」「本群昵称」「群名片」说的是别人**在这个群里**显示的名字 → 用 set_card；
  「QQ 昵称」「账号昵称」说的是账号本身的名字 → 用 set_qq_profile 的 nickname（只改机器人自己）。
- 改机器人自己的 QQ 账号昵称：action 填 set_qq_profile，params 填 {"nickname": "新昵称"}，targets 留空；
  绝对不要用 set_card 代替（set_card 只改本群名片）。
  两个词不能混：对方没说「QQ 昵称」就别去动账号资料；说的是「QQ 昵称」也别拿 set_card 顶替。
- targets 只能填「候选目标」里给出的 QQ 号，没有合适的就填空数组，绝对不要编造。
- 对方只是闲聊、提问，或你拿不准时，action 用 none。"""

#: 接口清单单独拼接，避免把 SYSTEM_PROMPT 撑得太长不好维护
CATALOG_PROMPT = """【接口清单】（这些要用 params 字段填参数）
{catalog}"""

_JSON_RE = re.compile(r"\{.*\}", re.S)

#: 一句话里出现这些连接词，就有理由怀疑藏了多个动作
_COMPOUND_RE = re.compile(r"然后|之后|并且|同时|顺便|接着|再把|再帮|再给|再让|再把|另外|还有")

#: 没叫名字时，本地先看一眼有没有「管群」的味道——命中才送去交给模型理解，
#: 免得管理员随口聊一句也要花一次模型调用，甚至被误当成指令。
_MGMT_HINT_RE = re.compile(
    r"禁言|闭嘴|安静|沉默|禁掉|踢|移除|飞机票|全员|公告|群名|群规|名片|昵称|头衔|精华|加精|"
    r"撤回|删掉|删了|管理员|违禁词|关键词|欢迎|入群|点赞|申请|同意|拒绝|审批|改名|头像|"
    r"记住|以后|拉黑|警告|刷屏|吵|闹|别说话|少废话|管一下|处理一下|解禁|解封|发个公告|改一下"
)

#: 兜底用：先把整句拆成互相独立的小指令
SPLIT_PROMPT = """把用户这一句话拆成若干条**互相独立、各自只做一件事**的小指令。

规则：
- 每行输出一条，不要编号、不要引号、不要解释、不要 JSON。
- 只是同一个动作里的多个对象，不要拆（「把张三李四都禁言」算一条）。
- 「把张三李四设为管理员」里，对象是两个人、动作只有一个，算一条，targets 会有两个 QQ。
- 本来就是一条指令时，原样输出一行即可。"""


class AdminNLPlugin(Plugin):
    name = "admin_nl"
    display_name = "白话群管"
    version = "0.1.0"
    description = "白话群管：管理员用自然语言下群管理指令"
    priority = 30  # 低于自主模式(40)与 AI 对话(50)，先于它们拿到消息

    def __init__(self, bot) -> None:
        super().__init__(bot)

    async def on_load(self) -> None:
        if self.bot.config.admin_nl.enabled:
            self.log.info(
                "白话群管已启用，称呼=%s，可调用接口 %d 个",
                self.bot.config.admin_nl.call_names, len(BY_NAME),
            )
        else:
            self.log.info("白话群管未启用（config.admin_nl.enabled=false）")

    async def on_unload(self) -> None:
        # 客户端由 Bot 共享持有，这里不关（否则会打断其它插件的会话）
        pass

    def _get_client(self):
        """用 Bot 上共享的客户端：与 AI 对话 / 自主模式共用同一份上下文。"""
        return self.bot.chat_client()

    # ---------- 触发判定 ----------

    @property
    def _active(self) -> bool:
        return bool(self.bot.config.admin_nl.enabled and self.bot.config.ai.enabled)

    def _render(self, ctx) -> str:
        """把消息渲染成带 @ 标记的文本，便于模型看清结构。"""
        parts: list[str] = []
        for seg in ctx.message:
            seg_type = getattr(seg, "type", "")
            if seg_type == "text":
                parts.append(str(seg.data.get("text", "")))
            elif seg_type == "at":
                qq = str(seg.data.get("qq", ""))
                parts.append("@全体成员" if qq == "all" else f"@{qq}")
        return "".join(parts)

    def _is_at_me(self, ctx) -> bool:
        if not self.bot.self_id:
            return False
        target = str(self.bot.self_id)
        for seg in ctx.message:
            if getattr(seg, "type", "") == "at" and str(seg.data.get("qq")) == target:
                return True
        return False

    def _called(self, ctx, text: str) -> bool:
        if self._called_private(ctx):
            return True
        if self._is_at_me(ctx):
            return True
        from ...core.bot import strip_call_word

        return strip_call_word(text, self.bot.call_words()) is not None

    def _strip_call_name(self, text: str) -> str:
        from ...core.bot import strip_call_word

        stripped = strip_call_word(text, self.bot.call_words())
        return text if stripped is None else stripped

    # ---------- 自动领会（没叫名字也听懂）----------

    def _free_listen_on(self, level: str) -> bool:
        """未叫名字时要不要也进入理解：off 关闭 / admin 仅管理员 / all 按权限表。"""
        mode = str(getattr(self.bot.config.admin_nl, "free_listen", "off") or "off").lower()
        if mode == "all":
            return True
        if mode == "admin":
            return LEVEL_VALUE.get(level, 0) >= LEVEL_VALUE["admin"]
        return False

    def _mgmt_hint_in(self, text: str) -> bool:
        """只看文本是否像管理指令（不看引用/艾特/目标）——私聊主人消息默认是闲聊。"""
        if _MGMT_HINT_RE.search(text or ""):
            return True
        custom = getattr(self.bot.config.admin_nl, "custom_words", {}) or {}
        return any(
            str(word).strip() and str(word).strip() in (text or "")
            for word in custom.values()
        )

    def _maybe_instruction(self, ctx, text: str, targets: dict[int, str] | None = None) -> bool:
        """本地先挡一道：看着像管理指令才送去交给模型理解。

        ``targets`` 传进来时会额外看「候选目标里是不是出现了别人」——
        按昵称召回的成员也在其中，这样「张三太吵了」这种不带动词的话也认得出来。
        """
        if self._mgmt_hint_in(text):
            return True
        if self._reply_message_id(ctx) is not None:
            return True
        if any(getattr(seg, "type", "") == "at" for seg in ctx.message):
            return True
        if targets:
            sender = int(getattr(ctx.event, "user_id", 0) or 0)
            if any(int(qq) != sender for qq in targets):
                return True
        return False

    async def _free_intent(self, ctx, text: str) -> dict[int, str] | None:
        """未叫名字时的领会判定：像管理指令就返回候选目标，否则返回 None。"""
        if not self._maybe_instruction(ctx, text):
            return None
        reply_target = await self._reply_target(ctx)
        targets = await self._collect_targets(ctx, text, reply_target)
        if not self._maybe_instruction(ctx, text, targets):
            return None
        return targets

    # ---------- 权限分级 ----------

    def levels(self) -> dict[str, str]:
        """每条动作当前生效的最低权限（后台配置可覆盖默认值）。"""
        overrides = self.bot.config.admin_nl.permissions or {}
        return {
            action: str(overrides.get(action) or ACTION_LEVELS.get(action, "admin"))
            for action in ACTION_LEVELS
        }

    def _user_level_of(self, ctx) -> str:
        """谁能算「管理员」：只有配置里的机器人主人（config.bot.admins）。

        QQ 群里的群主/群管理**不算**——他们和普通群员同级，只能用面板里
        主动降到「群员可用」的动作。否则随便哪个群的管理员都能指挥机器人
        （改名片、禁言，甚至让它记住长期要求）。
        """
        return "owner" if self._is_owner(ctx) else "member"

    def _allowed(self, action: str, user_level: str) -> bool:
        need = LEVEL_VALUE.get(self.levels().get(action, "admin"), 1)
        return LEVEL_VALUE.get(user_level, 0) >= need

    def _member_can_trigger(self) -> bool:
        """有任意一条动作降到「群员可用」时，普通成员的消息才需要进入解析。"""
        return any(LEVEL_VALUE.get(level, 1) == 0 for level in self.levels().values())

    @staticmethod
    def _reply_message_id(ctx) -> Any:
        for seg in ctx.message:
            if getattr(seg, "type", "") == "reply":
                return seg.data.get("id")
        return None

    # ---------- 候选目标 ----------

    async def _reply_target(self, ctx) -> dict[str, Any] | None:
        """回复了某条消息时，解析出那条消息的发送者。"""
        message_id = self._reply_message_id(ctx)
        if message_id is None:
            return None
        try:
            resp = await self.bot.call_api("get_msg", message_id=message_id)
        except Exception:  # noqa: BLE001
            return None
        sender = ((resp.get("data") or {}) if isinstance(resp, dict) else {}).get("sender") or {}
        user_id = sender.get("user_id")
        if not user_id:
            return None
        nickname = sender.get("card") or sender.get("nickname") or ""
        return {"user_id": int(user_id), "note": f"被回复消息的发送者（{nickname}）"}

    async def _members(self, group_id) -> list[dict[str, Any]]:
        """拉取群成员列表（本地接口，不消耗 token）。私聊没有群，直接返回空。"""
        if not group_id:
            return []
        try:
            resp = await self.bot.call_api("get_group_member_list", group_id=int(group_id))
        except Exception as exc:  # noqa: BLE001
            self.log.warning("获取群成员列表失败: %s", exc)
            return []
        members = resp.get("data") if isinstance(resp, dict) else None
        return members if isinstance(members, list) else []

    async def _collect_targets(self, ctx, text: str, reply_target) -> dict[int, str]:
        """只在本地召回候选目标，把结果作为上下文喂给模型，避免它编造 QQ 号。"""
        targets: dict[int, str] = {}

        # 先放发指令的人自己，「给我管理员」这类说法才解析得出来
        if ctx.event.user_id:
            targets[int(ctx.event.user_id)] = "发指令的人本人（我）"

        for seg in ctx.message:
            if getattr(seg, "type", "") != "at":
                continue
            qq = str(seg.data.get("qq", ""))
            if qq.isdigit() and int(qq) != self.bot.self_id:
                targets[int(qq)] = "被 @ 的人"

        if reply_target and reply_target["user_id"] != self.bot.self_id:
            targets.setdefault(reply_target["user_id"], reply_target["note"])

        # 已有明确目标（@ 或回复）时不必再拉群成员列表，省一次大响应
        if len(targets) <= 1 and not reply_target:
            for member in await self._members(ctx.group_id):
                name = str(member.get("card") or member.get("nickname") or "").strip()
                user_id = member.get("user_id")
                if not name or not user_id:
                    continue
                if int(user_id) == self.bot.self_id or int(user_id) in targets:
                    continue
                if name in text:
                    targets[int(user_id)] = f"群成员（{name}）"
                    if len(targets) >= 8:
                        break

        # 机器人自己也算一个候选目标——「改你自己的群昵称」这类要求
        # 必须能落到真实的 QQ 号上，否则模型只能猜别人，白跑一趟。
        if self.bot.self_id and int(self.bot.self_id) not in targets:
            targets[int(self.bot.self_id)] = "机器人本人（我自己）"
        return targets

    # ---------- 模型解析 ----------

    @staticmethod
    def _parse(raw: str) -> list[dict[str, Any]]:
        """解析成动作列表。兼容单对象与 actions 数组两种返回。"""
        match = _JSON_RE.search(raw or "")
        if not match:
            return []
        try:
            data = json.loads(match.group(0))
        except json.JSONDecodeError:
            return []
        if not isinstance(data, dict):
            return []

        if isinstance(data.get("actions"), list):
            items = data["actions"]
        else:
            items = [data]
        return [item for item in items if isinstance(item, dict)]

    def _allowed_actions(self, level: str) -> set[str]:
        """该等级真正能用的动作名（与执行前的权限校验同源）。

        提示词按它裁剪，模型就不会提出自己（或对方）根本没有的能力——
        「已有权限就是 AI 会的」这个边界由这里保证。
        """
        value = LEVEL_VALUE.get(level, 0)
        return {
            action
            for action in ACTIONS
            if action != "none" and LEVEL_VALUE.get(self.levels().get(action, "admin"), 1) <= value
        }

    def _build_system(self, level: str) -> str:
        """按当前发送者的权限拼系统提示词：显式列出可用动作 + 过滤后的接口清单。"""
        cfg = self.bot.config.admin_nl
        allowed = self._allowed_actions(level)
        # 提示词里含 JSON 花括号，不能用 str.format，改用占位符替换
        system = SYSTEM_PROMPT.replace("{default_mute}", str(int(cfg.default_mute_seconds)))
        listed = "、".join(sorted(allowed))
        level_label = LEVEL_LABEL.get(level, "群员")
        system = (
            f"{system}\n\n【你当前的身份】{level_label}。"
            "「本次可用动作」就是你现在真正拥有的全部能力：在列表里的就放手去做，"
            "不要怀疑自己有没有权限；不在列表里的不要提、也不要答应。"
            "\n接口调用失败时，多数是机器人在群里的身份不够或上游不支持，"
            "要如实说没做成，绝不能编「已经办好了」。"
            f"\n\n【本次可用动作】只允许用下面这些，用别的会被直接拒绝：{listed}"
        )
        # 通用接口补一句「用户会怎么说」，模型才认得大白话该落到哪个动作上
        usage = [
            f"- {action}（{BY_NAME[action].label}）：{action_usage(action)}"
            for action in sorted(allowed)
            if action in BY_NAME and action in ACTION_USAGE
        ]
        if usage:
            system += "\n\n【这些接口用户可能这么说】\n" + "\n".join(usage)
        # 管理员在面板里填的自定义理解词，直接当成动作别名交给模型
        custom = getattr(cfg, "custom_words", {}) or {}
        custom_lines = [
            f"- 用户说「{str(word).strip()}」→ {action}"
            f"（{BY_NAME[action].label if action in BY_NAME else ACTION_LABELS.get(action, action)}）"
            for action, word in custom.items()
            if action in allowed and str(word).strip()
        ]
        if custom_lines:
            system += (
                "\n\n【自定义理解词】用户说出下面这些词时，就执行对应动作：\n"
                + "\n".join(custom_lines)
            )
        catalog = "\n".join(prompt_lines(allowed))
        # 置控台人物绑定：白话指令里只叫名字时，模型也能落到真实 QQ 号上
        try:
            from ._ai_reply import bindings_text

            bindings = bindings_text(self.bot)
        except Exception:  # noqa: BLE001 - 绑定表缺失不影响解析
            bindings = ""
        if bindings:
            system += "\n\n" + bindings
        return f"{system}\n\n{CATALOG_PROMPT.replace('{catalog}', catalog)}"

    @staticmethod
    def _user_prompt(text: str, targets: dict[int, str], ctx=None) -> str:
        lines = [f"管理员说：{text}"]
        if ctx is not None:
            # 把真实的消息 ID 交给模型，转发/撤回类接口才用得上，不用它自己编
            reply_id = AdminNLPlugin._reply_message_id(ctx)
            message_id = getattr(getattr(ctx, "event", None), "message_id", None)
            if reply_id:
                lines.append(f"被回复消息ID：{reply_id}（用户说「这条」时优先用它）")
            if message_id:
                lines.append(f"当前消息ID：{message_id}")
            group_id = getattr(ctx, "group_id", None)
            if group_id:
                lines.append(f"当前群号：{group_id}")
        if targets:
            lines.append(
                "候选目标（targets 只能从这里选）："
                + "；".join(f"{qq}（{note}）" for qq, note in targets.items())
            )
        else:
            lines.append("候选目标：（无，targets 请填空数组）")
        return "\n".join(lines)

    async def _ask(
        self, text: str, targets: dict[int, str], level: str, ctx=None
    ) -> list[dict[str, Any]]:
        raw = await self._get_client().complete(
            self._build_system(level),
            self._user_prompt(text, targets, ctx),
            temperature=0.0,
            max_tokens=900,
        )
        return self._parse(raw)

    async def _ask_multi(
        self,
        text: str,
        targets: dict[int, str],
        level: str,
        transcript: list[tuple[str, str]],
        ctx=None,
    ) -> tuple[str, list[dict[str, Any]]]:
        """多轮思考的一次调用：带着「刚才做了什么、结果怎样」继续问。

        返回 (模型原始输出, 解析出的动作)——原始输出要回填进对话，
        否则下一轮模型看不到自己上一轮说过什么。
        """
        system = self._build_system(level)
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": system},
            {"role": "user", "content": self._user_prompt(text, targets, ctx)},
        ]
        for role, content in transcript:
            messages.append({"role": role, "content": content})
        raw = await self._get_client().complete_messages(
            system, messages, temperature=0.0, max_tokens=900
        )
        return raw, self._parse(raw)

    @staticmethod
    def _looks_compound(text: str) -> bool:
        """句子里是否出现「然后/再把」这类连接词，暗示可能是多条指令。"""
        return bool(_COMPOUND_RE.search(text or ""))

    async def _ask_split(
        self, text: str, targets: dict[int, str], level: str, ctx=None
    ) -> list[dict[str, Any]]:
        """兜底路径：先把整句拆成若干条独立小指令，再逐条解析。

        只在快路径失败、或明显是多条指令却只解析出一个动作时才走这里——
        多花几次调用换正确性，平时不影响速度。
        """
        try:
            raw = await self._get_client().complete(
                SPLIT_PROMPT, text, temperature=0.0, max_tokens=300
            )
        except Exception as exc:  # noqa: BLE001
            self.log.warning("拆分指令失败: %s", exc)
            return []

        parts: list[str] = []
        for line in (raw or "").splitlines():
            piece = re.sub(r"^[\s\-\*•·>]+|^[\d一二三四五六七八九十]+[\.、\)]\s*", "", line).strip()
            if piece:
                parts.append(piece)
        parts = parts[:8]

        self.log.info("拆分模式：%r -> %d 条小指令", text[:40], len(parts))
        actions: list[dict[str, Any]] = []
        for piece in parts:
            got = await self._ask(piece, targets, level, ctx)
            actions.extend(
                item for item in got
                if str(item.get("action") or "none") not in ("", "none")
            )
        return actions

    # ---------- 执行 ----------

    def _clamp(self, seconds: Any) -> int:
        cfg = self.bot.config.admin_nl
        default = int(cfg.default_mute_seconds or 600)
        limit = int(cfg.max_mute_seconds or 2592000)
        try:
            value = int(seconds) if seconds is not None else default
        except (TypeError, ValueError):
            value = default
        return max(60, min(value, limit))

    @staticmethod
    def _fmt_duration(seconds: int) -> str:
        if seconds % 86400 == 0:
            return f"{seconds // 86400} 天"
        if seconds % 3600 == 0:
            return f"{seconds // 3600} 小时"
        if seconds % 60 == 0:
            return f"{seconds // 60} 分钟"
        return f"{seconds} 秒"

    async def _message_image(self, ctx, limit: int = 400) -> str:
        """取本次消息（或所回复消息）里的第一张图片 URL。"""
        for seg in ctx.message:
            if getattr(seg, "type", "") == "image":
                url = str(seg.data.get("url") or seg.data.get("file") or "")
                if url.startswith(("http://", "https://", "file://", "base64://")):
                    return url

        message_id = self._reply_message_id(ctx)
        if message_id is None:
            return ""
        try:
            resp = await self.bot.call_api("get_msg", message_id=message_id)
            content = ((resp.get("data") or {}) if isinstance(resp, dict) else {}).get("message")
        except Exception:  # noqa: BLE001
            return ""
        if not isinstance(content, list):
            return ""
        for seg in content[:limit]:
            if not isinstance(seg, dict) or seg.get("type") != "image":
                continue
            data = seg.get("data") or {}
            url = str(data.get("url") or data.get("file") or "")
            if url.startswith(("http://", "https://", "file://", "base64://")):
                return url
        return ""

    async def _do_set_card(
        self, ctx, group_id: int, template: str, targets: list[int], want_all: bool
    ) -> str:
        """改群名片：支持单人、多个、全体；模板里的 {name} 会替换成原昵称。

        无论成功失败都如实汇报数量——绝不能出现「说好了但没改」。
        """
        members = await self._members(group_id)
        index = {int(m.get("user_id") or 0): m for m in members if m.get("user_id")}

        if want_all or not targets:
            selected = members
            broadcast = True
        else:
            selected = [index.get(uid, {"user_id": uid}) for uid in targets]
            broadcast = len(selected) > 1

        if not selected:
            return "拿不到群成员列表，没法改名片。"

        # 指名要改机器人自己的名片时（「改你自己的昵称」）不再跳过自己；
        # 「全体」批量改名片时仍然跳过，不动机器人自己的名片。
        want_self = bool(self.bot.self_id) and int(self.bot.self_id) in targets

        changed = failed = 0
        for member in selected[:MAX_BATCH]:
            uid = int(member.get("user_id") or 0)
            if not uid or (uid == self.bot.self_id and not want_self):
                continue
            original = str(member.get("card") or member.get("nickname") or "")
            card = template.replace("{name}", original).strip()[:60]
            try:
                await self._call("set_group_card", group_id=group_id, user_id=uid, card=card)
                changed += 1
            except Exception as exc:  # noqa: BLE001
                failed += 1
                self.log.warning("改名片失败 uid=%s: %s", uid, exc)
            if broadcast:
                await asyncio.sleep(BATCH_INTERVAL)  # 别把上游打爆

        self.log.info("白话群管：改群名片 %d 成功 / %d 失败（全体=%s）", changed, failed, broadcast)
        if broadcast:
            head = f"已改 {changed} 人的群名片"
            return head + (f"，另有 {failed} 人没改成。" if failed else "。")
        if failed:
            return "名片没能改成，我在本群的权限可能不够。"
        return "已修改群名片。"

    @staticmethod
    def _check(resp: Any) -> None:
        """OneBot 失败时不会抛异常，而是回 status=failed，这里显式转成异常。"""
        if isinstance(resp, dict) and resp.get("status") == "failed":
            raise RuntimeError(str(resp.get("message") or resp.get("wording") or "接口返回失败"))

    async def _call(self, action: str, **params: Any) -> Any:
        resp = await self.bot.call_api(action, params)
        self._check(resp)
        return resp

    async def _do_memory(self, ctx, action: str, text: str) -> str:
        """记住 / 忘掉一条长期记忆。

        记忆会长期影响机器人的言行，所以这里和记忆标记走同一套作用域规则，
        并且只允许管理员操作（权限已在上层校验过）。
        """
        from ...memory import normalize_scope

        store = self.bot.memory
        if action == "forget":
            needle = (text or "").strip()
            if not needle:
                return "要忘掉哪条？给我个关键片段就行。"
            group_id = int(ctx.group_id or 0)
            user_id = int(ctx.user_id or 0)
            candidates = (
                store.list("global")
                + (store.list("group", group_id) if group_id else [])
                + (store.list("user", user_id) if user_id else [])
            )
            hit = next((m for m in candidates if needle in str(m.get("content") or "")), None)
            if hit is None:
                return f"没找到含「{needle}」的记忆。"
            store.delete(int(hit["id"]))
            self.log.info("白话群管：忘记记忆 #%s", hit["id"])
            return f"已经忘掉「{str(hit.get('content'))[:40]}」。"

        parts = re.split(r"[|｜]", text or "", maxsplit=1)
        if len(parts) == 2:
            scope_raw, content = parts[0], parts[1]
        else:
            scope_raw, content = "", parts[0]
        content = content.strip()
        if not content:
            return "要记住什么？请再说一次。"

        scope = normalize_scope(scope_raw) or ("group" if ctx.is_group else "user")
        try:
            store.add(
                content,
                scope,
                int(ctx.group_id or 0) if scope == "group" else 0,
                int(ctx.user_id or 0) if scope == "user" else 0,
                "admin_nl",
            )
        except ValueError as exc:  # noqa: BLE001
            return f"没能记住：{exc}"
        self.log.info("白话群管：记住了 [%s] %s", scope, content[:40])
        return f"已记住：{content}"

    async def _do_like(self, ctx, data: dict[str, Any]) -> str:
        """给主页点赞：支持单个、多个、全体；次数从 text 或 seconds 取。

        「给本群所有人每人点20个赞」这种批量操作必须在这里展开——通用接口一次只能点一个人。
        """
        raw = data.get("targets") or []
        want_all = any(
            str(t).strip().lower() in ("all", "全体", "所有人", "全部") for t in raw
        )
        targets = [
            int(t) for t in raw
            if str(t).lstrip("-").isdigit() and int(t) != self.bot.self_id
        ]

        section = self.bot.config.custom.get("qq_social") or {}
        default_times = int(section.get("default_like_times") or 10)
        digits = [int(n) for n in re.findall(r"\d+", str(data.get("text") or ""))]
        times = digits[0] if digits else int(data.get("seconds") or default_times)
        times = max(1, min(times, 50))  # 点太快会被限流，封顶 50

        if want_all or not targets:
            if not ctx.group_id:
                return "要给大家点赞的话，在群里跟我说，或者把群号告诉我。"
            members = await self._members(ctx.group_id)
            targets = [
                int(m.get("user_id") or 0) for m in members
                if m.get("user_id") and int(m["user_id"]) != self.bot.self_id
            ]
        if not targets:
            return "要给谁点赞？@ 他一下，或者说「全体」。"
        targets = targets[:LIKE_MAX]

        done = failed = 0
        for uid in targets:
            try:
                self._check(await self.bot.call_api("send_like", user_id=uid, times=times))
                done += 1
            except Exception as exc:  # noqa: BLE001
                failed += 1
                self.log.warning("点赞 %s 失败: %s", uid, exc)
            if len(targets) > 1:
                await asyncio.sleep(LIKE_INTERVAL)  # 别把上游打爆
        self.log.info("白话群管：点赞 %d 成功 / %d 失败，每人 %d 次", done, failed, times)

        if len(targets) == 1:
            if done:
                return f"已经给 {targets[0]} 点了 {times} 个赞啦。"
            return "点赞没成功，可能是太频繁了，等一会儿再试试。"
        out = f"给大家点完赞了：成功 {done} 人"
        if failed:
            out += f"，{failed} 人失败"
        return out + f"，每人 {times} 个。"

    def _set_auto_approve(self, action: str, text: str) -> str:
        """开/关「申请自动处理」的开关。

        这是社交操作那套配置项，这里直接改它——用户只关心「以后能不能自动过」，
        不该被「这归哪个模块管」卡住。
        """
        section = self.bot.config.custom.setdefault("qq_social", {})
        said = str(text or "")
        is_group = ("加群" in said) or ("入群" in said) or ("群" in said)
        is_friend = ("好友" in said) or ("friend" in said.lower())
        if not is_group and not is_friend:  # 没说范围就两边都算
            is_group = is_friend = True

        what = "加群申请" if is_group and not is_friend else (
            "好友申请" if is_friend and not is_group else "加群和好友申请"
        )

        if action == "auto_off":
            if is_group:
                section["group_auto_accept"] = False
                section["group_auto_reject"] = False
            if is_friend:
                section["friend_auto_accept"] = False
                section["friend_auto_reject"] = False
            self.bot.config.save()
            self.log.info("白话群管：关闭自动审批（%s）", what)
            return f"好，以后{what}我不再自动处理了，会先转给你确认。"

        accept = "accept" in action
        if is_group:
            section["group_auto_accept"] = accept
            section["group_auto_reject"] = not accept
        if is_friend:
            section["friend_auto_accept"] = accept
            section["friend_auto_reject"] = not accept
        self.bot.config.save()
        verb = "同意" if accept else "拒绝"
        self.log.info("白话群管：自动%s（%s）", verb, what)
        return f"好，以后有{what}我直接{verb}，不再麻烦你确认。"

    async def _run_catalog(self, ctx, action: str, data: dict[str, Any]) -> str:
        """执行接口目录里的通用 QQ 接口。

        参数按目录白名单过滤后才转发，模型写错的参数名会被丢弃并如实告知，
        绝不把未知字段透传给协议层。返回值说成人话，不出现接口名与 JSON。
        """
        spec = BY_NAME[action]
        raw = data.get("params")
        given = dict(raw) if isinstance(raw, dict) else {}
        # 模型偶尔把该填进 params 的 QQ / 群号 / 消息 ID 写到顶层，这里按 ID 类字段兜底并回来；
        # QQ 号还能从 targets 搬进 user_id，群号缺省补当前群，
        # 消息 ID 用「被回复的那条」或「当前这条」——转发/撤回类接口全靠它。
        for key in ("user_id", "group_id", "message_id", "notice_id", "file_id", "flag"):
            if (
                key in spec.params
                and key not in given
                and key in data
                and data[key] not in (None, "", [])
            ):
                given[key] = data[key]
        if "user_id" in spec.params and "user_id" not in given:
            for item in data.get("targets") or []:
                value = str(item).strip()
                if value.lstrip("-").isdigit():
                    given["user_id"] = int(value)
                    break
        if "group_id" in spec.params and "group_id" not in given and ctx.group_id:
            given["group_id"] = ctx.group_id
        if "message_id" in spec.params and "message_id" not in given:
            message_id = self._reply_message_id(ctx) or getattr(ctx.event, "message_id", None)
            if message_id:
                given["message_id"] = message_id
        params, dropped = describe_params(action, given)
        if dropped:
            self.log.info("接口 %s 丢弃了未知参数 %s", action, dropped)
        # 必填参数没给齐就直接问用户，绝不发半截请求
        missing = [k for k in spec.required if k not in params]
        if missing or (not params and spec.params):
            return (
                f"「{spec.label}」需要参数："
                + "、".join(
                    f"{k}（{'必填，' if k in spec.required else ''}{v}）"
                    for k, v in spec.params.items()
                )
            )

        try:
            resp = await self.bot.call_api(action, params)
            self._check(resp)
        except Exception as exc:  # noqa: BLE001
            self.log.error("接口 %s 执行失败: %s", action, exc)
            return f"{spec.label}失败：{str(exc)[:120]}"

        payload = resp.get("data") if isinstance(resp, dict) else None
        self.log.info("接口 %s 执行成功 params=%s", action, list(params))
        return self._humanize(spec, params, payload)

    #: 写操作的人话模板：{参数名} 会被真实取值替换，尽量具体到「对谁做了什么」
    _HUMAN_DONE: dict[str, str] = {
        "delete_friend": "已经把 {user_id} 从好友里删掉了。",
        "set_friend_remark": "已经把 {user_id} 的备注改成「{remark}」了。",
        "set_friend_add_request": "那条好友申请已经处理好了。",
        "set_group_add_request": "那条加群申请已经处理好了。",
        "group_poke": "已经在群里戳过 {user_id} 了。",
        "friend_poke": "已经戳过 {user_id} 了。",
        "delete_msg": "那条消息已经撤回了。",
        "set_msg_emoji_like": "已经给那条消息贴上表情回应了。",
        "forward_group_single_msg": "已经把那条消息转到群里了。",
        "forward_friend_single_msg": "已经把那条消息转给他了。",
        "upload_group_file": "文件已经发到群文件里了。",
        "upload_private_file": "文件已经发过去了。",
        "mark_group_msg_as_read": "本群消息都标记成已读了。",
        "mark_private_msg_as_read": "跟他的消息都标记成已读了。",
        "_mark_all_as_read": "所有消息都标记成已读了。",
        "delete_qzone_msg": "那条说说已经删掉了。",
        "send_qzone_msg": "说说已经发出去了。",
        "set_qq_avatar": "头像已经换好了。",
        "set_qq_profile": "QQ 昵称已经改成「{nickname}」了。",
        "set_self_longnick": "签名已经改成「{longNick}」了。",
        "set_online_status": "在线状态已经改好了。",
        "set_group_sign": "本群签到完成啦。",
        "set_group_leave": "已经退出那个群了。",
        "_del_group_notice": "那条群公告已经删掉了。",
        "set_group_member_permissions": "群成员权限已经调好了。",
        "check_url_safely": "这个链接查过了，是安全的。",
    }

    def _humanize(self, spec, params: dict[str, Any], payload: Any) -> str:
        """把接口结果说成人话。

        绝不出现接口名、JSON 原文——用户要的是「你对我做了什么」，
        不是一份调用日志。查询类把关键字段压成一句摘要，写操作只报结果。
        """
        if not spec.read_only:
            template = self._HUMAN_DONE.get(spec.name)
            if template:
                try:
                    return template.format(**params)
                except (KeyError, IndexError):
                    # 取值缺失时只保留模板里能确定的那半句，别把「{xxx}」原样发出去
                    return re.split(r"[「{]", template)[0].rstrip("，。 ") + "。"
            return f"「{spec.label}」已经办好了。"

        summary = self._summarize(spec.name, payload)
        return summary or f"查完了，没查到什么内容。"

    @staticmethod
    def _summarize(action: str, payload: Any) -> str:
        """查询类接口的关键信息摘要。"""
        if payload in (None, "", [], {}):
            return ""

        if action == "_get_group_notice" and isinstance(payload, list):
            parts = []
            for item in payload[:5]:
                if not isinstance(item, dict):
                    continue
                text = str(item.get("notice") or item.get("content") or item.get("title") or "")
                text = re.sub(r"<[^>]+>", "", text).strip()
                if text:
                    parts.append(text[:120])
            return "本群共有 %d 条公告：\n" % len(payload) + "\n".join(
                f"{i}. {t}" for i, t in enumerate(parts, 1)
            )

        if action in ("get_group_member_list",) and isinstance(payload, list):
            names = []
            for item in payload[:15]:
                if not isinstance(item, dict):
                    continue
                name = str(item.get("card") or item.get("nickname") or "").strip()
                uid = item.get("user_id") or item.get("uin")
                names.append(f"{name}({uid})" if name else str(uid))
            more = f"，还有 {len(payload) - 15} 人" if len(payload) > 15 else ""
            return "本群共 %d 人：%s%s" % (len(payload), "、".join(names), more)

        if action in ("get_group_info", "get_group_info_ex") and isinstance(payload, dict):
            name = payload.get("group_name") or payload.get("groupName") or "未知"
            count = payload.get("member_count") or payload.get("memberNum")
            limit = payload.get("max_member_count") or payload.get("maxMemberNum")
            out = f"本群「{name}」"
            if count:
                out += f"，当前 {count} 人"
            if limit:
                out += f"，上限 {limit} 人"
            return out + "。"

        if action == "get_profile_like" and isinstance(payload, dict):
            total = payload.get("total_count") or (payload.get("voteInfo") or {}).get("total_count")
            return f"总共收到 {total or 0} 个赞。"

        if isinstance(payload, str):
            return payload[:400]

        # 通用兜底：从常见字段里凑一句能看的
        if isinstance(payload, dict):
            for key in ("message", "msg", "text", "info", "name", "nickname", "title"):
                value = payload.get(key)
                if isinstance(value, str) and value.strip():
                    return value.strip()[:300]
            return ""
        if isinstance(payload, list):
            items = []
            for item in payload[:10]:
                if isinstance(item, dict):
                    label = (
                        item.get("name") or item.get("nickname") or item.get("title")
                        or item.get("content") or item.get("user_id") or item.get("uin")
                    )
                    if label:
                        items.append(str(label)[:40])
                elif item:
                    items.append(str(item)[:40])
            if items:
                more = f" 等 {len(payload)} 项" if len(payload) > 10 else ""
                return "、".join(items) + more
        return ""

    async def _execute(self, ctx, data: dict[str, Any]) -> str:
        """执行单个动作，返回**基于真实结果**的说明。

        这里刻意不使用模型给的回复——它只会说「已帮你改好了」，
        哪怕实际一个都没改成功。结果必须由代码如实汇报。
        """
        action = str(data.get("action") or "none")
        if action not in ACTIONS or action == "none":
            return ""

        group_id = int(ctx.group_id) if ctx.group_id else 0
        # 私聊里执行离不开当前群的动作是不可能的，早点说清楚，别报一堆接口错误
        if action in _NEEDS_GROUP and not group_id:
            return "这个操作要在群里说才行（或者告诉我群号）。"
        text = str(data.get("text") or "").strip()
        raw_targets = data.get("targets") or []
        want_all = any(
            str(t).strip().lower() in ("all", "全体", "所有人", "全部")
            for t in raw_targets
        )
        # 机器人自己只在「改名片」这类动作里当目标；禁言、踢人之类绝不会落到自己头上
        allow_self = action in _SELF_TARGET_ACTIONS
        targets = [
            int(t) for t in raw_targets
            if str(t).lstrip("-").isdigit()
            and (allow_self or int(t) != self.bot.self_id)
        ]

        needs_target = (
            "mute", "unmute", "kick", "poke",
            "set_special_title", "set_admin", "unset_admin",
        )
        if action in needs_target and not targets:
            return "要操作谁？请 @ 他，或者回复他的消息再说一次。"

        try:
            if action == "mute":
                seconds = self._clamp(data.get("seconds"))
                for uid in targets:
                    await self._call(
                        "set_group_ban", group_id=group_id, user_id=uid, duration=seconds
                    )
                self.log.info("白话群管：禁言 %s %d 秒", targets, seconds)
                return f"已禁言 {len(targets)} 人 {self._fmt_duration(seconds)}。"

            if action == "unmute":
                for uid in targets:
                    await self._call("set_group_ban", group_id=group_id, user_id=uid, duration=0)
                self.log.info("白话群管：解除禁言 %s", targets)
                return "已解除禁言。"

            if action == "kick":
                for uid in targets:
                    await self._call(
                        "set_group_kick",
                        group_id=group_id, user_id=uid, reject_add_request=False,
                    )
                self.log.info("白话群管：踢出 %s", targets)
                return f"已踢出 {len(targets)} 人。"

            if action in ("whole_ban", "whole_unban"):
                enable = action == "whole_ban"
                await self._call("set_group_whole_ban", group_id=group_id, enable=enable)
                self.log.info("白话群管：全员禁言=%s", enable)
                return ("已开启全员禁言。" if enable else "已解除全员禁言。")

            if action in ("recall", "essence", "unessence"):
                message_id = self._reply_message_id(ctx)
                if message_id is None:
                    return "请先回复要处理的那条消息，再说一次。"
                if action == "recall":
                    await self._call("delete_msg", message_id=message_id)
                elif action == "essence":
                    await self._call("set_essence_msg", message_id=message_id)
                else:
                    await self._call("delete_essence_msg", message_id=message_id)
                self.log.info("白话群管：%s 消息 %s", action, message_id)
                default = {"recall": "已撤回。", "essence": "已设为精华。", "unessence": "已取消精华。"}
                return default[action]

            if action == "poke":
                for uid in targets:
                    await self._call("group_poke", group_id=group_id, user_id=uid)
                self.log.info("白话群管：戳一戳 %s", targets)
                return "已戳。"

            if action == "set_card":
                if not text:
                    return "名片要改成什么？可以用 {name} 代表原昵称。"
                return await self._do_set_card(ctx, group_id, text, targets, want_all)

            if action == "set_announcement":
                if not text:
                    return "公告内容是什么？"
                await self._call("_send_group_notice", group_id=group_id, content=text)
                self.log.info("白话群管：发布群公告")
                return "群公告已发布。"

            if action == "set_group_portrait":
                image = await self._message_image(ctx)
                if not image:
                    return "请把要用的图片一起发过来，或者回复一张带图的图片。"

                await self._call("set_group_portrait", group_id=group_id, file=image)
                self.log.info("白话群管：更换群头像")
                return "群头像已更换。"

            if action in ("set_admin", "unset_admin"):
                enable = action == "set_admin"
                for uid in targets:
                    await self._call(
                        "set_group_admin", group_id=group_id, user_id=uid, enable=enable
                    )
                self.log.info("白话群管：设置管理员 %s = %s", targets, enable)
                return ("已设置管理员。" if enable else "已取消管理员。")

            if action == "set_special_title":
                if not text:
                    return "头衔内容是什么？"
                for uid in targets:
                    await self._call(
                        "set_group_special_title",
                        group_id=group_id, user_id=uid, special_title=text, duration=-1,
                    )
                self.log.info("白话群管：设置头衔 %s -> %s", targets, text)
                return f"已设置头衔「{text}」。"

            if action == "set_group_name":
                if not text:
                    return "改成什么群名？"
                await self._call("set_group_name", group_id=group_id, group_name=text)
                self.log.info("白话群管：改群名 -> %s", text)
                return f"群名已改为「{text}」。"

            if action == "set_welcome":
                if not text:
                    return "欢迎语要说些什么？"
                section = self.bot.config.custom.setdefault("group_admin", {})
                section["welcome"] = text
                self.bot.config.save()
                self.log.info("白话群管：设置入群欢迎语")
                return "入群欢迎语已更新。"

            if action in ("ban_word", "unban_word"):
                raw_word = text or (str(raw_targets[0]) if raw_targets else "")
                words = [w for w in re.split(r"[、,，;；/\s]+", raw_word) if w]
                if not words:
                    return "是哪个词？"
                section = self.bot.config.custom.setdefault("group_admin", {})
                banned = section.setdefault("banned_words", [])
                if action == "ban_word":
                    banned.extend(w for w in words if w not in banned)
                    message = f"已把「{'、'.join(words)}」加入违禁词。"
                    # 顺带说了时长就一起存下，实现「一句话加词 + 设禁言时长」
                    if data.get("seconds") is not None:
                        seconds = self._clamp(data.get("seconds"))
                        section["ban_seconds"] = seconds
                        message += f"命中后禁言 {self._fmt_duration(seconds)}。"
                else:
                    removed = [w for w in words if w in banned]
                    for word in removed:
                        banned.remove(word)
                    message = (
                        f"已把「{'、'.join(removed)}」移出违禁词。" if removed
                        else f"「{'、'.join(words)}」本来就不在违禁词里。"
                    )
                self.bot.config.save()
                self.log.info("白话群管：违禁词 %s %s", action, words)
                return message

            if action in ("remember", "forget"):
                return await self._do_memory(ctx, action, text)

            if action == "like":
                return await self._do_like(ctx, data)

            if action in (
                "auto_accept_join", "auto_accept_friend",
                "auto_reject_join", "auto_reject_friend", "auto_off",
            ):
                return self._set_auto_approve(action, text)

            if action in ("add_keyword", "del_keyword"):
                section = self.bot.config.custom.setdefault("group_admin", {})
                keywords = section.setdefault("keywords", {})
                if action == "add_keyword":
                    key, _, value = text.partition("=>")
                    key = key.strip()
                    value = value.strip()
                    if not key or not value:
                        return "请告诉我「关键词=>回复内容」。"
                    keywords[key] = value
                    message = f"已添加关键词「{key}」的自动回复。"
                else:
                    key = text.strip()
                    if key in keywords:
                        keywords.pop(key)
                        message = f"已删除关键词「{key}」。"
                    else:
                        message = f"没有找到关键词「{key}」。"
                self.bot.config.save()
                self.log.info("白话群管：关键词 %s %s", action, text)
                return message

            if action == "silence":
                raw = data.get("seconds")
                # 没说时长＝永久闭嘴；说了时长才到点自动恢复
                seconds = 0 if raw in (None, "", 0, "0") else self._clamp(raw)
                self.bot.silence_group(group_id, seconds)
                if not seconds:
                    return "好，我在本群永久闭嘴，想我了叫我一声就行。"
                return (
                    f"好，我在本群闭嘴 {self._fmt_duration(seconds)}。"
                    "想我了记得叫我哦。"
                )

            if action == "wake":
                self.bot.wake_group(group_id)
                return "好哒。"

            if action == "group_info":
                resp = await self._call("get_group_info", group_id=group_id)
                info = resp.get("data") or {} if isinstance(resp, dict) else {}
                name = info.get("group_name") or "未知"
                count = info.get("member_count")
                limit = info.get("max_member_count")
                text_out = f"本群「{name}」，当前 {count} 人"
                if limit:
                    text_out += f"，上限 {limit} 人"
                return text_out + "。"

        except Exception as exc:  # noqa: BLE001
            self.log.error("白话群管执行 %s 失败: %s", action, exc)
            return f"执行失败：{exc}"

        # 手写分支之外，落到接口目录里的通用接口（拉群公告、审批入群申请、群里签到…）
        if action in BY_NAME:
            return await self._run_catalog(ctx, action, data)

        return ""

    # ---------- 执行与多轮思考 ----------

    async def _run_actions(
        self, ctx, actions: list[dict[str, Any]], level: str
    ) -> tuple[list[str], list[str]]:
        """执行一批动作，返回 (成功说明, 没做成的说明)。

        没做成的（动作不认识、权限不够）不再静默跳过：交给多轮思考回喂给模型，
        让它换成能做的方式；最终仍办不成时这些说明会原样回给用户。
        """
        done: list[str] = []
        blocked: list[str] = []
        for item in actions:
            action = str(item.get("action") or "")
            if action not in ACTIONS or action == "none":
                blocked.append(f"「{action or '这个'}」我不会")
                continue
            if not self._allowed(action, level):
                need = LEVEL_LABEL.get(self.levels().get(action, "admin"), "管理员")
                label = ACTION_LABELS.get(action) or (
                    BY_NAME[action].label if action in BY_NAME else action
                )
                blocked.append(f"{label}这事得{need}来，我做不到")
                continue
            try:
                outcome = await self._execute(ctx, item)
            except Exception as exc:  # noqa: BLE001
                self.log.error("白话群管执行 %s 失败: %s", action, exc)
                label = ACTION_LABELS.get(action) or (
                    BY_NAME[action].label if action in BY_NAME else action
                )
                outcome = f"{label}没做成（{str(exc)[:60]}）"
            if outcome:
                done.append(outcome)
        return done, blocked

    async def _think_and_act(
        self,
        ctx,
        text: str,
        targets: dict[int, str],
        level: str,
        seed_results: list[str],
        seed_blocked: list[str],
        *,
        force: bool,
    ) -> list[str]:
        """复杂/受阻指令的兜底：多轮思考，把真实结果回喂给模型，直到办成或确认办不到。

        只在快路径解析不出动作（``force``）或存在被拦下的动作时进入，
        平时仍是一次调用，不影响速度。轮数由 config.admin_nl.max_rounds 封顶。
        """
        cfg = self.bot.config.admin_nl
        limit = max(1, int(getattr(cfg, "max_rounds", 3) or 3))
        results = [r for r in seed_results if r]
        blocked = list(seed_blocked)
        transcript: list[tuple[str, str]] = []

        if force and not blocked:
            transcript.append(
                ("user", "你刚才没有给出任何动作。请重新想一遍：能做成的就直接给出动作；"
                         "确实不是管理要求就回 none。")
            )
        elif blocked:
            transcript.append(
                ("user", "下面这些你没做到：" + "；".join(blocked)
                         + "。请只在你确实能做到的范围内换个方式继续；做不到就回 none。")
            )

        last_sig = tuple(sorted(blocked))
        for _ in range(limit):
            try:
                raw, actions = await self._ask_multi(text, targets, level, transcript, ctx)
            except Exception as exc:  # noqa: BLE001
                self.log.warning("白话群管多轮思考调用失败: %s", exc)
                break
            # 模型自己的输出必须回填，否则下一轮它看不到上轮说过什么
            transcript.append(("assistant", raw or ""))
            real = [
                a for a in actions
                if str(a.get("action") or "none") not in ("", "none")
            ]
            if not real:
                break
            got, blocked = await self._run_actions(ctx, real, level)
            results.extend(got)
            if not blocked:
                break  # 都办成了，收工
            sig = tuple(sorted(blocked))
            if sig == last_sig:
                break  # 两轮都没变化，再问也是白问
            last_sig = sig
            transcript.append(
                ("user", "下面这些做不到：" + "；".join(blocked)
                         + "。请在你确实能做到的范围内换个方式；做不到就回 none。")
            )
        self.log.info("白话群管多轮思考结束：新增 %d 条结果，剩余 %d 条办不到", len(results), len(blocked))
        if blocked:
            results.extend(blocked)
        return results

    # ---------- 事件入口 ----------

    def _is_owner(self, ctx) -> bool:
        """是不是配置里的管理员（账号主人）。"""
        uid = int(getattr(ctx.event, "user_id", 0) or 0)
        return uid in [int(a) for a in (self.bot.config.bot.admins or [])]

    def _called_private(self, ctx) -> bool:
        """私聊里主人直接说就行，不用先喊机器人名字。"""
        return not ctx.is_group and self._is_owner(ctx)

    async def on_message(self, ctx) -> Any:
        if not self._active:
            return None
        # 群聊照旧（管理员或群员按权限表触发）；私聊只认账号主人，
        # 这样「拉取群公告」「审批入群申请」在私聊里也能用。
        if not ctx.is_group and not self._called_private(ctx):
            return None

        level = self._user_level_of(ctx)
        # 配置里的管理员全部能力可用；群员只有在权限表里至少放开了一条能力时
        # 才进入解析（具体动作仍会被 _allowed 逐条校验），否则只当普通聊天。
        if level != "owner" and not self._member_can_trigger():
            return None

        rendered = self._render(ctx)
        called = self._called(ctx, rendered)
        targets: dict[int, str] | None = None

        if called:
            text = self._strip_call_name(rendered).strip()
            if not text:
                return None
            # 叫了名字但完全不像管理指令 → 直接交给闲聊插件，省一次模型解析，
            # 也避免「菲比，想不想要」这种普通聊天被群管解析吞掉。
            if not self._mgmt_hint_in(text):
                return None
        else:
            # 没叫名字：按配置决定要不要「自动领会」，且本地先判像不像管理指令，
            # 不像就完全不动，交给后面的闲聊插件处理。
            if not self._free_listen_on(level):
                return None
            text = rendered.strip()
            if not text:
                return None
            targets = await self._free_intent(ctx, text)
            if targets is None:
                return None

        # 「忘掉以前的记忆 / 清理上下文 / 重置」直接在这里处理，
        # 不要交给动作解析模型——否则它可能编出一个撤回/禁言的动作来。
        from ._ai_reply import handle_context_reset

        mode = str(getattr(self.bot.config.ai, "reply_mode", "direct") or "direct")
        if await handle_context_reset(self.bot, self._get_client(), ctx, text, mode):
            return self.stop()

        try:
            if targets is None:
                reply_target = await self._reply_target(ctx)
                targets = await self._collect_targets(ctx, text, reply_target)
            actions = await self._ask(text, targets, level, ctx)  # 快路径：一次拿到全部动作
            # 兜底：JSON 没解析出来，或明显是多条指令却只给了一个动作
            if not actions or (len(actions) < 2 and self._looks_compound(text)):
                self.log.info(
                    "快路径只得到 %d 个动作，改用拆分模式重试", len(actions)
                )
                splitted = await self._ask_split(text, targets, level, ctx)
                if splitted:
                    actions = splitted
        except Exception as exc:  # noqa: BLE001
            # 解析失败绝不能退化成普通聊天——那样聊天模型会「脑补」一句
            # 「已帮你改好了」，用户以为做了其实什么都没发生。
            self.log.error("白话群管解析失败: %s: %s", type(exc).__name__, exc)
            if called:
                pass  # 意图解析失败：静默忽略，不打扰
                return self.stop()
            return None

        real = [a for a in actions if str(a.get("action") or "none") not in ("", "none")]
        if not real:
            if actions:
                # 模型明确判定为闲聊：叫了名字就走普通对话；
                # 没叫名字的直接放行，交给后续插件，避免同一条消息被回两次
                if called:
                    await self._chat(ctx, text)
                    return self.stop()
                return None
            # 一个动作都没解析出来 → 多轮思考再试，而不是直接说「没弄明白」
            results = await self._think_and_act(
                ctx, text, targets, level, [], [], force=True
            )
            if results:
                await self._send_feedback(ctx, results)
                return self.stop()
            # 看着像指令却没听懂时不能放给闲聊兜底——那样聊天模型会「脑补」一句
            # 「已帮你办好了」，用户以为做了其实什么都没发生。
            # 但完全不像指令的普通聊天必须放行，否则用户说话会被静默吞掉。
            if called and not self._maybe_instruction(ctx, text):
                return None
            return self.stop()

        results, blocked = await self._run_actions(ctx, real, level)
        if blocked:
            # 有办不成的 → 多轮思考，把「刚才没做到什么」回喂给模型换方式
            results = await self._think_and_act(
                ctx, text, targets, level, results, blocked, force=False
            )

        if not results:
            await self._send_feedback(ctx, ["这个我暂时办不到。"])
        else:
            await self._send_feedback(ctx, results)
        return self.stop()

    @staticmethod
    def _session(ctx) -> str:
        # 与 AI 对话插件用同一个会话键，上下文可以延续
        from ._ai_reply import session_key

        return session_key(ctx)

    async def _feedback(self, ctx, results: list[str]) -> str:
        """把真实执行结果交给人格模型改写，避免生硬的系统话术。"""
        facts = "\n".join(x for x in results if x)
        if not facts:
            return ""
        try:
            from ...ai.client import resolve_persona

            system = resolve_persona(self.bot.config.ai) or "你是一个住在 QQ 里的真人。"
        except Exception:  # noqa: BLE001
            system = "你是一个住在 QQ 里的真人。"
        nickname = getattr(ctx.event, "nickname", "") or str(ctx.user_id)
        instruction = (
            f"你刚替「{nickname}」办完这些事，真实结果如下：\n{facts}\n\n"
            "请用你平时的语气，简短地告诉他结果（一到两句），像熟人聊天。"
            "直接叫他的名字或直接说事，不要用 @，不要写「@某某」，"
            "不要提接口、系统、参数、内部标记或括号里的分类。"
        )
        try:
            text = await self._get_client().complete(
                system, instruction, temperature=0.7, max_tokens=120
            )
        except Exception as exc:  # noqa: BLE001
            self.log.warning("人格化反馈失败，改用原始结果: %s", exc)
            text = ""
        return self._clean_feedback(text) or facts

    @staticmethod
    def _clean_feedback(text: str) -> str:
        text = re.sub(r"\[CQ:at,[^\]]*\]", "", text or "")
        text = re.sub(r"(?m)^\s*@[^\s，。,:：]+[\s，。,:：]*", "", text)
        return text.strip()

    async def _send_feedback(self, ctx, results: list[str]) -> None:
        text = await self._feedback(ctx, results)
        if not text:
            return
        mode = str(getattr(self.bot.config.ai, "reply_mode", "direct") or "direct").lower()
        if ctx.is_group and mode == "quote":
            await ctx.reply(text, quote=True)
        else:
            await ctx.send(text)

    async def _chat(self, ctx, text: str) -> None:
        """不是管理指令时，走完整对话链路回一句。"""
        # 闭嘴里就别闲聊了（但上面的管理指令/唤醒照常执行）
        if ctx.is_group and self.bot.is_silenced(ctx.group_id):
            return
        try:
            from ._ai_reply import answer

            mode = str(getattr(self.bot.config.ai, "reply_mode", "direct") or "direct")
            await answer(self.bot, self._get_client(), ctx, text, self._session(ctx), mode)
        except Exception as exc:  # noqa: BLE001
            self.log.error("白话群管转普通对话失败: %s", exc)