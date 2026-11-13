"""链接解析：识别消息里的链接，联网解析后把视频直接下载并发出来。

两条路线（混合）：
  - B站：直接调它的官方接口拿**单文件 mp4**（不需要 ffmpeg，画质 360p~720p；
    在插件设置里填 cookie 能提到更高画质）；
  - 其他站点：交给 yt-dlp（随包内置，支持上千个站点）。
解析不是视频的普通网页，就只回一条「标题 + 链接」，不下载。

安全与资源约束：
  - 只允许**管理员**触发，否则任何群员都能拿你的号刷磁盘和带宽；
  - 下载有大小上限（默认 100MB）与时长上限（默认 5 分钟），超限改发群文件或只回链接；
  - 整条解析在后台任务里跑，绝不阻塞消息分发（否则一条长下载会把整个机器人卡住）。
"""

from __future__ import annotations

import asyncio
import re
import time
from pathlib import Path
from typing import Any

from ...core.message import Message, Segment
from ..base import Plugin

#: 从文本里抠链接（中文标点与常见收尾符号都当成边界）
URL_RE = re.compile(r"https?://[^\s，,。、）)】\]】\"'<>]+")

#: B站视频链接：标准页 / av 号 / b23.tv 短链
BILI_RE = re.compile(
    r"(?:bilibili\.com/video/|b23\.tv/)(BV[0-9A-Za-z]{10}|av\d+|[0-9A-Za-z]+)"
)

#: 浏览器 UA：B站接口会拒绝默认 UA，必须伪装
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
)

#: 只有这些后缀的链接才当视频处理，避免把 .zip/.exe 也拖下来
_VIDEO_HINT = re.compile(r"(bilibili\.com/video|b23\.tv|youtube\.com|youtu\.be|douyin\.com|"
                         r"ixigua\.com|weibo\.com|v\.qq\.com|x\.com|twitter\.com|tiktok\.com)")


