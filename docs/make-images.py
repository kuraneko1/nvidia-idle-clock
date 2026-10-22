#!/usr/bin/env python3
"""Generate the README/reference figures as mobile-app-style cards, in English and Japanese.

Every number drawn here is copied from the "Measurements" section of
docs/reference.{ja,en}.md; keep the two in sync when a measurement changes.
The visible text lives in one string table per language (TEXT below), so the
two variants share the same layout, palette and numbers. The output is
deterministic: fixed data, fixed dpi, no timestamps or randomness, then
re-encoded to RGB PNG without metadata.

Usage:
    python3 docs/make-images.py

Writes img/ja/<name>.png and img/en/<name>.png.

Requires matplotlib (3.x) + Pillow. Japanese text is drawn with Noto Sans CJK
JP loaded from an explicit file (the .ttc faces are not reliably selected by
family name); the English set keeps the family-name fonts used before.
"""

from __future__ import annotations

import sys
from functools import lru_cache
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.font_manager import FontProperties  # noqa: E402
from matplotlib.patches import Circle, FancyBboxPatch  # noqa: E402
from matplotlib.textpath import TextPath  # noqa: E402
from PIL import Image  # noqa: E402

# --------------------------------------------------------------------------
# Design tokens (shared by all four figures)
# --------------------------------------------------------------------------

DPI = 150
LATIN_SANS = "Noto Sans CJK JP"
LATIN_MONO = "DejaVu Sans Mono"

# Verified Japanese faces: matplotlib FontProperties(fname=...) renders these
# correctly on this host.
JA_SANS = {
    "normal": "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "bold": "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
}

BG = "#F4F6FA"  # page background
CARD = "#FFFFFF"  # card fill
INK = "#101828"  # primary text
MUTED = "#667085"  # secondary text
GREEN = "#12805C"  # savings / released
AMBER = "#B54708"  # cost / clamped
BLUE = "#1D4ED8"  # clock / time
LINE = "#EAECF0"  # hairlines

SHADOW_NEAR = "#E7EBF3"
SHADOW_FAR = "#EDF0F6"

GREEN_TINT = "#E7F4EE"
AMBER_TINT = "#FBEEE3"
BLUE_TINT = "#E8EDFB"

RADIUS_CARD = 22
RADIUS_ROW = 18
RADIUS_CHIP = 999  # clamped to half the height by the helper

# --------------------------------------------------------------------------
# Data table — transcribed from docs/reference.{ja,en}.md ("Measurements")
# --------------------------------------------------------------------------

# Idle A/B, 2026-10-22, driver 580.178.04, GPU board power (power.draw),
# ~31GiB/GPU held by the inference server, GPUs otherwise idle.
IDLE = {
    "saved_total_w": 26.2,  # 12.63 + 13.58 = 26.21 W across the two cards
    "gpu0": {"name": "GPU0 · V100-PCIE-32GB", "before_w": 37.8, "after_w": 25.2, "delta_w": 12.6},
    "gpu1": {"name": "GPU1 · PG500-216", "before_w": 42.4, "after_w": 28.9, "delta_w": 13.6},
    # The "combined" column of the table is the two-card mean, not the sum.
    "held": {"before_w": 40.1, "after_w": 27.0},  # 40.14 -> 27.04 W per-GPU average
    "empty": {"before_w": 27.3, "after_w": 27.2},  # 27.35 -> 27.21 W; 0.28W == noise
    "kwh_year": 229.6,
    "jpy_year": 8494,
    "jpy_per_kwh": 37,
    "measured": "2026-10-22",
    "driver": "580.178.04",
}

# Clamp ladder, PG500-216, 8GiB held, 20s per step.
LADDER = [
    {"mhz": 1260, "cmd": "no clamp", "w": 40.94},
    {"mhz": 555, "cmd": "-lgc 135,555", "w": 31.73},
    {"mhz": 300, "cmd": "-lgc 135,300", "w": 29.52},
    {"mhz": 135, "cmd": "-lgc 135,135", "w": 28.40},
]

