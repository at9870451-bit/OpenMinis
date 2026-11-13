"""全能动作：把用户的白话条件与动作，整理成可执行的触发规则。

规则和插件分离：面板通过本模块读写规则，插件按规则匹配事件并执行动作。
"""

from __future__ import annotations

import json
import re
import secrets
import threading
import time
from pathlib import Path
from typing import Any

from .log import get_logger

log = get_logger("omni")

TRIGGER_TYPES: dict[str, str] = {
    "keyword": "触发词",
    "poke": "被戳一戳",
    "profile_like": "被点赞",
    "friend_request": "收到好友申请",
    "group_request": "收到加群申请/邀请",
}

TRIGGER_HELP: dict[str, str] = {
    "keyword": "群聊或私聊消息包含指定词时触发",
    "poke": "有人戳机器人时触发",
    "profile_like": "有人给机器人名片点赞时触发",
    "friend_request": "收到加好友申请时触发",
    "group_request": "收到加群申请或邀请时触发",
}

ACTION_TYPES: dict[str, str] = {
    "reply": "回复消息",
    "poke": "戳一戳",
    "like": "点赞",
    "approve_friend": "同意好友申请",
    "reject_friend": "拒绝好友申请",
    "approve_group": "同意加群申请",
    "reject_group": "拒绝加群申请",
}

MATCH_MODES: dict[str, str] = {
    "contains": "包含",
    "startswith": "以…开头",
    "exact": "完全等于",
    "regex": "正则匹配",
}

SCOPES: dict[str, str] = {
    "all": "群聊和私聊",
    "group": "仅群聊",
    "private": "仅私聊",
}


def _text(value: Any, limit: int = 300) -> str:
    return str(value or "").strip()[:limit]


def _keywords(value: Any) -> list[str]:
    if isinstance(value, str):
        items = re.split(r"[,，、\n]", value)
    elif isinstance(value, (list, tuple)):
        items = list(value)
    else:
        items = []
    result: list[str] = []
    for item in items:
        word = _text(item, 40)
        if word and word not in result:
            result.append(word)
    return result[:8]


def trigger_label(trigger: dict[str, Any]) -> str:
    kind = str(trigger.get("type") or "keyword")
    if kind == "keyword":
        words = trigger.get("keywords") or []
        return "触发词：" + " / ".join(str(word) for word in words) if words else "触发词"
    return TRIGGER_TYPES.get(kind, kind)


def action_summary(actions: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for action in actions:
        kind = str(action.get("type") or "")
        if kind == "reply":
            if action.get("mode") == "fixed" and action.get("text"):
                parts.append("回复固定内容")
            else:
                parts.append("AI 回复")
        elif kind == "poke":
            parts.append("戳回去")
        elif kind == "like":
            parts.append(f"点赞 {int(action.get('times') or 10)} 次")
        else:
            parts.append(ACTION_TYPES.get(kind, kind))
    return "、".join(parts) or "未设置动作"


def normalize_trigger(raw: Any) -> dict[str, Any]:
    data = raw if isinstance(raw, dict) else {}
    kind = str(data.get("type") or "keyword")
    if kind not in TRIGGER_TYPES:
        kind = "keyword"
    mode = str(data.get("mode") or "contains")
    if mode not in MATCH_MODES:
        mode = "contains"
    scope = str(data.get("scope") or "all")
    if scope not in SCOPES:
        scope = "all"
    return {
        "type": kind,
        "keywords": _keywords(data.get("keywords")),
        "mode": mode,
        "scope": scope,
    }


def normalize_actions(raw: Any, fallback_text: str = "", like_times: int = 10) -> list[dict[str, Any]]:
    items = raw if isinstance(raw, list) else []
    actions: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("type") or "")
        if kind not in ACTION_TYPES:
            continue
        if kind == "reply":
            mode = "ai" if str(item.get("mode") or "ai") == "ai" else "fixed"
            text = _text(item.get("text") or fallback_text, 500)
            instruction = _text(item.get("text") or item.get("instruction") or fallback_text, 500)
            if mode == "fixed" and not text:
                continue
            actions.append({
                "type": "reply",
                "mode": mode,
                "text": text,
                "instruction": instruction or "结合当前情况，自然地回复一句",
            })
        elif kind == "poke":
            actions.append({"type": "poke", "target": "sender"})
        elif kind == "like":
            times = int(item.get("times") or like_times or 10)
            actions.append({"type": "like", "target": "sender", "times": max(1, min(20, times))})
        else:
            actions.append({"type": kind})
    if not actions and fallback_text:
        actions.append({
            "type": "reply",
            "mode": "ai",
            "text": fallback_text,
            "instruction": fallback_text,
        })
    return actions[:6]


