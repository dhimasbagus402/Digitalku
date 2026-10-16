#!/usr/bin/env bash
# DIGIOS - WINEHQ FRESH INSTALLER (Debian 13 Trixie)
# Jalankan: bash updatewine2.sh   (otomatis minta sudo)

set -Eeuo pipefail

# Naikkan ke root otomatis jika belum
if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

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
    echo "ERROR: Jalankan dari akun admin (bukan root langsung)."
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
    done < <(ps -u "$USER_UID" -o pid=,comm= || true)
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

# 3. Persiapan repository
echo "=== Menyiapkan dependencies ==="

dpkg --add-architecture i386

# Nonaktifkan konfigurasi WineHQ lama jika ada
rm -f /etc/apt/sources.list.d/winehq-trixie.sources

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gnupg

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

# 11. Hapus prefix lama
# PERINGATAN: ini menghapus semua instalasi aplikasi Windows (termasuk MT4/MT5) di prefix berikut.
echo "=== Membersihkan prefix Wine lama ==="

for prefix in \
    .wine \
    .wine-devel \
    .wine11 \
    .wine11-check \
    .wine-test11 \
    .wine-xvfb-test
do
    rm -rf -- "$USER_HOME/$prefix"
done

# 12. Update dan upgrade sistem
echo "===================================="
echo " MENJALANKAN UPDATE DAN UPGRADE"
echo "===================================="

apt-get update && apt-get upgrade -y

# 13. Verifikasi akhir
echo ""
echo "===================================="
echo " WINEHQ INSTALLATION COMPLETED"
echo "===================================="
echo ""
echo "Wine version:"
"$WINE_BIN" --version
echo ""
echo "Wine executable: $WINE_BIN"
echo "Repository: WineHQ Debian Trixie"
echo "Update sistem: Selesai"
echo ""
echo "Untuk inisialisasi Wine:"
echo "/opt/wine-devel/bin/wineboot -i"
echo ""
echo "Jika shell masih memakai wine lama, jalankan: hash -r"
echo "===================================="
