#!/usr/bin/env python3
"""Generates every vector asset for the Bollard mark from one set of paths.

The mark is a mooring double bitt, two flared posts on a shared base with a
line made fast around them in a figure-eight. Where the line crosses itself or
passes a post, the nearer piece is drawn whole and the farther one is cut back.

Outputs
  Resources/Bollard.icon/            layered Icon Composer document
                                     (rope-back, posts, rope-front)
  Resources/MenuBarIcon.pdf          vector template glyph for the status item

Run scripts/build-icon.sh to also export the .icns and compile Assets.car.
Needs rsvg-convert (brew install librsvg) for the glyph PDF.
"""
import json
import math
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "Resources"

# Shared by the icon layers. The post is shaded like a cylinder, the rope like a lit strand.
PAINT = (
    '<linearGradient id="cyl" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#b9c9e6"/>'
    '<stop offset=".35" stop-color="#ffffff"/><stop offset=".62" stop-color="#f1f5fc"/><stop offset="1" stop-color="#a9bbdc"/></linearGradient>'
    '<linearGradient id="rope" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffb457"/><stop offset="1" stop-color="#f2862a"/></linearGradient>'
)
CX = 512
DY = -10  # optical centring of the whole mark on the 1024 grid

# Figure-eight is a lemniscate of Bernoulli, squashed vertically by K.
A, K, CY, ROPE = 290, 1.2, 520, 64
# Posts, centred on CX plus or minus P, with a flared head.
P, NECK, CAP, TOP, CAP_H, BASE_Y, BASE_H, BASE_X = 156, 140, 224, 290, 90, 690, 92, 170

PI = math.pi


def lem(t: float) -> tuple[float, float]:
    d = 1 + math.sin(t) ** 2
    return CX + A * math.cos(t) / d, CY + K * A * math.sin(t) * math.cos(t) / d


def centreline(t0: float, t1: float, n: int = 80) -> str:
    pts = [lem(t0 + (t1 - t0) * i / n) for i in range(n + 1)]
    return "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)


def band(t0: float, t1: float, half: float, n: int = 40) -> str:
    """Polygon covering the rope between t0 and t1, grown to half-width `half`."""
    left, right = [], []
    for i in range(n + 1):
        t = t0 + (t1 - t0) * i / n
        x, y = lem(t)
        x2, y2 = lem(t + 1e-4)
        dx, dy = x2 - x, y2 - y
        m = math.hypot(dx, dy)
        nx, ny = -dy / m * half, dx / m * half
        left.append((x + nx, y + ny))
        right.append((x - nx, y - ny))
    pts = left + right[::-1]
    return "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"


def stroke(d: str, colour: str, width: float = ROPE, extra: str = "", cap: str = "round") -> str:
    return (
        f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{width}" '
        f'stroke-linecap="{cap}" stroke-linejoin="round" {extra}/>'
    )


def rope_strand(d: str, colours: dict[str, str]) -> str:
    """Rope body, plus the lay marks across the strand when the colours ask for them."""
    out = stroke(d, colours["rope"])
    if "lay" in colours:
        out += stroke(d, colours["lay"], ROPE - 14, 'stroke-dasharray="5 21" opacity=".55"', "butt")
    return out


def post(px: float, grow: float = 0) -> str:
    hw, cw, r = NECK / 2 + grow, CAP / 2 + grow, CAP_H / 2
    top, foot = TOP - grow, BASE_Y + 10
    return (
        f"M {px - hw} {foot} V {TOP + CAP_H + 50} C {px - hw} {TOP + CAP_H + 10} {px - cw} {TOP + CAP_H} {px - cw} {TOP + r} "
        f"A {r + grow} {r + grow} 0 0 1 {px - cw + r + grow} {top} H {px + cw - r - grow} "
        f"A {r + grow} {r + grow} 0 0 1 {px + cw} {TOP + r} "
        f"C {px + cw} {TOP + CAP_H} {px + hw} {TOP + CAP_H + 10} {px + hw} {TOP + CAP_H + 50} V {foot} Z"
    )


def base(grow: float = 0) -> str:
    x, y, w, h = BASE_X - grow, BASE_Y - grow, 1024 - 2 * BASE_X + 2 * grow, BASE_H + 2 * grow
    r = h / 2
    return f"M {x + r} {y} H {x + w - r} A {r} {r} 0 0 1 {x + w - r} {y + h} H {x + r} A {r} {r} 0 0 1 {x + r} {y} Z"


def posts_and_base(grow: float = 0) -> str:
    return " ".join([post(CX - P, grow), post(CX + P, grow), base(grow)])


def cut(inner: str, hole: str, ident: str) -> tuple[str, str]:
    """Returns (<clipPath> def, wrapped inner) keeping everything except `hole`."""
    clip = (
        f'<clipPath id="{ident}"><path clip-rule="evenodd" '
        f'd="M -200 -200 H 1300 V 1300 H -200 Z {hole}"/></clipPath>'
    )
    return clip, f'<g clip-path="url(#{ident})">{inner}</g>'