# Throughput while clamped, PG500-216, 8GiB held, as % of the unclamped rate.
# Released / realistic-path results are within -0.49%..0% of the unclamped run.
PERF = {
    "pg500": "PG500-216",
    "vram": "8 GiB held",
    "tests": [
        {"name": "DtoD copy", "clamped_pct": 19.4},
        {"name": "memset", "clamped_pct": 12.0},
        {"name": "SGEMM 4096", "clamped_pct": 8.9},
    ],
    "released_pct": 100.0,
    "slowdown_mult": 11,  # 100 / 8.9 == 11.2 -> "up to 11x"
}

# Clamp/release cycle, PG500-216, 8GiB held (timeline run).
TIMELINE = {
    "clamped": {"mhz": 135, "w": 27.8},
    "running": {"mhz": 1260, "w": 39.5},
    "release_s": 0.5,
    "idle_s": 30.2,
}

# --------------------------------------------------------------------------
# String table — the only place the visible language lives.
# --------------------------------------------------------------------------

TEXT = {
    "en": {
        "hero": {
            "eyebrow": "measured effect · two V100-class cards",
            "saved": "saved while VRAM is held",
            "combined": "two cards, combined",
            "held": "VRAM held · per-GPU average",
            "held_chip": "SAVED",
            "empty": "VRAM empty · per-GPU average",
            "empty_chip": "NO SAVING",
            "energy": "{kwh:.1f} kWh/year  ·  ¥{jpy:,}/year @ {rate} JPY/kWh "
            "(Shizuoka example)",
            "conditions": "GPU board power · measured {measured} · driver {driver}",
        },
        "ladder": {
            "eyebrow": "clamp ladder",
            "sub": "PG500-216 · 8 GiB held · 20 s each",
            "no_clamp": "no clamp",
        },
        "perf": {
            "eyebrow": "throughput while clamped",
            "sub": "PG500-216 · 8 GiB held",
            "legend_released": "after release",
            "legend_clamped": "clamped {mhz} MHz",
            "tag_clamped": "clamped",
            "tag_released": "released",
            "callout": "up to {mult}× slower while clamped",
        },
        "timeline": {
            "eyebrow": "clamp / release cycle",
            "sub": "PG500-216 · 8 GiB held · schematic",
            "release_value": "≤ {s:.1f} s",
            "release_caption": "release after load detected",
            "idle_value": "{s:.1f} s",
            "idle_caption": "idle before re-clamp",
        },
    },
    "ja": {
        "hero": {
            "eyebrow": "実測効果 · V100 クラス 2 枚",
            "saved": "VRAM 保持中の節電",
            "combined": "2 枚合計",
            "held": "VRAM 保持中 · 1 枚あたり平均",
            "held_chip": "節電",
            "empty": "VRAM 空き · 1 枚あたり平均",
            "empty_chip": "節電なし",
            "energy": "{kwh:.1f} kWh/年  ·  ¥{jpy:,}/年 @ {rate} JPY/kWh "
            "(静岡の例)",
            "conditions": "GPU ボード電力 · 実測 {measured} · driver {driver}",
        },
        "ladder": {
            "eyebrow": "クランプ階段",
            "sub": "PG500-216 · 8 GiB 保持 · 各 20 秒",
            "no_clamp": "クランプなし",
        },
        "perf": {
            "eyebrow": "クランプ中のスループット",
            "sub": "PG500-216 · 8 GiB 保持",
            "legend_released": "解除後",
            "legend_clamped": "クランプ中 {mhz} MHz",
            "tag_clamped": "クランプ中",
            "tag_released": "解除後",
            "callout": "クランプ中は最大 {mult} 倍遅い",
        },
        "timeline": {
            "eyebrow": "クランプ / 解除サイクル",
            "sub": "PG500-216 · 8 GiB 保持 · 模式図",
            "release_value": "≤ {s:.1f} 秒",
            "release_caption": "負荷検出から解除まで",
            "idle_value": "{s:.1f} 秒",
            "idle_caption": "再クランプまでの無負荷",
        },
    },
}

LANGS = ("en", "ja")