class LinkParserPlugin(Plugin):
    name = "link_parser"
    display_name = "链接解析"
    version = "0.1.0"
    description = "链接解析：管理员发链接，自动解析并下载视频发出来"
    priority = 25  # 先于白话群管(30)/自主模式(40)/AI对话(50)，链接才不会被抢走

    config_labels: dict[str, str] = {
        "enabled": "启用本插件",
        "strict_admin": "严格管理员权限（只认「AI 配置」里的管理员，群主/群管理不算）",
        "max_size_mb": "视频大小上限（MB，超过就改发群文件）",
        "max_duration_sec": "视频时长上限（秒，超过直接不下载）",
        "fallback_to_file": "超限时改上传群文件 / 私聊文件",
        "fallback_to_link": "兜底时只回标题和原链接",
        "ack_reply": "收到链接先回一句「正在解析」",
        "keep_files": "下载后保留临时文件（默认下完就删）",
        "request_timeout": "接口请求超时（秒）",
        "download_timeout": "下载超时（秒）",
        "bilibili_cookie": "B站 Cookie（可选，填了能解锁更高画质）",
    }

    default_config: dict[str, Any] = {
        "enabled": True,
        #: True=只有「AI 配置」里填的管理员（主人）能用；False=群主/群管理也算
        "strict_admin": True,
        #: 超过这个大小就不当视频发，改走群文件/链接
        "max_size_mb": 100,
        #: 超过这个时长直接不下载，避免拖一个几小时的视频
        "max_duration_sec": 300,
        #: 超限时改上传群文件（群聊）/私聊文件
        "fallback_to_file": True,
        #: 再不行就只回标题和链接
        "fallback_to_link": True,
        #: 收到链接后先回一句「正在解析」
        "ack_reply": True,
        "keep_files": False,
        "request_timeout": 30,
        "download_timeout": 180,
        #: 可选：填 B站 cookie 能解锁更高画质（不填就按游客画质）
        "bilibili_cookie": "",
    }

    def __init__(self, bot) -> None:
        super().__init__(bot)
        self._tasks: set[asyncio.Task] = set()
        self.cache_dir = self.data_dir / "cache"
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    async def on_load(self) -> None:
        self.add_command(
            "parse_url", self._cmd_parse,
            aliases=("解析", "解析链接"), admin=True,
            description="手动解析指定链接：<链接>",
        )
        self.log.info("链接解析已加载（B站直连 + yt-dlp 兜底）")

    async def on_unload(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        self._tasks.clear()

    # ---------- 触发 ----------

    @property
    def _active(self) -> bool:
        return bool(self.cfg_get("enabled", True))

    def _url_of(self, text: str) -> str:
        match = URL_RE.search(text or "")
        return match.group(0).rstrip("。，,、") if match else ""

    def _allowed(self, ctx) -> bool:
        """默认只认「AI 配置」里的管理员（账号主人），本群群主/群管理不算。

        解析会真下载文件、吃带宽和磁盘，权限收紧一点更稳；要放开把
        strict_admin 改成 False 即可。
        """
        if self.cfg_get("strict_admin", True) is not False:
            uid = int(getattr(ctx.event, "user_id", 0) or 0)
            return uid in [int(a) for a in (self.bot.config.bot.admins or [])]
        return bool(ctx.is_admin)

    def _should_handle(self, ctx, url: str) -> bool:
        """只接「管理员 + 带链接 + 不是显式指令」的消息，避免抢走别的插件的工作。"""
        if not url:
            return False
        if not self._allowed(ctx):
            return False
        text = (ctx.text or "").strip()
        rest = text.replace(url, "").strip()
        # 显式前缀指令（如 #白话群管 xxx）交给对应插件，别抢
        if text.startswith(("#", "/", "！", "!")):
            return False
        return len(rest) <= 40

    async def on_message(self, ctx) -> Any:
        if not self._active:
            return None
        url = self._url_of(ctx.text)
        if not self._should_handle(ctx, url):
            return None
        self._spawn(ctx, url)
        return self.stop()  # 立刻交回，下载在后台跑，绝不阻塞分发

    async def _cmd_parse(self, ctx, args: str) -> Any:
        url = self._url_of(args)
        if not url:
            await ctx.reply("要解析哪个链接？把链接带上再发一次。")
            return
        self._spawn(ctx, url)  # 后台跑，_handle 里会先回一句「正在解析」

    def _spawn(self, ctx, url: str) -> None:
        task = asyncio.create_task(self._handle(ctx, url))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # ---------- 主流程 ----------

    async def _handle(self, ctx, url: str) -> None:
        try:
            if self.cfg_get("ack_reply", True):
                await self._safe(ctx, "收到链接，正在解析…")
            target = await self._resolve_url(url)
            if self._is_bilibili(target):
                ok = await self._bilibili(ctx, target, url)
            else:
                ok = await self._generic(ctx, target, url)
            if not ok and self.cfg_get("fallback_to_link", True):
                await self._reply_title(ctx, target, url)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            self.log.error("解析 %s 失败: %s: %s", url, type(exc).__name__, exc)
            await self._safe(ctx, f"解析失败：{str(exc)[:120]}")

    async def _resolve_url(self, url: str) -> str:
        """b23.tv 短链先跟一次跳转拿真实地址。"""
        if "b23.tv" not in url:
            return url
        try:
            import httpx

            async with httpx.AsyncClient(
                timeout=float(self.cfg_get("request_timeout", 30)),
                headers={"User-Agent": UA},
                follow_redirects=True,
            ) as client:
                resp = await client.head(url)
                if resp.status_code >= 400:
                    resp = await client.get(url)
                return str(resp.url)
        except Exception as exc:  # noqa: BLE001
            self.log.warning("短链跳转解析失败: %s", exc)
            return url

    @staticmethod
    def _is_bilibili(url: str) -> bool:
        return bool(re.search(r"bilibili\.com/video/", url)) and bool(BILI_RE.search(url))

    # ---------- B站直连 ----------

    def _bili_headers(self) -> dict[str, str]:
        headers = {"User-Agent": UA, "Referer": "https://www.bilibili.com/"}
        cookie = str(self.cfg_get("bilibili_cookie") or "").strip()
        if cookie:
            headers["Cookie"] = cookie
        return headers

    async def _bilibili(self, ctx, url: str, origin: str) -> bool:
        """走 B站接口取单文件 mp4 并发送；拿不到就返回 False 交给 yt-dlp。"""
        match = BILI_RE.search(url)
        if not match:
            return False
        vid = match.group(1)
        param = f"bvid={vid}" if vid.startswith("BV") else f"aid={vid[2:]}"

        import httpx

        timeout = float(self.cfg_get("request_timeout", 30))
        async with httpx.AsyncClient(
            timeout=timeout, headers=self._bili_headers(), follow_redirects=True
        ) as client:
            info = await self._bili_view(client, param)
            if not info:
                return False
            title = str(info.get("title") or "")
            duration = int(info.get("duration") or 0)
            cid = int(info.get("cid") or 0)
            if not cid:
                return False

            max_dur = int(self.cfg_get("max_duration_sec", 300) or 300)
            if max_dur and duration > max_dur:
                await self._safe(ctx, f"视频时长 {duration} 秒，超过上限 {max_dur} 秒，就不下载了：{title}")
                return True

            playurl = await self._bili_playurl(client, param, cid)
            if not playurl:
                self.log.info("B站未拿到直链，转 yt-dlp 兜底: %s", title)
                return False

            size = int(playurl.get("size") or 0)
            max_bytes = int(self.cfg_get("max_size_mb", 100) or 100) * 1024 * 1024
            if size and size > max_bytes:
                self.log.info("B站直链 %d 字节超限，转 yt-dlp 兜底", size)
                return False

            dest = self.cache_dir / f"bili_{vid}_{int(time.time())}.mp4"
            await self._download(client, playurl["url"], dest, max_bytes)

        await self._send_video(ctx, dest, title, origin, duration)
        return True

    async def _bili_view(self, client, param: str) -> dict[str, Any] | None:
        resp = await client.get(f"https://api.bilibili.com/x/web-interface/view?{param}")
        data = resp.json() if resp.status_code == 200 else {}
        if data.get("code") != 0:
            self.log.warning("B站 view 接口失败: %s", data.get("message"))
            return None
        return data.get("data") or {}

    async def _bili_playurl(self, client, param: str, cid: int) -> dict[str, Any] | None:
        """fnval=1 要的是 durl 单文件 mp4，不是 DASH 分离流，所以不用 ffmpeg。"""
        params = f"{param}&cid={cid}&qn=80&fnval=1&fourk=1&platform=pc"
        resp = await client.get(f"https://api.bilibili.com/x/player/playurl?{params}")
        data = resp.json() if resp.status_code == 200 else {}
        if data.get("code") != 0:
            return None
        durl = (data.get("data") or {}).get("durl") or []
        if not durl:
            return None
        first = durl[0] or {}
        url = str(first.get("url") or "")
        if not url:
            return None
        return {"url": url, "size": first.get("size")}

    async def _download(self, client, url: str, dest: Path, max_bytes: int) -> None:
        """流式下载并在超过上限时立刻中断，避免把磁盘写爆。"""
        total = 0
        async with client.stream("GET", url, headers=self._bili_headers()) as resp:
            resp.raise_for_status()
            with dest.open("wb") as fh:
                async for chunk in resp.aiter_bytes(256 * 1024):
                    total += len(chunk)
                    if total > max_bytes:
                        raise RuntimeError(f"文件超过大小上限 {max_bytes // 1024 // 1024}MB")
                    fh.write(chunk)
        if total == 0:
            raise RuntimeError("下载到 0 字节")

    # ---------- 通用站点（yt-dlp） ----------

    async def _generic(self, ctx, url: str, origin: str) -> bool:
        if not _VIDEO_HINT.search(url):
            return False  # 明显不是视频站的链接，交给上层回标题
        max_bytes = int(self.cfg_get("max_size_mb", 100) or 100) * 1024 * 1024
        max_dur = int(self.cfg_get("max_duration_sec", 300) or 300)
        try:
            info = await asyncio.to_thread(self._ytdlp, url, max_bytes, max_dur)
        except Exception as exc:  # noqa: BLE001
            self.log.warning("yt-dlp 下载失败: %s", exc)
            return False
        if not info:
            return False
        path, title, duration = info
        await self._send_video(ctx, path, title, origin, duration)
        return True

    def _ytdlp(self, url: str, max_bytes: int, max_dur: int) -> tuple[Path, str, int] | None:
        """在线程里跑 yt-dlp（阻塞库，不能占事件循环）。"""
        try:
            import yt_dlp
        except ImportError as exc:
            raise RuntimeError("缺少 yt-dlp，无法解析该站点") from exc

        def _filter(info: dict[str, Any], *, incomplete: bool = False) -> str | None:
            duration = info.get("duration")
            if max_dur and duration and float(duration) > max_dur:
                return f"时长 {int(duration)} 秒超过上限"
            return None

        before = {p.name for p in self.cache_dir.iterdir()}
        opts: dict[str, Any] = {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "outtmpl": str(self.cache_dir / "%(id)s.%(ext)s"),
            # 只要单文件 mp4：本机没有 ffmpeg，合流不了分离的音视频流
            "format": "best[ext=mp4]/best",
            "max_filesize": max_bytes,
            "socket_timeout": float(self.cfg_get("download_timeout", 180) or 180),
            "match_filter": _filter,
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=True)
        if not info:
            return None

        title = str(info.get("title") or "")
        duration = int(info.get("duration") or 0)
        prepared = Path(ydl.prepare_filename(info))
        candidates = [prepared] if prepared.exists() else []
        if not candidates:
            new = [p for p in self.cache_dir.iterdir() if p.name not in before and p.is_file()]
            candidates = sorted(new, key=lambda p: p.stat().st_mtime, reverse=True)[:1]
        if not candidates:
            return None
        return candidates[0], title, duration

    # ---------- 发送 ----------

    async def _send_video(self, ctx, path: Path, title: str, origin: str, duration: int) -> None:
        """按大小决定：能发就发视频段，超限改群文件，再不行只回链接。"""
        max_bytes = int(self.cfg_get("max_size_mb", 100) or 100) * 1024 * 1024
        size = path.stat().st_size if path.exists() else 0
        head = f"《{title}》" if title else ""
        if duration:
            head += f"（{self._fmt_duration(duration)}）"

        if size and size <= max_bytes:
            seg = Segment("video", {"file": path.as_uri()})
            try:
                await ctx.send(Message([seg]))
                self.log.info("已发送视频 %s（%.1fMB）", path.name, size / 1024 / 1024)
                await self._safe(ctx, f"{head}\n已发送，大小 {size / 1024 / 1024:.1f}MB")
                self._cleanup(path)
                return
            except Exception as exc:  # noqa: BLE001
                self.log.warning("视频段发送失败，改用文件: %s", exc)

        if self.cfg_get("fallback_to_file", True) and await self._send_as_file(ctx, path):
            await self._safe(ctx, f"{head}\n体积较大（{size / 1024 / 1024:.1f}MB），已作为文件发给你。")
            self._cleanup(path)
            return

        self.log.info("未发送视频，仅回链接: %s", origin)
        await self._safe(ctx, f"{head}\n视频没送出去（体积 {size / 1024 / 1024:.1f}MB），原链接：{origin}")
        self._cleanup(path)

    async def _send_as_file(self, ctx, path: Path) -> bool:
        try:
            if ctx.is_group:
                await self.bot.call_api(
                    "upload_group_file",
                    group_id=int(ctx.group_id),
                    file=path.as_uri(),
                    name=path.name,
                )
            else:
                await self.bot.call_api(
                    "upload_private_file",
                    user_id=int(ctx.user_id),
                    file=path.as_uri(),
                    name=path.name,
                )
            return True
        except Exception as exc:  # noqa: BLE001
            self.log.warning("上传文件失败: %s", exc)
            return False

    def _cleanup(self, path: Path) -> None:
        if self.cfg_get("keep_files", False):
            return
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            self.log.warning("清理临时文件失败: %s", exc)

    # ---------- 兜底：回页面标题 ----------

    async def _reply_title(self, ctx, url: str, origin: str) -> None:
        title = ""
        try:
            import httpx

            async with httpx.AsyncClient(
                timeout=float(self.cfg_get("request_timeout", 30)),
                headers={"User-Agent": UA},
                follow_redirects=True,
            ) as client:
                resp = await client.get(url)
                text = resp.text[:200000]
            match = re.search(r"<title[^>]*>(.*?)</title>", text, re.S | re.I)
            if match:
                title = re.sub(r"\s+", " ", match.group(1)).strip()[:120]
        except Exception as exc:  # noqa: BLE001
            self.log.warning("抓取页面标题失败: %s", exc)
        await self._safe(ctx, f"{title or '这个链接不是视频'}\n{origin}")

    async def _safe(self, ctx, message: str) -> None:
        try:
            await ctx.send(message)
        except Exception as exc:  # noqa: BLE001
            self.log.warning("发送消息失败: %s", exc)

    @staticmethod
    def _fmt_duration(seconds: int) -> str:
        if seconds >= 3600:
            return f"{seconds // 3600}小时{seconds % 3600 // 60}分"
        if seconds >= 60:
            return f"{seconds // 60}分{seconds % 60}秒"
        return f"{seconds}秒"
