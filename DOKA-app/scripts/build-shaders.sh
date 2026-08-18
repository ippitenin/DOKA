#!/bin/bash
# Компиляция Metal-шейдеров панели записи в default.metallib.
#
# Зачем отдельный скрипт: SwiftPM .metal НЕ компилирует (кладёт файл в бандл
# как есть), а build-tool-плагин SPM ломает universal-сборку
# (`swift build --arch arm64 --arch x86_64` падает на резолве плагин-таргета).
# Поэтому metallib собирается заранее и попадает в бандл обычным ресурсом:
# `.process("Resources")` кладёт его в DOKA_DOKA.bundle, откуда build.sh
# забирает бандл своим циклом `*.bundle` — правок в build.sh не нужно.
#
# Файл сгенерированный, в git не хранится (см. .gitignore). После правки
# любого .metal скрипт надо прогнать заново, иначе `swift build` соберёт
# приложение со СТАРЫМ шейдером (или вовсе без него — панель покажет
# капсулу без эффекта и напишет об этом в лог).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Sources/DOKA/Resources/default.metallib"
SRC=(Shaders/*.metal)

echo "==> Компиляция шейдеров: ${SRC[*]} → $OUT"
xcrun -sdk macosx metal -O -o "$OUT" "${SRC[@]}"
echo "    Готово: $(du -h "$OUT" | cut -f1)"
