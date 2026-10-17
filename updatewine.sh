#!/bin/bash
# =====================================================================
#  Install WineHQ terbaru + corefonts, vcrun2022, dotnet48, WebView2
#  + double-click file .ex4/.ex5/.mq4/.mq5 langsung masuk ke MetaTrader
#    (mt5-open + penjaga asosiasi mt5-assoc)
#  + backup MetaTrader (AppData\MetaQuotes + folder instalasi MT) lalu
#    restore otomatis ke prefix baru, lalu backup dihapus.
#    NO_BACKUP=1 = tanpa backup, KEEP_BACKUP=1 = simpan file backup.
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
# 1. Tutup Wine, BACKUP data MetaTrader, lalu hapus prefix lama
# ---------------------------------------------------------------------
wineserver -k 2>/dev/null || true
sleep 2

# Yang dibackup (relatif terhadap drive_c):
#  - AppData\Roaming\MetaQuotes (data, EA, indikator, profil, akun)
#  - folder instalasi MetaTrader saja di Program Files / Program Files (x86)
#    (dikenali dari terminal.exe / terminal64.exe di dalamnya)
BACKUP_DIR="${BACKUP_DIR:-$HOME/wine-backup}"
BACKUP=""
OLD_DC="$HOME/.wine/drive_c"
if [[ "${NO_BACKUP:-0}" != 1 && -d "$OLD_DC" ]]; then
    SRC=()
    d="users/${USER:-$(id -un)}/AppData/Roaming/MetaQuotes"
    [[ -d "$OLD_DC/$d" ]] && SRC+=("$d")
    shopt -s nullglob nocaseglob
    for t in "$OLD_DC/Program Files/"*/terminal64.exe "$OLD_DC/Program Files/"*/terminal.exe \
             "$OLD_DC/Program Files (x86)/"*/terminal64.exe "$OLD_DC/Program Files (x86)/"*/terminal.exe; do
        d="$(dirname "${t#$OLD_DC/}")"
        [[ " ${SRC[*]} " == *" $d "* ]] || SRC+=("$d")
    done
    shopt -u nullglob nocaseglob
    if (( ${#SRC[@]} )); then
        mkdir -p "$BACKUP_DIR"
        BACKUP="$BACKUP_DIR/wine-mt-$(date +%Y%m%d-%H%M%S).tar.gz"
        # Cache WebView2 milik MT tidak ikut (dibuat ulang otomatis)
        EXCL=(--exclude="*/temp/EBWebView")

        echo "=== Backup data Wine ==="
        printf '    %s\n' "${SRC[@]}"
        SIZE="$(cd "$OLD_DC" && du -sch "${SRC[@]}" 2>/dev/null | tail -1 | cut -f1)"
        FREE="$(df -h --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ')"
        echo "    ukuran ~$SIZE, ruang kosong $FREE"
        echo "    -> $BACKUP"

        if ! tar -C "$OLD_DC" -czf "$BACKUP" "${EXCL[@]}" "${SRC[@]}" \
           || ! tar -tzf "$BACKUP" >/dev/null 2>&1; then
            echo "ERROR: Backup gagal. Prefix lama TIDAK dihapus, proses dihentikan."
            rm -f "$BACKUP"
            exit 1
        fi
        echo "    -> Backup OK ($(du -h "$BACKUP" | cut -f1))"
    fi
fi

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
sudo apt-get install -y wget ca-certificates cabextract unzip p7zip-full xz-utils zenity yad inotify-tools libnotify-bin

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

mkdir -p "$HOME/.cache"
LOG="$HOME/.cache/mt5-open.log"
echo "$(date '+%F %T') DIPANGGIL: $*" >> "$LOG"
err() { echo "    ERROR: $1" >> "$LOG"; zenity --error --title="MT5 Open" --text="$1" 2>/dev/null || echo "$1" >&2; exit 1; }

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
# Nama file aman untuk markup zenity (mis. "E&E POINTS")
BN="$(basename "$FILE")"; BN="${BN//&/&amp;}"; BN="${BN//</&lt;}"; BN="${BN//>/&gt;}"

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

# Belum ketemu? Lihat siapa yang membuka jendela Explorer ini:
# MT -> File > Open Data Folder -> explorer.exe -> (double-click) -> mt5-open
# Telusuri proses induk sampai menemukan terminal/explorer milik sebuah MT.
owner_from_dir() {   # $1 = folder Linux; cetak folder instalasi MT pemiliknya
    local d="$1" o
    while [[ -n "$d" && "$d" != "/" ]]; do
        if [[ -f "$d/origin.txt" ]]; then
            o="$(iconv -f UTF-16LE -t UTF-8 "$d/origin.txt" 2>/dev/null | tr -d '\r\n\357\273\277')"
            [[ -n "$o" ]] && { readlink -f "$(winepath -u "$o" 2>/dev/null)"; return; }
        elif [[ -f "$d/terminal64.exe" || -f "$d/terminal.exe" ]]; then
            readlink -f "$d"; return
        fi
        d="$(dirname "$d")"
    done
}
if [[ -z "$OWNER" ]]; then
    pid=$PPID
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -r /proc/$pid/cmdline ]] || break
        mapfile -d '' -t CL < /proc/$pid/cmdline
        for a in "${CL[@]}"; do
            case "${a,,}" in
                *\\terminal64.exe|*\\terminal.exe|*/terminal64.exe|*/terminal.exe)
                    u="$a"; [[ "$u" =~ ^[A-Za-z]:\\ ]] && u="$(winepath -u "$u" 2>/dev/null)"
                    OWNER="$(readlink -f "$(dirname "$u")")"; VIA="proses $pid" ;;
                [a-z]:\\*)
                    # argumen explorer.exe = folder yang dibuka (Data Folder)
                    u="$(winepath -u "$a" 2>/dev/null)"
                    [[ -d "$u" ]] && { o="$(owner_from_dir "$u")"; [[ -n "$o" ]] && OWNER="$o" VIA="explorer $pid"; } ;;
            esac
            [[ -n "$OWNER" ]] && break
        done
        [[ -n "$OWNER" ]] && break
        pid="$(awk '{print $4}' /proc/$pid/stat 2>/dev/null)"
        [[ -n "$pid" && "$pid" != 1 && "$pid" != 0 ]] || break
    done