def normalize_rule(data: dict[str, Any], base: dict[str, Any] | None = None) -> dict[str, Any]:
    merged: dict[str, Any] = dict(base or {})
    for key, value in (data or {}).items():
        if value is None:
            continue
        merged[key] = value
    trigger = normalize_trigger(merged.get("trigger"))
    like_times = int(merged.get("like_times") or 10)
    like_times = max(1, min(20, like_times))
    actions = normalize_actions(merged.get("actions"), _text(merged.get("action_text"), 500), like_times)
    name = _text(merged.get("name"), 40)
    if not name:
        name = trigger_label(trigger)
        if trigger.get("type") == "keyword" and trigger.get("keywords"):
            name = "触发词 · " + " / ".join(trigger["keywords"][:2])
    now = time.time()
    return {
        "id": _text(merged.get("id"), 40) or new_id(),
        "name": name,
        "enabled": bool(merged.get("enabled", True)),
        "trigger": trigger,
        "actions": actions,
        "action_text": _text(merged.get("action_text"), 500),
        "like_times": like_times,
        "created_at": float(merged.get("created_at") or now),
        "updated_at": now,
    }


def new_id() -> str:
    return "om_" + secrets.token_hex(4)


def validate_rule(rule: dict[str, Any]) -> str:
    trigger = rule.get("trigger") or {}
    if trigger.get("type") == "keyword" and not trigger.get("keywords"):
        return "触发词不能为空"
    if trigger.get("mode") == "regex":
        for word in trigger.get("keywords") or []:
            try:
                re.compile(word)
            except re.error as exc:
                return f"正则表达式无效：{word}（{exc}）"
    if not rule.get("actions"):
        return "至少需要一个动作"
    return ""


