#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成桌面小组件预览图 ic_launcher_widget_preview.png。

背景（批次19）：小组件 provider 的 android:previewImage 原先指向
@mipmap/ic_launcher——API 26+ 上该资源解析为 adaptive-icon XML
（mipmap-anydpi-v26/ic_launcher.xml），部分启动器渲染小组件预览时会崩。
修复：改指向一张静态 PNG 预览图（本脚本产物），白底 + 黑音符，与 legacy
xxxhdpi 图标同款配方（不透明白底 + 纯黑音符墨），但音符取自高清母材
mipmap-nodpi/ic_launcher.webp，缩放到画布 ~60% 并居中——legacy 图标音符包围盒约占画布 45%×48%，
webp 母材原生占 72%×76%（为自适应图标的系统遮罩/缩放预留），60% 介于
两者之间，小尺寸预览下清晰且不顶边。

产物：android/app/src/main/res/drawable-nodpi/ic_launcher_widget_preview.png
依赖：Pillow（venv 已装）。可重复执行，结果确定。
"""

from pathlib import Path

from PIL import Image

# 画布边长（与 legacy xxxhdpi ic_launcher.png 一致）
CANVAS_SIZE = 192
# 音符包围盒最大边占画布的比例（~60%）
NOTE_SIZE_RATIO = 0.60
# 母材：高清透明底黑音符（512×512，纯黑墨、透明底）
SOURCE_REL = "android/app/src/main/res/mipmap-nodpi/ic_launcher.webp"
# 产物：白底黑音符预览图
OUTPUT_REL = (
    "android/app/src/main/res/drawable-nodpi/ic_launcher_widget_preview.png"
)
# 音符墨色（与 legacy/webp/adaptive_fg 一致：纯黑）
INK_RGB = (0, 0, 0)
# 底色（不透明白）
BG_RGBA = (255, 255, 255, 255)
# 包围盒判定阈值：alpha 低于该值视为抗锯齿尘点，不计入音符区域
ALPHA_THRESHOLD = 8


def build_note_layer(source_path: Path) -> Image.Image:
    """从母材提取音符图层：纯黑 RGB + 母材 alpha 作为蒙版，裁剪到包围盒。"""
    src = Image.open(source_path).convert("RGBA")
    alpha = src.getchannel("A")
    # 阈值化后取包围盒，排除透明尘点
    mask = alpha.point(lambda v: 255 if v > ALPHA_THRESHOLD else 0)
    bbox = mask.getbbox()
    if bbox is None:
        raise RuntimeError(f"母材中未找到音符像素: {source_path}")
    mask = mask.crop(bbox)
    # 黑 RGB（三通道全 0）+ 音符 alpha，得到干净的音符图层
    black = Image.new("L", mask.size, INK_RGB[0])
    return Image.merge("RGBA", (black, black, black, mask))


def compose_preview(note: Image.Image, canvas_size: int, ratio: float) -> Image.Image:
    """把音符图层缩放到画布 ~ratio（按包围盒最大边）并居中合成到白底画布。"""
    target = int(round(canvas_size * ratio))
    scale = target / max(note.size)
    new_size = (
        max(1, round(note.width * scale)),
        max(1, round(note.height * scale)),
    )
    note = note.resize(new_size, Image.LANCZOS)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), BG_RGBA)
    offset = ((canvas_size - new_size[0]) // 2, (canvas_size - new_size[1]) // 2)
    # paste 以音符自身为蒙版，alpha=255 处完全覆盖为黑，其余保持白底
    canvas.paste(note, offset, note)
    # 强制全不透明：部分启动器对 previewImage 的 alpha 处理怪异（预览发灰/
    # 透明底），白底黑音符的纯色图不应带任何半透明边缘像素
    canvas.putalpha(255)
    return canvas


def verify(output_path: Path, canvas_size: int) -> None:
    """落盘后复核：尺寸、四角不透明白、音符墨色占比与居中情况。"""
    im = Image.open(output_path).convert("RGBA")
    assert im.size == (canvas_size, canvas_size), f"尺寸异常: {im.size}"
    px = im.load()
    for xy in ((0, 0), (canvas_size - 1, 0), (0, canvas_size - 1),
               (canvas_size - 1, canvas_size - 1)):
        assert px[xy] == BG_RGBA, f"角落非不透明白: {xy} -> {px[xy]}"
    xs: list[int] = []
    ys: list[int] = []
    ink = 0
    for y in range(canvas_size):
        for x in range(canvas_size):
            r, g, b, a = px[x, y]
            assert a == 255, f"存在非不透明像素: ({x},{y}) a={a}"
            if r < 128 and g < 128 and b < 128:
                ink += 1
                xs.append(x)
                ys.append(y)
    bw = max(xs) - min(xs) + 1
    bh = max(ys) - min(ys) + 1
    cx = (min(xs) + max(xs)) / 2
    cy = (min(ys) + max(ys)) / 2
    print(f"[verify] 尺寸 {im.size[0]}x{im.size[1]}，四角不透明白，全图不透明")
    print(
        f"[verify] 音符包围盒 {bw}x{bh}（宽占 {bw / canvas_size:.0%} / "
        f"高占 {bh / canvas_size:.0%}），中心 ({cx:.1f}, {cy:.1f})，"
        f"画布中心 ({canvas_size / 2}, {canvas_size / 2})，"
        f"墨色占比 {ink / (canvas_size * canvas_size):.1%}"
    )


def main() -> None:
    # 脚本位于 <repo>/android/tools/，仓库根为其上两级
    repo_root = Path(__file__).resolve().parents[2]
    source_path = repo_root / SOURCE_REL
    output_path = repo_root / OUTPUT_REL
    output_path.parent.mkdir(parents=True, exist_ok=True)

    note = build_note_layer(source_path)
    preview = compose_preview(note, CANVAS_SIZE, NOTE_SIZE_RATIO)
    preview.save(output_path, format="PNG")
    print(f"[gen] 已生成 {output_path}")
    verify(output_path, CANVAS_SIZE)


if __name__ == "__main__":
    main()
