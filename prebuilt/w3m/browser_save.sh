#!/system/bin/sh
# Simpan profile browser dari RAM (tmpfs) ke penyimpanan (persistent)

WORK="/tmp/w3m"
PERSIST="/sdcard/.browser_profile"

if [ ! -d "$WORK" ]; then
    echo "browser: workspace $WORK tidak ada, tidak ada yang disimpan"
    exit 1
fi

mkdir -p "$PERSIST" 2>/dev/null
if [ ! -d "$PERSIST" ]; then
    echo "browser: GAGAL membuat $PERSIST - data sudah di-decrypt di TWRP?"
    exit 1
fi

if cp -a "$WORK/." "$PERSIST/" 2>/dev/null; then
    echo "browser: profile tersimpan di $PERSIST"
else
    echo "browser: GAGAL menulis ke $PERSIST"
    exit 1
fi
