#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/luma "$HOME/.local/bin/luma"
install -d "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/luma.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Luma
Comment=Control an Elgato Key Light
Exec=$HOME/.local/bin/luma
Terminal=false
Categories=Utility;
StartupNotify=true
EOF
printf 'Installed Luma. Open it from your application launcher.\n'