class OmniStore:
    """规则落盘：data/omni_action/rules.json。"""

    def __init__(self, data_dir: Path) -> None:
        self.path = Path(data_dir) / "omni_action" / "rules.json"
        self._lock = threading.Lock()

    def _load(self) -> list[dict[str, Any]]:
        if not self.path.is_file():
            return []
        try:
            data = json.loads(self.path.read_text("utf-8"))
        except (OSError, ValueError) as exc:
            log.warning("读取全能动作规则失败: %s", exc)
            return []
        items = data.get("rules") if isinstance(data, dict) else data
        return [item for item in items or [] if isinstance(item, dict)] if isinstance(items, list) else []

    def _save(self, rules: list[dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps({"rules": rules}, ensure_ascii=False, indent=2), "utf-8")
        temp.replace(self.path)

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            rules = self._load()
        return sorted(rules, key=lambda item: float(item.get("created_at") or 0))

    def get(self, rule_id: str) -> dict[str, Any] | None:
        for rule in self.list():
            if str(rule.get("id")) == str(rule_id):
                return rule
        return None

    def upsert(self, rule: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            rules = self._load()
            for index, old in enumerate(rules):
                if str(old.get("id")) == str(rule.get("id")):
                    rules[index] = rule
                    break
            else:
                rules.append(rule)
            self._save(rules)
        return rule

    def set_enabled(self, rule_id: str, enabled: bool) -> dict[str, Any] | None:
        rule = self.get(rule_id)
        if not rule:
            return None
        rule["enabled"] = bool(enabled)
        rule["updated_at"] = time.time()
        return self.upsert(rule)

    def delete(self, rule_id: str) -> bool:
        with self._lock:
            rules = self._load()
            kept = [item for item in rules if str(item.get("id")) != str(rule_id)]
            if len(kept) == len(rules):
                return False
            self._save(kept)
        return True


def extract_json(text: str) -> dict[str, Any]:
    """从模型输出里取出 JSON，兼容 ```json 围栏和前后解释。"""
    raw = str(text or "").strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw, flags=re.IGNORECASE)
    raw = re.sub(r"\s*```$", "", raw)
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("模型没有返回可解析的规则")
    data = json.loads(raw[start:end + 1])
    if not isinstance(data, dict):
        raise ValueError("模型返回的不是规则对象")
    return data


PLANNER_SYSTEM = """你在为 QQ 机器人配置「全能动作」。
用户会用白话说一个条件和一个动作，你要把它整理成固定结构的规则。

可用条件 type：
- keyword：消息包含指定触发词（必须给 keywords，1-3 个短词）
- poke：被戳一戳
- profile_like：有人给机器人名片点赞
- friend_request：收到加好友申请
- group_request：收到加群申请或邀请

可用动作 type：
- reply：回复一句，mode 用 "ai" 表示由你结合人格自由措辞，text 写动作要求
- poke：戳回触发者
- like：给触发者点赞，times 写次数（默认 10）
- approve_friend / reject_friend：同意或拒绝好友申请
- approve_group / reject_group：同意或拒绝加群申请

只输出 JSON，不要解释。格式：
{
  "name": "不超过 20 字的规则名",
  "trigger": {"type": "poke", "keywords": [], "mode": "contains", "scope": "all"},
  "like_times": 10,
  "actions": [
    {"type": "poke"},
    {"type": "reply", "mode": "ai", "text": "被戳了，有点不耐烦地回一句"}
  ]
}

要求：
1. 用户说「有人给你点赞时」→ profile_like；「有人申请加你为好友时」→ friend_request；
   说「戳你」→ poke；其余带具体句子或词语的 → keyword。
2. 用户没提点赞次数时不要瞎编，用 10。
3. 动作必须真实可实现，不要输出上述清单以外的动作。
4. 如果用户只给了动作没说条件，根据动作推断最合适的条件；推不出来就用 keyword，并把用户原话里最关键的词作为触发词。
""".strip()


async def ai_plan(bot, request_text: str = "", trigger: dict[str, Any] | None = None,
                  action_text: str = "") -> dict[str, Any]:
    """让模型把白话条件/动作整理成规则。trigger 非空表示条件由表单指定。"""
    if not getattr(bot.config.ai, "enabled", False):
        raise ValueError("AI 未启用，无法理解白话条件")
    client = bot.chat_client()
    lines: list[str] = []
    if trigger:
        lines.append(f"条件已经由用户选定：{json.dumps(trigger, ensure_ascii=False)}")
    if action_text:
        lines.append(f"用户想要的动作：{action_text}")
    if request_text:
        lines.append(f"用户的完整想法：{request_text}")
    if not lines:
        raise ValueError("请先填写想要的效果")
    text = await client.complete(
        PLANNER_SYSTEM, "\n".join(lines) + "\n请输出规则 JSON：",
        temperature=0.2, max_tokens=700,
    )
    data = extract_json(text)
    base: dict[str, Any] = {}
    if trigger:
        base["trigger"] = trigger
    if action_text:
        data.setdefault("action_text", action_text)
    rule = normalize_rule(data, base)
    problem = validate_rule(rule)
    if problem:
        raise ValueError(problem)
    return rule
