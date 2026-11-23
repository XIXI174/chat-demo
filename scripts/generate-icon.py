#!/usr/bin/env python3
"""Generate the 1024x1024 app icon for ChatDemo.

The icon is a DeepSeek-blue gradient with a white whale mark. Everything is
drawn at 4x and downsampled, so the edges stay clean without any SVG tooling.

    python scripts/generate-icon.py
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SUPERSAMPLE = 4
CANVAS = SIZE * SUPERSAMPLE

TOP_COLOR = (77, 107, 254)
BOTTOM_COLOR = (37, 49, 172)
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / (
    "ios/ChatDemo/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
)


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def draw_background(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        # 轻微 gamma，让亮部铺得更开一点，避免整张图看着发闷。
        eased = t**0.85
        color = (
            lerp(TOP_COLOR[0], BOTTOM_COLOR[0], eased),
            lerp(TOP_COLOR[1], BOTTOM_COLOR[1], eased),
            lerp(TOP_COLOR[2], BOTTOM_COLOR[2], eased),
        )
        draw.line([(0, y), (CANVAS, y)], fill=color)


def build_whale_mask() -> Image.Image:
    """Whale body pointing right, built from a body and a V-shaped fluke."""
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw = ImageDraw.Draw(mask)
    unit = CANVAS / 1024

    def box(cx: float, cy: float, rx: float, ry: float) -> list[float]:
        return [
            (cx - rx) * unit,
            (cy - ry) * unit,
            (cx + rx) * unit,
            (cy + ry) * unit,
        ]

    # 身体：横向拉长的椭圆。
    draw.ellipse(box(455, 545, 265, 155), fill=255)

    # 背鳍：根部埋在身体里，只露出一个圆钝的弧顶。
    draw.polygon(
        [
            (486 * unit, 492 * unit),
            (566 * unit, 356 * unit),
            (648 * unit, 470 * unit),
        ],
        fill=255,
    )

    # 胸鳍：身体下前方探出的一片，同样把根部藏进身体。
    draw.polygon(
        [
            (528 * unit, 706 * unit),
            (616 * unit, 792 * unit),
            (712 * unit, 686 * unit),
        ],
        fill=255,
    )

    # 尾鳍：从身体右端分叉出去的两片三角。
    tail = (716, 545)
    draw.polygon(
        [
            (tail[0] * unit, (tail[1] - 34) * unit),
            (888 * unit, 372 * unit),
            (866 * unit, 516 * unit),
        ],
        fill=255,
    )
    draw.polygon(
        [
            (tail[0] * unit, (tail[1] + 34) * unit),
            (866 * unit, 574 * unit),
            (888 * unit, 718 * unit),
        ],
        fill=255,
    )

    # 三角鳍的尖角太生硬，先模糊再阈值化，把角磨圆（等价于给多边形做圆角）。
    mask = mask.filter(ImageFilter.GaussianBlur(radius=13 * unit))
    mask = mask.point(lambda value: 255 if value >= 128 else 0)

    return mask


def main() -> None:
    image = Image.new("RGB", (CANVAS, CANVAS), TOP_COLOR)
    draw_background(image)

    mask = build_whale_mask()
    # 整体轻微倾斜，鲸鱼往右上游。
    mask = mask.rotate(-7, resample=Image.BICUBIC, center=(512 * SUPERSAMPLE,) * 2)
    image.paste((255, 255, 255), mask=mask)

    # 眼睛：先用身体色画在白色上，再点一个更亮的圆点当高光。
    draw = ImageDraw.Draw(image)
    unit = CANVAS / 1024
    eye_center = (642 * unit, 500 * unit)
    radius = 23 * unit
    draw.ellipse(
        [
            eye_center[0] - radius,
            eye_center[1] - radius,
            eye_center[0] + radius,
            eye_center[1] + radius,
        ],
        fill=(46, 60, 190),
    )
    highlight = 7 * unit
    draw.ellipse(
        [
            eye_center[0] - highlight,
            eye_center[1] - highlight,
            eye_center[0] + highlight,
            eye_center[1] + highlight,
        ],
        fill=(255, 255, 255),
    )

    icon = image.resize((SIZE, SIZE), Image.LANCZOS)
    # App Store 图标必须是纯 RGB，不能带 alpha。
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon.convert("RGB").save(OUTPUT, format="PNG", optimize=True)
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()