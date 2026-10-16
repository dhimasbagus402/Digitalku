#!/usr/bin/env bash
# =====================================================================
#  DIGIOS - WINEHQ FRESH INSTALLER + WEBVIEW2
#  Target : Debian 13 Trixie
#  Cara pakai : ./updatewine.sh   (JANGAN pakai sudo, script akan
#               meminta password sudo sendiri untuk bagian sistem)
# =====================================================================

if [[ "$EUID" -eq 0 ]]; then
    echo "ERROR: Jangan jalankan dengan sudo/root."
    echo "Jalankan: ./updatewine.sh"
    exit 1
fi

# =====================================================================
#  BAGIAN 1 - SISTEM (root)
# =====================================================================
sudo bash <<'EOF'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "===================================="
echo " DIGIOS - WINEHQ FRESH INSTALLER"
echo "===================================="

# 1. Validasi sistem
source /etc/os-release

if [[ "$ID" != "debian" || "$VERSION_CODENAME" != "trixie" ]]; then
    echo "ERROR: Script hanya untuk Debian 13 Trixie."
    exit 1
fi

USER_NAME="${SUDO_USER:-}"

if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
    echo "ERROR: Jalankan dari akun admin dengan sudo."
    exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_UID="$(id -u "$USER_NAME")"

if [[ -z "$USER_HOME" || "$USER_HOME" == "/" ]]; then
    echo "ERROR: Direktori HOME tidak valid."
    exit 1
fi

# 2. Tutup paksa proses Wine
echo "=== Menghentikan seluruh aplikasi Wine ==="