# --------------------------------------------------------------------------
# Fonts
# --------------------------------------------------------------------------


@lru_cache(maxsize=None)
def ja_font_path(weight: str) -> str:
    path = JA_SANS.get(weight, JA_SANS["normal"])
    if not Path(path).exists():
        raise SystemExit(f"Japanese font not found: {path}")
    return path


@lru_cache(maxsize=None)
def font_prop(lang: str, weight: str = "normal", mono: bool = False, size: float = 12.0) -> FontProperties:
    """Font for *lang*. Japanese code strings stay monospace while ASCII."""
    if lang == "ja":
        if mono:
            # Monospace is only requested for ASCII technical tokens such as
            # "-lgc 135,555"; text()/text_px() keep CJK strings on the CJK face.
            return FontProperties(family=LATIN_MONO, weight=weight, size=size)
        return FontProperties(fname=ja_font_path(weight), size=size)
    family = LATIN_MONO if mono else LATIN_SANS
    return FontProperties(family=family, weight=weight, size=size)


def text_px(
    s: str, size: float, weight: str = "normal", mono: bool = False, lang: str = "en"
) -> float:
    """Rendered width of *s* in pixels at *size* points."""
    if not s:
        return 0.0
    # A CJK string never goes through the monospace face.
    prop = font_prop(lang, weight, mono and s.isascii(), size)
    return TextPath((0, 0), s, size=size, prop=prop).get_extents().width * DPI / 72.0


class Canvas:
    """A pixel-addressed canvas: y grows downwards, like a screen."""

    def __init__(self, lang: str, w: int, h: int) -> None:
        self.lang = lang
        self.w, self.h = w, h
        self.fig = plt.figure(figsize=(w / DPI, h / DPI), dpi=DPI, facecolor=BG)
        self.ax = self.fig.add_axes((0, 0, 1, 1))
        self.ax.set_xlim(0, w)
        self.ax.set_ylim(h, 0)  # invert: origin top-left
        self.ax.set_axis_off()
        self.ax.set_facecolor(BG)

    def card(self, x: float, y: float, w: float, h: float, r: float = RADIUS_CARD, fill: str = CARD) -> None:
        # Two offset layers fake a soft, low-contrast shadow.
        for dy, col in ((7, SHADOW_FAR), (3, SHADOW_NEAR)):
            self.ax.add_patch(
                FancyBboxPatch(
                    (x, y + dy),
                    w,
                    h,
                    boxstyle=f"round,pad=0,rounding_size={r}",
                    linewidth=0,
                    facecolor=col,
                    zorder=1,
                )
            )
        self.ax.add_patch(
            FancyBboxPatch(
                (x, y),
                w,
                h,
                boxstyle=f"round,pad=0,rounding_size={r}",
                linewidth=0,
                facecolor=fill,
                zorder=2,
            )
        )

    def text(
        self,
        x: float,
        y: float,
        s: str,
        size: float,
        color: str = INK,
        weight: str = "normal",
        ha: str = "left",
        va: str = "center",
        mono: bool = False,
        zorder: int = 5,
    ):
        return self.ax.text(
            x,
            y,
            s,
            fontproperties=font_prop(self.lang, weight, mono and s.isascii(), size),
            color=color,
            ha=ha,
            va=va,
            zorder=zorder,
        )

    def chip_width(self, label: str, size: float = 10.5, dot: bool = True, pad: float = 16) -> float:
        dot_w = 18 if dot else 0
        return pad * 2 + dot_w + text_px(label, size, "bold", lang=self.lang)

    def chip(
        self,
        x: float,
        y: float,
        label: str,
        color: str,
        size: float = 10.5,
        dot: bool = True,
        fill: str = CARD,
        weight: str = "bold",
        pad: float = 16,
        height: float = 30,
    ) -> float:
        """Draw a pill with an optional colour dot; returns its width."""
        dot_w = 18 if dot else 0
        w = self.chip_width(label, size, dot, pad)
        self.ax.add_patch(
            FancyBboxPatch(
                (x, y - height / 2),
                w,
                height,
                boxstyle=f"round,pad=0,rounding_size={height / 2}",
                linewidth=0,
                facecolor=fill,
                zorder=3,
            )
        )
        if dot:
            self.ax.add_patch(
                Circle((x + pad + 4, y), radius=4.5, facecolor=color, linewidth=0, zorder=4)
            )
        self.text(x + pad + dot_w, y, label, size, color, weight)
        return w

    def eyebrow(self, title: str, sub: str, y: float = 34, x: float = 40) -> None:
        self.text(x, y, title, 13, INK, "bold")
        self.text(x + text_px(title, 13, "bold", lang=self.lang) + 10, y, sub, 11.5, MUTED)

    def save(self, path: Path) -> tuple[int, int, int]:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        self.fig.savefig(
            tmp,
            format="png",
            dpi=DPI,
            facecolor=BG,
            edgecolor="none",
            metadata={"Software": None},
        )
        plt.close(self.fig)
        with Image.open(tmp) as im:
            rgb = im.convert("RGB")
            rgb.save(path, format="PNG", optimize=True, compress_level=9)
        tmp.unlink()
        with Image.open(path) as im:
            assert im.mode == "RGB", f"{path}: expected RGB, got {im.mode}"
            return im.size[0], im.size[1], path.stat().st_size


