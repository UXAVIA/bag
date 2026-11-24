#!/usr/bin/env python3
"""
Store, website and marketing screenshots for Bag, from the Flutter goldens.

Layout: a bold headline and a one-line description above the whole phone, drawn with its status bar
and rounded bottom, never cropped.
The first two screenshots carry the product promise as text (growth playbook); images are not
localised.

Source: `FLUTTER_ROOT=<sdk> flutter test --update-goldens test/screenshots/screenshot_test.dart
--name "pixel7_|iphone69_"` (FLUTTER_ROOT makes it load real Roboto; the iPhone set renders as
iOS, Tor connected, the store flavor's Pro sheet).
  test/screenshots/goldens/screenshots/pixel7/<scene>.png    1079×2400 → Android
  test/screenshots/goldens/screenshots/iphone69/<scene>.png  1290×2796 → iOS
No OS chrome in these; this script draws it.

Output:
  store-assets/android/<nn>-<slug>.png        1080×1920 (Play), Android status bar + punch-hole
  store-assets/android/feature-graphic.png    1024×500
  store-assets/ios/<nn>-<slug>.png            1320×2868 (6.9" App Store), Dynamic Island, 9:41
                                              status bar with iOS glyphs (App Review 2.3.10),
                                              home indicator. Android-only screens are skipped.
  store-assets/device-only/{android,ios}/<nn>-<slug>.png
                                              the phone alone on a transparent background, for
                                              marketing pages
  store-assets/website/<name>.png + img/<name>-{480,720}.webp
                                              plain screens with a status bar, named as
                                              bitbag.app's public/ and public/img/ expect
  --fdroid  also copies the Android set to fastlane/metadata/android/en-US/images/phoneScreenshots/
            and the feature graphic to fastlane/metadata/android/en-US/images/featureGraphic.png.

Run:    /path/to/python-with-Pillow tools/store/make_store_screenshots.py [--fdroid]
Fonts:  Noto Sans (Bold / Regular) via fontconfig for the captions; falls back to the default sans.
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

# Palette: lib/core/theme/app_theme.dart (dark scheme)
ORANGE = (247, 147, 26)
BG = (10, 10, 15)
INK = (255, 255, 255)
GREY = (136, 136, 170)
FRAME = (24, 24, 30)
FRAME_EDGE = (78, 78, 92)


@dataclass(frozen=True)
class Shot:
    slug: str
    headline: str
    subline: str
    scene: str
    android_only: bool = False


# Order matters: the first two carry the promise. Sentinel is Android-only and goes last.
SHOTS = [
    Shot("wallets", "Your Bitkey and cold storage, watched", "Multisig or single-sig. No seed phrase, ever.", "walletPrivacy"),
    Shot("home", "Tor built in. No account. No tracking.", "Your net worth in three currencies at once.", "homeWithWallet"),
    Shot("pro", "Every lookup goes through Tor", "One-time unlock. No subscription.", "proUpgradeSheet"),
    Shot("dca", "Every buy, your average, your P&L", "Log each purchase in your own currency.", "dcaTracker"),
    Shot("health-check", "A privacy score for your UTXOs", "Reused addresses, dust and coinjoins, flagged.", "healthCheck"),
    Shot("health-breakdown", "See exactly what costs you points", "Address hygiene, coinjoin coverage, Tor use.", "healthCheckBreakdown"),
    Shot("settings", "Sats mode, app lock, home widget", "Dark or light. Open source. No ads.", "settingsProUnlocked"),
    Shot("sentinel", "Always-on wallet alerts", "Sentinel fires the moment a tx hits the mempool.", "sentinelActive", android_only=True),
]
MAX_HEADLINE, MAX_SUBLINE = 42, 48

# bitbag.app's screenshot names (public/<name>.png, public/img/<name>-480|720.webp) → scene.
WEBSITE = {
    "02_home_wallet": "homeWithWallet",
    "03_dca": "dcaTracker",
    "04_settings_pro_unlocked": "settingsProUnlocked",
    "06_sentinel": "sentinelActive",
    "07_health_check": "healthCheck",
    "08_health_check_breakdown": "healthCheckBreakdown",
    "09_wallet_privacy": "walletPrivacy",
}

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


# ---------------------------------------------------------------- screens and devices

def edge_colour(img: Image.Image, top: bool) -> tuple[int, int, int]:
    """The app's colour along its top or bottom edge, to continue it under the drawn chrome."""
    y = 2 if top else img.height - 3
    return img.convert("RGB").getpixel((img.width // 2, y))


def android_status_bar(d: ImageDraw.ImageDraw, w: int, h: int, fg=INK) -> None:
    """9:30, punch-hole camera, signal / Wi-Fi / battery (Material-style glyphs)."""
    s = h / 70
    d.text((int(36 * s), int(14 * s)), "9:30", font=font(int(34 * s), bold=False), fill=fg)
    r = int(13 * s)
    d.ellipse((w // 2 - r, h // 2 - r, w // 2 + r, h // 2 + r), fill=(0, 0, 0))
    x = w - int(150 * s)
    yb = int(50 * s)
    # Wi-Fi: a filled quarter-fan
    d.pieslice((x - int(18 * s), yb - int(26 * s), x + int(18 * s), yb + int(10 * s)), 225, 315, fill=fg)
    # signal: a filled right triangle
    x += int(34 * s)
    d.polygon([(x, yb), (x + int(26 * s), yb), (x + int(26 * s), yb - int(26 * s))], fill=fg)
    # battery: an upright rounded bar
    x += int(44 * s)
    d.rounded_rectangle((x, yb - int(28 * s), x + int(15 * s), yb), radius=int(3 * s), fill=fg)
    d.rectangle((x + int(4 * s), yb - int(31 * s), x + int(11 * s), yb - int(28 * s)), fill=fg)


def android_screen(content: Image.Image, width: int = 1080) -> Image.Image:
    """The app capture under an Android status bar, with a gesture-bar strip below: a whole screen."""
    scale = width / content.width
    body = content.convert("RGB").resize((width, round(content.height * scale)), Image.LANCZOS)
    status_h, nav_h = round(70 * width / 1080 * 1.4), round(36 * width / 1080 * 1.4)
    screen = Image.new("RGB", (width, status_h + body.height + nav_h), edge_colour(content, top=False))
    screen.paste(Image.new("RGB", (width, status_h), edge_colour(content, top=True)), (0, 0))
    screen.paste(body, (0, status_h))
    d = ImageDraw.Draw(screen)
    android_status_bar(d, width, status_h)
    pill = int(width * 0.18)
    py = status_h + body.height + nav_h // 2
    d.rounded_rectangle(((width - pill) // 2, py - 4, (width + pill) // 2, py + 4), radius=4, fill=(200, 200, 210))
    return screen


def ios_status_bar(d: ImageDraw.ImageDraw, w: int, h: int, fg=INK) -> None:
    """9:41 with iOS glyphs drawn by hand: bars, Wi-Fi arcs, battery outline."""
    s = w / 1000
    d.text((int(90 * s), int(40 * s)), "9:41", font=font(int(40 * s)), fill=fg)
    bx, base = w - int(240 * s), int(78 * s)
    for i, hgt in enumerate((12, 18, 24, 30)):
        x = bx + int(i * 14 * s)
        d.rounded_rectangle((x, base - int(hgt * s), x + int(9 * s), base), radius=2, fill=fg)
    wx, wy = w - int(158 * s), int(80 * s)
    for r, width in ((30, 5), (19, 5), (8, 6)):
        r = int(r * s)
        d.arc((wx - r, wy - r, wx + r, wy + r), start=215, end=325, fill=fg, width=max(2, int(width * s)))
    bx0, by0 = w - int(110 * s), int(50 * s)
    d.rounded_rectangle((bx0, by0, bx0 + int(54 * s), by0 + int(26 * s)), radius=int(7 * s), outline=fg, width=3)
    d.rounded_rectangle((bx0 + int(4 * s), by0 + int(4 * s), bx0 + int(50 * s), by0 + int(22 * s)), radius=int(4 * s), fill=fg)
    d.rounded_rectangle((bx0 + int(57 * s), by0 + int(8 * s), bx0 + int(61 * s), by0 + int(18 * s)), radius=2, fill=fg)


def ios_screen(content: Image.Image, width: int = 1000) -> Image.Image:
    """The app capture under an iOS status bar with the Dynamic Island, home indicator below."""
    scale = width / content.width
    body = content.convert("RGB").resize((width, round(content.height * scale)), Image.LANCZOS)
    status_h, home_h = round(width * 0.125), round(width * 0.075)
    screen = Image.new("RGB", (width, status_h + body.height + home_h), edge_colour(content, top=False))
    screen.paste(Image.new("RGB", (width, status_h), edge_colour(content, top=True)), (0, 0))
    screen.paste(body, (0, status_h))
    d = ImageDraw.Draw(screen)
    ios_status_bar(d, width, status_h)
    iw, ih = int(width * 0.3), int(width * 0.084)
    d.rounded_rectangle(((width - iw) // 2, int(width * 0.03), (width + iw) // 2, int(width * 0.03) + ih), radius=ih // 2, fill=(0, 0, 0))
    hw = int(width * 0.32)
    hy = status_h + body.height + home_h // 2
    d.rounded_rectangle(((width - hw) // 2, hy - 6, (width + hw) // 2, hy + 6), radius=6, fill=(230, 230, 236))
    return screen


def device(screen: Image.Image, height: int, ios: bool) -> Image.Image:
    """The whole phone, `height` px tall: bezel and frame edge around a rounded screen."""
    bezel = round(height * (0.014 if ios else 0.012))
    sh = height - 2 * bezel
    sw = round(screen.width * sh / screen.height)
    scr = screen.convert("RGBA").resize((sw, sh), Image.LANCZOS)
    radius = round(sw * (0.13 if ios else 0.09))
    fw, fh = sw + 2 * bezel, height
    dev = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    d = ImageDraw.Draw(dev)
    d.rounded_rectangle((0, 0, fw - 1, fh - 1), radius=radius + bezel, fill=FRAME + (255,))
    d.rounded_rectangle((2, 2, fw - 3, fh - 3), radius=radius + bezel - 2, outline=FRAME_EDGE + (255,), width=3)
    scr.putalpha(rounded_mask(scr.size, radius))
    dev.alpha_composite(scr, (bezel, bezel))
    return dev


def compose(canvas_size: tuple[int, int], screen: Image.Image, ios: bool, headline: str, body: str) -> Image.Image:
    """Headline, orange rule, subline, then the whole phone fitted below them."""
    W, H = canvas_size
    canvas = background(W, H).convert("RGBA")
    d = ImageDraw.Draw(canvas)
    f1, f2 = font(int(W * 0.066)), font(int(W * 0.034), bold=False)
    margin = int(W * 0.07)
    y = int(H * 0.045)
    for line in wrap(d, headline, f1, W - 2 * margin):
        d.text(((W - d.textlength(line, font=f1)) / 2, y), line, font=f1, fill=INK)
        y += int(f1.size * 1.18)
    y += int(f2.size * 0.7)
    rule_w = int(W * 0.06)
    d.rounded_rectangle(((W - rule_w) // 2, y, (W + rule_w) // 2, y + 5), radius=3, fill=ORANGE)
    y += int(f2.size * 0.7)
    for line in wrap(d, body, f2, W - 2 * margin):
        d.text(((W - d.textlength(line, font=f2)) / 2, y), line, font=f2, fill=GREY)
        y += int(f2.size * 1.3)
    top = y + int(H * 0.03)
    phone = device(screen, H - top - int(H * 0.035), ios)
    if phone.width > W - 2 * margin:  # a very short headline would make the phone too wide
        phone = device(screen, round(phone.height * (W - 2 * margin) / phone.width), ios)
    x = (W - phone.width) // 2
    glow = Image.new("RGBA", (phone.width + 200, phone.height + 200), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((100, 90, phone.width + 100, phone.height + 100), radius=160, fill=(247, 147, 26, 38))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(60)), (x - 100, top - 100))
    canvas.alpha_composite(phone, (x, top))
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


# ---------------------------------------------------------------- outputs

def golden(device_name: str, scene: str) -> Image.Image:
    return Image.open(GOLDENS / device_name / f"{scene}.png")


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


def write_website() -> None:
    out = OUT / "website"
    (out / "img").mkdir(parents=True, exist_ok=True)
    for name, scene in WEBSITE.items():
        screen = android_screen(golden("pixel7", scene), width=1080)
        screen.save(out / f"{name}.png", optimize=True)
        for w in (480, 720):
            screen.resize((w, round(screen.height * w / screen.width)), Image.LANCZOS).save(
                out / "img" / f"{name}-{w}.webp", quality=88, method=6)
        print(f"wrote website/{name} ({screen.width}×{screen.height}) <- {scene}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fdroid", action="store_true", help="also refresh fastlane/metadata/android/en-US/images")
    args = ap.parse_args()

    for s in SHOTS:
        assert len(s.headline) <= MAX_HEADLINE, f"{s.slug}: headline {len(s.headline)} > {MAX_HEADLINE}"
        assert len(s.subline) <= MAX_SUBLINE, f"{s.slug}: subline {len(s.subline)} > {MAX_SUBLINE}"
    dirs = [OUT / "ios", OUT / "android", OUT / "device-only" / "ios", OUT / "device-only" / "android"]
    for d in dirs:
        d.mkdir(parents=True, exist_ok=True)
        for stale in d.glob("[0-9]*.png"):
            stale.unlink()
    print("font:", font_name())

    android_files: list[Path] = []
    ios_n = 0
    for i, shot in enumerate(SHOTS, start=1):
        nn = f"{i:02d}"
        a_screen = android_screen(golden("pixel7", shot.scene))
        out_android = OUT / "android" / f"{nn}-{shot.slug}.png"
        compose((1080, 1920), a_screen, False, shot.headline, shot.subline).save(out_android, optimize=True)
        device(a_screen, 1500, ios=False).save(OUT / "device-only" / "android" / f"{nn}-{shot.slug}.png", optimize=True)
        android_files.append(out_android)
        if not shot.android_only:
            ios_n += 1
            i_screen = ios_screen(golden("iphone69", shot.scene))
            name = f"{ios_n:02d}-{shot.slug}.png"
            compose((1320, 2868), i_screen, True, shot.headline, shot.subline).save(OUT / "ios" / name, optimize=True)
            device(i_screen, 2148, ios=True).save(OUT / "device-only" / "ios" / name, optimize=True)
        print(f"wrote {nn} {shot.slug:<17} <- {shot.scene:<21} {shot.headline!r}" + ("  (android only)" if shot.android_only else ""))
    feature = OUT / "android" / "feature-graphic.png"
    feature_graphic(Image.open(ICON)).save(feature, optimize=True)
    print("wrote android/feature-graphic.png")
    write_website()
    if args.fdroid:
        sync_fdroid(android_files, feature)


if __name__ == "__main__":
    main()
