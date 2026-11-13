"""托盘图标绘制。"""

from __future__ import annotations

from typing import Any

ACCENT = (91, 140, 255, 255)
INK = (13, 20, 40, 255)
GLOW = (34, 211, 238, 255)


def make_icon_image(size: int = 64) -> Any:
    from PIL import Image, ImageDraw

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    pad = max(2, size // 16)
    draw.rounded_rectangle([pad, pad, size - pad, size - pad], radius=size // 5, fill=ACCENT)

    # 天线
    line_w = max(2, size // 24)
    draw.line([size * 0.5, size * 0.32, size * 0.5, size * 0.16], fill=ACCENT, width=line_w)
    r_ant = size * 0.055
    draw.ellipse(
        [size * 0.5 - r_ant, size * 0.16 - r_ant, size * 0.5 + r_ant, size * 0.16 + r_ant],
        fill=GLOW,
    )

    # 面板
    draw.rounded_rectangle(
        [size * 0.20, size * 0.30, size * 0.80, size * 0.70], radius=size // 8, fill=INK
    )

    # 眼睛
    r_eye = size * 0.07
    for cx in (size * 0.37, size * 0.63):
        draw.ellipse(
            [cx - r_eye, size * 0.44 - r_eye, cx + r_eye, size * 0.44 + r_eye], fill=GLOW
        )

    return img