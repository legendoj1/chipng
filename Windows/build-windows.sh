#!/bin/zsh
# Builds a single, self-contained Chipng.exe for 64-bit Windows 10/11.
# Runs on macOS, Linux or Windows (Git Bash/WSL) with the .NET 10 SDK.
#   ./Windows/build-windows.sh   → Windows/Chipng.exe
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# Build products stay off Google Drive / network folders.
WORK="${XDG_CACHE_HOME:-$HOME/Library/Caches}/Chipng-dotnet"
OUT="$WORK/publish"

rm -rf "$OUT"
dotnet publish "$ROOT/Windows/Chipng/Chipng.csproj" \
  -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true \
  -p:DebugType=none \
  -p:PublishReferencesDocumentationFiles=false \
  --artifacts-path "$WORK" \
  -o "$OUT"

cp "$OUT/Chipng.exe" "$ROOT/Windows/Chipng.exe"
echo "✓ $ROOT/Windows/Chipng.exe ($(du -h "$ROOT/Windows/Chipng.exe" | cut -f1))"
