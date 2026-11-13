"""表情包库：本地图片文件 + 标签索引。

模型在回复末尾用 ``[表情:标签]`` 表达情绪，这里按标签随机挑一张发出去。
标签由用户自己定义（开心、难过、吃瓜……），导入时填写。
"""

from __future__ import annotations

import json
import re
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from .log import get_logger

log = get_logger("stickers")

#: 允许的图片格式
ALLOWED_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}
#: 单个文件大小上限（8MB）
MAX_BYTES = 8 * 1024 * 1024

_EMOTION_RE = re.compile(r"\[\s*表情\s*[:：]\s*([^\]\s]+)\s*\]")


def emotion_instruction(tags: list[str]) -> str:
    """拼给模型的说明：鼓励它在聊天里自然地主动配表情包。

    指令写得太"被动"（"如果更生动就用"）会让模型默认不发，只在被点名要求时才配图；
    这里改成正面引导，并点明适用的语气场景，让它把表情包当成聊天的自然反应。
    """
    return (
        "\n\n【表情包】回复时你可以顺手配一张表情包：在回复的最后单独一行输出 "
        f"[表情:标签]，标签只能从这些里选：{'、'.join(tags)}；标签对不上系统就不发。"
        "请主动用起来，不要等对方点名要表情包——只要这一轮语气是轻松、俏皮、卖萌、调侃、"
        "吐槽、害羞、开心、生气、委屈、吃瓜、敷衍之类带情绪起伏的，就在末尾配一张合适的表情包，"
        "让它像真人聊天一样自然；只有严肃、正式或纯信息说明的回复才省略。"
    )


def split_emotion(text: str) -> tuple[str, str]:
    """从回复里剥离 ``[表情:xx]``，返回 (正文, 标签)。"""
    raw = text or ""
    match = _EMOTION_RE.search(raw)
    if not match:
        return raw.strip(), ""
    return _EMOTION_RE.sub("", raw).strip(), match.group(1).strip()


def clean_tags(tags: Any) -> list[str]:
    """归一化标签：去空白、去重、限长。"""
    if isinstance(tags, str):
        tags = re.split(r"[,，\s]+", tags)
    if not isinstance(tags, list):
        return []
    out: list[str] = []
    for tag in tags:
        name = str(tag).strip()[:16]
        if name and name not in out:
            out.append(name)
    return out[:12]


class StickerStore:
    """表情包索引，落地为 data/stickers/index.json + 同目录的图片文件。"""

    def __init__(self, config) -> None:
        self.dir: Path = config.paths.sticker_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.index_file = self.dir / "index.json"
        self._lock = threading.Lock()

    # ---------- 索引读写 ----------

    def _load(self) -> list[dict[str, Any]]:
        if not self.index_file.is_file():
            return []
        try:
            data = json.loads(self.index_file.read_text("utf-8"))
        except (OSError, json.JSONDecodeError):
            log.warning("表情包索引损坏，已按空库处理")
            return []
        return [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []

    def _save(self, items: list[dict[str, Any]]) -> None:
        tmp = self.index_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.index_file)

    def path_of(self, item: dict[str, Any]) -> Path:
        return self.dir / str(item.get("file") or "")

    # ---------- 增删改查 ----------

    def add(self, filename: str, data: bytes, tags: Any) -> dict[str, Any]:
        ext = Path(filename or "").suffix.lower()
        if ext not in ALLOWED_EXT:
            raise ValueError(f"不支持的图片格式：{ext or '未知'}")
        if not data:
            raise ValueError("文件内容为空")
        if len(data) > MAX_BYTES:
            raise ValueError(f"图片过大（上限 {MAX_BYTES // 1024 // 1024}MB）")

        sticker_id = uuid.uuid4().hex[:12]
        stored = f"{sticker_id}{ext}"
        with self._lock:
            (self.dir / stored).write_bytes(data)
            items = self._load()
            item = {
                "id": sticker_id,
                "file": stored,
                "name": Path(filename).stem[:40],
                "tags": clean_tags(tags),
                "created_at": time.time(),
            }
            items.append(item)
            self._save(items)
        log.info("已导入表情包 %s，标签 %s", stored, item["tags"])
        return item

    def list(self) -> list[dict[str, Any]]:
        items = self._load()
        out: list[dict[str, Any]] = []
        for item in items:
            if not self.path_of(item).is_file():
                continue  # 文件被手动删了就不展示
            out.append({**item, "size": self.path_of(item).stat().st_size})
        return out

    def delete(self, sticker_id: str) -> bool:
        with self._lock:
            items = self._load()
            target = next((i for i in items if i.get("id") == sticker_id), None)
            if target is None:
                return False
            try:
                self.path_of(target).unlink(missing_ok=True)
            except OSError as exc:
                log.warning("删除表情包文件失败: %s", exc)
            self._save([i for i in items if i.get("id") != sticker_id])
        return True

    def update_tags(self, sticker_id: str, tags: Any) -> bool:
        with self._lock:
            items = self._load()
            for item in items:
                if item.get("id") == sticker_id:
                    item["tags"] = clean_tags(tags)
                    self._save(items)
                    return True
        return False

    # ---------- 检索 ----------

    def tags(self) -> list[str]:
        """全部标签（去重，按出现顺序）。

        直接读索引、不检查文件是否存在——它在每次 AI 回复时都会被调用，
        必须足够轻。
        """
        out: list[str] = []
        for item in self._load():
            for tag in item.get("tags") or []:
                if tag not in out:
                    out.append(tag)
        return out

    def random_by_tag(self, tag: str) -> dict[str, Any] | None:
        """按标签随机取一张（只对候选做一次真实存在性检查）。"""
        import random

        name = str(tag or "").strip()
        if not name:
            return None
        matched = [i for i in self._load() if name in (i.get("tags") or [])]
        random.shuffle(matched)
        for item in matched:
            if self.path_of(item).is_file():
                return item
        return None

    def stats(self) -> dict[str, Any]:
        items = self.list()
        return {
            "count": len(items),
            "tags": self.tags(),
            "dir": str(self.dir),
            "bytes": sum(i.get("size") or 0 for i in items),
        }