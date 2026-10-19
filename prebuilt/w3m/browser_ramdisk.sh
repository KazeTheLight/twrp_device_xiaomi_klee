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

# Halaman sambutan - selalu diregenerasi (bukan data user)
cat > "$WORK/welcome.html" << 'EOF'
<title>Welcome - w3m recovery</title>
<h1>w3m di recovery (mode RAM)</h1>
<p>Workspace: /tmp/w3m (tmpfs) - Profile: /sdcard/.browser_profile</p>
<h2>Tombol penting</h2>
<ul>
<li><b>o</b> - buka URL/path (contoh: o file:///sdcard/)</li>
<li><b>v</b> - bookmark</li>
<li><b>b</b> - back</li>
<li><b>h</b> - bantuan</li>
<li><b>q</b> - keluar (profile otomatis tersimpan)</li>
</ul>
<h2>Coba</h2>
<ul>
<li><a href="file:///sdcard/">Isi /sdcard</a></li>
<li><a href="file:///tmp/w3m/bookmark.html">Bookmark</a></li>
</ul>
<p><i>Mode offline: aktifkan jaringan recovery (fase 2) buat browsing internet.</i></p>
EOF

echo "browser: workspace siap di $WORK (RAM)"
