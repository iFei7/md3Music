#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""md3Music 桌面图标生成脚本（Sonify 配方）。

背景：仓库原先只有 mipmap-nodpi/ic_launcher.webp（512x512 RGBA、黑色八分音符、
全透明底），不同设备/启动器拿到的图标大小不一致。本脚本按 Sonify 参考仓库的
配方补齐自适应图标与 legacy 五档位图，使 API 26+ 走 adaptive-icon、
API 24/25 走固定密度 PNG，解决「不同设备桌面图标大小不一样」。

产出（全部写入 android/app/src/main/res/）：
  1. drawable-nodpi/ic_launcher_adaptive_fg.png   432x432 RGBA 透明底，黑音符
  2. drawable-nodpi/ic_launcher_adaptive_back.png 432x432 RGB  纯色品牌红满幅
  3. mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png       48/72/96/144/192
     满幅方形、红底黑音符、四角不透明、不烘焙圆角
  4. mipmap-{dpi}/ic_launcher_round.png           同设计 + 烘焙满内切圆（圆外 alpha=0）
  5. mipmap-nodpi/ic_launcher.webp 保留不动（兜底）

设计口径：
  - 品牌红 #F54047，与 lib/core/theme/app_theme.dart 的 defaultSeedColor 一致；
    背景禁用渐变，保证任意 launcher mask 下无接缝。
  - 音符 ink 外接圆直径：
      * adaptive fg = 264px（半径 132px，即安全区 66dp @432px/108dp，贴边不越界）
      * legacy     = 画布边长 62%（视觉重量与 adaptive 接近）
  - 缩放统一 LANCZOS；合成后用源 alpha 作 mask，保留抗锯齿边缘。

用法（在仓库任意目录执行均可，路径基于本文件位置推导）：
    python scripts/tools/gen_launcher_icons.py

依赖：pillow（隔离 venv：~/.workbuddy/binaries/python/envs/default）。
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw

# ---------------------------------------------------------------- 常量配置

#: 品牌主色（sonify 红），与 app_theme.dart defaultSeedColor 保持一致
BRAND_RED = (0xF5, 0x40, 0x47)

#: adaptive-icon 画布尺寸：108dp x 4（xxxhdpi 基准）
ADAPTIVE_SIZE = 432

#: adaptive fg 中音符 ink 外接圆直径；264/2=132px 正好等于安全区半径 66dp
ADAPTIVE_INK_DIAMETER = 264

#: legacy 图标中音符 ink 外接圆直径占画布边长的比例
LEGACY_INK_RATIO = 0.62

#: legacy 五档密度与边长（mdpi=48 起，每档 1.5 倍）
LEGACY_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

#: 本文件位于 <repo>/scripts/tools/，回溯两级即仓库根
REPO_ROOT = Path(__file__).resolve().parents[2]
RES_DIR = REPO_ROOT / "android" / "app" / "src" / "main" / "res"

#: 源图：512x512 RGBA webp，黑色八分音符 + 全透明底（保留作兜底，不删不改）
SRC_WEBP = RES_DIR / "mipmap-nodpi" / "ic_launcher.webp"


# ---------------------------------------------------------------- 基础工具

def load_source_note():
    """读取源 webp，裁出 alpha 非透明 bbox，返回 (crop, ink_radius)。

    crop        : RGBA 图，内容仅为音符 ink（bbox 已对齐到左上角）
    ink_radius  : 以 crop 中心为圆心、覆盖全部 ink 像素的外接圆半径（px）
    """
    src = Image.open(SRC_WEBP).convert("RGBA")
    bbox = src.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError(f"源图全透明，无法裁出 ink：{SRC_WEBP}")
    crop = src.crop(bbox)
    print(f"[源] {SRC_WEBP.relative_to(REPO_ROOT).as_posix()} "
          f"{src.size} {src.mode} alpha-bbox={bbox}")

    # 用 numpy 求 ink 像素到 crop 中心的实际最大距离（不是 bbox 外接圆，
    # 音符四角是空的，按真实 ink 外接圆缩放才能既顶满安全区又不越界）
    alpha = np.asarray(crop.getchannel("A"))
    h, w = alpha.shape
    cy, cx = (h - 1) / 2.0, (w - 1) / 2.0
    ys, xs = np.nonzero(alpha > 0)
    if len(xs) == 0:
        raise RuntimeError("裁出的 bbox 内没有不透明像素")
    r_max = float(np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max())
    print(f"[源] ink 实际外接圆半径 r_max={r_max:.2f}px（bbox {w}x{h}）")
    return crop, r_max


def _measure_ink_radius(img):
    """测 img 中 ink（alpha>0）相对自身 bbox 几何中心的最大半径。"""
    alpha = np.asarray(img.getchannel("A"))
    h, w = alpha.shape
    cy, cx = (h - 1) / 2.0, (w - 1) / 2.0
    ys, xs = np.nonzero(alpha > 0)
    if len(xs) == 0:
        raise RuntimeError("图中没有不透明像素")
    return float(np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max())


def scale_note_to_diameter(crop, r_max, ink_diameter):
    """把 crop 中的音符等比缩放到 ink 外接圆 = ink_diameter，返回 RGBA 图。

    LANCZOS 的抗锯齿边缘会让缩放后 ink 外接半径比重采样前膨胀零点几 px，
    因此缩放后实测一次半径，若越过目标则按比例再缩一轮反馈校正，
    保证 fg 严格落在安全区（半径 132px）内。
    """
    scale = ink_diameter / (2.0 * r_max)
    w, h = crop.size
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    note = crop.resize((nw, nh), Image.LANCZOS)

    target_r = ink_diameter / 2.0
    r_actual = _measure_ink_radius(note)
    if r_actual > target_r:
        fix = target_r / r_actual
        note = note.resize((max(1, round(nw * fix)), max(1, round(nh * fix))),
                           Image.LANCZOS)
    return note


