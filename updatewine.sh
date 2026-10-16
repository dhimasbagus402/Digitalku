#!/bin/bash
# =====================================================================
#  Install WineHQ terbaru + corefonts, vcrun2022, dotnet48, WebView2
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
# 7. Konfigurasi WebView2 agar jalan di Wine (fix tab Market MetaTrader)
# ---------------------------------------------------------------------
echo "=== Konfigurasi WebView2 untuk Wine ==="

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
echo "Log      : $LOG"
if (( ${#FAILED[@]} )); then
    echo "GAGAL:"; printf '  - %s\n' "${FAILED[@]}"
    exit 2
fi
echo "Semua komponen terpasang."
