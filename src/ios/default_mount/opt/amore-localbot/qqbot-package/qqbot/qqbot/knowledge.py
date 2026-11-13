"""群聊知识库：本地 SQLite 存储 + 关键词倒排索引检索。

省 token 的三条设计原则：
  1. **不做向量嵌入**。嵌入要调用模型、是额外开销；这里索引与检索全在本机完成，
     从入库到命中都是 0 token。
  2. **只把命中的少量片段拼进系统提示**，用 top_k 与 max_chars 双重限流。
  3. **不写入对话历史**。参考资料只在当次请求的 system 消息里出现，不会每轮重复计费。

中文检索：不做分词，改用「字符二元组(bigram)」建索引，
「A产品的价格是多少」这类查询也能命中「A产品价格：199 元」。
"""

from __future__ import annotations

import math
import re
import sqlite3
import threading
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

from .log import get_logger

log = get_logger("knowledge")

#: 拉丁字母/数字词：长度 >= 2 才建索引，避免 "a" 这种噪音
_LATIN = re.compile(r"[a-z0-9_]{2,}")
#: 连续中日韩字符
_CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS docs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id   INTEGER NOT NULL,
    title      TEXT    NOT NULL DEFAULT '',
    content    TEXT    NOT NULL,
    tags       TEXT    NOT NULL DEFAULT '',
    created_at REAL    NOT NULL,
    updated_at REAL    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_docs_group ON docs(group_id);

