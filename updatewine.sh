#!/bin/bash
# =====================================================================
#  Install WineHQ terbaru + corefonts, vcrun2022, dotnet48, WebView2
#  + double-click file .ex5/.mq5 langsung masuk ke MetaTrader (mt5-open)
#  Mendukung Debian / Ubuntu / turunan Ubuntu (Mint, Pop!_OS, dll.)
#  Jalankan sebagai user biasa:  bash updatewine.sh
# =====================================================================

# Cabang WineHQ: devel = versi terbaru, stable = versi stabil
WINE_BRANCH="${WINE_BRANCH:-devel}"

set -uo pipefail

if [[ "$EUID" -eq 0 ]]; then
    echo "ERROR: Jangan jalankan dengan sudo. Jalankan: bash updatewine.sh"
    exit 1
fi

# ---------------------------------------------------------------------
# Deteksi distro
# ---------------------------------------------------------------------
source /etc/os-release
if [[ "$ID" == "debian" ]]; then
    DISTRO="debian"; CODENAME="$VERSION_CODENAME"
elif [[ "$ID" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* ]]; then
    DISTRO="ubuntu"; CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
else
    echo "ERROR: Distro tidak didukung ($ID)."
    exit 1
fi
echo "Distro: $DISTRO $CODENAME | Wine: winehq-$WINE_BRANCH"

# ---------------------------------------------------------------------
# 1. Tutup Wine & hapus prefix lama
# ---------------------------------------------------------------------
wineserver -k 2>/dev/null || true
sleep 2
rm -rf ~/.wine

# ---------------------------------------------------------------------
# 2. Hapus paket Wine lama (repo distro maupun WineHQ)
# ---------------------------------------------------------------------
sudo apt-get remove --purge -y 'wine*' 'libwine*' 'winehq*' 'fonts-wine' || true
sudo apt-get autoremove -y

# ---------------------------------------------------------------------
# 3. Tambah repository WineHQ resmi
# ---------------------------------------------------------------------
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y wget ca-certificates cabextract unzip p7zip-full xz-utils zenity

sudo mkdir -pm755 /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
sudo rm -f /etc/apt/sources.list.d/winehq-*.sources
if ! sudo wget -qNP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/$DISTRO/dists/$CODENAME/winehq-$CODENAME.sources"; then
    echo "ERROR: WineHQ belum menyediakan repo untuk $DISTRO $CODENAME."
    exit 1
fi

# ---------------------------------------------------------------------
# 4. Install WineHQ terbaru
# ---------------------------------------------------------------------
sudo apt-get update
if ! sudo apt-get install -y --install-recommends "winehq-$WINE_BRANCH"; then
    echo "ERROR: Gagal menginstal winehq-$WINE_BRANCH."
    exit 1
fi
hash -r
wine --version

# ---------------------------------------------------------------------
# 5. Winetricks terbaru
# ---------------------------------------------------------------------
WORK="$HOME/.cache/wine-setup"
LOG="$WORK/setup-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$WORK" && cd "$WORK" || exit 1

wget -qO winetricks https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks
chmod +x winetricks

export WINEPREFIX="$HOME/.wine"
export WINEARCH=win64
export WINEDEBUG=-all

# Tunggu Wine selesai, tapi jangan menunggu selamanya
wait_wine() {
    if ! timeout "${1:-120}" wineserver -w; then
        echo "    (proses background Wine masih aktif, dihentikan paksa)"
        wineserver -k
        sleep 2
    fi
}

FAILED=()
run() {
    echo "=== $* ===" | tee -a "$LOG"
    if "$@" >>"$LOG" 2>&1; then echo "    -> OK"; else echo "    -> GAGAL"; FAILED+=("$*"); fi
    wait_wine 120
}

# ---------------------------------------------------------------------
# 6. Buat prefix & install komponen
# ---------------------------------------------------------------------
echo "=== Membuat prefix baru ==="
wineboot -i >>"$LOG" 2>&1
wait_wine 120

run ./winetricks -q corefonts
run ./winetricks -q vcrun2022
echo "(dotnet48 bisa 10-20 menit, jangan tutup jendela yang muncul)"
run ./winetricks -q dotnet48
run ./winetricks -q win10

