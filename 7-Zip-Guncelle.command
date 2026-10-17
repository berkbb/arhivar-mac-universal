#!/bin/bash
# Finder'da çift tıklayınca projedeki 7-Zip'i (Vendor/7-Zip) ve varsa derlenmiş
# build/Arhivar.app içindeki 7-Zip'i GitHub'daki son sürüme günceller.
cd "$(dirname "$0")" || exit 1
TARGETS=(--dest "$(pwd)/Vendor/7-Zip")
if [ -d build/Arhivar.app ]; then TARGETS+=(--app "$(pwd)/build/Arhivar.app"); fi
./Scripts/update-7zip.sh install "${TARGETS[@]}" "$@"
STATUS=$?
echo
read -r -p "Kapatmak için Enter'a basın…" _
exit $STATUS
