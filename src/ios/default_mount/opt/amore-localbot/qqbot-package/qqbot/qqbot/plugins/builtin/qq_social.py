"""QQ 社交操作：好友/加群申请处理、删好友、点赞、发空间说说（朋友圈）、设置备注。

能力边界（必须先说清楚，否则模型会瞎承诺）：
  - NapCat **没有**「主动加好友」与「创建群聊」接口，被要求时只能如实说做不到；
    能用的是 ArkSharePeer 发推荐名片，不是真正的加好友。
  - 本插件所有动作都是**账号级破坏性操作**，因此一律只允许管理员触发。

申请处理有两种模式（由配置决定，两个开关都不开就是「待审批」）：
  - 自动同意 / 自动拒绝；
  - 待审批：把申请排队并私聊通知管理员，管理员用 ``#同意加好友 <编号>`` 处理。
"""

from __future__ import annotations

import re
import time
from typing import Any

from ..base import Plugin

#: 说说的查看权限取值（NapCat 规定，不能乱填）
UGC_RIGHTS = {
    1: "所有人可见",
    4: "好友可见",
    16: "部分好友可见",
    64: "仅自己可见",
    128: "部分好友不可见",
}

#: 待审批申请的保留时长（秒），过期自动丢弃，避免内存越攒越多
PENDING_TTL = 24 * 3600


