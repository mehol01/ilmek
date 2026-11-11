"""App Store ekran görüntülerini çerçeveler (6,9" iPhone: 1320×2868).

Ham görüntüler: docs/screenshots/raw/01.png … (telefondan, `./deploy.sh --demo` ile açılan demo verisiyle;
                xcrun devicectl device capture screenshot --device <udid> --destination <dosya>)
Çıktı:         docs/screenshots/framed/01.png …

Her görüntüde: yeşil zemin (simgeyle aynı), üstte başlık, altta telefon ekranı (alt kenardan taşar).
Durum çubuğu temizlenir: saat 9:41, dolu pil. (Köktende'deki aracın uyarlaması.)

Kullanım: python3 -I tools/frame_screenshots.py          (Türkçe: raw → framed, framed-6.3)
          python3 -I tools/frame_screenshots.py en       (İngilizce: raw-en → framed-en, framed-en-6.3)
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
LANG = sys.argv[1] if len(sys.argv) > 1 else "tr"
SUFFIX = "" if LANG == "tr" else f"-{LANG}"
RAW = ROOT / f"docs/screenshots/raw{SUFFIX}"
OUT = ROOT / f"docs/screenshots/framed{SUFFIX}"
OUT_63 = ROOT / f"docs/screenshots/framed{SUFFIX}-6.3"   # 1206×2622 for the 6.1"/6.3" slot

W, H = 1320, 2868
TOP = (0x2F, 0x6A, 0x4C)
BOTTOM = (0x3E, 0x8E, 0x62)
FONT = "/System/Library/Fonts/SFNS.ttf"

CAPTIONS = {
    "01": "Alışkanlıklarını\ntek dokunuşla işaretle",
    "02": "Her gün bir ilmek,\nyıl sonunda atkın hazır",
    "03": "Serini ve ilerlemeni\nbir bakışta gör",
    "04": "Arkadaşlarınla\nbirlikte devam et",
    "05": "Ne paylaşacağını\nsen seçersin",
    "06": "Simgeni\nkendin seç",
}

CAPTIONS_EN = {
    "01": "Check off habits\nwith a single tap",
    "02": "One stitch a day,\na scarf by year's end",
    "03": "See your streaks\nand progress at a glance",
    "04": "Keep going\ntogether with friends",
    "05": "You choose\nwhat to share",
    "06": "Pick your\nown icon",
}
if LANG == "en":
    CAPTIONS = CAPTIONS_EN

WALLPAPER: set[str] = set()
ERASE_BELOW: dict[str, float] = {}

SHOT_W = 1100          # ekranın tuvaldeki genişliği
BEZEL = 22             # telefon kenarı
RADIUS = 120           # ekran köşe yarıçapı
SHOT_TOP = 640         # ekranın üst kenarı


def font(size: int, weight: str = "Bold") -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def gradient() -> Image.Image:
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def clean_status_bar(shot: Image.Image, wallpaper: bool = False) -> Image.Image:
    """Saati, sinyali ve pili siler; yerine 9:41 ve dolu pil çizer."""
    shot = shot.convert("RGB")
    w = shot.width
    scale = w / 1170
    bar_h = round(125 * scale)
    bg = shot.getpixel((w // 2, round(12 * scale)))
    dark = sum(bg) < 3 * 128
    ink = (255, 255, 255) if dark else (0, 0, 0)
    side = round(330 * scale)
    if wallpaper:
        strip = shot.crop((0, bar_h, w, 2 * bar_h)).transpose(Image.FLIP_TOP_BOTTOM).filter(ImageFilter.GaussianBlur(12 * scale))
        shot.paste(strip, (0, 0))
        bg = shot.getpixel((w // 2, round(60 * scale)))
        dark = sum(bg) < 3 * 128
        ink = (255, 255, 255) if dark else (0, 0, 0)
    draw = ImageDraw.Draw(shot)
    if not wallpaper:
        # Ortadaki Dynamic Island / çentik alanına dokunma; yalnız iki yanı temizle.
        draw.rectangle([0, 0, side, bar_h], fill=bg)
        draw.rectangle([w - side, 0, w, bar_h], fill=bg)
    f = font(round(52 * scale), "Semibold")
    draw.text((round(165 * scale), round(76 * scale)), "9:41", font=f, fill=ink, anchor="mm")
    # Pil: çerçeve + dolu iç + uç
    bx, by, bw, bh = w - round(160 * scale), round(58 * scale), round(76 * scale), round(36 * scale)
    draw.rounded_rectangle([bx, by, bx + bw, by + bh], radius=round(10 * scale), outline=ink, width=max(2, round(3 * scale)))
    pad = round(6 * scale)
    draw.rounded_rectangle([bx + pad, by + pad, bx + bw - pad, by + bh - pad], radius=round(5 * scale), fill=ink)
    draw.rounded_rectangle([bx + bw + round(4 * scale), by + round(12 * scale), bx + bw + round(9 * scale), by + bh - round(12 * scale)],
                           radius=2, fill=ink)
    return shot


def erase_below(shot: Image.Image, fraction: float) -> None:
    """Her satırı sol kenardaki zemin rengiyle boyar (dock ve sayfa noktaları gider)."""
    draw = ImageDraw.Draw(shot)
    for y in range(round(shot.height * fraction), shot.height):
        draw.line([(0, y), (shot.width, y)], fill=shot.getpixel((3, y)))


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def frame(key: str, path: Path) -> Path:
    canvas = gradient()
    draw = ImageDraw.Draw(canvas)

    # Başlık
    caption = CAPTIONS.get(key, "")
    size = 112
    while size > 70:
        f = font(size)
        box = draw.multiline_textbbox((0, 0), caption, font=f, spacing=size // 5, align="center")
        if box[2] - box[0] <= W - 160:
            break
        size -= 4
    draw.multiline_text((W // 2, 360), caption, font=f, fill="white", anchor="mm", align="center", spacing=size // 5)

    # Telefon ekranı
    shot = clean_status_bar(Image.open(path), wallpaper=key in WALLPAPER)
    if key in ERASE_BELOW:
        erase_below(shot, ERASE_BELOW[key])
    shot_h = round(shot.height * SHOT_W / shot.width)
    shot = shot.resize((SHOT_W, shot_h), Image.LANCZOS)
    x = (W - SHOT_W) // 2

    phone = (SHOT_W + 2 * BEZEL, shot_h + 2 * BEZEL)
    px, py = x - BEZEL, SHOT_TOP - BEZEL

    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([px, py + 30, px + phone[0], py + phone[1] + 30], radius=RADIUS + BEZEL, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas.paste((0x12, 0x2E, 0x20), (0, 0), shadow)

    body = Image.new("RGB", phone, (0x12, 0x12, 0x12))
    canvas.paste(body, (px, py), rounded_mask(phone, RADIUS + BEZEL))
    canvas.paste(shot, (x, SHOT_TOP), rounded_mask(shot.size, RADIUS))

    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"{key}.png"
    canvas.save(out, optimize=True)
    OUT_63.mkdir(parents=True, exist_ok=True)
    canvas.resize((1206, 2622), Image.LANCZOS).save(OUT_63 / f"{key}.png", optimize=True)
    return out


def main() -> None:
    shots = sorted(RAW.glob("*.png"))
    if not shots:
        raise SystemExit(f"Ham görüntü yok: {RAW}")
    for path in shots:
        print(frame(path.stem[:2], path).relative_to(ROOT))


if __name__ == "__main__":
    main()
