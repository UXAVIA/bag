#!/usr/bin/env python3
"""
Store screenshots for Bag: dark background, bold headline + one-line subline above a device frame
that shows the real app capture. The first two screenshots carry the product promise as text
(growth playbook); images are not localised.

Sources (--source, default "goldens"):
  goldens  Flutter golden renders from `flutter test --update-goldens test/screenshots/screenshot_test.dart`
           test/screenshots/goldens/screenshots/pixel7/<scene>.png    1079×2400 → Android
           test/screenshots/goldens/screenshots/iphone69/<scene>.png  1290×2796 → iOS
           No OS chrome in these (the app's own safe-area padding may be present), so they are
           scaled into the frame as-is.
  raw      Emulator captures <n>.png (1280×2856, Android status bar ~130 px + gesture nav ~80 px),
           read from --raw-dir (default store-assets/raw/). The Android chrome is kept inside the
           Android frame and cropped (STATUS_PX / NAV_PX) before the iOS frame.

Output: store-assets/android/<nn>-<slug>.png         1080×1920 (Play)
        store-assets/android/feature-graphic.png     1024×500
        store-assets/ios/<nn>-<slug>.png             1320×2868 (6.9" App Store size), iOS chrome drawn:
                                                     Dynamic Island, 9:41 status bar, home indicator.
                                                     Android-only screens (Sentinel) are skipped.
  --fdroid  also copies the Android set to fastlane/metadata/android/en-US/images/phoneScreenshots/<n>.png
            (removing leftover higher-numbered files) and the feature graphic to
            fastlane/metadata/android/en-US/images/featureGraphic.png.

Run:    /path/to/python-with-Pillow tools/store/make_store_screenshots.py [--source goldens|raw] [--fdroid]
Fonts:  Inter/JetBrains Mono are only available as woff2 on this machine (Pillow needs ttf/otf), so
        the script uses Noto Sans (Bold / Regular) via fontconfig and falls back to the default sans.
"""
from __future__ import annotations

import argparse
import subprocess
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
GOLDENS = ROOT / "test" / "screenshots" / "goldens" / "screenshots"
OUT = ROOT / "store-assets"
ICON = ROOT / "assets" / "icons" / "icon.png"
FDROID_IMAGES = ROOT / "fastlane" / "metadata" / "android" / "en-US" / "images"
STATUS_PX, NAV_PX = 130, 80  # Android chrome to crop from 1280×2856 raw captures

# Palette: lib/core/theme/app_theme.dart (dark scheme)
ORANGE = (247, 147, 26)
BG = (10, 10, 15)
APP_BG = (10, 10, 15)
INK = (255, 255, 255)
GREY = (136, 136, 170)
FRAME = (28, 28, 36)
FRAME_EDGE = (70, 70, 84)


@dataclass(frozen=True)
class Shot:
    slug: str
    headline: str
    subline: str
    scene: str | None  # golden scene name (None: not available as a golden)
    raw: int | None  # raw capture number (None: not available as a raw capture)
    android_only: bool = False


# Order matters: the first two carry the promise. Sentinel is Android-only and goes last.
SHOTS = [
    Shot("wallet", "Watch your Bitkey or cold-storage balance", "No seed phrase on your phone. Ever.", "walletPrivacy", 9),
    Shot("home", "Your xpub never leaves your phone", "Tor built in. No account. No analytics.", "homeWithWallet", 2),
    Shot("net-worth", "Net worth in 3 currencies at once", "Live price chart from one day to all time.", None, 1),
    Shot("dca", "Every buy, your average, your P&L", "Log each purchase in USD, EUR or GBP.", "dcaTracker", 3),
    Shot("health-check", "A privacy score for your UTXOs", "Reused addresses, dust and coinjoins, flagged.", "healthCheck", 7),
    Shot("health-breakdown", "See exactly what costs you points", "Address hygiene, coinjoin coverage, Tor use.", "healthCheckBreakdown", 8),
    Shot("settings", "Sats mode, app lock, home widget", "Dark or light theme. Open source. No ads.", "settingsProUnlocked", 4),
    Shot("sentinel", "Always-on wallet alerts", "Sentinel fires the moment a tx hits the mempool.", "sentinelActive", 6, android_only=True),
]
MAX_HEADLINE, MAX_SUBLINE = 42, 48  # 38 is the target; the wallet promise is 41 and wraps to two lines