# --------------------------------------------------------------------------
# Figure 1 — hero
# --------------------------------------------------------------------------


def fig_hero(lang: str) -> Canvas:
    t = TEXT[lang]["hero"]
    c = Canvas(lang, 1500, 640)
    c.eyebrow("nvidia-idle-clock", t["eyebrow"])

    # Headline card.
    c.card(40, 58, 690, 250)
    c.text(72, 96, t["saved"], 12.5, MUTED)
    num = f"{IDLE['saved_total_w']:.1f}"
    c.text(68, 182, num, 64, GREEN, "bold")
    c.text(68 + text_px(num, 64, "bold", lang=lang) + 28, 200, "W", 30, GREEN, "bold")
    c.text(72, 266, t["combined"], 10.5, MUTED)

    # Per-GPU breakdown.
    for y, gpu in ((58, IDLE["gpu0"]), (194, IDLE["gpu1"])):
        c.card(750, y, 710, 114, RADIUS_ROW)
        c.text(782, y + 30, gpu["name"], 10.5, MUTED)
        c.text(782, y + 70, f"{gpu['before_w']:.1f} → {gpu['after_w']:.1f} W", 20, INK, "bold")
        c.text(1432, y + 70, f"-{gpu['delta_w']:.1f} W", 18, GREEN, "bold", ha="right")

    # VRAM held vs empty.
    held, empty = IDLE["held"], IDLE["empty"]
    c.card(40, 330, 700, 170)
    c.text(72, 366, t["held"], 11, MUTED)
    c.chip(712 - c.chip_width(t["held_chip"]), 366, t["held_chip"], GREEN, fill=GREEN_TINT, dot=False)
    # The after-value is green: this card is the one that saves something.
    before_s = f"{held['before_w']:.1f} W"
    after_s = f"{held['after_w']:.1f} W"
    c.text(72, 428, before_s, 24, INK, "bold")
    arrow_x = 72 + text_px(before_s, 24, "bold", lang=lang) + 14
    c.text(arrow_x, 428, "→", 24, MUTED, "bold")
    c.text(
        arrow_x + text_px("→", 24, "bold", lang=lang) + 14, 428, after_s, 24, GREEN, "bold"
    )

    c.card(760, 330, 700, 170)
    c.text(792, 366, t["empty"], 11, MUTED)
    c.chip(
        1432 - c.chip_width(t["empty_chip"]),
        366,
        t["empty_chip"],
        MUTED,
        fill="#F2F4F7",
        dot=False,
    )
    empty_s = f"{empty['before_w']:.1f} W → {empty['after_w']:.1f} W"
    c.text(792, 428, empty_s, 24, MUTED, "bold")
    c.text(792 + text_px(empty_s, 24, "bold", lang=lang) + 14, 430, "≈ 0", 17, MUTED, "bold")

    # Footer strip.
    c.card(40, 518, 1420, 86, RADIUS_ROW, fill=CARD)
    c.text(
        72,
        546,
        t["energy"].format(
            kwh=IDLE["kwh_year"], jpy=IDLE["jpy_year"], rate=IDLE["jpy_per_kwh"]
        ),
        15,
        INK,
        "bold",
    )
    c.text(
        72,
        584,
        t["conditions"].format(measured=IDLE["measured"], driver=IDLE["driver"]),
        10.5,
        MUTED,
    )
    return c