class QQSocialPlugin(Plugin):
    name = "qq_social"
    display_name = "QQ 社交操作"
    version = "0.1.0"
    description = "QQ 社交操作：好友/加群申请处理、删好友、点赞、发空间说说"
    priority = 35  # 与白话群管同档，先于 AI 对话（50）

    config_labels: dict[str, str] = {
        "enabled": "启用本插件",
        "strict_admin": "严格管理员权限（只认「AI 配置」里的管理员，群主/群管理不算）",
        "friend_auto_accept": "自动同意好友申请",
        "friend_auto_reject": "自动拒绝好友申请（和上面都不勾＝转给管理员审批）",
        "friend_accept_remark": "同意好友后自动设置的备注（{name} 代表对方昵称）",
        "friend_notify": "有好友申请时私聊通知管理员",
        "group_auto_accept": "自动同意加群申请 / 邀请",
        "group_auto_reject": "自动拒绝加群申请 / 邀请（和上面都不勾＝转给管理员审批）",
        "group_notify": "有加群申请时私聊通知管理员",
        "default_like_times": "点赞默认次数（指令没写次数时用）",
        "qzone_ugc_right": "说说查看权限：1 所有人 / 4 好友 / 16 部分好友 / 64 仅自己 / 128 部分好友不可见",
        "qzone_target_uins": "权限为 16 或 128 时的目标 QQ（逗号分隔）",
    }

    default_config: dict[str, Any] = {
        "enabled": True,
        #: True=只有「AI 配置」里填的管理员（主人）能用；False=群主/群管理也算
        "strict_admin": True,
        # ---- 好友申请 ----
        "friend_auto_accept": False,
        "friend_auto_reject": False,
        "friend_accept_remark": "",
        "friend_notify": True,
        # ---- 加群申请 / 邀请 ----
        "group_auto_accept": False,
        "group_auto_reject": False,
        "group_notify": True,
        # ---- 点赞 / 说说 ----
        "default_like_times": 10,
        "qzone_ugc_right": 1,
        "qzone_target_uins": [],
    }

    def __init__(self, bot) -> None:
        super().__init__(bot)
        #: 待审批申请：编号 -> 申请信息
        self._pending: dict[int, dict[str, Any]] = {}
        self._seq = 0

    async def on_load(self) -> None:
        self.add_command(
            "del_friend", self._cmd_del_friend,
            aliases=("删好友", "删除好友"), admin=True,
            description="删除好友：@某人 或 直接给 QQ 号",
        )
        self.add_command(
            "like", self._cmd_like,
            aliases=("点赞", "名片赞"), admin=True,
            description="给某人点赞：@某人 [次数]，不填次数用默认值",
        )
        self.add_command(
            "post_qzone", self._cmd_post_qzone,
            aliases=("发说说", "发朋友圈", "空间说说"), admin=True,
            description="发空间说说：正文内容；消息里带图会一起发出去",
        )
        self.add_command(
            "del_qzone", self._cmd_del_qzone,
            aliases=("删说说",), admin=True,
            description="删除空间说说：给 tid",
        )
        self.add_command(
            "friend_remark", self._cmd_friend_remark,
            aliases=("好友备注",), admin=True,
            description="设置好友备注：@某人 备注内容（或 QQ号 备注内容）",
        )
        self.add_command(
            "friend_requests", self._cmd_friend_requests,
            aliases=("好友申请",), admin=True, description="查看待处理的好友申请",
        )
        self.add_command(
            "accept_friend", self._cmd_accept_friend,
            aliases=("同意加好友", "同意好友"), admin=True,
            description="同意好友申请：给编号",
        )
        self.add_command(
            "reject_friend", self._cmd_reject_friend,
            aliases=("拒绝加好友", "拒绝好友"), admin=True,
            description="拒绝好友申请：给编号",
        )
        self.add_command(
            "group_requests", self._cmd_group_requests,
            aliases=("加群申请", "入群申请"), admin=True,
            description="查看待处理的加群申请/邀请",
        )
        self.add_command(
            "accept_group", self._cmd_accept_group,
            aliases=("同意加群", "同意入群"), admin=True,
            description="同意加群申请：给编号",
        )
        self.add_command(
            "reject_group", self._cmd_reject_group,
            aliases=("拒绝加群", "拒绝入群"), admin=True,
            description="拒绝加群申请：给编号 [理由]",
        )
        self.log.info(
            "QQ 社交操作已加载（好友申请=%s）",
            self._mode_text("friend"),
        )

    @property
    def _active(self) -> bool:
        return bool(self.cfg_get("enabled", True))

    def _allowed(self, ctx) -> bool:
        """谁能下这些指令。

        默认 strict_admin=True：只认「AI 配置」里填的管理员（也就是账号主人本人）。
        这一点必须比 ctx.is_admin 更严——ctx.is_admin 把「本群群主/群管理」也算管理员，
        而这些是**账号级破坏性操作**（删好友、发说说），不能让随便哪个群的群主用你的号。
        """
        if not self._active:
            return False
        if self.cfg_get("strict_admin", True) is not False:
            uid = int(getattr(ctx.event, "user_id", 0) or 0)
            return uid in [int(a) for a in (self.bot.config.bot.admins or [])]
        return bool(ctx.is_admin)

    async def handle_message(self, ctx) -> Any:
        """不是有权限的人就完全不入场：既不执行，也不回「没权限」，免得群里刷屏。"""
        if not self._allowed(ctx):
            return None
        return await super().handle_message(ctx)

    def _mode_text(self, kind: str) -> str:
        if self.cfg_get(f"{kind}_auto_accept"):
            return "自动同意"
        if self.cfg_get(f"{kind}_auto_reject"):
            return "自动拒绝"
        return "待审批并通知管理员"

    # ---------- 申请事件 ----------

    async def on_request(self, event) -> Any:
        if not self._active:
            return None
        kind = str(getattr(event, "request_type", "") or "")
        if kind not in ("friend", "group"):
            return None

        item = {
            "kind": kind,
            "flag": str(getattr(event, "flag", "") or ""),
            "user_id": int(getattr(event, "user_id", 0) or 0),
            "group_id": int(getattr(event, "group_id", 0) or 0),
            "comment": str(getattr(event, "comment", "") or ""),
            "sub_type": str(event.get("sub_type") or ""),
            "time": time.time(),
        }
        if not item["flag"]:
            return None

        if self.cfg_get(f"{kind}_auto_accept"):
            note = await self._approve(item)
            await self._notify(item, f"已自动同意", note)
            return self.stop()
        if self.cfg_get(f"{kind}_auto_reject"):
            await self._reject(item)
            await self._notify(item, "已自动拒绝")
            return self.stop()

        seq = self._push_pending(item)
        if self.cfg_get(f"{kind}_notify"):
            what = "好友申请" if kind == "friend" else "加群申请/邀请"
            await self._notify(
                item,
                f"收到一条{what}，编号 {seq}",
                f"同意用「#同意{'加好友' if kind == 'friend' else '加群'} {seq}」",
            )
        self.log.info("待审批 %s flag=%s user=%s", kind, item["flag"], item["user_id"])
        return self.stop()

    def _push_pending(self, item: dict[str, Any]) -> int:
        now = time.time()
        for seq, old in list(self._pending.items()):
            if now - float(old.get("time") or 0) > PENDING_TTL:
                self._pending.pop(seq, None)
        self._seq += 1
        self._pending[self._seq] = item
        return self._seq

    def _take_pending(self, kind: str, raw: str) -> dict[str, Any] | None:
        """按编号取一条待审批申请；也兼容直接粘贴 flag。"""
        key = str(raw or "").strip()
        if not key:
            return None
        if key.isdigit() and int(key) in self._pending:
            item = self._pending.pop(int(key))
            return item if item.get("kind") == kind else None
        for seq, item in list(self._pending.items()):
            if item.get("flag") == key and item.get("kind") == kind:
                self._pending.pop(seq, None)
                return item
        return None

    async def _approve(self, item: dict[str, Any]) -> str:
        if item["kind"] == "friend":
            remark = str(self.cfg_get("friend_accept_remark") or "")
            resp = await self.bot.call_api(
                "set_friend_add_request",
                flag=item["flag"],
                approve=True,
                **({"remark": remark} if remark else {}),
            )
            note = f"（备注：{remark}）" if remark else ""
            self._check(resp)
            return note
        resp = await self.bot.call_api("set_group_add_request", flag=item["flag"], approve=True)
        self._check(resp)
        return ""

    async def _reject(self, item: dict[str, Any], reason: str = "") -> None:
        action = "set_friend_add_request" if item["kind"] == "friend" else "set_group_add_request"
        params: dict[str, Any] = {"flag": item["flag"], "approve": False}
        if item["kind"] == "group" and reason:
            params["reason"] = reason
        resp = await self.bot.call_api(action, params)
        self._check(resp)

    async def _notify(self, item: dict[str, Any], head: str, tail: str = "") -> None:
        """把申请详情私聊给所有管理员。通知失败只记日志，不影响主流程。"""
        lines = [
            f"【{head}】",
            f"QQ：{item['user_id']}",
        ]
        if item["kind"] == "group" and item["group_id"]:
            lines.append(f"群号：{item['group_id']}（{item.get('sub_type') or 'add'}）")
        if item["comment"]:
            lines.append(f"留言：{item['comment']}")
        if tail:
            lines.append(tail)
        message = "\n".join(lines)
        for admin in self.bot.config.bot.admins or []:
            try:
                await self.bot.send_private_msg(int(admin), message)
            except Exception as exc:  # noqa: BLE001
                self.log.warning("通知管理员 %s 失败: %s", admin, exc)

    @staticmethod
    def _check(resp: Any) -> None:
        """OneBot 失败时回 status=failed 而不是抛异常，这里显式转成异常。"""
        if isinstance(resp, dict) and resp.get("status") == "failed":
            raise RuntimeError(str(resp.get("message") or resp.get("wording") or "接口返回失败"))

    # ---------- 目标解析 ----------

    @staticmethod
    def _target(ctx, args: str) -> int:
        """取目标 QQ：优先用 @ 的人，其次用参数里的纯数字。"""
        targets = ctx.at_targets
        if targets:
            return int(targets[0])
        match = re.search(r"\d{5,}", args or "")
        return int(match.group(0)) if match else 0

    @staticmethod
    def _rest_args(ctx, args: str) -> str:
        """去掉 @ 段与首个数字后剩下的文本（用于备注内容）。"""
        cleaned = re.sub(r"\d{5,}", "", args or "", count=1)
        return cleaned.strip()

    # ---------- 指令 ----------

    async def _cmd_del_friend(self, ctx, args: str) -> Any:
        uid = self._target(ctx, args)
        if not uid:
            await ctx.reply("要删谁？@ 他一下，或者直接给 QQ 号。")
            return
        try:
            self._check(await self.bot.call_api("delete_friend", user_id=uid))
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"删除失败：{str(exc)[:80]}")
            return
        self.log.info("已删除好友 %s", uid)
        await ctx.reply(f"已删除好友 {uid}。")

    async def _cmd_like(self, ctx, args: str) -> Any:
        uid = self._target(ctx, args)
        if not uid:
            await ctx.reply("要给谁点赞？@ 他一下，或者直接给 QQ 号。")
            return
        times = int(self.cfg_get("default_like_times", 10) or 10)
        digits = [int(n) for n in re.findall(r"\d+", args or "") if int(n) < 100]
        if digits:
            times = max(1, min(digits[-1], 50))  # 频率太快会被限流，封顶 50
        try:
            self._check(await self.bot.call_api("send_like", user_id=uid, times=times))
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"点赞失败：{str(exc)[:80]}")
            return
        self.log.info("已给 %s 点赞 %d 次", uid, times)
        await ctx.reply(f"已给 {uid} 点了 {times} 个赞。")

    async def _cmd_post_qzone(self, ctx, args: str) -> Any:
        content = (args or "").strip()
        images = self._images(ctx)
        if not content and not images:
            await ctx.reply("说说要写点啥？直接跟在指令后面就行。")
            return

        right = int(self.cfg_get("qzone_ugc_right", 1) or 1)
        if right not in UGC_RIGHTS:
            right = 1
        params: dict[str, Any] = {"content": content or " ", "ugc_right": right}
        if images:
            params["images"] = images
        if right in (16, 128):
            targets = [int(t) for t in (self.cfg_get("qzone_target_uins") or [])]
            if not targets:
                await ctx.reply(
                    f"当前权限「{UGC_RIGHTS[right]}」需要在插件设置里填目标 QQ，先改成 1（所有人可见）再发。"
                )
                return
            params["target_uins"] = targets
        try:
            resp = await self.bot.call_api("send_qzone_msg", params)
            self._check(resp)
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"发说说失败：{str(exc)[:100]}")
            return
        tid = ""
        data = resp.get("data") if isinstance(resp, dict) else None
        if isinstance(data, dict):
            tid = str(data.get("tid") or "")
        self.log.info("已发说说（权限=%s，图片=%d）", right, len(images))
        await ctx.reply(
            f"说说已发布（{UGC_RIGHTS[right]}）" + (f"，tid={tid}" if tid else "")
        )

    async def _cmd_del_qzone(self, ctx, args: str) -> Any:
        tid = (args or "").strip()
        if not tid:
            await ctx.reply("要给 tid 才能删，发说说时会返回 tid。")
            return
        try:
            self._check(await self.bot.call_api("delete_qzone_msg", tid=tid))
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"删说说失败：{str(exc)[:80]}")
            return
        await ctx.reply("说说已删除。")

    async def _cmd_friend_remark(self, ctx, args: str) -> Any:
        uid = self._target(ctx, args)
        remark = self._rest_args(ctx, args)
        if not uid or not remark:
            await ctx.reply("用法：#好友备注 @某人 备注内容")
            return
        try:
            self._check(await self.bot.call_api("set_friend_remark", user_id=uid, remark=remark))
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"设置备注失败：{str(exc)[:80]}")
            return
        await ctx.reply(f"已把 {uid} 的备注改成「{remark}」。")

    async def _cmd_friend_requests(self, ctx, args: str) -> Any:
        await ctx.reply(self._pending_text("friend"))

    async def _cmd_group_requests(self, ctx, args: str) -> Any:
        await ctx.reply(self._pending_text("group"))

    def _pending_text(self, kind: str) -> str:
        items = [(seq, it) for seq, it in sorted(self._pending.items()) if it.get("kind") == kind]
        if not items:
            return "当前没有待处理的申请。"
        head = "待处理好友申请：" if kind == "friend" else "待处理加群申请/邀请："
        lines = [head]
        for seq, it in items:
            extra = f" ｜ {it['comment']}" if it.get("comment") else ""
            grp = f" ｜ 群 {it['group_id']}" if it.get("group_id") else ""
            lines.append(f"{seq}. QQ {it.get('user_id')}{grp}{extra}")
        verb = "同意加好友" if kind == "friend" else "同意加群"
        lines.append(f"用「#{verb} <编号>」处理。")
        return "\n".join(lines)

    async def _cmd_accept_friend(self, ctx, args: str) -> Any:
        item = self._take_pending("friend", args)
        if item is None:
            await ctx.reply("没找到这个编号的好友申请，先用 #好友申请 看看。")
            return
        try:
            note = await self._approve(item)
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"同意失败：{str(exc)[:80]}")
            return
        await ctx.reply(f"已同意 QQ {item.get('user_id')} 的好友申请。{note}")

    async def _cmd_reject_friend(self, ctx, args: str) -> Any:
        item = self._take_pending("friend", args)
        if item is None:
            await ctx.reply("没找到这个编号的好友申请，先用 #好友申请 看看。")
            return
        try:
            await self._reject(item)
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"拒绝失败：{str(exc)[:80]}")
            return
        await ctx.reply(f"已拒绝 QQ {item.get('user_id')} 的好友申请。")

    async def _cmd_accept_group(self, ctx, args: str) -> Any:
        item = self._take_pending("group", args)
        if item is None:
            await ctx.reply("没找到这个编号的加群申请，先用 #加群申请 看看。")
            return
        try:
            await self._approve(item)
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"同意失败：{str(exc)[:80]}")
            return
        await ctx.reply(f"已同意 QQ {item.get('user_id')} 加入群 {item.get('group_id')}。")

    async def _cmd_reject_group(self, ctx, args: str) -> Any:
        parts = (args or "").split(None, 1)
        item = self._take_pending("group", parts[0] if parts else "")
        if item is None:
            await ctx.reply("没找到这个编号的加群申请，先用 #加群申请 看看。")
            return
        reason = parts[1].strip() if len(parts) > 1 else ""
        try:
            await self._reject(item, reason)
        except Exception as exc:  # noqa: BLE001
            await ctx.reply(f"拒绝失败：{str(exc)[:80]}")
            return
        await ctx.reply(f"已拒绝 QQ {item.get('user_id')} 的加群申请。")

    @staticmethod
    def _images(ctx) -> list[str]:
        """取消息里的图片引用，交给 NapCat 自己上传（支持 http/file/base64）。"""
        urls: list[str] = []
        for seg in ctx.message:
            if getattr(seg, "type", "") != "image":
                continue
            data = seg.data or {}
            url = str(data.get("url") or data.get("file") or "")
            if url.startswith(("http://", "https://", "file://", "base64://")):
                urls.append(url)
        return urls
