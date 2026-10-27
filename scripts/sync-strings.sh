#!/bin/zsh
# Brings the three String Catalogs in step with the source.
#
# The apps' catalog lives in Shared/ and serves both the iPhone and the Mac, so it is synced from
# both builds at once: synced from one alone, every string only the other uses is marked stale.
#
# Xcode does this itself when it builds; `xcodebuild` writes the extracted strings (.stringsdata)
# but never merges them, so a command-line build leaves the catalogs behind. Run after any change
# to user-facing text, then fill in the translations the catalogs mark as new.
set -euo pipefail
cd "${0:A:h}/.."

xcodebuild -project Embers.xcodeproj -scheme Embers \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build -quiet
# Unsigned: only the extracted strings are wanted, and signing needs this Mac registered.
xcodebuild -project Embers.xcodeproj -scheme EmbersMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build -quiet

intermediates=$(/bin/ls -td ~/Library/Developer/Xcode/DerivedData/Embers-*/Build/Intermediates.noindex | head -1)

# sync <catalog> <target build dir>…: every target whose strings the catalog holds, together.
sync() {
  local catalog=$1; shift
  local args=()
  for target in "$@"; do
    local files=("${(@f)$(find "$intermediates" -path "*/$target/*" -name '*.stringsdata')}")
    for f in $files; do args+=(--stringsdata "$f"); done
  done
  xcrun xcstringstool sync "$catalog" $args
}

sync Shared/Localizable.xcstrings \
  Embers.build/Debug-iphonesimulator/Embers.build \
  Embers.build/Debug/EmbersMac.build
# Xcode's build of the package targets writes no .stringsdata, but SwiftPM's own does — with the
# real placeholders (%lld, %@). `xcstringstool extract` reads source without types and writes
# `%arg`, which no lookup at run time would ever match.
(cd Packages/EmbersCore && swift build --target EmbersData -q)
spm=Packages/EmbersCore/.build/out/Intermediates.noindex/EmbersCore.build/Debug
for module in EmbersCore EmbersData; do
  files=("${(@f)$(find "$spm/$module-t.build" -name '*.stringsdata')}")
  args=()
  for f in $files; do args+=(--stringsdata "$f"); done
  xcrun xcstringstool sync Packages/EmbersCore/Sources/$module/Localizable.xcstrings $args
done
