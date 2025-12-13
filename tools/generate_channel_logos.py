#!/usr/bin/env python3
"""Convert Android vector channel logos to standalone SVG assets."""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
ANDROID_DRAWABLE_DIR = REPO_ROOT / "android" / "app" / "src" / "main" / "res" / "drawable"
ANDROID_DRAWABLE_NIGHT_DIR = REPO_ROOT / "android" / "app" / "src" / "main" / "res" / "drawable-night"
OUTPUT_DIR = REPO_ROOT / "Zapp" / "Resources" / "ChannelLogos"

ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
AAPT_NS = "{http://schemas.android.com/aapt}"

TARGET_LOGOS = [
    "channel_logo_das_erste",
    "channel_logo_zdf",
    "channel_logo_arte",
    "channel_logo_3sat",
    "channel_logo_kika",
    "channel_logo_phoenix",
    "channel_logo_tagesschau24",
    "channel_logo_ard_alpha",
    "channel_logo_zdf_info",
    "channel_logo_zdf_neo",
    "channel_logo_one",
    "channel_logo_br",
    "channel_logo_hr",
    "channel_logo_mdr",
    "channel_logo_ndr",
    "channel_logo_rbb",
    "channel_logo_rb",
    "channel_logo_sr",
    "channel_logo_swr",
    "channel_logo_wdr",
    "channel_logo_parlamentsfernsehen",
]


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for svg_file in OUTPUT_DIR.glob("channel_logo_*.svg"):
        svg_file.unlink()

    for logo_name in TARGET_LOGOS:
        convert_logo(logo_name, ANDROID_DRAWABLE_DIR)
        convert_logo(logo_name, ANDROID_DRAWABLE_NIGHT_DIR, suffix="_dark", optional=True)


def convert_logo(logo_name: str, source_dir: Path, suffix: str = "", optional: bool = False) -> None:
    vector_path = source_dir / f"{logo_name}.xml"
    if not vector_path.exists():
        if optional:
            return
        raise FileNotFoundError(vector_path)

    svg_path = OUTPUT_DIR / f"{logo_name}{suffix}.svg"
    svg_content = vector_to_svg(vector_path)
    svg_path.write_text(svg_content, encoding="utf-8")


def vector_to_svg(vector_path: Path) -> str:
    tree = ET.parse(vector_path)
    root = tree.getroot()
    viewport_width = float(root.attrib[f"{ANDROID_NS}viewportWidth"])
    viewport_height = float(root.attrib[f"{ANDROID_NS}viewportHeight"])

    paths: List[SvgPath] = []
    for child in root:
        paths.extend(extract_paths(child))

    svg_lines = [
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
        f"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{viewport_width}\" height=\"{viewport_height}\" viewBox=\"0 0 {viewport_width} {viewport_height}\">",
    ]
    for path in paths:
        svg_lines.append(path.to_svg())
    svg_lines.append("</svg>")
    return "\n".join(svg_lines)


def extract_paths(element: ET.Element) -> List[SvgPath]:
    tag = strip_ns(element.tag)
    if tag == "path":
        path = svg_path_from_element(element)
        return [path] if path else []
    if tag == "group":
        clip_nodes = [child for child in element if strip_ns(child.tag) == "clip-path"]
        path_nodes = [child for child in element if strip_ns(child.tag) == "path"]
        result: List[SvgPath] = []
        if clip_nodes and path_nodes:
            count = min(len(clip_nodes), len(path_nodes))
            for i in range(count):
                clip = clip_nodes[i]
                path_elem = path_nodes[i]
                override_d = clip.attrib.get(f"{ANDROID_NS}pathData")
                path = svg_path_from_element(path_elem, override_d)
                if path:
                    result.append(path)
        else:
            for child in element:
                result.extend(extract_paths(child))
        return result
    if tag == "clip-path":
        return []
    # default: recurse into children
    result: List[SvgPath] = []
    for child in element:
        result.extend(extract_paths(child))
    return result


def svg_path_from_element(element: ET.Element, override_d: Optional[str] = None) -> Optional[SvgPath]:
    d = override_d or element.attrib.get(f"{ANDROID_NS}pathData")
    if not d:
        return None

    fill = element.attrib.get(f"{ANDROID_NS}fillColor")
    fill_alpha = element.attrib.get(f"{ANDROID_NS}fillAlpha")
    stroke = element.attrib.get(f"{ANDROID_NS}strokeColor")
    stroke_alpha = element.attrib.get(f"{ANDROID_NS}strokeAlpha")
    stroke_width = element.attrib.get(f"{ANDROID_NS}strokeWidth")

    grad_fill, grad_alpha = extract_gradient_color(element)
    if grad_fill:
        fill = grad_fill
        if grad_alpha is not None:
            fill_alpha = grad_alpha

    fill_color, fill_opacity = normalize_color(fill)
    stroke_color, stroke_opacity = normalize_color(stroke)

    fill_rule = element.attrib.get(f"{ANDROID_NS}fillType")

    return SvgPath(
        d=d,
        fill=fill_color,
        fill_opacity=fill_alpha or fill_opacity,
        stroke=stroke_color,
        stroke_opacity=stroke_alpha or stroke_opacity,
        stroke_width=stroke_width,
        fill_rule=fill_rule,
    )


def extract_gradient_color(element: ET.Element) -> Tuple[Optional[str], Optional[str]]:
    for attr in element.findall(f"{AAPT_NS}attr"):
        name = attr.attrib.get(f"{ANDROID_NS}name") or attr.attrib.get("name")
        if name != "android:fillColor":
            continue
        gradient = attr.find("gradient")
        if gradient is None:
            continue
        start_color = gradient.attrib.get(f"{ANDROID_NS}startColor")
        if start_color:
            color, alpha = normalize_color(start_color)
            return color, alpha
        first_item = gradient.find("item")
        if first_item is not None:
            item_color = first_item.attrib.get(f"{ANDROID_NS}color")
            if item_color:
                color, alpha = normalize_color(item_color)
                return color, alpha
    return None, None


def normalize_color(raw: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    if not raw:
        return None, None
    raw = raw.strip()
    if not raw.startswith("#"):
        return raw, None
    hex_value = raw[1:]
    if len(hex_value) == 6:
        return f"#{hex_value}", None
    if len(hex_value) == 8:
        alpha = int(hex_value[:2], 16) / 255
        rgb = hex_value[2:]
        return f"#{rgb}", f"{alpha:.3f}"
    return f"#{hex_value}", None


def strip_ns(tag: str) -> str:
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


@dataclass
class SvgPath:
    d: str
    fill: Optional[str]
    fill_opacity: Optional[str]
    stroke: Optional[str]
    stroke_opacity: Optional[str]
    stroke_width: Optional[str]
    fill_rule: Optional[str]

    def to_svg(self) -> str:
        attrs = [f"d=\"{self.d}\""]
        if self.fill:
            attrs.append(f"fill=\"{self.fill}\"")
        else:
            attrs.append("fill=\"none\"")
        if self.fill_opacity:
            attrs.append(f"fill-opacity=\"{self.fill_opacity}\"")
        if self.stroke:
            attrs.append(f"stroke=\"{self.stroke}\"")
        if self.stroke_opacity:
            attrs.append(f"stroke-opacity=\"{self.stroke_opacity}\"")
        if self.stroke_width:
            attrs.append(f"stroke-width=\"{self.stroke_width}\"")
        if self.fill_rule:
            attrs.append(f"fill-rule=\"{self.fill_rule}\"")
        return "  <path " + " ".join(attrs) + " />"


if __name__ == "__main__":
    main()
