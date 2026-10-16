#!/bin/bash
# =====================================================================
#  Install WineHQ terbaru + corefonts, vcrun2022, dotnet48, WebView2
#  Mendukung Debian / Ubuntu / turunan Ubuntu (Mint, Pop!_OS, dll.)
#  Jalankan sebagai user biasa:  ./install-winehq.sh
# =====================================================================

# Cabang WineHQ: devel = versi terbaru, stable = versi stabil
WINE_BRANCH="${WINE_BRANCH:-devel}"

set -uo pipefail

if [[ "$EUID" -eq 0 ]]; then
    echo "ERROR: Jangan jalankan dengan sudo. Jalankan: ./install-winehq.sh"
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
sudo apt-get install -y wget ca-certificates cabextract unzip p7zip-full xz-utils

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
    timeout "${1:-120}" wineserver -w || { wineserver -k; sleep 2; }
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
if wget -qO webview2.exe "https://go.microsoft.com/fwlink/?linkid=2124701"; then
    run wine webview2.exe /silent /install
else
    FAILED+=("download webview2")
fi
wineserver -k; sleep 2   # hentikan layanan Edge Update yang dijalankan installer

# ---------------------------------------------------------------------
# 7. Konfigurasi WebView2 agar jalan di Wine (fix tab Market MetaTrader)
# ---------------------------------------------------------------------
for svc in edgeupdate edgeupdatem; do
    wine reg add "HKLM\\System\\CurrentControlSet\\Services\\$svc" /v Start /t REG_DWORD /d 4 /f >>"$LOG" 2>&1
done
wine reg add 'HKCU\Software\Wine' /v Version /d win10 /f >>"$LOG" 2>&1

WV2_ARGS="--no-sandbox --disable-gpu --disable-gpu-compositing --disable-direct-composition --disable-features=CalculateNativeWinOcclusion"
for HIVE in HKCU HKLM; do
    for APP in terminal64.exe terminal.exe metaeditor64.exe; do
        wine reg add "$HIVE\\Software\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments" \
            /v "$APP" /d "$WV2_ARGS" /f >>"$LOG" 2>&1
    done
done
wait_wine 60

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
echo "Log      : $LOG"
if (( ${#FAILED[@]} )); then
    echo "GAGAL:"; printf '  - %s\n' "${FAILED[@]}"
    exit 2
fi
echo "Semua komponen terpasang."