fi

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
        --text="Buka <b>$BN</b> di:" \
        --column="No" --column="MetaTrader" --column="Status" \
        --hide-column=1 --print-column=1 --width=420 --height=320 \
        "${ROWS[@]}" 2>/dev/null)" || exit 0
    [[ -n "$CH" ]] || exit 0
    if [[ $CH == all ]]; then SEL=("${!DIRS[@]}"); else SEL=("$((CH-1))"); fi
fi

WFILE="$(winepath -w "$FILE" 2>/dev/null)"
mkdir -p "$HOME/.cache"
{
    echo "$(date '+%F %T') $(basename "$FILE")"
    echo "    lokasi : $FILE"
    echo "    pemilik: ${OWNER:-(tidak terdeteksi)} ${VIA:+(dari $VIA)}"
    if [[ -z "$OWNER" ]]; then
        q=$PPID
        for _ in 1 2 3 4 5 6; do
            [[ -r /proc/$q/cmdline ]] || break
            echo "    induk  : $q $(tr '\0' ' ' < /proc/$q/cmdline | cut -c1-150)"
            q="$(awk '{print $4}' /proc/$q/stat 2>/dev/null)"; [[ "$q" -gt 1 ]] 2>/dev/null || break
        done
    fi
    for i in "${SEL[@]}"; do echo "    kirim  : ${NAMES[$i]}"; done
} >> "$HOME/.cache/mt5-open.log"
# ---------------------------------------------------------------------
# .ex4 / .ex5: file disalin langsung ke folder MQL4/MQL5 milik terminal tujuan.
# (MT4 tidak bisa mengimpor dari argumen; MT5 hanya berhasil sekali karena
#  instance yang sudah berjalan mengabaikan kiriman berikutnya.)
# Jenis ditanyakan lewat dialog kecil bila tidak bisa ditentukan otomatis.
# ---------------------------------------------------------------------
if [[ $EXT == ex4 || $EXT == ex5 ]]; then
    if [[ $EXT == ex5 ]]; then MQ=MQL5; TT="MT5"; else MQ=MQL4; TT="MT4"; fi
    NAME="$(basename "$FILE")"
    MSG=""
    for i in "${SEL[@]}"; do
        inst="$(readlink -f "${DIRS[$i]}")"
        # Data folder: AppData\...\Terminal\<kode> yang origin.txt-nya menunjuk ke instalasi ini
        DATA=""
        shopt -s nullglob
        for o in "$DC"/users/*/AppData/Roaming/MetaQuotes/Terminal/*/origin.txt; do
            p="$(iconv -f UTF-16LE -t UTF-8 "$o" 2>/dev/null | tr -d '\r\n\357\273\277')"
            [[ -n "$p" && "$(readlink -f "$(winepath -u "$p" 2>/dev/null)")" == "$inst" ]] \
                && DATA="$(dirname "$o")"
        done
        shopt -u nullglob
        [[ -d "$DATA/$MQ" ]] || DATA="$inst"          # mode portable
        M4="$DATA/$MQ"

        # Tentukan jenis:
        # 1) dari folder asal (…/Experts, …/Indicators, …/Scripts)
        # 2) selain itu tanya lewat dialog kecil (Expert / Indicator / Script)
        CAT=""
        case "${FILE,,}" in
            */experts/*)    CAT=Experts ;;
            */indicators/*) CAT=Indicators ;;
            */scripts/*)    CAT=Scripts ;;
        esac
        # Sudah pernah dipasang? tampilkan di dialog (tetap ditanya agar ada reaksi)
        ADA=""
        for c in Experts Indicators Scripts; do
            [[ -f "$M4/$c/$NAME" ]] && ADA="$c"
        done
        if [[ -z "$CAT" ]]; then
            # Dialog kecil di tengah layar: satu klik memilih jenis (Esc = batal)
            if command -v yad >/dev/null; then
                yad --center --on-top --fixed --borders=12 --title="$TT" \
                    --window-icon=wine --image=dialog-question \
                    --text="<b>$BN</b>${ADA:+\n<small>sudah ada di $ADA, akan ditimpa</small>}" \
                    --button="Expert:10" --button="Indicator:11" --button="Script:12" \
                    >/dev/null 2>&1
                case $? in 10) ANS=Expert ;; 11) ANS=Indicator ;; 12) ANS=Script ;; *) ANS="" ;; esac
            else
                ANS="$(zenity --question --switch --no-wrap --title="$TT" \
                        --text="<b>$BN</b>${ADA:+\n<small>sudah ada di $ADA, akan ditimpa</small>}" \
                        --extra-button="Expert" --extra-button="Indicator" --extra-button="Script" \
                        2>/dev/null)"
            fi
            case "$ANS" in
                Expert)    CAT=Experts ;;
                Indicator) CAT=Indicators ;;
                Script)    CAT=Scripts ;;
                *)         echo "    batal" >> "$LOG"; exit 0 ;;
            esac
        fi

        # Pindah jenis? hapus salinan lama agar tidak dobel
        [[ -n "$ADA" && "$ADA" != "$CAT" ]] && rm -f "$M4/$ADA/$NAME"

        DEST="$M4/$CAT"
        mkdir -p "$DEST"
        if [[ "$(readlink -f "$FILE")" == "$(readlink -f "$DEST/$NAME")" ]]; then
            MSG+="${NAMES[$i]}: sudah ada di $MQ/$CAT\n"
        elif cp -f "$FILE" "$DEST/"; then
            MSG+="${NAMES[$i]}: masuk ke $MQ/$CAT\n"
        else
            MSG+="${NAMES[$i]}: GAGAL menyalin\n"
        fi
        echo "    salin  : $DEST" >> "$LOG"

        # Jalankan MT bila belum berjalan (file terbaca saat start)
        if ! pgrep -f "${NAMES[$i]}\\\\terminal" >/dev/null; then
            nohup wine "$(winepath -w "${DIRS[$i]}/$EXE")" >/dev/null 2>&1 &
        fi
    done
    exit 0
fi

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

# Penjaga asosiasi: installer MetaTrader menimpa asosiasi .ex4/.ex5 setiap kali
# diinstal; mt5-assoc mengembalikannya otomatis saat registry Wine berubah.
echo "=== Memasang penjaga asosiasi file ==="
cat > "$BIN/mt5-assoc" <<'ASSOC'
#!/bin/bash
# mt5-assoc: pastikan .ex4/.ex5/.mq4/.mq5/.mqh di Wine selalu dibuka lewat mt5-open.
# Installer MetaTrader menimpa asosiasi ini setiap kali dijalankan (di HKLM
# maupun HKCU); script ini mengembalikannya. Hanya membaca file registry
# (tanpa menyalakan Wine) kecuali memang ada yang perlu diperbaiki.
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export WINEDEBUG=-all

# Mode pantau: jalan terus di background, periksa ulang setiap registry berubah
if [[ "${1:-}" == "--watch" ]]; then
    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/mt5-assoc-$UID.lock"
    flock -n 9 || exit 0                       # sudah ada yang memantau
    command -v inotifywait >/dev/null || exit 0
    "$0"
    while inotifywait -qq -e close_write,moved_to "$WINEPREFIX" 2>/dev/null \
          || sleep 30; do
        sleep 5                                # beri waktu wineserver menyimpan
        "$0"
    done
    exit 0
fi

# --- Sisi Linux: cegah Wine membuat asosiasi .ex4/.ex5 sendiri ---------
APPS="$HOME/.local/share/applications"
MIMED="$HOME/.local/share/mime"
CHG=0
for e in ex4 ex5 mq4 mq5 mqh; do
    for f in "$APPS/wine-extension-$e.desktop" "$MIMED/packages/x-wine-extension-$e.xml"; do
        [[ -f "$f" ]] && { mv -f "$f" "$f.bak"; CHG=1; }
    done
done
for t in application/x-mql-ex5 application/x-mql-ex4 text/x-mql5 text/x-mql4 text/x-mqh; do
    [[ "$(xdg-mime query default "$t" 2>/dev/null)" == mt5-open.desktop ]] \
        || { xdg-mime default mt5-open.desktop "$t" 2>/dev/null; CHG=1; }
done
if (( CHG )); then
    update-mime-database "$MIMED" >/dev/null 2>&1
    update-desktop-database "$APPS" >/dev/null 2>&1
    mkdir -p "$HOME/.cache"
    echo "$(date '+%F %T') asosiasi Linux diperbaiki" >> "$HOME/.cache/mt5-assoc.log"
fi

SYSREG="$WINEPREFIX/system.reg"     # HKLM\Software\Classes
USRREG="$WINEPREFIX/user.reg"       # HKCU\Software\Classes (lebih diutamakan)
LAUNCH="$HOME/.local/bin/mt5-open"
[[ -f "$SYSREG" && -x "$LAUNCH" ]] || exit 0
command -v wine >/dev/null || exit 0

WLAUNCH="Z:${LAUNCH//\//\\}"
CMD="\"$WLAUNCH\" \"%1\""

# Nilai (Default) sebuah key; $1 = file .reg, $2 = key, mis. Software\Classes\.ex5
# Hasil "<none>" bila key tidak ada sama sekali.
reg_default() {
    [[ -f "$1" ]] || { echo "<none>"; return; }
    local hdr="[${2//\\/\\\\}]"
    H="${hdr,,}" awk '
        BEGIN                      { h = ENVIRON["H"]; found = 0 }
        index(tolower($0), h) == 1 { f = 1; found = 1; next }
        /^\[/                      { f = 0 }
        f && /^@=/                 { sub(/^@="/, ""); sub(/"$/, ""); print; done = 1; exit }
        END                        { if (!found) print "<none>" }
    ' "$1"
}

FIX=()
# Matikan pembuatan asosiasi file Linux oleh Wine (shortcut menu tetap dibuat)
if ! grep -qi '^\[Software\\\\Wine\\\\FileOpenAssociations\]' "$USRREG" 2>/dev/null; then
    FIX+=("_foa:")
fi
for ext in ex4 ex5 mq4 mq5 mqh; do
    # ProgID efektif: HKCU menang atas HKLM
    pu="$(reg_default "$USRREG" "Software\\Classes\\.$ext")"
    ps="$(reg_default "$SYSREG" "Software\\Classes\\.$ext")"
    progid="$pu"; [[ "$progid" == "<none>" || -z "$progid" ]] && progid="$ps"
    [[ "$progid" == "<none>" || -z "$progid" ]] && progid="${ext^^}.File"

    cu="$(reg_default "$USRREG" "Software\\Classes\\$progid\\shell\\open\\command")"
    cs="$(reg_default "$SYSREG" "Software\\Classes\\$progid\\shell\\open\\command")"
    ok=1
    [[ "$cs" == *mt5-open* ]] || ok=0                         # HKLM harus benar
    [[ "$cu" == "<none>" || "$cu" == *mt5-open* ]] || ok=0    # HKCU kosong atau benar
    (( ok )) || FIX+=("$ext:$progid")
done

(( ${#FIX[@]} )) || exit 0
mkdir -p "$HOME/.cache"

for item in "${FIX[@]}"; do
    ext="${item%%:*}"; progid="${item#*:}"
    if [[ $ext == _foa ]]; then
        wine reg add 'HKCU\Software\Wine\FileOpenAssociations' /v Enable /d N /f >/dev/null 2>&1
        continue
    fi
    for HIVE in HKLM HKCU; do
        wine reg add "$HIVE\\Software\\Classes\\.$ext" /ve /d "$progid" /f >/dev/null 2>&1
        wine reg add "$HIVE\\Software\\Classes\\$progid\\shell\\open\\command" /ve /d "$CMD" /f >/dev/null 2>&1
    done
    echo "$(date '+%F %T') .$ext -> $progid diperbaiki (HKLM+HKCU)" >> "$HOME/.cache/mt5-assoc.log"
done
ASSOC
chmod +x "$BIN/mt5-assoc"

# Jalankan otomatis setiap kali registry Wine berubah (mis. setelah install MT baru)
SYSD="$HOME/.config/systemd/user"
mkdir -p "$SYSD" "$HOME/.cache"
cat > "$SYSD/mt5-assoc.path" <<EOF
[Unit]
Description=Pantau registry Wine untuk asosiasi file MetaTrader

[Path]
PathChanged=$HOME/.wine/system.reg
PathChanged=$HOME/.wine/user.reg
Unit=mt5-assoc.service

[Install]
WantedBy=default.target
EOF
cat > "$SYSD/mt5-assoc.service" <<EOF
[Unit]
Description=Kembalikan asosiasi .ex4/.ex5 ke mt5-open

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=$BIN/mt5-assoc
EOF

# Cadangan bila systemd --user tidak aktif: jalankan saat login desktop
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/mt5-assoc.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MT5 file association guard
Exec=$BIN/mt5-assoc --watch
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

if systemctl --user daemon-reload 2>/dev/null && \
   systemctl --user enable --now mt5-assoc.path 2>/dev/null; then
    echo "    -> Penjaga asosiasi aktif (systemd --user)"
else
    # Tanpa systemd: pemantau inotify di background (otomatis lagi saat login)
    nohup "$BIN/mt5-assoc" --watch >/dev/null 2>&1 &
    echo "    -> Penjaga asosiasi aktif (inotify, otomatis saat login)"
fi

[[ "$WV2_POLICY" == "OK" ]] || FAILED+=("registry argumen webview2")

# ---------------------------------------------------------------------
# 8. Restore data MetaTrader dari backup ke prefix baru
# ---------------------------------------------------------------------
RESTORE="tidak ada backup"
if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    echo "=== Restore data dari backup ==="
    wineserver -k 2>/dev/null; sleep 2
    if tar -C "$WINEPREFIX/drive_c" -xzf "$BACKUP" \
       && tar -C "$WINEPREFIX/drive_c" -dzf "$BACKUP" >/dev/null 2>&1; then
        RESTORE="OK"
        echo "    -> Restore OK (isi terverifikasi sama dengan backup)"
        # Backup dihapus hanya bila restore terverifikasi. KEEP_BACKUP=1 untuk menyimpan.
        if [[ "${KEEP_BACKUP:-0}" != 1 ]]; then
            rm -f "$BACKUP" && echo "    -> File backup dihapus"
            rmdir "$BACKUP_DIR" 2>/dev/null
            BACKUP=""
        fi
        # Jalankan penjaga asosiasi sekali (MT hasil restore tidak lewat installer)
        [[ -x "$HOME/.local/bin/mt5-assoc" ]] && "$HOME/.local/bin/mt5-assoc"
    else
        RESTORE="GAGAL"
        FAILED+=("restore backup")
        echo "    -> GAGAL. File backup TIDAK dihapus. Restore manual:"
        echo "       tar -C ~/.wine/drive_c -xzf \"$BACKUP\""
    fi
fi

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
echo "Restore  : $RESTORE${BACKUP:+ ($BACKUP)}"
echo "Log      : $LOG"
if (( ${#FAILED[@]} )); then
    echo "GAGAL:"; printf '  - %s\n' "${FAILED[@]}"
    exit 2
fi
echo "Semua komponen terpasang."