"""补丁：修复 AI 回复时 @ 自己 / 喊自己名字（菲比）的问题。

QQ 场景：群里 @菲比 / @1780685132 触发机器人，模型有时会把触发语原样带进
回复（「好的 @菲比」「@1780685132 马上来」）——等于机器人艾特自己。
修复：发送前剥掉所有 @自己 的片段（开头/中间都处理），以及开头的「菲比：」自称前缀。
"""

import re

SELF_NAMES = ("菲比",)

def strip_self_ref(text: str, self_id: str | int | None) -> str:
    """剥离回复中的自指片段：@自己QQ / @自己昵称（任意位置）+ 开头「菲比：」"""
    t = (text or "").strip()
    if not t:
        return t
    sid = str(self_id or "")

    # 1) 所有 @自己QQ 号（@1780685132 → 空）
    if sid:
        t = re.sub(rf"@\s*{sid}\s*", "", t)
        # 清理可能留下的连续空格
        t = re.sub(r"\s{2,}", " ", t)

    # 2) 所有 @自己昵称（@菲比 → 空）
    for nm in SELF_NAMES:
        t = re.sub(rf"@\s*{nm}\s*", "", t)
    t = re.sub(r"\s{2,}", " ", t)

    # 3) 开头「菲比：」「菲比，」自称前缀
    for nm in SELF_NAMES:
        t = re.sub(rf"^{nm}\s*[:：，,]\s*", "", t)

    return t.strip()


def strip_all_self_names(text: str) -> str:
    """把所有自称名字片段（菲比）也去掉——用于不需要报名字的场景。"""
    t = (text or "").strip()
    if not t:
        return t
    for nm in SELF_NAMES:
        t = re.sub(rf"@{nm}\s*", "", t)
    return t.strip()