#!/system/bin/sh
# Browser workspace (RAM/tmpfs) + load profile persisten
# Dipanggil otomatis oleh browser_start.sh, bisa juga manual.

WORK="/tmp/w3m"
PERSIST="/sdcard/.browser_profile"

mkdir -p "$WORK" 2>/dev/null

# Pastikan workspace benar-benar di RAM (tmpfs).
# Catatan: /tmp di recovery biasanya sudah tmpfs; mount di atasnya juga aman.
if ! mount 2>/dev/null | grep " on $WORK " >/dev/null 2>&1; then
    mount -t tmpfs -o size=192m,mode=777 tmpfs "$WORK" 2>/dev/null
fi

mkdir -p "$WORK/tmp" 2>/dev/null

# Load profile persisten (cookie/bookmark/history) jika sudah ada
if [ -d "$PERSIST" ]; then
    cp -a "$PERSIST/." "$WORK/" 2>/dev/null
fi

# Bookmark default (hanya dibuat sekali)
if [ ! -f "$WORK/bookmark.html" ]; then
    cat > "$WORK/bookmark.html" << 'EOF'
<title>Bookmarks</title>
<h1>Bookmarks</h1>
<ul>
<li><a href="https://duckduckgo.com/">DuckDuckGo</a></li>
<li><a href="https://en.wikipedia.org/">Wikipedia</a></li>
</ul>
EOF
fi

echo "browser: workspace siap di $WORK (RAM)"