def mark(parts: set[str], colours: dict[str, str], gap: float, hollow: bool) -> tuple[str, str]:
    """Builds the requested pieces of the mark. Returns (defs, body).

    `hollow` cuts gaps wherever one piece passes another, which the monochrome
    glyph needs. The coloured icon relies on colour and only separates the two
    rope strands at the centre.
    """
    defs, body = [], []
    half = ROPE / 2 + gap
    # Strand 2 yields to strand 1 at the centre crossing.
    centre = band(PI / 2 - 0.55, PI / 2 + 0.55, half)

    # Strand 1 is 0..pi, strand 2 is pi..2pi. Split each by front and back.
    s1_front, s1_back = (0, PI / 2), (PI / 2, PI)
    s2_front, s2_back = (PI, 3 * PI / 2), (3 * PI / 2, 2 * PI)

    def pieces(ranges, avoid_centre: bool, extra_hole: str, ident: str) -> str:
        inner = "".join(rope_strand(centreline(*r), colours) for r in ranges)
        hole = (centre if avoid_centre else "") + " " + extra_hole
        if not hole.strip():
            return inner
        clip, wrapped = cut(inner, hole, ident)
        defs.append(clip)
        return wrapped

    if "rope-back" in parts:
        hole = posts_and_base(gap) if hollow else ""
        body.append(pieces([s1_back], False, hole, "b1"))
        body.append(pieces([s2_back], True, hole, "b2"))
    if "posts" in parts:
        inner = f'<path d="{posts_and_base()}" fill="{colours["post"]}"/>'
        if hollow:
            front = band(*s1_front, half) + " " + band(*s2_front, half)
            clip, inner = cut(inner, front, "pf")
            defs.append(clip)
        body.append(inner)
    if "rope-front" in parts:
        body.append(pieces([s1_front], False, "", "f1"))
        body.append(pieces([s2_front], True, "", "f2"))
    return "".join(defs), "".join(body)


def svg(size: float, vb: str, transform: str, defs: str, body: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="{vb}">'
        f"<defs>{defs}</defs><g transform=\"{transform}\">{body}</g></svg>\n"
    )


def write_icon() -> None:
    icon = RES / "Bollard.icon"
    assets = icon / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    colours = {"rope": "url(#rope)", "lay": "#c8651a", "post": "url(#cyl)"}
    for name in ("rope-back", "posts", "rope-front"):
        defs, body = mark({name}, colours, gap=14, hollow=False)
        (assets / f"{name}.svg").write_text(svg(1024, "0 0 1024 1024", f"translate(0 {DY})", PAINT + defs, body))

    def layer(name: str, **extra) -> dict:
        return {
            "image-name": f"{name}.svg",
            "name": name,
            "glass": True,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
            **extra,
        }

    def group(name: str, **extra) -> dict:
        return {"layers": [layer(name)], "shadow": {"kind": "neutral", "opacity": 0.5}, "specular": True, **extra}

    doc = {
        "fill": {"linear-gradient": ["srgb:0.17000,0.40000,0.79000,1.00000", "srgb:0.05000,0.12000,0.28000,1.00000"]},
        "fill-specializations": [
            {
                "appearance": "dark",
                "value": {"linear-gradient": ["srgb:0.13000,0.26000,0.52000,1.00000", "srgb:0.03000,0.07000,0.17000,1.00000"]},
            }
        ],
        # Front-most group first.
        "groups": [
            group("rope-front", translucency={"enabled": True, "value": 0.12}),
            group("posts", translucency={"enabled": False, "value": 0}),
            group("rope-back", translucency={"enabled": True, "value": 0.12}),
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (icon / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


def write_glyph() -> None:
    # 18 pt canvas. Mark is 684 units wide, so the rope lands near 1.5 pt, the
    # weight of the system glyphs.
    s = 16.5 / (1024 - 2 * BASE_X)
    cy = (TOP + BASE_Y + BASE_H) / 2 + DY
    transform = f"translate({9 - CX * s:.4f} {9 - cy * s:.4f}) scale({s:.5f}) translate(0 {DY})"
    defs, body = mark({"rope-back", "posts", "rope-front"}, {"rope": "#000", "post": "#000"}, gap=34, hollow=True)
    tmp = pathlib.Path("/private/tmp") / "bollard-glyph.svg"
    tmp.write_text(svg(18, "0 0 18 18", transform, defs, body))
    subprocess.run(["rsvg-convert", "-f", "pdf", str(tmp), "-o", str(RES / "MenuBarIcon.pdf")], check=True)
    tmp.unlink()


if __name__ == "__main__":
    write_icon()
    if "--no-glyph" not in sys.argv:
        write_glyph()