def paste_center(canvas, note):
    """把 note 的中心对准 canvas 中心，用 note 自身 alpha 作 mask 合成。"""
    cw, ch = canvas.size
    nw, nh = note.size
    ox, oy = round((cw - nw) / 2), round((ch - nh) / 2)
    canvas.paste(note, (ox, oy), note)


# ---------------------------------------------------------------- 各产物构建

def build_adaptive_fg(crop, r_max):
    """432x432 RGBA 透明底：音符 ink 外接圆 264px，中心对准 (216,216)。"""
    note = scale_note_to_diameter(crop, r_max, ADAPTIVE_INK_DIAMETER)
    fg = Image.new("RGBA", (ADAPTIVE_SIZE, ADAPTIVE_SIZE), (0, 0, 0, 0))
    paste_center(fg, note)
    return fg


def build_adaptive_back():
    """432x432 RGB 不透明：品牌红满幅（纯色无渐变，任意 mask 无接缝）。"""
    return Image.new("RGB", (ADAPTIVE_SIZE, ADAPTIVE_SIZE), BRAND_RED)


def build_legacy_square(crop, r_max, size):
    """满幅方形 legacy 图标：红底 + 黑音符（ink 直径 = 画布 62%），不烘焙圆角。"""
    note = scale_note_to_diameter(crop, r_max, size * LEGACY_INK_RATIO)
    canvas = Image.new("RGBA", (size, size), BRAND_RED + (255,))
    paste_center(canvas, note)
    # 音符之外全部不透明（四角必为红底），转 RGB 丢弃 alpha 通道
    return canvas.convert("RGB")


def build_legacy_round(crop, r_max, size):
    """legacy 圆形图标：同方形设计，再叠加满内切圆 mask（圆外 alpha=0）。"""
    canvas = build_legacy_square(crop, r_max, size).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    # 新 alpha = min(原 alpha, 圆 mask)：圆内保留抗锯齿，圆外强制全透
    canvas.putalpha(ImageChops.darker(canvas.getchannel("A"), mask))
    return canvas


# ---------------------------------------------------------------- 校验

def verify_and_report(records):
    """对每张产出重新读回校验尺寸/模式，打印表格，任一失败即抛错。"""
    print("\n[校验] 重新读回产出文件：")
    print(f"{'文件':<58}{'期望':<12}{'实际':<12}{'模式':<8}结果")
    ok = True
    for rel, (w, h), mode in records:
        p = REPO_ROOT / rel
        with Image.open(p) as im:
            got = f"{im.width}x{im.height}"
            size_ok = (im.width, im.height) == (w, h)
            mode_ok = im.mode == mode
        passed = size_ok and mode_ok
        ok = ok and passed
        flag = "PASS" if passed else "FAIL"
        if not size_ok:
            flag += f"(尺寸应为 {w}x{h})"
        if not mode_ok:
            flag += f"(模式应为 {mode})"
        print(f"{rel:<58}{f'{w}x{h}':<12}{got:<12}{mode:<8}{flag}")
    if not ok:
        raise RuntimeError("存在校验失败的产出，请检查上方表格")
    print("[校验] 全部通过")


def main():
    # 目标目录（drawable-nodpi / mipmap 五档）尚不存在，先统一建好
    target_dirs = [RES_DIR / "drawable-nodpi"]
    target_dirs += [RES_DIR / f"mipmap-{dpi}" for dpi in LEGACY_SIZES]
    for d in target_dirs:
        d.mkdir(parents=True, exist_ok=True)

    crop, r_max = load_source_note()
    records = []  # (相对路径, (宽, 高), 模式)

    # 1) adaptive 前景/背景（drawable-nodpi）
    fg = build_adaptive_fg(crop, r_max)
    back = build_adaptive_back()
    fg_rel = "android/app/src/main/res/drawable-nodpi/ic_launcher_adaptive_fg.png"
    back_rel = "android/app/src/main/res/drawable-nodpi/ic_launcher_adaptive_back.png"
    fg.save(REPO_ROOT / fg_rel)
    back.save(REPO_ROOT / back_rel)
    records.append((fg_rel, fg.size, fg.mode))
    records.append((back_rel, back.size, back.mode))

    # 2) legacy 五档（方形满幅 + 圆形烘焙）
    for dpi, size in LEGACY_SIZES.items():
        square = build_legacy_square(crop, r_max, size)
        round_icon = build_legacy_round(crop, r_max, size)
        sq_rel = f"android/app/src/main/res/mipmap-{dpi}/ic_launcher.png"
        rd_rel = f"android/app/src/main/res/mipmap-{dpi}/ic_launcher_round.png"
        square.save(REPO_ROOT / sq_rel)
        round_icon.save(REPO_ROOT / rd_rel)
        records.append((sq_rel, square.size, square.mode))
        records.append((rd_rel, round_icon.size, round_icon.mode))

    verify_and_report(records)
    print(f"\n[完成] 共生成 {len(records)} 个文件；"
          f"mipmap-nodpi/ic_launcher.webp 与 drawable/ic_launcher_monochrome.png 未改动。")


if __name__ == "__main__":
    main()