_FONT_CACHE: dict[tuple[str, int], ImageFont.FreeTypeFont] = {}


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    key = ("b" if bold else "r", size)
    if key not in _FONT_CACHE:
        pattern = "Noto Sans:bold" if bold else "Noto Sans"
        path = subprocess.check_output(["fc-match", "-f", "%{file}", pattern], text=True).strip()
        if "NotoSans" not in Path(path).name:
            path = subprocess.check_output(["fc-match", "-f", "%{file}", "sans:bold" if bold else "sans"], text=True).strip()
        _FONT_CACHE[key] = ImageFont.truetype(path, size)
    return _FONT_CACHE[key]


def font_name() -> str:
    return Path(font(10).path).name


def background(w: int, h: int) -> Image.Image:
    """Near-black canvas with a faint orange radial glow behind the headline."""
    glow = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(glow)
    r = int(w * 0.55)
    cx, cy = w // 2, int(h * 0.12)
    d.ellipse((cx - r, cy - r // 2, cx + r, cy + r // 2), fill=(52, 34, 18))
    return glow.filter(ImageFilter.GaussianBlur(int(w * 0.18)))


def rounded_mask(size, radius) -> Image.Image:
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return m


def wrap(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont, max_w: int) -> list[str]:
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=f) <= max_w:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def strip_android_chrome(raw: Image.Image) -> Image.Image:
    """A raw emulator capture without its status bar and gesture-nav bar."""
    return raw.crop((0, STATUS_PX, raw.width, raw.height - NAV_PX))


# ---------------------------------------------------------------- iOS device frame

def ios_status_bar(d: ImageDraw.ImageDraw, x0: int, y0: int, w: int, fg=INK) -> None:
    f = font(40)
    d.text((x0 + 70, y0 + 34), "9:41", font=f, fill=fg)
    bx = x0 + w - 230
    for i, hgt in enumerate((12, 18, 24, 30)):
        d.rounded_rectangle((bx + i * 14, y0 + 68 - hgt, bx + i * 14 + 9, y0 + 68), radius=2, fill=fg)
    wx, wy = x0 + w - 150, y0 + 70
    for r, width in ((30, 5), (19, 5), (8, 6)):
        d.arc((wx - r, wy - r, wx + r, wy + r), start=215, end=325, fill=fg, width=width)
    bx0, by0 = x0 + w - 100, y0 + 40
    d.rounded_rectangle((bx0, by0, bx0 + 54, by0 + 26), radius=7, outline=fg, width=3)
    d.rounded_rectangle((bx0 + 4, by0 + 4, bx0 + 50, by0 + 22), radius=4, fill=fg)
    d.rounded_rectangle((bx0 + 57, by0 + 8, bx0 + 61, by0 + 18), radius=2, fill=fg)


def ios_device(content: Image.Image, screen_w: int = 1000) -> Image.Image:
    """iPhone-style frame (Dynamic Island, status bar, home indicator) around chrome-free app content."""
    bezel = 30
    screen_h = int(screen_w * 2.164)  # 19.5:9
    radius = 120
    fw, fh = screen_w + 2 * bezel, screen_h + 2 * bezel
    dev = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    d = ImageDraw.Draw(dev)
    d.rounded_rectangle((0, 0, fw - 1, fh - 1), radius=radius + bezel, fill=FRAME + (255,))
    d.rounded_rectangle((3, 3, fw - 4, fh - 4), radius=radius + bezel - 3, outline=FRAME_EDGE + (255,), width=3)

    screen = Image.new("RGBA", (screen_w, screen_h), APP_BG + (255,))
    status_h = 110
    body_h = screen_h - status_h - 90
    # Fit the whole capture between the status bar and the home indicator (never crop the bottom:
    # a sliced-off nav bar reads as a broken app). The app background matches APP_BG, so a slightly
    # narrower, centred capture blends into the screen.
    scale = min(screen_w / content.width, body_h / content.height)
    scaled = content.convert("RGBA").resize((round(content.width * scale), round(content.height * scale)), Image.LANCZOS)
    screen.alpha_composite(scaled, ((screen_w - scaled.width) // 2, status_h))
    sd = ImageDraw.Draw(screen)
    ios_status_bar(sd, 0, 0, screen_w)
    iw, ih = 300, 84
    sd.rounded_rectangle(((screen_w - iw) // 2, 28, (screen_w + iw) // 2, 28 + ih), radius=ih // 2, fill=(0, 0, 0, 255))
    sd.rounded_rectangle(((screen_w - 300) // 2, screen_h - 34, (screen_w + 300) // 2, screen_h - 22), radius=6, fill=(230, 230, 236, 255))
    screen.putalpha(rounded_mask(screen.size, radius))
    dev.alpha_composite(screen, (bezel, bezel))
    return dev


def android_device(capture: Image.Image, screen_w: int = 820) -> Image.Image:
    """Slim frame around an Android capture, scaled to width as-is (a raw capture keeps its own status bar)."""
    bezel = 18
    scaled = capture.convert("RGBA").resize((screen_w, int(capture.height * screen_w / capture.width)), Image.LANCZOS)
    radius = 70
    fw, fh = screen_w + 2 * bezel, scaled.height + 2 * bezel
    dev = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    d = ImageDraw.Draw(dev)
    d.rounded_rectangle((0, 0, fw - 1, fh - 1), radius=radius + bezel, fill=FRAME + (255,))
    d.rounded_rectangle((2, 2, fw - 3, fh - 3), radius=radius + bezel - 2, outline=FRAME_EDGE + (255,), width=2)
    scaled.putalpha(rounded_mask(scaled.size, radius))
    dev.alpha_composite(scaled, (bezel, bezel))
    return dev


def compose(canvas_size: tuple[int, int], device: Image.Image, headline: str, body: str, top_gap: int) -> Image.Image:
    W, H = canvas_size
    canvas = background(W, H).convert("RGBA")
    d = ImageDraw.Draw(canvas)
    f1, f2 = font(int(W * 0.066)), font(int(W * 0.034), bold=False)
    margin = int(W * 0.07)
    y = int(H * 0.04)
    for line in wrap(d, headline, f1, W - 2 * margin):
        d.text(((W - d.textlength(line, font=f1)) / 2, y), line, font=f1, fill=INK)
        y += int(f1.size * 1.18)
    # thin orange rule between headline and subline — the one accent on the page
    y += int(f2.size * 0.85)
    rule_w = int(W * 0.06)
    d.rounded_rectangle(((W - rule_w) // 2, y, (W + rule_w) // 2, y + 5), radius=3, fill=ORANGE)
    y += int(f2.size * 0.75)
    for line in wrap(d, body, f2, W - 2 * margin):
        d.text(((W - d.textlength(line, font=f2)) / 2, y), line, font=f2, fill=GREY)
        y += int(f2.size * 1.3)
    top = max(y + top_gap, int(H * 0.20))
    x = (W - device.width) // 2
    # soft orange-tinted glow under the device; the device may run off the bottom edge
    shadow = Image.new("RGBA", (device.width + 160, device.height + 160), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((80, 60, device.width + 80, device.height + 80), radius=150, fill=(247, 147, 26, 42))
    shadow = shadow.filter(ImageFilter.GaussianBlur(60))
    canvas.alpha_composite(shadow, (x - 80, top - 80))
    canvas.alpha_composite(device, (x, top))
    return canvas.convert("RGB")


def feature_graphic(icon: Image.Image) -> Image.Image:
    img = background(1024, 500).convert("RGBA")
    d = ImageDraw.Draw(img)
    ic = icon.convert("RGBA").resize((280, 280), Image.LANCZOS)
    ic.putalpha(rounded_mask(ic.size, 60))
    img.alpha_composite(ic, (80, 110))
    f1, f2 = font(150), font(30, bold=False)
    d.text((410, 90), "Bag", font=f1, fill=INK)
    d.rounded_rectangle((418, 300, 478, 305), radius=3, fill=ORANGE)
    d.text((410, 328), "Watch-only Bitcoin tracker.", font=f2, fill=INK)
    d.text((410, 372), "Private by design.", font=f2, fill=GREY)
    return img.convert("RGB")


# ---------------------------------------------------------------- sources

def load_goldens(shot: Shot) -> tuple[Image.Image, Image.Image | None]:
    """(android capture, ios chrome-free content) from the Flutter goldens."""
    android = Image.open(GOLDENS / "pixel7" / f"{shot.scene}.png")
    ios = None if shot.android_only else Image.open(GOLDENS / "iphone69" / f"{shot.scene}.png")
    return android, ios


def load_raw(shot: Shot, raw_dir: Path) -> tuple[Image.Image, Image.Image | None]:
    raw = Image.open(raw_dir / f"{shot.raw}.png")
    return raw, None if shot.android_only else strip_android_chrome(raw)


def sync_fdroid(android_files: list[Path], feature: Path) -> None:
    shots_dir = FDROID_IMAGES / "phoneScreenshots"
    shots_dir.mkdir(parents=True, exist_ok=True)
    for old in shots_dir.glob("*.png"):
        old.unlink()
    for i, src in enumerate(android_files, start=1):
        (shots_dir / f"{i}.png").write_bytes(src.read_bytes())
    # F-Droid's existing feature graphic is 1024×500 RGBA; keep that shape.
    Image.open(feature).convert("RGBA").save(FDROID_IMAGES / "featureGraphic.png", optimize=True)
    print(f"synced {len(android_files)} screenshots + featureGraphic.png to {FDROID_IMAGES.relative_to(ROOT)}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=("goldens", "raw"), default="goldens")
    ap.add_argument("--raw-dir", type=Path, default=OUT / "raw", help="directory with <n>.png emulator captures (--source raw)")
    ap.add_argument("--fdroid", action="store_true", help="also refresh fastlane/metadata/android/en-US/images")
    args = ap.parse_args()

    shots = [s for s in SHOTS if (s.scene if args.source == "goldens" else s.raw) is not None]
    for s in shots:
        assert len(s.headline) <= MAX_HEADLINE, f"{s.slug}: headline {len(s.headline)} > {MAX_HEADLINE}"
        assert len(s.subline) <= MAX_SUBLINE, f"{s.slug}: subline {len(s.subline)} > {MAX_SUBLINE}"
    for sub in ("ios", "android"):
        (OUT / sub).mkdir(parents=True, exist_ok=True)
    for stale in list((OUT / "ios").glob("*.png")) + list((OUT / "android").glob("[0-9]*.png")):
        stale.unlink()
    print("source:", args.source, "| font:", font_name())

    android_files: list[Path] = []
    ios_n = 0
    for i, shot in enumerate(shots, start=1):
        android, ios = load_goldens(shot) if args.source == "goldens" else load_raw(shot, args.raw_dir)
        nn = f"{i:02d}"
        out_android = OUT / "android" / f"{nn}-{shot.slug}.png"
        compose((1080, 1920), android_device(android), shot.headline, shot.subline, top_gap=60).save(out_android, optimize=True)
        android_files.append(out_android)
        if ios is not None:
            ios_n += 1
            compose((1320, 2868), ios_device(ios), shot.headline, shot.subline, top_gap=90).save(OUT / "ios" / f"{ios_n:02d}-{shot.slug}.png", optimize=True)
        src = shot.scene if args.source == "goldens" else f"{shot.raw}.png"
        print(f"wrote {nn} {shot.slug:<17} <- {src:<21} {shot.headline!r} / {shot.subline!r}" + ("  (android only)" if shot.android_only else ""))
    feature = OUT / "android" / "feature-graphic.png"
    feature_graphic(Image.open(ICON)).save(feature, optimize=True)
    print("wrote android/feature-graphic.png")
    if args.fdroid:
        sync_fdroid(android_files, feature)


if __name__ == "__main__":
    main()
