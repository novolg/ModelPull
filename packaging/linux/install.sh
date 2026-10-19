#!/bin/sh
# Install ModelPull for the current user (no sudo needed).
#   ./install.sh              install + app menu entry
#   ./install.sh --autostart  also start hidden at login (downloads resume by themselves)
#   ./install.sh --uninstall  remove app (keeps your downloads, jobs and tokens)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin/modelpull"
APPS="$HOME/.local/share/applications"
ICON="$HOME/.local/share/icons/hicolor/256x256/apps/modelpull.png"
AUTO="$HOME/.config/autostart/modelpull.desktop"
LOGDIR="$HOME/.local/state/modelpull"

# Earlier versions were called "Downloader". Their jobs and config move on first start; remove the old app files.
remove_old() {
  pkill -x downloader 2>/dev/null || true
  rm -f "$HOME/.local/bin/downloader" "$APPS/downloader.desktop" "$HOME/.config/autostart/downloader.desktop" \
        "$HOME/.local/share/icons/hicolor/256x256/apps/downloader.png" "$HOME/.local/share/icons/hicolor/scalable/apps/downloader.svg"
  rm -rf "$HOME/.local/state/downloader"
}

if [ "${1:-}" = "--uninstall" ]; then
  pkill -x modelpull 2>/dev/null || true
  remove_old
  rm -f "$BIN" "$APPS/modelpull.desktop" "$ICON" "$AUTO"
  echo "Removed. Your jobs (~/.local/share/ModelPull), tokens and settings (~/.config/modelpull) are kept."
  exit 0
fi

remove_old
mkdir -p "$HOME/.local/bin" "$APPS" "$(dirname "$ICON")" "$LOGDIR"
install -m 755 "$HERE/modelpull" "$BIN"
install -m 644 "$HERE/modelpull.png" "$ICON"
gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

desktop() { # $1 = extra args
  cat <<EOF
[Desktop Entry]
Type=Application
Name=ModelPull
Comment=Resumable downloads from Hugging Face and Civitai
Exec=sh -c '"$BIN" $1 >>"$LOGDIR/modelpull.log" 2>&1'
Icon=modelpull
Terminal=false
Categories=Network;FileTransfer;
StartupNotify=false
EOF
}
desktop "" > "$APPS/modelpull.desktop"

if [ "${1:-}" = "--autostart" ]; then
  mkdir -p "$(dirname "$AUTO")"
  desktop "--no-open" > "$AUTO"
  echo "Autostart on login: on"
fi

update-desktop-database "$APPS" 2>/dev/null || true

MISSING=$(ldd "$BIN" | grep "not found" || true)
if [ -n "$MISSING" ]; then
  echo "Missing system libraries:"
  echo "$MISSING"
  echo "Install them with:  sudo apt install libcurl4t64"
  exit 1
fi

echo "Installed. Open \"ModelPull\" from the app menu, or run: $BIN"
