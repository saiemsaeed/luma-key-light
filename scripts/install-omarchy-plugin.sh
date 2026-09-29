#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

plugin_id="io.github.saiemsaeed.luma"
source_dir="$PWD/omarchy-plugin"
target_dir="$HOME/.config/omarchy/plugins/$plugin_id"

omarchy plugin validate "$source_dir"

if [[ -e $target_dir ]]; then
  backup="$target_dir.bak.$(date +%s)"
  cp -a "$target_dir" "$backup"
  echo "Backed up the existing plugin to $backup"
fi

mkdir -p "$(dirname "$target_dir")"
rm -rf "$target_dir"
cp -a "$source_dir" "$target_dir"
chmod +x "$target_dir/control.py"

omarchy-shell shell rescanPlugins >/dev/null
omarchy plugin enable "$plugin_id" --section right

echo "Installed and enabled $plugin_id"