# --------------------------------------------------------------------------
# Figure 2 — clamp ladder
# --------------------------------------------------------------------------


def fig_ladder(lang: str) -> Canvas:
    t = TEXT[lang]["ladder"]
    c = Canvas(lang, 1500, 700)
    c.eyebrow(t["eyebrow"], t["sub"])

    top, row_h, gap = 70, 138, 16
    bar_x, bar_max = 520, 560
    max_w = max(r["w"] for r in LADDER)

    for i, row in enumerate(LADDER):
        y = top + i * (row_h + gap)
        c.card(40, y, 1420, row_h, RADIUS_ROW)
        c.text(72, y + 56, f"{row['mhz']}", 38, INK, "bold")
        c.text(72 + text_px(f"{row['mhz']}", 38, "bold", lang=lang) + 24, y + 72, "MHz", 15, MUTED)
        cmd = t["no_clamp"] if row["cmd"] == "no clamp" else row["cmd"]
        c.text(72, y + 100, cmd, 11, MUTED, mono=True)

        length = bar_max * row["w"] / max_w
        c.ax.add_patch(
            FancyBboxPatch(
                (bar_x, y + 56 - 9),
                length,
                18,
                boxstyle="round,pad=0,rounding_size=9",
                linewidth=0,
                facecolor=AMBER,
                zorder=3,
            )
        )
        c.text(bar_x + length + 18, y + 57, f"{row['w']:.2f} W", 17, INK, "bold")
    return c


# --------------------------------------------------------------------------
# Figure 3 — throughput while clamped
# --------------------------------------------------------------------------


def fig_perf(lang: str) -> Canvas:
    t = TEXT[lang]["perf"]
    c = Canvas(lang, 1500, 640)
    c.eyebrow(t["eyebrow"], t["sub"])

    # Legend, right aligned: clamped = amber, after release = green.
    legend = (
        (t["legend_released"], GREEN),
        (t["legend_clamped"].format(mhz=TIMELINE["clamped"]["mhz"]), AMBER),
    )
    cursor = 1460.0
    for label, color in legend:
        w = c.chip_width(label)
        cursor -= w
        c.chip(cursor, 34, label, color)
        cursor -= 10

    margin, gap = 40, 24
    card_w = (1460 - margin - 2 * gap) / 3
    base, max_bar = 470, 240

    for i, test in enumerate(PERF["tests"]):
        x = margin + i * (card_w + gap)
        center = x + card_w / 2
        c.card(x, 86, card_w, 434)
        c.text(center, 124, test["name"], 15, INK, "bold", ha="center")

        for j, (pct, color, tag) in enumerate(
            (
                (test["clamped_pct"], AMBER, t["tag_clamped"]),
                (PERF["released_pct"], GREEN, t["tag_released"]),
            )
        ):
            bx = center - 90 + j * 96
            bh = max_bar * pct / 100.0
            c.ax.add_patch(
                FancyBboxPatch(
                    (bx, base - bh),
                    84,
                    bh,
                    boxstyle="round,pad=0,rounding_size=8",
                    linewidth=0,
                    facecolor=color,
                    zorder=3,
                )
            )
            label = f"{pct:.1f} %" if j == 0 else "≈100 %"
            if j == 0:
                # Right-align the clamped label above its short bar so it cannot
                # run into the released column next to it.
                c.text(bx + 84, base - bh - 18, label, 17, color, "bold", ha="right")
            else:
                c.text(bx + 42, base - bh - 18, label, 17, color, "bold", ha="center")
            c.text(bx + 42, base + 22, tag, 9.5, MUTED, ha="center")

        c.ax.plot([x + 28, x + card_w - 28], [base, base], color=LINE, linewidth=1.5, zorder=2.5)

    # Callout.
    cw = 720
    cx = (1500 - cw) / 2
    c.card(cx, 544, cw, 64, 32, fill=AMBER_TINT)
    c.text(
        1500 / 2,
        576,
        t["callout"].format(mult=PERF["slowdown_mult"]),
        15,
        AMBER,
        "bold",
        ha="center",
    )
    return c


