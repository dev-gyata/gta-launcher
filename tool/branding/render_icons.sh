#!/usr/bin/env bash
# Renders assets/branding/logo.svg into the macOS and Windows app icons and docs/logo.png.
# macOS only (uses Google Chrome headless to rasterise the SVG and sips to resize); no other dependencies.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
svg="$repo/assets/branding/logo.svg"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# render <html> <png>: 1024x1024 screenshot with a transparent background
render() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$2" "file://$1" >/dev/null 2>&1
}
page() {  # page <html> <img style>
  cat > "$1" <<EOF
<!doctype html><html><body style="margin:0;width:1024px;height:1024px;background:transparent">
<img src="file://$svg" style="position:absolute;display:block;$2"></body></html>
EOF
}

# Windows / docs: the tile edge to edge. macOS: Apple's icon grid (824 px tile on a 1024 canvas) with a soft shadow.
page "$work/full.html" 'left:0;top:0;width:1024px;height:1024px'
page "$work/macos.html" 'left:72px;top:72px;width:880px;height:880px;filter:drop-shadow(0 12px 18px rgba(0,0,0,.35))'
render "$work/full.html" "$work/full.png"
render "$work/macos.html" "$work/macos.png"

icons="$repo/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
  sips -s format png -z "$size" "$size" "$work/macos.png" --out "$icons/app_icon_$size.png" >/dev/null
done

for size in 16 24 32 48 64 256; do
  sips -s format png -z "$size" "$size" "$work/full.png" --out "$work/win_$size.png" >/dev/null
done
# ICO with PNG-compressed entries (supported since Windows Vista)
python3 -I - "$repo/windows/runner/resources/app_icon.ico" "$work"/win_{16,24,32,48,64,256}.png <<'EOF'
import struct, sys
out, pngs = sys.argv[1], sys.argv[2:]
data = [open(p, 'rb').read() for p in pngs]
sizes = [struct.unpack('>I', d[16:20])[0] for d in data]   # PNG IHDR width
header = struct.pack('<HHH', 0, 1, len(data))
offset = 6 + 16 * len(data)
entries = b''
for size, d in zip(sizes, data):
    dim = 0 if size >= 256 else size
    entries += struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(d), offset)
    offset += len(d)
open(out, 'wb').write(header + entries + b''.join(data))
EOF

sips -s format png -z 256 256 "$work/full.png" --out "$repo/docs/logo.png" >/dev/null
echo "Icons written: $icons, windows/runner/resources/app_icon.ico, docs/logo.png"