get_wine_pids() {
    local pid comm exe

    while read -r pid comm; do
        [[ -n "${pid:-}" ]] || continue

        exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"

        if [[ "$comm" == "wineserver" ]] ||
           [[ "$comm" == "winedbg" ]] ||
           [[ "$comm" == "wineboot" ]] ||
           [[ "$comm" == "wine-preloader" ]] ||
           [[ "$comm" == "wine64-preloader" ]] ||
           [[ "$comm" == *.exe ]] ||
           [[ "$exe" == /opt/wine-*/bin/* ]] ||
           [[ "$exe" == /usr/lib/wine/* ]]; then
            echo "$pid"
        fi
    done < <(ps -u "$USER_UID" -o pid=,comm=)
}

mapfile -t WINE_PIDS < <(get_wine_pids)

if (( ${#WINE_PIDS[@]} > 0 )); then
    echo "Menutup ${#WINE_PIDS[@]} proses Wine..."

    kill -TERM "${WINE_PIDS[@]}" 2>/dev/null || true
    sleep 3

    mapfile -t REMAINING_PIDS < <(get_wine_pids)

    if (( ${#REMAINING_PIDS[@]} > 0 )); then
        echo "Memaksa proses Wine yang masih aktif berhenti..."
        kill -KILL "${REMAINING_PIDS[@]}" 2>/dev/null || true
    fi

    sleep 2
else
    echo "Tidak ditemukan proses Wine aktif."
fi

mapfile -t STILL_RUNNING < <(get_wine_pids)

if (( ${#STILL_RUNNING[@]} > 0 )); then
    echo "ERROR: Masih terdapat proses Wine aktif."
    exit 1
fi

echo "Semua proses Wine yang terdeteksi telah dihentikan."

# 3. Persiapan repository + dependencies winetricks
echo "=== Menyiapkan dependencies ==="

dpkg --add-architecture i386

# Nonaktifkan konfigurasi WineHQ lama jika ada
rm -f /etc/apt/sources.list.d/winehq-trixie.sources

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    cabextract \
    unzip \
    p7zip-full \
    xz-utils

# 4. Instal GPG key WineHQ
echo "=== Menambahkan GPG WineHQ ==="

install -d -m 0755 /etc/apt/keyrings

curl -fsSL \
    https://dl.winehq.org/wine-builds/winehq.key \
    | gpg --batch --yes --dearmor \
    -o /etc/apt/keyrings/winehq-archive.gpg

chmod 644 /etc/apt/keyrings/winehq-archive.gpg

# 5. Repository WineHQ Debian 13
echo "=== Menambahkan repository WineHQ ==="

cat > /etc/apt/sources.list.d/winehq-trixie.sources <<'SOURCE'
Types: deb
URIs: https://dl.winehq.org/wine-builds/debian
Suites: trixie
Components: main
Architectures: amd64 i386
Signed-By: /etc/apt/keyrings/winehq-archive.gpg
SOURCE

apt-get update

# 6. Memeriksa Wine Development
echo "=== Memeriksa WineHQ Development terbaru ==="

CANDIDATE="$(apt-cache policy winehq-devel | awk '/Candidate:/ {print $2; exit}')"

if [[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]]; then
    INSTALL_PACKAGE="winehq-devel"
else
    CANDIDATE="$(apt-cache policy wine-devel | awk '/Candidate:/ {print $2; exit}')"

    if [[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]]; then
        INSTALL_PACKAGE="wine-devel"
    else
        echo "ERROR: Wine Development tidak tersedia."
        exit 1
    fi
fi

echo "Paket: $INSTALL_PACKAGE"
echo "Versi: $CANDIDATE"

# 7. Hapus paket Wine lama
echo "=== Menghapus paket Wine lama ==="

mapfile -t WINE_PACKAGES < <(
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' |
    awk '$1 ~ /^ii/ && $2 ~ /^(wine|wine32|wine64|libwine|winehq|wine-stable|wine-devel|wine-staging)(:|-|$)/ {print $2}'
)

if (( ${#WINE_PACKAGES[@]} > 0 )); then
    apt-get purge -y "${WINE_PACKAGES[@]}"
else
    echo "Tidak ditemukan paket Wine lama."
fi

# 8. Instal Wine terbaru
echo "=== Menginstal WineHQ Development ==="

if [[ "$INSTALL_PACKAGE" == "winehq-devel" ]]; then
    apt-get install -y --install-recommends winehq-devel
else
    apt-get install -y --install-recommends \
        wine-devel \
        wine-devel-amd64 \
        wine-devel-i386:i386
fi

# 9. Verifikasi
echo "=== Memverifikasi instalasi ==="

WINE_BIN="/opt/wine-devel/bin/wine"

if [[ ! -x "$WINE_BIN" ]]; then
    echo "ERROR: Executable Wine tidak ditemukan."
    exit 1
fi

"$WINE_BIN" --version

# 10. Wine sebagai default
echo "=== Mengatur Wine default ==="

for cmd in wine wineboot winecfg wineserver; do
    if [[ -x "/opt/wine-devel/bin/$cmd" ]]; then
        ln -sfn "/opt/wine-devel/bin/$cmd" "/usr/local/bin/$cmd"
    fi
done

# 11. Pindahkan prefix lama ke backup (bukan dihapus permanen)
echo "=== Membackup prefix Wine lama ==="

BACKUP_DIR="$USER_HOME/wine-prefix-backup-$(date +%Y%m%d-%H%M%S)"
MOVED=0

for prefix in \
    .wine \
    .wine-devel \
    .wine11 \
    .wine11-check \
    .wine-test11 \
    .wine-xvfb-test
do
    if [[ -e "$USER_HOME/$prefix" ]]; then
        install -d -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" "$BACKUP_DIR"
        mv -- "$USER_HOME/$prefix" "$BACKUP_DIR/"
        echo "  $prefix -> $BACKUP_DIR/"
        MOVED=1
    fi
done

if (( MOVED == 0 )); then
    echo "Tidak ada prefix lama."
else
    echo "Hapus backup manual jika sudah tidak diperlukan:"
    echo "  rm -rf \"$BACKUP_DIR\""
fi

# 12. Update dan upgrade sistem
echo "===================================="
echo " MENJALANKAN UPDATE DAN UPGRADE"
echo "===================================="

apt-get update && apt-get upgrade -y

echo ""
echo "Wine version: $("$WINE_BIN" --version)"
echo "Bagian sistem selesai."
EOF

SYS_STATUS=$?
if (( SYS_STATUS != 0 )); then
    echo "ERROR: Bagian instalasi sistem gagal (exit $SYS_STATUS). Dihentikan."
    exit "$SYS_STATUS"
fi

hash -r

# =====================================================================
#  BAGIAN 2 - PREFIX + KOMPONEN (user biasa)
# =====================================================================
set -uo pipefail

echo ""
echo "===================================="
echo " SETUP PREFIX + WEBVIEW2"
echo "===================================="

export WINE=/opt/wine-devel/bin/wine
export WINESERVER=/opt/wine-devel/bin/wineserver
export WINEPREFIX="$HOME/.wine"
export WINEARCH=win64
export WINEDEBUG=-all

WORK="$HOME/.cache/wine-setup"
LOG="$WORK/setup-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$WORK"
cd "$WORK" || exit 1

# Winetricks terbaru
echo "=== Mengunduh winetricks terbaru ==="
if ! curl -fsSL -o winetricks \
    https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks; then
    echo "ERROR: Gagal mengunduh winetricks."
    exit 1
fi
chmod +x winetricks

# Inisialisasi prefix
echo "=== Inisialisasi prefix ($WINEPREFIX) ==="
"$WINE" wineboot -i >>"$LOG" 2>&1
timeout 120 "$WINESERVER" -w || "$WINESERVER" -k

# Tunggu proses Wine selesai, tapi jangan menunggu selamanya
# (layanan background seperti Edge Update tidak pernah berhenti sendiri)
wait_wine() {
    if ! timeout "${1:-60}" "$WINESERVER" -w; then
        echo "    (proses background Wine masih aktif, dihentikan paksa)" | tee -a "$LOG"
        "$WINESERVER" -k
        sleep 2
    fi
}

FAILED=()
run() {
    echo "=== $* ===" | tee -a "$LOG"
    if ! "$@" >>"$LOG" 2>&1; then
        FAILED+=("$*")
        echo "    -> GAGAL (lihat log)"
    else
        echo "    -> OK"
    fi
    wait_wine 120
}

run ./winetricks -q corefonts
run ./winetricks -q vcrun2022

echo "(dotnet48 bisa memakan waktu 10-20 menit, jangan tutup jendela yang muncul)"
run ./winetricks -q dotnet48

# WebView2 langsung dari Microsoft
echo "=== Mengunduh WebView2 Runtime ==="
if curl -fL -o webview2.exe "https://go.microsoft.com/fwlink/?linkid=2124701" >>"$LOG" 2>&1; then
    run ./winetricks -q win10
    run "$WINE" webview2.exe /silent /install
else
    FAILED+=("download webview2")
    echo "    -> GAGAL mengunduh WebView2"
fi

# Hentikan layanan Edge Update yang dijalankan installer WebView2
"$WINESERVER" -k
sleep 2

echo "=== Konfigurasi WebView2 untuk Wine ===" | tee -a "$LOG"

# Matikan layanan Edge Update (penyebab wineserver tidak pernah idle)
for svc in edgeupdate edgeupdatem; do
    "$WINE" reg add "HKLM\\System\\CurrentControlSet\\Services\\$svc" \
        /v Start /t REG_DWORD /d 4 /f >>"$LOG" 2>&1
done

# Pastikan seluruh prefix memakai Windows 10 (WebView2 110+ tidak jalan di win7)
"$WINE" reg add 'HKCU\Software\Wine' /v Version /d win10 /f >>"$LOG" 2>&1
"$WINE" reg delete 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' /f >>"$LOG" 2>&1 || true

# Argumen WebView2 agar halaman (mis. tab Market di MetaTrader) tidak blank.
# Lewat registry Policies karena environment variable diabaikan oleh MT.
WV2_ARGS="--no-sandbox --disable-gpu --disable-gpu-compositing --disable-direct-composition --disable-features=CalculateNativeWinOcclusion"
WV2_APPS=(terminal64.exe terminal.exe metaeditor64.exe)

for HIVE in HKCU HKLM; do
    for APP in "${WV2_APPS[@]}"; do
        "$WINE" reg add "$HIVE\\Software\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments" \
            /v "$APP" /d "$WV2_ARGS" /f >>"$LOG" 2>&1
    done
done

# Bersihkan profil WebView lama milik MetaTrader (jika prefix sudah berisi MT)
shopt -s nullglob
for d in "$WINEPREFIX/drive_c/Program Files/"*/temp/EBWebView \
         "$WINEPREFIX/drive_c/Program Files (x86)/"*/temp/EBWebView; do
    rm -rf -- "$d"
    echo "    Cache dihapus: $d" | tee -a "$LOG"
done
shopt -u nullglob

# Tunggu registry tersimpan (jangan langsung -k)
wait_wine 60

# Verifikasi argumen tersimpan
if "$WINE" reg query 'HKCU\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments' \
        /v terminal64.exe >>"$LOG" 2>&1; then
    WV2_POLICY="OK"
else
    WV2_POLICY="tidak tersimpan"
    FAILED+=("registry argumen webview2")
fi
wait_wine 30

# Verifikasi WebView2
WV2_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
if [[ -d "$WV2_DIR" ]] && ls "$WV2_DIR" | grep -qE '^[0-9]+\.'; then
    WV2_VER="$(ls "$WV2_DIR" | grep -E '^[0-9]+\.' | sort -V | tail -n1)"
else
    WV2_VER=""
    [[ " ${FAILED[*]-} " == *webview2* ]] || FAILED+=("verifikasi webview2")
fi

# =====================================================================
#  RINGKASAN
# =====================================================================
echo ""
echo "===================================="
echo " SELESAI"
echo "===================================="
echo "Wine     : $("$WINE" --version)"
echo "Prefix   : $WINEPREFIX"
echo "WebView2 : ${WV2_VER:-tidak terdeteksi}"
echo "Argumen  : ${WV2_POLICY:-tidak dicek} (MetaTrader WebView2)"
echo "Log      : $LOG"
echo ""

if (( ${#FAILED[@]} > 0 )); then
    echo "Komponen yang GAGAL:"
    printf '  - %s\n' "${FAILED[@]}"
    exit 2
else
    echo "Semua komponen terpasang."
fi