# WebView2 langsung dari Microsoft (lebih andal dari verb winetricks)
# Tidak lewat run(): installer meninggalkan layanan Edge Update yang tidak
# pernah berhenti, jadi menunggu wineserver idle di sini percuma.
echo "=== Instal WebView2 Runtime ===" | tee -a "$LOG"
if wget -qO webview2.exe "https://go.microsoft.com/fwlink/?linkid=2124701"; then
    if wine webview2.exe /silent /install >>"$LOG" 2>&1; then
        echo "    -> OK"
    else
        echo "    -> GAGAL"; FAILED+=("install webview2")
    fi
else
    echo "    -> GAGAL mengunduh"; FAILED+=("download webview2")
fi


# ---------------------------------------------------------------------
# 6b. Launcher mt5-open: double-click .ex5/.mq5 -> MetaTrader yang tepat
#     - dari Data Folder sebuah terminal -> otomatis ke terminal itu
#     - dari folder lain               -> dialog pilih terminal
# ---------------------------------------------------------------------
echo "=== Memasang launcher mt5-open ==="
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
MIME="$HOME/.local/share/mime"
mkdir -p "$BIN" "$APPS" "$MIME/packages"

cat > "$BIN/mt5-open" <<'LAUNCHER'
#!/bin/bash
# mt5-open: buka file MQL di MetaTrader yang dipilih
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export WINEDEBUG=-all
DC="$WINEPREFIX/drive_c"

err() { zenity --error --title="MT5 Open" --text="$1" 2>/dev/null || echo "$1" >&2; exit 1; }

[[ $# -ge 1 ]] || err "Tidak ada file yang dibuka."
command -v wine >/dev/null || err "Wine tidak ditemukan."

ARG="$1"
# Dipanggil dari Wine (Explorer / Open Data Folder) -> path Windows
if [[ "$ARG" =~ ^[A-Za-z]:\\ ]]; then
    ARG="$(winepath -u "$ARG" 2>/dev/null)"
fi
FILE="$(readlink -f "$ARG")"
[[ -f "$FILE" ]] || err "File tidak ditemukan:\n$1"
EXT="${FILE##*.}"; EXT="${EXT,,}"

# Tentukan jenis terminal & program yang dipakai
case "$EXT" in
    ex5)          EXE=terminal64.exe;    GEN=5 ;;
    mq5|mqh)      EXE=MetaEditor64.exe;  GEN=5 ;;
    ex4)          EXE=terminal.exe;      GEN=4 ;;
    mq4)          EXE=metaeditor.exe;    GEN=4 ;;
    *)            err "Jenis file .$EXT tidak didukung." ;;
esac

# Cari semua instalasi MetaTrader di prefix
NAMES=(); DIRS=()
shopt -s nullglob nocaseglob
if [[ $GEN == 5 ]]; then
    CANDS=("$DC/Program Files/"*/terminal64.exe)
else
    CANDS=("$DC/Program Files (x86)/"*/terminal.exe "$DC/Program Files/"*/terminal.exe)
fi
shopt -u nocaseglob
for t in "${CANDS[@]}"; do
    d="$(dirname "$t")"
    # .mqh boleh dibuka MetaEditor MT5 mana pun; pastikan programnya ada
    p=( "$d"/"$EXE" ); [[ -e "${p[0]}" ]] || continue
    DIRS+=("$d"); NAMES+=("$(basename "$d")")
done
shopt -u nullglob

