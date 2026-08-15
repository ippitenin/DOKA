#!/bin/bash
# Сборка и запуск DOKA.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
open "${DOKA_INSTALL_DIR:-$HOME/Applications}/DOKA.app"
