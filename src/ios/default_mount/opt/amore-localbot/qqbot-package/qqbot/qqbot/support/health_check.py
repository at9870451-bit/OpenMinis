"""输出健康检查：识别乱码/幻觉垃圾输出，避免发到群里。

特征：回复中混入大量多语言脚本（韩文/阿拉伯文/俄文/日文/西里尔）或
「token/FileInputStream/ObjectMapper」等代码噪声，且中文字符占比过低
→ 判定为模型幻觉乱码 → 整条丢弃（上层跳过不发送）。
"""
import re

_SCRIPT_RE = re.compile(
    r"[\uac00-\ud7af\u0600-\u06ff\u0400-\u04ff\u3040-\u30ff"
    r"\uac00-\ud7af\U0001F300-\U0001FAFF]"
)
_CODE_NOISE = re.compile(r"(FileInputStream|ObjectMapper|tokenizer|CURLOPT|RoundedRectangle|instanceof|regularizer|Boot|gadgets)")


def looks_garbled(text: str) -> bool:
    """true = 疑似乱码/幻觉输出，应丢弃。"""
    t = (text or "").strip()
    if not t:
        return False
    if len(t) < 12:
        return False  # 短文本不做判断，避免误杀
    cjk = sum(1 for ch in t if "\u4e00" <= ch <= "\u9fff")
    ratio = cjk / len(t)
    # 中文占比过低（<40%）且含多语言脚本/代码噪声 → 乱码
    scripts = len(_SCRIPT_RE.findall(t))
    if ratio < 0.4 and scripts >= 3:
        return True
    if ratio < 0.3 and _CODE_NOISE.search(t):
        return True
    return False