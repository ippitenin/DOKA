#!/bin/bash
# Генерация Resources/AppIcon.icns из квадратного PNG с альфой.
# Использование: scripts/make-appicon.sh [исходник.png]
# По умолчанию исходник — Resources/AppIcon.png.
#
# Поля по сетке macOS-иконок: контент 822/1024 (~80% холста) со скруглением
# ~22,5% стороны — иначе иконка выглядит «переростком» рядом с системными.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-Resources/AppIcon.png}"
OUT="Resources/AppIcon.icns"
[ -f "$SRC" ] || { echo "Исходник не найден: $SRC"; exit 1; }

TMP="$(mktemp -d /tmp/doka-icon.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/master_1024.png"

# Мастер: скруглённый квадрат 822pt по центру прозрачного холста 1024.
# sips не умеет прозрачные поля и скругление — рисуем через CoreGraphics.
swift - "$SRC" "$MASTER" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let canvas: CGFloat = 1024, content: CGFloat = 822
let corner: CGFloat = content * 0.225   // радиус сетки Apple (~185/824)
guard let img = NSImage(contentsOfFile: args[1]) else { exit(1) }
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset = (canvas - content) / 2
let rect = NSRect(x: inset, y: inset, width: content, height: content)
NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
SWIFT

ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
echo "Готово: $OUT"
