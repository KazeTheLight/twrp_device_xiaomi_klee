#!/system/bin/sh
# w3m browser untuk recovery (OrangeFox/TWRP) - jalan di RAM, profile persisten
# Pemakaian : browser_start.sh [url]
# Contoh    : browser_start.sh https://duckduckgo.com/
#             browser_start.sh file:///sdcard/README.html
# Kalo "bad interpreter": jalankan dengan  sh /system/bin/browser_start.sh

# Siapkan workspace RAM + load profile persisten
sh /system/bin/browser_ramdisk.sh || exit 1

WORK="/tmp/w3m"
CFG="$WORK/w3mconfig"

# Konfigurasi w3m (dibuat sekali, lalu ikut tersimpan di profile)
if [ ! -f "$CFG" ]; then
    cat > "$CFG" << 'EOF'
use_cookie
auto_save cookies
cookie_file /tmp/w3m/cookie
cookie_reject /tmp/w3m/cookie_reject
bookmark /tmp/w3m/bookmark.html
display_charset UTF-8
document_charset UTF-8
EOF
fi

export HOME="$WORK"
export TMPDIR="$WORK/tmp"
export TERM="${TERM:-xterm}"
export TERMINFO="/system/usr/share/terminfo"
export SSL_CERT_FILE="/system/etc/w3m/cert.pem"
export SSL_CERT_DIR=""

# Cek jaringan (offline-safe)
NET=0
if ip route 2>/dev/null | grep default >/dev/null 2>&1; then
    NET=1
else
    echo "browser: mode OFFLINE (tidak ada route jaringan)."
    echo "browser: Internet butuh WiFi/USB network recovery (fase 2)."
    echo ""
fi

# Default halaman: online -> search engine, offline -> halaman sambutan lokal
if [ $# -eq 0 ]; then
    if [ "$NET" -eq 1 ]; then
        set -- https://duckduckgo.com/
    else
        set -- "file:///tmp/w3m/welcome.html"
    fi
fi

/system/bin/w3m -config "$CFG" -bookmark "$WORK/bookmark.html" "$@"
RET=$?

# Auto-save profile setiap selesai browsing (persistent)
sh /system/bin/browser_save.sh

exit $RET
