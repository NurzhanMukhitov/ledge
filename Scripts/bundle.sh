#!/bin/bash
# Builds Ledge.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Ledge.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

# Обе архитектуры, а не только своя. Приложение раздаётся, и маки на Intel
# ещё в ходу — macOS 15 ставится на них с 2018 года. Библиотеки в бандле уже
# универсальные, и однобокий исполняемый файл делал бы их вес бессмысленным:
# на Intel не запустилось бы вообще ничего.
# Две отдельные сборки и lipo, а не флаг --arch. Флаг переводит SwiftPM на
# другую систему сборки, и та отказывается от swiftLanguageMode(.v5):
# «Some of the Swift language versions used in target are supported.
# (given: [5], supported: [])». Локально с одним тулчейном это проходит, на
# раннере с другим — нет, и ловится только в CI, то есть после того, как
# выпущено. По триплетам собирается тем же путём, что и обычная сборка.
echo "==> swift build -c $CONFIG (arm64 + x86_64)"
SLICES=()
for TRIPLE in arm64-apple-macosx x86_64-apple-macosx; do
    swift build -c "$CONFIG" --package-path "$ROOT" --triple "$TRIPLE"
    SLICES+=("$(swift build -c "$CONFIG" --package-path "$ROOT" --triple "$TRIPLE" --show-bin-path)/Ledge")
done
BIN="$ROOT/.build/Ledge-universal"
lipo -create "${SLICES[@]}" -output "$BIN"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ledge"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ledge</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Ledge</string>
    <key>CFBundleIdentifier</key><string>com.ledge.app</string>
    <key>CFBundleExecutable</key><string>Ledge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Ledge читает название текущего трека и управляет воспроизведением в Apple Music и Spotify.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Ledge показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Ledge показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Таблицы строк кладутся прямо в бандл, а не через ресурсы SwiftPM: бандл здесь
# собирается вручную, и .lproj рядом с исполняемым файлом — то, где их ищет сама
# macOS. Язык она выбирает потом сама, по списку предпочитаемых у пользователя.
echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "    $(basename "$lproj")"
done

# MP3 encoder. Ships inside the bundle because macOS has no MP3 encoder of its
# own — `afconvert -f MPG3` answers `fmt?` — and whoever is handed this build
# must not have to install anything. Loaded with dlopen at runtime, never linked:
# LAME is LGPL and Ledge is MIT, and dynamic loading is precisely what keeps
# those two compatible. Its licence travels beside it, which the LGPL requires.
if [ -f "$ROOT/Vendor/lame/libmp3lame.dylib" ]; then
    echo "==> MP3 encoder (LAME)"
    mkdir -p "$APP/Contents/Frameworks"
    cp "$ROOT/Vendor/lame/libmp3lame.dylib" "$APP/Contents/Frameworks/"
    cp "$ROOT/Vendor/lame/COPYING" "$APP/Contents/Frameworks/libmp3lame-COPYING.txt"
    echo "    $(lipo -archs "$APP/Contents/Frameworks/libmp3lame.dylib")"
else
    # Not fatal: the app runs without it and simply does not offer MP3.
    echo "==> MP3 encoder: Vendor/lame/libmp3lame.dylib отсутствует, пункт mp3 будет скрыт" >&2
fi

# ffmpeg for the four formats macOS will not open — WMV, MKV, FLV, WebM.
# A separate process, never linked: ffmpeg here is LGPL and Ledge is MIT, and a
# process boundary leaves nothing to argue about. Its licence and the recipe that
# built it travel beside it, which is what the LGPL asks of a redistributor.
if [ -f "$ROOT/Vendor/ffmpeg/ffmpeg" ]; then
    echo "==> ffmpeg (LGPL, только недостающие форматы)"
    cp "$ROOT/Vendor/ffmpeg/ffmpeg" "$APP/Contents/Resources/ffmpeg"
    chmod +x "$APP/Contents/Resources/ffmpeg"
    cp "$ROOT/Vendor/ffmpeg/COPYING.LGPLv2.1" "$APP/Contents/Resources/ffmpeg-COPYING.txt" 2>/dev/null || true
    echo "    $(lipo -archs "$APP/Contents/Resources/ffmpeg") · $(du -h "$APP/Contents/Resources/ffmpeg" | cut -f1)"
else
    echo "==> ffmpeg отсутствует: WMV, MKV, FLV и WebM останутся нечитаемыми" >&2
fi

# Now Playing helper. Built here rather than by SwiftPM because it is not linked
# into the app: it is loaded into /usr/bin/perl at runtime. See helper.m.
echo "==> building Now Playing helper"
clang -dynamiclib -fobjc-arc -O2 \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=15.0 \
    -framework Foundation \
    -o "$APP/Contents/Resources/libledgemedia.dylib" \
    "$ROOT/Sources/LedgeMediaHelper/helper.m"

# Однобокий файл в универсальном бандле — молчаливая поломка: собралось,
# подписалось, а на половине машин не запускается. Проверяется здесь, где это
# ещё стоит одну пересборку.
echo "==> проверка архитектур"
for f in "$APP/Contents/MacOS/Ledge" \
         "$APP/Contents/Resources/libledgemedia.dylib" \
         "$APP/Contents/Frameworks/libmp3lame.dylib" \
         "$APP/Contents/Resources/ffmpeg"; do
    [ -f "$f" ] || continue
    archs="$(lipo -archs "$f")"
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) echo "    $(basename "$f"): $archs" ;;
        *) echo "!!! $(basename "$f") собран только под $archs" >&2; exit 1 ;;
    esac
done

echo "==> ad-hoc signing"
# Расширенные атрибуты снимаются первыми. iCloud вешает на файлы
# com.apple.FinderInfo, а codesign отказывается подписывать что-либо с ним —
# «resource fork, Finder information, or similar detritus not allowed». Папка
# «Рабочий стол» синхронизируется с iCloud у многих по умолчанию, так что клон
# репозитория там перестает подписываться, стоило его туда перенести.
xattr -cr "$APP"

# Ошибка не глушится и не понижается до предупреждения. Раньше отказ печатал
# мягкую строку и возвращал ноль: скрипт доходил до «done», а в build лежал
# бандл, про который codesign говорит «code object is not signed at all».
# Заметить это можно было только по возвращающимся запросам TCC — то есть у
# того, кто уже поставил приложение.
codesign --force --deep --sign - "$APP" || {
    echo "!!! codesign не смог подписать бандл — см. вывод выше" >&2
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> done: $APP"