(( ${#DIRS[@]} )) || err "Tidak ada MetaTrader $GEN di:\n$WINEPREFIX"

# Mana yang sedang berjalan?
RUNNING=()
for i in "${!DIRS[@]}"; do
    pgrep -f "${NAMES[$i]}\\\\terminal" >/dev/null && RUNNING+=("$i")
done

# Apakah file berada di Data Folder milik terminal tertentu?
#  - mode portable / Program Files : folder induk berisi terminal64.exe
#  - mode AppData                  : folder induk berisi origin.txt (path instalasi)
OWNER=""
d="$(dirname "$FILE")"
while [[ "$d" != "/" && -z "$OWNER" ]]; do
    if [[ -f "$d/origin.txt" ]]; then
        o="$(iconv -f UTF-16LE -t UTF-8 "$d/origin.txt" 2>/dev/null | tr -d '\r\n\357\273\277')"
        [[ -n "$o" ]] && OWNER="$(readlink -f "$(winepath -u "$o" 2>/dev/null)")"
    elif [[ -f "$d/terminal64.exe" || -f "$d/terminal.exe" ]]; then
        OWNER="$(readlink -f "$d")"
    fi
    d="$(dirname "$d")"
done

# Pilih target
SEL=()
if [[ -n "$OWNER" ]]; then
    for i in "${!DIRS[@]}"; do
        [[ "$(readlink -f "${DIRS[$i]}")" == "$OWNER" ]] && SEL=("$i")
    done
fi
if (( ${#SEL[@]} )); then
    :   # pemilik folder ditemukan -> langsung, tanpa dialog
elif (( ${#DIRS[@]} == 1 )); then
    SEL=(0)
elif (( ${#RUNNING[@]} == 1 )) && [[ $EXT == ex? ]]; then
    SEL=("${RUNNING[0]}")
else
    ROWS=()
    for i in "${!DIRS[@]}"; do
        st=""; for r in "${RUNNING[@]}"; do [[ $r == "$i" ]] && st="berjalan"; done
        ROWS+=("$((i+1))" "${NAMES[$i]}" "$st")
    done
    [[ $EXT == ex? ]] && ROWS+=("all" "Semua terminal" "")
    CH="$(zenity --list --title="MT5 Open" \
        --text="Buka <b>$(basename "$FILE")</b> di:" \
        --column="No" --column="MetaTrader" --column="Status" \
        --hide-column=1 --print-column=1 --width=420 --height=320 \
        "${ROWS[@]}" 2>/dev/null)" || exit 0
    [[ -n "$CH" ]] || exit 0
    if [[ $CH == all ]]; then SEL=("${!DIRS[@]}"); else SEL=("$((CH-1))"); fi
fi

WFILE="$(winepath -w "$FILE" 2>/dev/null)"
for i in "${SEL[@]}"; do
    WEXE="$(winepath -w "${DIRS[$i]}/$EXE" 2>/dev/null)"
    nohup wine "$WEXE" "$WFILE" >/dev/null 2>&1 &
    sleep 1
done
LAUNCHER
chmod +x "$BIN/mt5-open"

# Asosiasi di file manager Linux
cat > "$MIME/packages/mql.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-mql-ex5"><comment>MetaTrader 5 program</comment><glob pattern="*.ex5" weight="90"/></mime-type>
  <mime-type type="application/x-mql-ex4"><comment>MetaTrader 4 program</comment><glob pattern="*.ex4" weight="90"/></mime-type>
  <mime-type type="text/x-mql5"><sub-class-of type="text/plain"/><comment>MQL5 source</comment><glob pattern="*.mq5" weight="90"/></mime-type>
  <mime-type type="text/x-mql4"><sub-class-of type="text/plain"/><comment>MQL4 source</comment><glob pattern="*.mq4" weight="90"/></mime-type>
  <mime-type type="text/x-mqh"><sub-class-of type="text/plain"/><comment>MQL include</comment><glob pattern="*.mqh" weight="90"/></mime-type>
</mime-info>
XML
update-mime-database "$MIME" >/dev/null 2>&1

cat > "$APPS/mt5-open.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MetaTrader (pilih terminal)
Exec=$BIN/mt5-open %f
Icon=wine
Terminal=false
NoDisplay=true
MimeType=application/x-mql-ex5;application/x-mql-ex4;text/x-mql5;text/x-mql4;text/x-mqh;
EOF
for t in application/x-mql-ex5 application/x-mql-ex4 text/x-mql5 text/x-mql4 text/x-mqh; do
    xdg-mime default mt5-open.desktop "$t" 2>/dev/null
done
# Asosiasi Wine lama (dari prefix yang sudah dihapus) -> sumber error "no Windows program"
for e in ex5 ex4 mq5 mq4 mqh; do
    [[ -f "$APPS/wine-extension-$e.desktop" ]] && mv -f "$APPS/wine-extension-$e.desktop" "$APPS/wine-extension-$e.desktop.bak"
done
update-desktop-database "$APPS" >/dev/null 2>&1
echo "    -> $BIN/mt5-open"

# ---------------------------------------------------------------------
# 7. Konfigurasi WebView2 agar jalan di Wine (fix tab Market MetaTrader)
# ---------------------------------------------------------------------
echo "=== Konfigurasi WebView2 & asosiasi file untuk Wine ==="

# Command untuk Explorer Wine (Open Data Folder): Wine bisa menjalankan
# launcher Linux langsung. ProgID mengikuti nama yang dipakai installer MT
# (EX5.File, dst.), jadi saat MT diinstal nanti perintahnya sudah tersedia.
MT5_OPEN_W="$(winepath -w "$BIN/mt5-open" 2>/dev/null)"
MT5_OPEN_ESC="${MT5_OPEN_W//\\/\\\\}"

WV2_ARGS="--no-sandbox --disable-gpu --disable-gpu-compositing --disable-direct-composition --disable-features=CalculateNativeWinOcclusion"
WV2_KEY='Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments'

# Semua setting ditulis dalam satu file .reg -> satu kali start Wine
REGFILE="$WORK/webview2-wine.reg"
{
    echo 'REGEDIT4'
    echo
    echo '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\edgeupdate]'
    echo '"Start"=dword:00000004'
    echo
    echo '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\edgeupdatem]'
    echo '"Start"=dword:00000004'
    echo
    echo '[HKEY_CURRENT_USER\Software\Wine]'
    echo '"Version"="win10"'
    for HIVE in HKEY_CURRENT_USER HKEY_LOCAL_MACHINE; do
        echo
        echo "[$HIVE\\$WV2_KEY]"
        for APP in terminal64.exe terminal.exe metaeditor64.exe; do
            echo "\"$APP\"=\"$WV2_ARGS\""
        done
    done
    for e in "ex5:EX5.File:MQL5 Program" "ex4:EX4.File:MQL4 Program" \
             "mq5:MQ5.File:MQL5 Source"  "mq4:MQ4.File:MQL4 Source" \
             "mqh:MQH.File:MQL Include"; do
        IFS=: read -r ext progid desc <<< "$e"
        echo
        echo "[HKEY_CLASSES_ROOT\\.$ext]"
        echo "@=\"$progid\""
        echo
        echo "[HKEY_CLASSES_ROOT\\$progid]"
        echo "@=\"$desc\""
        echo
        echo "[HKEY_CLASSES_ROOT\\$progid\\shell\\open\\command]"
        echo "@=\"\\\"$MT5_OPEN_ESC\\\" \\\"%1\\\"\""
    done
} > "$REGFILE"

# Ulangi sampai layanan Edge Update benar-benar mati dan registry tersimpan.
# Wine baru dianggap selesai bila wineserver bisa keluar normal (= registry tersimpan).
WV2_POLICY="tidak tersimpan"
for attempt in 1 2 3; do
    echo "    Percobaan $attempt: menghentikan Edge Update & menulis registry..."
    wineserver -k 2>/dev/null; sleep 2
    wine regedit /S "$(winepath -w "$REGFILE")" >>"$LOG" 2>&1
    if timeout 30 wineserver -w; then
        if wine reg query "HKCU\\$WV2_KEY" /v terminal64.exe >>"$LOG" 2>&1; then
            WV2_POLICY="OK"
            timeout 30 wineserver -w || wineserver -k
            break
        fi
    fi
done
echo "    -> Argumen WebView2: $WV2_POLICY"

if wine reg query 'HKCR\EX5.File\shell\open\command' 2>/dev/null | grep -q mt5-open; then
    ASSOC="OK"
else
    ASSOC="tidak tersimpan"; FAILED+=("asosiasi file .ex5")
fi
timeout 30 wineserver -w 2>/dev/null || wineserver -k
[[ "$WV2_POLICY" == "OK" ]] || FAILED+=("registry argumen webview2")

# ---------------------------------------------------------------------
# Ringkasan
# ---------------------------------------------------------------------
WV2_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
WV2_VER="$(ls "$WV2_DIR" 2>/dev/null | grep -E '^[0-9]+\.' | sort -V | tail -n1)"
[[ -n "$WV2_VER" ]] || FAILED+=("verifikasi webview2")

echo ""
echo "===================================="
echo " SELESAI"
echo "===================================="
echo "Wine     : $(wine --version)"
echo "WebView2 : ${WV2_VER:-tidak terdeteksi}"
echo "Argumen  : $WV2_POLICY (MetaTrader WebView2)"
echo "Asosiasi : $ASSOC (.ex5/.mq5 -> mt5-open)"
echo "Log      : $LOG"
if (( ${#FAILED[@]} )); then
    echo "GAGAL:"; printf '  - %s\n' "${FAILED[@]}"
    exit 2
fi
echo "Semua komponen terpasang."