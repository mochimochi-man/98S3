#!/usr/bin/env bash
# Flash the firmware.
# Usage: ./flash.sh [PORT]     (default port: /dev/ttyUSB0)
#
# The port is the one of the board's serial (UART) USB socket. idf.py takes the
# flash mode and the offsets from sdkconfig, so this writes the bootloader, the
# partition table and the app together.
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-/dev/ttyUSB0}"

if ! command -v idf.py >/dev/null 2>&1; then
  for e in "$IDF_PATH/export.sh" "$HOME/esp/esp-idf-v5.5/export.sh" "$HOME/esp/esp-idf/export.sh"; do
    if [ -f "$e" ]; then . "$e" >/dev/null; break; fi
  done
fi
if ! command -v idf.py >/dev/null 2>&1; then
  echo "ERROR: ESP-IDF not found. Run: . \$HOME/esp/esp-idf-v5.5/export.sh" >&2
  exit 1
fi

idf.py -p "$PORT" flash
