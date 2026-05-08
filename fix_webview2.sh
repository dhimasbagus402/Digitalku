#!/bin/bash

rm -rf ~/.wine

sudo apt remove --purge wine* libwine* -y
sudo apt autoremove -y

sudo dpkg --add-architecture i386
sudo apt update

sudo apt install wine wine32 wine64 libwine fonts-wine wget -y

wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O winetricks

chmod +x winetricks

timeout 60s winecfg || true

wineserver -k || true

./winetricks -q corefonts vcrun2022 || true
./winetricks -q dotnet48 || true
./winetricks -q webview2 || true

echo "Script selesai dijalankan"
