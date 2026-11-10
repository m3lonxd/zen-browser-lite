#!/usr/bin/env python3
"""Render the README banner and memory chart from bench/results.json.

Every number in the pictures comes from the benchmark file, so the README can never
show a figure that was not measured. Run after bench/measure.py:

    python3 tools/render_assets.py [bench/results.json] [docs/assets]
"""

from __future__ import annotations

import json
import sys
from html import escape
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

FONT_SANS = "Inter, -apple-system, 'SF Pro Display', 'Segoe UI', Roboto, sans-serif"
FONT_MONO = "'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace"
MINT = "#3ddc84"
TEAL = "#2fd3c4"
VARIANT_STYLE = {
    "stock": ("Zen (stock)", "#6b7a74"),
    "lite": ("NexLite lite", TEAL),
    "max": ("NexLite max", MINT),
}


def saving(stock: float, value: float) -> int:
    return round((1 - value / stock) * 100) if stock else 0


def fmt_mb(mb: float) -> str:
    return f"{mb / 1024:.2f} GB" if mb >= 1024 else f"{mb:.0f} MB"


def render_chart(res: dict) -> str:
    s = res["summary"]
    variants = [v for v in ("stock", "lite", "max") if v in s]
    groups = [("loaded_mb", "All tabs loaded", "90 s after start"),
              ("idle_mb", "Background tabs idle", "after the unload timer")]
    peak = max(s[v][k] for v in variants for k, _, _ in groups)
    width, left, right = 960, 210, 150
    bar_w = width - left - right
    bar_h, gap, group_gap = 30, 12, 44
    top = 130
    rows = []
    y = top
    delay = 0.0
    for key, title, sub in groups:
        rows.append(
            f'<text x="40" y="{y + 4}" class="h">{escape(title)}</text>'
            f'<text x="40" y="{y + 24}" class="sub">{escape(sub)}</text>'
        )
        y += 40
        for v in variants:
            label, color = VARIANT_STYLE[v]
            value = s[v][key]
            w = max(4, bar_w * value / peak)
            procs = s[v][key.replace("_mb", "_processes")]
            tag = ""
            if v != "stock":
                pct = saving(s["stock"][key], value)
                tag = (f'<text x="{left + w + 14}" y="{y + 20}" class="pct" '
                       f'style="animation-delay:{delay + 0.5:.2f}s">-{pct}%</text>')
            rows.append(
                f'<text x="40" y="{y + 20}" class="lbl">{escape(label)}</text>'
                f'<rect x="{left}" y="{y}" width="{bar_w}" height="{bar_h}" rx="8" class="track"/>'
                f'<rect x="{left}" y="{y}" width="{w:.1f}" height="{bar_h}" rx="8" fill="{color}" '
                f'class="bar" style="animation-delay:{delay:.2f}s"/>'
                f'<text x="{left + 12}" y="{y + 20}" class="val" style="animation-delay:{delay + 0.3:.2f}s">'
                f'{fmt_mb(value)} <tspan class="procs">· {procs:g} processes</tspan></text>'
                + tag
            )
            y += bar_h + gap
            delay += 0.12
        y += group_gap - gap
    height = y + 40
    m = res["method"]
    foot = (f'Zen {escape(res["zen_version"])} · {len(m["sites"])} real sites · '
            f'PSS + SwapPss, median of {m["rounds"]} runs · {escape(res["date"])}')
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="Memory use: Zen compared with NexLite">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b1412"/><stop offset="1" stop-color="#070c0b"/>
    </linearGradient>
    <style>
      .h {{ font: 700 19px {FONT_SANS}; fill: #f2fff8; }}
      .sub {{ font: 400 13px {FONT_SANS}; fill: #7f948b; }}
      .t {{ font: 800 26px {FONT_SANS}; fill: #f2fff8; letter-spacing: -0.5px; }}
      .lbl {{ font: 500 14px {FONT_SANS}; fill: #c9d8d1; }}
      .val {{ font: 600 13px {FONT_MONO}; fill: #06110d; opacity: 0; animation: fade .5s ease-out forwards; }}
      .procs {{ font-weight: 400; }}
      .pct {{ font: 700 15px {FONT_MONO}; fill: {MINT}; opacity: 0; animation: fade .5s ease-out forwards; }}
      .foot {{ font: 400 12px {FONT_MONO}; fill: #63766e; }}
      .track {{ fill: #ffffff; fill-opacity: .045; }}
      .bar {{ transform-box: fill-box; transform-origin: left center; transform: scaleX(0);
              animation: grow 1.1s cubic-bezier(.2,.8,.2,1) forwards; }}
      @keyframes grow {{ to {{ transform: scaleX(1); }} }}
      @keyframes fade {{ to {{ opacity: 1; }} }}
      @media (prefers-reduced-motion: reduce) {{
        .bar {{ animation: none; transform: none; }} .val, .pct {{ animation: none; opacity: 1; }}
      }}
    </style>
  </defs>
  <rect width="{width}" height="{height}" rx="22" fill="url(#bg)"/>
  <rect x=".5" y=".5" width="{width - 1}" height="{height - 1}" rx="21.5" fill="none" stroke="#fff" stroke-opacity=".1"/>
  <text x="40" y="62" class="t">Memory use, same tabs</text>
  <text x="40" y="86" class="sub">Lower is better. All browser processes counted, shared memory split fairly.</text>
  {''.join(rows)}
  <text x="40" y="{height - 24}" class="foot">{foot}</text>
</svg>
"""


def render_banner(res: dict) -> str:
    s = res["summary"]
    stock_idle = s["stock"]["idle_mb"]
    lite_idle = s["lite"]["idle_mb"]
    pct = saving(stock_idle, lite_idle)
    # Tab pills: the first stays active, the others go to sleep one after another.
    tabs = ["wikipedia.org", "github.com", "youtube.com", "bbc.com", "mdn", "news.ycombinator"]
    pills = []
    for i, name in enumerate(tabs):
        y = 34 + i * 36
        cls = "pill active" if i == 0 else f"pill p{i}"
        pills.append(
            f'<g class="{cls}" transform="translate(760 {y})">'
            f'<rect width="300" height="30" rx="10" class="pbg"/>'
            f'<circle cx="18" cy="15" r="5" class="dot"/>'
            f'<text x="34" y="20" class="ptxt">{escape(name)}</text>'
            f'<text x="286" y="20" text-anchor="end" class="zz">sleeping</text></g>'
        )
    sleep_rules = "\n".join(
        f"      .p{i} .pbg, .p{i} .dot, .p{i} .ptxt {{ animation-delay: {0.6 + i * 0.55:.2f}s; }}\n"
        f"      .p{i} .zz {{ animation-delay: {0.6 + i * 0.55:.2f}s; }}"
        for i in range(1, len(tabs))
    )
    meter_full = 300
    ratio = max(0.04, lite_idle / stock_idle)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="320" viewBox="0 0 1200 320" role="img" aria-label="NexLite: Zen Browser using {pct}% less memory once background tabs are idle">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0a1513"/><stop offset="1" stop-color="#060a09"/>
    </linearGradient>
    <radialGradient id="glow" cx=".5" cy=".5" r=".5">
      <stop offset="0" stop-color="{MINT}" stop-opacity=".38"/><stop offset="1" stop-color="{MINT}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow2" cx=".5" cy=".5" r=".5">
      <stop offset="0" stop-color="{TEAL}" stop-opacity=".28"/><stop offset="1" stop-color="{TEAL}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="ink" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ffffff"/><stop offset=".55" stop-color="#d8ffec"/><stop offset="1" stop-color="{MINT}"/>
    </linearGradient>
    <linearGradient id="vane" x1=".2" y1="1" x2=".85" y2="0">
      <stop offset="0" stop-color="{TEAL}"/><stop offset="1" stop-color="#a6f7c8"/>
    </linearGradient>
    <linearGradient id="meter" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{TEAL}"/><stop offset="1" stop-color="{MINT}"/>
    </linearGradient>
    <pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse">
      <path d="M32 0H0V32" fill="none" stroke="#fff" stroke-opacity=".035"/>
    </pattern>
    <clipPath id="card"><rect width="1200" height="320" rx="24"/></clipPath>
    <style>
      .orb {{ animation: drift 16s ease-in-out infinite alternate; }}
      .orb2 {{ animation: drift2 20s ease-in-out infinite alternate; }}
      .ptxt {{ font: 500 14px {FONT_MONO}; fill: #e6fff3; }}
      .zz {{ font: 500 11px {FONT_MONO}; fill: #6d827a; opacity: 0; }}
      .pbg {{ fill: #fff; fill-opacity: .08; stroke: #fff; stroke-opacity: .16; }}
      .dot {{ fill: {MINT}; }}
      .active .pbg {{ fill: {MINT}; fill-opacity: .16; stroke: {MINT}; stroke-opacity: .6; }}
      .pill:not(.active) .pbg {{ animation: pbg 9s ease-in-out infinite; }}
      .pill:not(.active) .dot {{ animation: dot 9s ease-in-out infinite; }}
      .pill:not(.active) .ptxt {{ animation: ptxt 9s ease-in-out infinite; }}
      .pill:not(.active) .zz {{ animation: zz 9s ease-in-out infinite; }}
{sleep_rules}
      .bar {{ transform-box: fill-box; transform-origin: left center; animation: meter 9s ease-in-out infinite; }}
      .num {{ font: 700 15px {FONT_MONO}; fill: #e6fff3; }}
      .cap {{ font: 500 12px {FONT_MONO}; fill: #7f948b; letter-spacing: 1px; }}
      .chip {{ font: 500 14px {FONT_MONO}; fill: #eafff4; }}
      @keyframes drift {{ from {{ transform: translate(0,0); }} to {{ transform: translate(120px,24px); }} }}
      @keyframes drift2 {{ from {{ transform: translate(0,0); }} to {{ transform: translate(-140px,-16px); }} }}
      @keyframes pbg {{ 0%,8% {{ fill-opacity: .08; stroke-opacity: .16; }} 22%,85% {{ fill-opacity: .015; stroke-opacity: .07; }} 100% {{ fill-opacity: .08; stroke-opacity: .16; }} }}
      @keyframes dot {{ 0%,8% {{ fill: {MINT}; }} 22%,85% {{ fill: #34423d; }} 100% {{ fill: {MINT}; }} }}
      @keyframes ptxt {{ 0%,8% {{ fill: #e6fff3; }} 22%,85% {{ fill: #5d6f68; }} 100% {{ fill: #e6fff3; }} }}
      @keyframes zz {{ 0%,8% {{ opacity: 0; }} 22%,85% {{ opacity: 1; }} 100% {{ opacity: 0; }} }}
      @keyframes meter {{ 0%,12% {{ transform: scaleX(1); }} 55%,85% {{ transform: scaleX({ratio:.3f}); }} 100% {{ transform: scaleX(1); }} }}
      @media (prefers-reduced-motion: reduce) {{
        .orb, .orb2, .bar, .pill .pbg, .pill .dot, .pill .ptxt, .pill .zz {{ animation: none; }}
      }}
    </style>
  </defs>
  <g clip-path="url(#card)">
    <rect width="1200" height="320" fill="url(#bg)"/>
    <rect width="1200" height="320" fill="url(#grid)"/>
    <circle class="orb" cx="260" cy="80" r="270" fill="url(#glow)"/>
    <circle class="orb2" cx="1000" cy="280" r="260" fill="url(#glow2)"/>
  </g>
  <rect x=".5" y=".5" width="1199" height="319" rx="23.5" fill="none" stroke="#fff" stroke-opacity=".13"/>

  <g transform="translate(70 40) scale(.15)">
    <rect width="512" height="512" rx="116" fill="#0d1815" stroke="#fff" stroke-opacity=".1" stroke-width="6"/>
    <path d="M370 104c-92 10-170 72-196 162-9 31-11 62-8 92l34-34 2 46 34-38 8 40 30-40c70-36 112-112 112-190 0-14-6-30-16-38z" fill="url(#vane)"/>
    <path d="M364 132C292 200 218 290 140 410" stroke="#e9fff4" stroke-width="16" stroke-linecap="round" fill="none"/>
  </g>
  <text x="66" y="192" font-family="{FONT_SANS}" font-size="76" font-weight="800" letter-spacing="-2.5" fill="url(#ink)">NexLite</text>
  <text x="73" y="236" font-family="{FONT_SANS}" font-size="22" fill="#c4d4cc">Zen Browser on a memory diet</text>
  <g transform="translate(73 260)">
    <rect width="214" height="32" rx="16" fill="{MINT}" fill-opacity=".16" stroke="{MINT}" stroke-opacity=".55"/>
    <text class="chip" x="107" y="21" text-anchor="middle">-{pct}% RAM when idle</text>
    <rect x="226" width="168" height="32" rx="16" fill="#fff" fill-opacity=".07" stroke="#fff" stroke-opacity=".16"/>
    <text class="chip" x="310" y="21" text-anchor="middle">official Zen build</text>
    <rect x="406" width="150" height="32" rx="16" fill="#fff" fill-opacity=".07" stroke="#fff" stroke-opacity=".16"/>
    <text class="chip" x="481" y="21" text-anchor="middle">no rebuild</text>
  </g>

  {''.join(pills)}
  <g transform="translate(760 282)">
    <text class="cap" x="0" y="-8">MEMORY</text>
    <text class="num" x="300" y="-8" text-anchor="end">{fmt_mb(stock_idle)} → {fmt_mb(lite_idle)}</text>
    <rect width="300" height="10" rx="5" fill="#fff" fill-opacity=".07"/>
    <rect class="bar" width="{meter_full}" height="10" rx="5" fill="url(#meter)"/>
  </g>
</svg>
"""


def main(argv: list[str]) -> int:
    results = Path(argv[1]) if len(argv) > 1 else REPO / "bench" / "results.json"
    out_dir = Path(argv[2]) if len(argv) > 2 else REPO / "docs" / "assets"
    res = json.loads(results.read_text())
    missing = {"stock", "lite"} - set(res["summary"])
    if missing:
        print(f"error: results lack variants: {', '.join(sorted(missing))}", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "memory-chart.svg").write_text(render_chart(res))
    (out_dir / "banner.svg").write_text(render_banner(res))
    print(f"wrote {out_dir / 'banner.svg'} and {out_dir / 'memory-chart.svg'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
