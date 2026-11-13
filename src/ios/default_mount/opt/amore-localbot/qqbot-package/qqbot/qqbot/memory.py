"""长期记忆库：把「以后跟我说话带个哥哥」这类长期要求记下来，之后每次对话都遵守。

与知识库的分工：
  - 知识库是「按问题检索」的产品资料，命中才注入；
  - 记忆库是「长期生效」的规则与偏好，只要命中作用域就无条件注入。

省 token 的三条原则（与知识库一致）：
  1. 存储用本机 SQLite，读写零 token；
  2. 注入有字符预算，超出预算按「最近更新优先」保留；
  3. 记忆只在当次请求的 system 消息里出现，不进对话历史，避免每轮重复计费。

作用域三分：
  global  全局：任何群、任何人对机器人都生效（如「你叫小粉丸」）
  group   本群：只在记录它的那个群生效（如「本群不许发广告」）
  user    对我：只对指定的那个人生效（如「以后跟我说话带个哥哥」）
"""

from __future__ import annotations

import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .log import get_logger

log = get_logger("memory")

SCOPES = ("global", "group", "user")
SCOPE_LABELS = {"global": "全局", "group": "本群", "user": "对我"}

#: 模型在回复末尾输出 [记住:范围|内容] 来表达「这条要长期记住」
_MEMO_RE = re.compile(r"\[\s*记住\s*[:：]\s*([^\]\n]+?)\s*\]")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS memories (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    scope      TEXT    NOT NULL DEFAULT 'group',
    group_id   INTEGER NOT NULL DEFAULT 0,
    user_id    INTEGER NOT NULL DEFAULT 0,
    content    TEXT    NOT NULL,
    source     TEXT    NOT NULL DEFAULT 'panel',
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at REAL    NOT NULL,
    updated_at REAL    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mem_scope ON memories(scope, group_id, user_id);
CREATE TABLE IF NOT EXISTS summaries (
    session    TEXT PRIMARY KEY,
    content    TEXT NOT NULL,
    updated_at REAL NOT NULL
);
"""


def normalize_scope(raw: str) -> str:
    """把模型写的范围词归一化成作用域；认不出来返回空串，交给调用方兜底。"""
    value = str(raw or "").strip().lower()
    if not value:
        return ""
    if "全局" in value or value in ("all", "global", "everywhere"):
        return "global"
    if "群" in value or value in ("group", "chat"):
        return "group"
    if "我" in value or "个人" in value or "自己" in value or value in ("user", "me"):
        return "user"
    return ""


def split_memory(text: str) -> tuple[str, str, str]:
    """从回复里剥离 ``[记住:范围|内容]``，返回 (正文, 范围词, 记忆内容)。

    范围词可以是「全局/本群/对我」；写成 ``[记住:内容]`` 时范围词为空串。
    """
    raw = text or ""
    match = _MEMO_RE.search(raw)
    if not match:
        return raw.strip(), "", ""
    inner = match.group(1)
    parts = re.split(r"[|｜]", inner, maxsplit=1)
    if len(parts) == 2:
        scope_raw, content = parts[0], parts[1]
    else:
        scope_raw, content = "", parts[0]
    return _MEMO_RE.sub("", raw, count=1).strip(), scope_raw.strip(), content.strip()


def memory_instruction() -> str:
    """拼给模型的说明：什么时候该把对方的话记成长期记忆。"""
    return (
        "\n\n【长期记忆】对方说「以后……」「每次都要……」「记住……」这类长期要求时，"
        "请把要点记下来：在回复的最后单独一行输出 [记住:范围|内容]。"
        "范围只能填 全局 / 本群 / 对我 三者之一——"
        "全局表示任何场合都生效（如「你叫小粉丸」）；"
        "本群表示只在本群生效（如「本群不许发广告」）；"
        "对我表示只针对当前说话的这个人（如「以后叫我哥哥」）。"
        "内容用一句简短的话写清要记住的事。只是随口一说、不是长期要求的，不要输出这一行。"
    )


class MemoryStore:
    """长期记忆索引，落地为 data/memory/memory.sqlite3。"""

    def __init__(self, config) -> None:
        self.path: Path = config.paths.memory_file
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init_db()

    # ---------- 基础设施 ----------

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.path), timeout=10.0)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._lock, self._connect() as conn:
            conn.executescript(_SCHEMA)
            conn.execute("PRAGMA journal_mode=WAL")

    @staticmethod
    def _row(row: sqlite3.Row) -> dict[str, Any]:
        item = dict(row)
        item["enabled"] = bool(item.get("enabled"))
        item["scope_label"] = SCOPE_LABELS.get(str(item.get("scope")), "本群")
        return item

    # ---------- 增删改查 ----------

    def add(
        self,
        content: str,
        scope: str = "group",
        group_id: int = 0,
        user_id: int = 0,
        source: str = "panel",
    ) -> int:
        text = str(content or "").strip()
        if not text:
            raise ValueError("记忆内容不能为空")
        name = scope if scope in SCOPES else "group"
        now = time.time()
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO memories(scope, group_id, user_id, content, source, enabled,"
                " created_at, updated_at) VALUES(?, ?, ?, ?, ?, 1, ?, ?)",
                (
                    name,
                    int(group_id or 0) if name == "group" else 0,
                    int(user_id or 0) if name == "user" else 0,
                    text[:500],
                    str(source or "panel")[:16],
                    now,
                    now,
                ),
            )
            mem_id = int(cur.lastrowid or 0)
        log.info("已记录记忆 #%s [%s] %s", mem_id, name, text[:40])
        return mem_id

    def update(
        self,
        mem_id: int,
        content: str | None = None,
        scope: str | None = None,
        group_id: int | None = None,
        user_id: int | None = None,
    ) -> bool:
        with self._lock, self._connect() as conn:
            row = conn.execute("SELECT * FROM memories WHERE id = ?", (int(mem_id),)).fetchone()
            if row is None:
                return False
            name = scope if scope in SCOPES else str(row["scope"])
            text = str(row["content"]) if content is None else str(content).strip()
            if not text:
                return False
            gid = int(row["group_id"]) if group_id is None else int(group_id or 0)
            uid = int(row["user_id"]) if user_id is None else int(user_id or 0)
            conn.execute(
                "UPDATE memories SET content = ?, scope = ?, group_id = ?, user_id = ?,"
                " updated_at = ? WHERE id = ?",
                (
                    text[:500],
                    name,
                    gid if name == "group" else 0,
                    uid if name == "user" else 0,
                    time.time(),
                    int(mem_id),
                ),
            )
        return True

    def set_enabled(self, mem_id: int, enabled: bool) -> bool:
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "UPDATE memories SET enabled = ?, updated_at = ? WHERE id = ?",
                (1 if enabled else 0, time.time(), int(mem_id)),
            )
        return bool(cur.rowcount)

    def delete(self, mem_id: int) -> bool:
        with self._lock, self._connect() as conn:
            cur = conn.execute("DELETE FROM memories WHERE id = ?", (int(mem_id),))
        return bool(cur.rowcount)

    def delete_scope(self, scope: str, group_id: int = 0, user_id: int = 0) -> int:
        """清空某个作用域：全局、某个群、或某个人。"""
        name = scope if scope in SCOPES else ""
        if not name:
            return 0
        with self._lock, self._connect() as conn:
            if name == "group":
                cur = conn.execute(
                    "DELETE FROM memories WHERE scope = 'group' AND group_id = ?",
                    (int(group_id or 0),),
                )
            elif name == "user":
                cur = conn.execute(
                    "DELETE FROM memories WHERE scope = 'user' AND user_id = ?",
                    (int(user_id or 0),),
                )
            else:
                cur = conn.execute("DELETE FROM memories WHERE scope = 'global'")
        return int(cur.rowcount)

    def get(self, mem_id: int) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM memories WHERE id = ?", (int(mem_id),)).fetchone()
        return self._row(row) if row is not None else None

    def list(
        self, scope: str = "", group_id: int = 0, user_id: int = 0, limit: int = 800
    ) -> list[dict[str, Any]]:
        """按作用域列出条目；scope 为空时返回全部。"""
        sql = "SELECT * FROM memories"
        params: list[Any] = []
        if scope == "group":
            sql += " WHERE scope = 'group' AND group_id = ?"
            params.append(int(group_id or 0))
        elif scope == "user":
            sql += " WHERE scope = 'user' AND user_id = ?"
            params.append(int(user_id or 0))
        elif scope == "global":
            sql += " WHERE scope = 'global'"
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(int(limit))
        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [self._row(row) for row in rows]

    def groups(self) -> list[dict[str, Any]]:
        """有群级记忆的群及其条数。"""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT group_id, COUNT(*) AS count FROM memories"
                " WHERE scope = 'group' GROUP BY group_id ORDER BY group_id"
            ).fetchall()
        return [{"group_id": row["group_id"], "count": row["count"]} for row in rows]

    def users(self) -> list[dict[str, Any]]:
        """有个人记忆的 QQ 及其条数。"""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT user_id, COUNT(*) AS count FROM memories"
                " WHERE scope = 'user' GROUP BY user_id ORDER BY user_id"
            ).fetchall()
        return [{"user_id": row["user_id"], "count": row["count"]} for row in rows]

    def stats(self) -> dict[str, Any]:
        with self._connect() as conn:
            total = conn.execute("SELECT COUNT(*) FROM memories").fetchone()[0]
            enabled = conn.execute(
                "SELECT COUNT(*) FROM memories WHERE enabled = 1"
            ).fetchone()[0]
            by_scope = {
                row["scope"]: row["count"]
                for row in conn.execute(
                    "SELECT scope, COUNT(*) AS count FROM memories GROUP BY scope"
                ).fetchall()
            }
        return {
            "total": total,
            "enabled": enabled,
            "by_scope": {name: by_scope.get(name, 0) for name in SCOPES},
            "path": str(self.path),
        }

    # ---------- 临时摘要（L3） ----------

    def summary(self, session: str) -> str:
        """读取某个会话的滚动摘要；没有返回空串。"""
        key = str(session or "").strip()
        if not key:
            return ""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT content FROM summaries WHERE session = ?", (key,)
            ).fetchone()
        return str(row["content"] or "") if row is not None else ""

    def set_summary(self, session: str, content: str) -> None:
        """写入/覆盖某个会话的滚动摘要。"""
        key = str(session or "").strip()
        text = str(content or "").strip()
        if not key or not text:
            return
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO summaries(session, content, updated_at) VALUES(?, ?, ?)"
                " ON CONFLICT(session) DO UPDATE SET content = excluded.content,"
                " updated_at = excluded.updated_at",
                (key, text[:2000], time.time()),
            )

    def clear_summary(self, session: str) -> None:
        key = str(session or "").strip()
        if not key:
            return
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM summaries WHERE session = ?", (key,))

    # ---------- 注入 ----------

    def context_for(self, group_id: Any, user_id: Any, max_chars: int = 600) -> str:
        """拼出当前场景该遵守的记忆文本；没有任何条目时返回空串（0 token）。"""
        gid = int(group_id or 0)
        uid = int(user_id or 0)
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT scope, content FROM memories"
                " WHERE enabled = 1 AND (scope = 'global'"
                "   OR (scope = 'group' AND group_id = ?)"
                "   OR (scope = 'user' AND user_id = ?))"
                " ORDER BY updated_at DESC",
                (gid, uid),
            ).fetchall()
        if not rows:
            return ""

        budget = max(60, int(max_chars))
        used = 0
        lines: list[str] = []
        for row in rows:
            content = str(row["content"] or "").strip()
            if not content:
                continue
            line = f"[{SCOPE_LABELS.get(row['scope'], '本群')}] {content}"
            if used + len(line) > budget:
                break
            lines.append(line)
            used += len(line) + 1
        return "\n".join(lines)
