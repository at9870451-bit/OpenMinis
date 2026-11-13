"""AI 生图插件：管理员让机器人画图时，调用图片模型并把图发出来。

管理员专属；非管理员即使说「画个图」也只会得到普通聊天回复。
触发示例：
    画个图，一只戴墨镜的猫，9:16 720P
    给我画个图：赛博朋克城市夜景
    你长什么样画出来
    帮他设计个 logo
"""

from __future__ import annotations

import asyncio
import base64
import re
import time
from typing import Any

from ...core.message import Message, image as image_seg
from ..base import Plugin

#: 只有确实在要求出图时才触发，避免把「画饼」这类日常用语当成指令
_DRAW_RE = re.compile(
    r"(画个|画一张|画张|画一|画出来|帮我画|给我画|给你画|为他画|为她画|给他画|给她画|"
    r"生成(一|个|张)?图|生图|出图|绘图|设计.{0,10}(图|海报|头像|壁纸|封面|logo|标志))"
)


class ImageGenPlugin(Plugin):
    name = "image_gen"
    display_name = "AI 生图"
    version = "0.1.0"
    description = "管理员让我画图时，调用生图模型画好并发送"
    priority = 25  # 先于白话群管，避免「画个头像」被当成改资料

    async def on_load(self) -> None:
        self._tasks: set[asyncio.Task] = set()
        self._busy = asyncio.Semaphore(1)
        self._last_draw_at: dict[int, float] = {}  # user_id -> 上次生图时间
        if self.bot.config.image.enabled:
            self.log.info("生图已启用，模型=%s", self.bot.config.image.model or "未填写")

    async def on_unload(self) -> None:
        for task in list(getattr(self, "_tasks", ())):
            task.cancel()
        self._tasks.clear()

    async def _refine_prompt(self, text: str, session: str = "") -> str:
        """让对话模型把口语要求补成一段可用的生图提示词。"""
        if not self.bot.config.ai.enabled:
            return text
        try:
            from ...ai.client import resolve_persona

            persona = resolve_persona(self.bot.config.ai) or ""
        except Exception:  # noqa: BLE001
            persona = ""
        system = (
            f"{persona}\n\n"
            "你现在要画一张图。请根据管理员的要求写一段生图提示词，只输出提示词本身，"
            "不要解释、不要加引号、不要分段。"
            "如果对方要画你、问你长什么样，就按你的人设描述自己的外貌；"
            "如果对方让你设计，就补全合理的构图、风格和细节；"
            "如果他说「他/她」而不明确是谁，结合下面的最近对话判断指的是谁，"
            "把那个人在外貌或特征上的已知信息写进提示词。"
        ).strip()
        client = self.bot.chat_client()
        context = ""
        if session:
            try:
                history = client.recent_messages(session, 8)
            except AttributeError:
                history = []
            lines = []
            for item in history:
                content = item.get("content")
                if isinstance(content, list):
                    content = " ".join(
                        str(part.get("text", ""))
                        for part in content
                        if isinstance(part, dict)
                    )
                content = str(content or "").strip()
                if content:
                    lines.append(f"{'对方' if item.get('role') == 'user' else '我'}：{content}")
            if lines:
                context = "最近的对话：\n" + "\n".join(lines) + "\n\n"
        try:
            prompt = await client.complete(
                system,
                f"{context}管理员的要求：{text}\n请写出提示词：",
                temperature=0.7,
                max_tokens=300,
            )
        except Exception as exc:  # noqa: BLE001
            self.log.warning("生图提示词改写失败，改用原话: %s", exc)
            return text
        prompt = str(prompt or "").strip().strip('"').strip()
        return prompt or text

    async def _notify(self, ctx, fact: str, fallback: str) -> None:
        """失败提示也按人格说，不暴露接口/配置这些内部说法。"""
        text = ""
        if self.bot.config.ai.enabled:
            try:
                from ...ai.client import resolve_persona

                persona = resolve_persona(self.bot.config.ai) or ""
                text = await self.bot.chat_client().complete(
                    f"{persona}\n\n"
                    "你刚才试着替主人画图，但这次没画成。用你自己的口吻发一句很短的回复，"
                    "不要用 @，不要提接口、配置、模型、参数这些词，也不要解释技术原因。",
                    f"情况：{fact}\n请用一句话回复：",
                    temperature=0.7,
                    max_tokens=60,
                )
            except Exception:  # noqa: BLE001
                text = ""
        text = re.sub(r"\[CQ:at,[^\]]*\]", "", str(text or "")).strip().strip('"').strip()
        try:
            from ._ai_reply import ensure_punct
            text = ensure_punct(text)
            fallback = ensure_punct(fallback)
        except Exception:
            pass
        await ctx.send(text or fallback)

    async def on_message(self, ctx) -> Any:
        cfg = self.bot.config.image
        if not cfg.enabled:
            return None
        text = (ctx.text or "").strip()
        if not text or not _DRAW_RE.search(text):
            return None
        # 确认是画图请求后，才检查频率：主人不受限制；其他人 3 分钟内一次
        try:
            uid = int(ctx.user_id or 0)
        except (TypeError, ValueError):
            uid = 0
        admins = [int(a) for a in (self.bot.config.bot.admins or [])]
        if uid and uid not in admins:
            last = self._last_draw_at.get(uid, 0.0)
            if time.time() - last < 180:
                await self._safe_send(ctx, "画图太频繁了，过三分钟再让我画吧。")
                return self.stop()
            self._last_draw_at[uid] = time.time()

        from ...core.bot import strip_call_word

        prompt_text = (strip_call_word(text, self.bot.call_words()) or text).strip()
        if not prompt_text:
            return None

        ai_cfg = self.bot.config.ai
        if not (cfg.base_url or ai_cfg.base_url) or not cfg.model:
            await self._notify(ctx, "画图的工具还没接好", "画画的工具还没接好，晚点再来找我画吧")
            return self.stop()

        if self._busy.locked():
            await self._safe_send(ctx, "上一张还在画，等我画完这张再来。")
            return self.stop()

        try:
            self.bot._image_busy_until = time.time() + 300
        except Exception:
            pass
        self.log.info("开始生图：%s", prompt_text[:60])
        await self._safe_send(ctx, "画着呢，稍等一下。")
        # 画图通常要几十秒，放到后台跑：先回一句，避免整段对话像卡死一样没有响应
        task = asyncio.create_task(self._draw_and_send(ctx, prompt_text, text))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return self.stop()

    async def _safe_send(self, ctx, text: str) -> None:
        try:
            await ctx.send(text)
        except Exception as exc:  # noqa: BLE001
            self.log.warning("发送失败: %s", exc)

    async def _notify_safe(self, ctx, fact: str, fallback: str) -> None:
        """失败提示额外限时，避免再等一次模型回复。"""
        try:
            await asyncio.wait_for(self._notify(ctx, fact, fallback), timeout=20)
        except Exception:  # noqa: BLE001
            await self._safe_send(ctx, fallback)

    #: 常见会被审核拦截的专有名词 → 泛化描述
    _SOFTEN_MAP = {
        "奥特曼": "经典特摄英雄", "皮卡丘": "黄色电气小怪兽",
        "米老鼠": "卡通老鼠", "迪士尼": "卡通", "漫威": "超级英雄",
        "蜘蛛侠": "爬墙英雄", "蝙蝠侠": "黑夜英雄", "钢铁侠": "机械装甲英雄",
        "火影": "忍者少年", "海贼王": "海盗冒险", "原神": "幻想世界角色",
        "初音": "虚拟歌姬", "王者荣耀": "游戏角色", "黑丝": "深色长袜",
        "女仆": "服务员", "萝莉": "可爱女孩", "裸": "自然", "性感": "优雅",
    }

    def _soften_prompt(self, text: str) -> str:
        """审核拦截后的降敏：把专有名词替换成泛化描述。"""
        t = text or ""
        for k, v in self._SOFTEN_MAP.items():
            if k in t:
                t = t.replace(k, v)
        return t

    async def _draw_and_send(self, ctx, prompt_text: str, original: str) -> None:
        cfg = self.bot.config.image
        ai_cfg = self.bot.config.ai
        timeout = max(30.0, float(getattr(cfg, "timeout", 120.0) or 120.0))
        async with self._busy:
            try:
                from ...ai.image import generate, save_image
                from ._ai_reply import session_key

                try:
                    refined = await asyncio.wait_for(
                        self._refine_prompt(prompt_text, session_key(ctx)), timeout=45
                    )
                except asyncio.TimeoutError:
                    refined = prompt_text

                data, ext, width, height = await asyncio.wait_for(
                    generate(cfg, ai_cfg, refined, size_text=original),
                    timeout=timeout + 15,
                )
                path = save_image(self.bot.config.paths.data_dir / "images", data, ext)
                # QQ 跑在 Docker 容器里读不到宿主机 file:// 路径；改发 base64://
                try:
                    data_b64 = base64.b64encode(path.read_bytes()).decode()
                except OSError:
                    data_b64 = base64.b64encode(data).decode()
                await ctx.send(Message([image_seg("base64://" + data_b64)]))
                self.log.info("生图完成：%sx%s -> %s（%d KB）",
                              width, height, path.name, len(data) // 1024)
            except asyncio.TimeoutError:
                self.log.error("生图超时（%.0f 秒）", timeout + 15)
                await self._safe_send(ctx, "这张画太久没出来，先不画了，等会儿再试。")
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                msg = str(exc)
                self.log.error("生图失败: %s", msg)
                # 内容审核拦截：自动降敏重试一次（去掉 IP/敏感专有名词）
                if "400" in msg or "内容" in msg or "敏感" in msg or "contentFilter" in msg:
                    try:
                        softened = self._soften_prompt(refined)
                        if softened != refined:
                            self.log.info("审核拦截，降敏重试：%s", softened[:40])
                            data, ext, width, height = await asyncio.wait_for(
                                generate(cfg, ai_cfg, softened, size_text=original),
                                timeout=timeout + 15)
                            path = save_image(self.bot.config.paths.data_dir / "images", data, ext)
                            try:
                                data_b64 = base64.b64encode(path.read_bytes()).decode()
                            except OSError:
                                data_b64 = base64.b64encode(data).decode()
                            await ctx.send(Message([image_seg("base64://" + data_b64)]))
                            self.log.info("降敏重试成功：%sx%s", width, height)
                            return
                    except Exception as exc2:  # noqa: BLE001
                        self.log.warning("降敏重试也失败: %s", exc2)
                    await self._safe_send(ctx, "这个题材被审核拦了，换个描述再试试。")
                    return
                await self._notify_safe(ctx, "这次生成没有成功", "这张没画出来，等会儿再试一次。")