# --------------------------------------------------------------------------
# Figure 4 — clamp / release cycle
# --------------------------------------------------------------------------


def fig_timeline(lang: str) -> Canvas:
    t = TEXT[lang]["timeline"]
    c = Canvas(lang, 1500, 600)
    c.eyebrow(t["eyebrow"], t["sub"])

    c.card(40, 64, 1420, 400)

    x0, x_end, y_hi, y_lo, floor = 210, 1390, 170, 370, 430
    segs = (270, 26, 640, 244)  # clamped, release ramp, running, clamped again
    xs = [x0]
    for s in segs:
        xs.append(xs[-1] + s)

    # Step path: low -> ramp up at the release -> high across the idle window
    # -> back down when the daemon re-clamps.
    px = [xs[0], xs[1], xs[2], xs[3], xs[3], xs[4]]
    py = [y_lo, y_lo, y_hi, y_hi, y_lo, y_lo]
    c.ax.fill_between(px, py, floor, color=BLUE_TINT, linewidth=0, zorder=2.5)
    c.ax.plot(px, py, color=BLUE, linewidth=3.5, solid_capstyle="round", solid_joinstyle="round", zorder=3)

    # Transition markers: end of the release ramp, and the re-clamp.
    for x in (xs[2], xs[3]):
        c.ax.add_patch(Circle((x, y_hi), radius=6, facecolor=BLUE, linewidth=0, zorder=4))

    # Only the two clock levels are labelled on the axis.
    c.text(190, y_hi, f"{TIMELINE['running']['mhz']} MHz", 13, INK, "bold", ha="right")
    c.text(190, y_lo, f"{TIMELINE['clamped']['mhz']} MHz", 13, INK, "bold", ha="right")
    c.text(xs[0] + 130, y_lo - 22, f"{TIMELINE['clamped']['w']:.1f} W", 11, MUTED, ha="center")
    c.text(xs[2] + 330, y_hi - 22, f"{TIMELINE['running']['w']:.1f} W", 11, MUTED, ha="center")

    # Duration callouts.
    for x, value, caption in (
        (
            40,
            t["release_value"].format(s=TIMELINE["release_s"]),
            t["release_caption"],
        ),
        (
            770,
            t["idle_value"].format(s=TIMELINE["idle_s"]),
            t["idle_caption"],
        ),
    ):
        c.card(x, 476, 690, 92, RADIUS_ROW)
        c.text(x + 40, 522, value, 30, BLUE, "bold")
        c.text(x + 40 + text_px(value, 30, "bold", lang=lang) + 18, 522, caption, 11.5, MUTED)
    return c


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

FIGURES = (
    ("hero", fig_hero),
    ("clamp-ladder", fig_ladder),
    ("perf", fig_perf),
    ("timeline", fig_timeline),
)


def render(lang: str) -> dict[str, tuple[int, int, int]]:
    """Draw all four figures for *lang* into img/<lang>/."""
    out_dir = ROOT / "img" / lang
    sizes: dict[str, tuple[int, int, int]] = {}
    for name, fn in FIGURES:
        path = out_dir / f"{name}.png"
        sizes[f"img/{lang}/{name}.png"] = fn(lang).save(path)
        print(f"img/{lang}/{name}.png", sizes[f"img/{lang}/{name}.png"])
    return sizes


def main() -> int:
    for lang in LANGS:
        render(lang)
    return 0


ROOT = Path(__file__).resolve().parent.parent

if __name__ == "__main__":
    sys.exit(main())