CREATE TABLE IF NOT EXISTS terms (
    term   TEXT    NOT NULL,
    doc_id INTEGER NOT NULL,
    tf     INTEGER NOT NULL,
    PRIMARY KEY (term, doc_id)
);
CREATE INDEX IF NOT EXISTS idx_terms_doc ON terms(doc_id);
"""


def tokenize(text: str) -> list[str]:
    """中文按字符二元组切分，英文/数字按词切分。"""
    lowered = (text or "").lower()
    tokens: list[str] = list(_LATIN.findall(lowered))
    for run in _CJK.findall(lowered):
        if len(run) == 1:
            tokens.append(run)
        else:
            tokens.extend(run[i : i + 2] for i in range(len(run) - 1))
    return tokens


def split_chunks(text: str, max_len: int = 600) -> list[tuple[str, str]]:
    """把整篇文档按空行切块，返回 [(标题, 正文)]。

    刻意保持粒度细：一段一条。命中的片段越小，注入系统提示的 token 就越少，
    也更适合「一问一答」式的产品知识。单段超过 max_len 时才按长度硬切。
    """
    blocks = [b.strip() for b in re.split(r"\n\s*\n", text or "") if b.strip()]
    result: list[tuple[str, str]] = []
    for block in blocks:
        first_line = block.splitlines()[0].strip()
        title = first_line[:40] or block[:40]
        if len(block) <= max_len:
            result.append((title, block))
            continue
        for i in range(0, len(block), max_len):
            piece = block[i : i + max_len].strip()
            if piece:
                result.append((title, piece))
    return result


class KnowledgeBase:
    """按群隔离的本地知识库。"""

    def __init__(self, config) -> None:
        self.path: Path = config.paths.kb_file
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
    def _index_terms(conn: sqlite3.Connection, doc_id: int, text: str) -> None:
        counts: dict[str, int] = defaultdict(int)
        for token in tokenize(text):
            counts[token] += 1
        conn.executemany(
            "INSERT INTO terms(term, doc_id, tf) VALUES(?, ?, ?)",
            [(term, doc_id, tf) for term, tf in counts.items()],
        )

    def _reindex(self, conn: sqlite3.Connection, doc_id: int) -> None:
        row = conn.execute(
            "SELECT title, content, tags FROM docs WHERE id = ?", (doc_id,)
        ).fetchone()
        conn.execute("DELETE FROM terms WHERE doc_id = ?", (doc_id,))
        if row is not None:
            self._index_terms(conn, doc_id, f"{row['title']} {row['tags']} {row['content']}")

    # ---------- 增删改查 ----------

    def add(self, group_id: int, content: str, title: str = "", tags: str = "") -> int:
        now = time.time()
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO docs(group_id, title, content, tags, created_at, updated_at)"
                " VALUES(?, ?, ?, ?, ?, ?)",
                (int(group_id), title, content, tags, now, now),
            )
            doc_id = int(cur.lastrowid or 0)
            self._index_terms(conn, doc_id, f"{title} {tags} {content}")
        return doc_id

    def add_many(self, group_id: int, items: list[dict[str, str]]) -> int:
        now = time.time()
        with self._lock, self._connect() as conn:
            count = 0
            for item in items:
                content = str(item.get("content") or "").strip()
                if not content:
                    continue
                title = str(item.get("title") or "")
                tags = str(item.get("tags") or "")
                cur = conn.execute(
                    "INSERT INTO docs(group_id, title, content, tags, created_at, updated_at)"
                    " VALUES(?, ?, ?, ?, ?, ?)",
                    (int(group_id), title, content, tags, now, now),
                )
                self._index_terms(conn, int(cur.lastrowid or 0), f"{title} {tags} {content}")
                count += 1
        return count

    def update(self, doc_id: int, title: str, content: str, tags: str) -> bool:
        with self._lock, self._connect() as conn:
            exists = conn.execute("SELECT 1 FROM docs WHERE id = ?", (doc_id,)).fetchone()
            if exists is None:
                return False
            conn.execute(
                "UPDATE docs SET title = ?, content = ?, tags = ?, updated_at = ? WHERE id = ?",
                (title, content, tags, time.time(), doc_id),
            )
            self._reindex(conn, doc_id)
        return True

    def delete(self, doc_id: int) -> bool:
        with self._lock, self._connect() as conn:
            cur = conn.execute("DELETE FROM docs WHERE id = ?", (doc_id,))
            conn.execute("DELETE FROM terms WHERE doc_id = ?", (doc_id,))
        return bool(cur.rowcount)

    def delete_group(self, group_id: int) -> int:
        with self._lock, self._connect() as conn:
            ids = [
                row[0]
                for row in conn.execute(
                    "SELECT id FROM docs WHERE group_id = ?", (int(group_id),)
                ).fetchall()
            ]
            if ids:
                marks = ",".join("?" * len(ids))
                conn.execute(f"DELETE FROM terms WHERE doc_id IN ({marks})", ids)
            cur = conn.execute("DELETE FROM docs WHERE group_id = ?", (int(group_id),))
        return int(cur.rowcount)

    def list_docs(self, group_id: int, limit: int = 500) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id, title, content, tags, updated_at FROM docs"
                " WHERE group_id = ? ORDER BY id DESC LIMIT ?",
                (int(group_id), int(limit)),
            ).fetchall()
        return [dict(row) for row in rows]

    def groups(self) -> list[dict[str, Any]]:
        """所有已有知识条目的群及其条数。"""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT group_id, COUNT(*) AS count FROM docs GROUP BY group_id ORDER BY group_id"
            ).fetchall()
        return [{"group_id": row["group_id"], "count": row["count"]} for row in rows]

    def stats(self) -> dict[str, Any]:
        with self._connect() as conn:
            docs = conn.execute("SELECT COUNT(*) FROM docs").fetchone()[0]
            terms = conn.execute("SELECT COUNT(*) FROM terms").fetchone()[0]
        return {"docs": docs, "terms": terms, "path": str(self.path)}

    # ---------- 检索 ----------

    def search(self, group_id: int, query: str, top_k: int = 3) -> list[tuple[dict[str, Any], float]]:
        """关键词检索，返回 [(文档, 得分)]，按得分降序。全程不消耗 token。"""
        terms = list({t for t in tokenize(query) if t})
        if not terms:
            return []

        marks = ",".join("?" * len(terms))
        with self._connect() as conn:
            total = conn.execute(
                "SELECT COUNT(*) FROM docs WHERE group_id = ?", (int(group_id),)
            ).fetchone()[0]
            if not total:
                return []
            rows = conn.execute(
                f"SELECT t.doc_id, t.term, t.tf FROM terms t"
                f" JOIN docs d ON d.id = t.doc_id"
                f" WHERE d.group_id = ? AND t.term IN ({marks})",
                [int(group_id), *terms],
            ).fetchall()

        if not rows:
            return []

        df: dict[str, int] = defaultdict(int)
        for row in rows:
            df[row["term"]] += 1

        scores: dict[int, float] = defaultdict(float)
        for row in rows:
            idf = math.log(1 + total / df[row["term"]])
            scores[row["doc_id"]] += (1 + math.log(row["tf"])) * idf

        ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)[: max(1, int(top_k))]
        ids = [doc_id for doc_id, _ in ranked]
        if not ids:
            return []

        doc_marks = ",".join("?" * len(ids))
        with self._connect() as conn:
            doc_rows = conn.execute(
                f"SELECT id, title, content, tags FROM docs WHERE id IN ({doc_marks})", ids
            ).fetchall()
        by_id = {row["id"]: dict(row) for row in doc_rows}
        return [(by_id[i], s) for i, s in ranked if i in by_id]

    def context_for(
        self, group_id: int, query: str, top_k: int = 3, max_chars: int = 800
    ) -> str:
        """检索并按字符预算拼接成可直接塞进系统提示的文本；无命中返回空串。"""
        hits = self.search(group_id, query, top_k)
        if not hits:
            return ""
        budget = max(80, int(max_chars))
        blocks: list[str] = []
        used = 0
        for doc, _score in hits:
            text = str(doc.get("content") or "").strip()
            if not text:
                continue
            if used + len(text) > budget:
                text = text[: max(0, budget - used)]
            if not text:
                break
            blocks.append(text)
            used += len(text)
            if used >= budget:
                break
        return "\n---\n".join(blocks)