#!/bin/bash
# ReadIt.app 빌드 스크립트
#   ./build.sh          → build/ReadIt (Test).app 생성 (테스트용, Bundle ID: com.seungjun.readit.test)
#   ./build.sh run      → 테스트용 빌드 후 바로 실행 (권한 분리)
#   ./build.sh release  → build/ReadIt.app 생성 (정식 배포용, Bundle ID: com.seungjun.readit)
#   ./build.sh install  → 정식 빌드 후 /Applications 에 설치하고 실행
#   ./build.sh dmg      → build/ReadIt.dmg 생성 (정식 배포용)
set -euo pipefail
cd "$(dirname "$0")"

ACTION="${1:-test}"

case "${ACTION}" in
  dmg|install|release)
    IS_TEST=false
    APP_NAME="ReadIt"
    BUNDLE_ID="com.seungjun.readit"
    DISPLAY_NAME="ReadIt"
    ;;
  *)
    IS_TEST=true
    APP_NAME="ReadIt (Test)"
    BUNDLE_ID="com.seungjun.readit.test"
    DISPLAY_NAME="ReadIt (Test)"
    ;;
esac

APP="build/${APP_NAME}.app"

echo "▶ Swift 빌드 (release)…"
if [ "${IS_TEST}" = "true" ]; then
  swift build -c release
  BIN_PATH=".build/release/ReadIt"
else
  swift build -c release --arch arm64 --arch x86_64
  BIN_PATH=".build/apple/Products/Release/ReadIt"
fi

echo "▶ 앱 번들 구성 (${APP_NAME})…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH" "$APP/Contents/MacOS/ReadIt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
  echo "오류: Sparkle.framework를 찾을 수 없습니다 ($SPARKLE_SRC)" >&2
  exit 1
fi
/usr/bin/ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ReadIt" 2>/dev/null || true

if [ "${IS_TEST}" = "true" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${DISPLAY_NAME}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -oE '"(Developer ID Application|Apple Development|ReadIt Signing)[^"]*"' | tr -d '"' || true)
fi
if [ -z "${IDENTITY}" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -oE '"[^"]+"' | tr -d '"' || true)
fi

if [ -n "${IDENTITY}" ]; then
  SIGN_TARGET="${IDENTITY}"
  echo "▶ 코드 서명: ${SIGN_TARGET}"
elif [ "${IS_TEST}" = "true" ] || [ "${ALLOW_ADHOC:-0}" = "1" ]; then
  SIGN_TARGET="-"
  echo "▶ 코드 서명: ad-hoc (${APP_NAME})"
else
  echo "오류: 정식 빌드에는 고정 코드 서명 인증서가 필요합니다." >&2
  echo "  키체인 접근에서 'ReadIt Signing' 코드 서명 인증서를 생성하거나," >&2
  echo "  SIGN_IDENTITY=\"인증서 이름\" 환경변수를 지정하세요." >&2
  echo "  (테스트 목적으로 ad-hoc 서명을 강제하려면 ALLOW_ADHOC=1 ./build.sh ${ACTION})" >&2
  exit 1
fi

SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  codesign --force --sign "${SIGN_TARGET}" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  codesign --force --sign "${SIGN_TARGET}" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --sign "${SIGN_TARGET}" "$SPARKLE_FW/Versions/B/Autoupdate"
  codesign --force --sign "${SIGN_TARGET}" "$SPARKLE_FW/Versions/B/Updater.app"
  codesign --force --sign "${SIGN_TARGET}" "$SPARKLE_FW"
fi
codesign --force --sign "${SIGN_TARGET}" "$APP"
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 || true

echo "완료: $APP"

case "${ACTION}" in
  run)
    pkill -f "${APP}/Contents/MacOS/ReadIt" 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "실행 완료: $APP"
    ;;
  install)
    pkill -x "ReadIt" 2>/dev/null || true
    sleep 0.3
    rm -rf "/Applications/ReadIt.app"
    cp -R "$APP" "/Applications/ReadIt.app"
    open "/Applications/ReadIt.app"
    echo "/Applications/ReadIt.app 설치 완료"
    ;;
  dmg)
    DMG_DIR="build/dmg"
    DMG_NAME="${APP_NAME}.dmg"
    DMG_PATH="build/${DMG_NAME}"
    DMG_TEMP="build/${APP_NAME}_rw.dmg"

    echo "DMG 생성 준비..."
    rm -rf "$DMG_DIR" "$DMG_PATH" "$DMG_TEMP"
    mkdir -p "$DMG_DIR/.background"

    cp -R "$APP" "$DMG_DIR/"
    ln -s /Applications "$DMG_DIR/Applications"

    if [ -f "Resources/dmg-background.svg" ]; then
      rsvg-convert -w 660 -h 400 Resources/dmg-background.svg -o "$DMG_DIR/.background/background.png"
      rsvg-convert -w 1320 -h 800 Resources/dmg-background.svg -o "$DMG_DIR/.background/background@2x.png"
    fi

    hdiutil create -srcfolder "$DMG_DIR" -volname "${APP_NAME}" -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" -format UDRW -size 200m "$DMG_TEMP"

    DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP" | grep '^/dev/' | head -n 1 | awk '{print $1}')
    MOUNT_DIR=$(hdiutil info | grep -A 1 "$DEVICE" | grep '/Volumes/' | awk '{print $NF}')
    if [ -z "$MOUNT_DIR" ]; then
      MOUNT_DIR="/Volumes/${APP_NAME}"
    fi

    echo "마운트 위치: $MOUNT_DIR (Device: $DEVICE)"
    sleep 2

    VOL_NAME=$(basename "$MOUNT_DIR")
    osascript - "$VOL_NAME" "$MOUNT_DIR" "${APP_NAME}" << 'EOF' || true
    on run argv
      set volName to item 1 of argv
      set mountDir to item 2 of argv
      set appName to item 3 of argv
      set bgPosix to mountDir & "/.background/background.png"
      tell application "Finder"
        tell disk volName
          open
          set current view of container window to icon view
          set toolbar visible of container window to false
          set statusbar visible of container window to false
          set the bounds of container window to {400, 200, 1060, 600}
          set theViewOptions to the icon view options of container window
          set arrangement of theViewOptions to not arranged
          set icon size of theViewOptions to 96
          try
            set background picture of theViewOptions to (POSIX file bgPosix as alias)
          on error errMsg
            log "Background set error: " & errMsg
          end try
          delay 1
          set position of item (appName & ".app") of container window to {210, 240}
          set position of item "Applications" of container window to {450, 240}
          update without registering applications
          delay 1
          close
        end tell
      end tell
    end run
EOF

    sync || true
    hdiutil detach "$DEVICE" -force || true
    sleep 1

    echo "최종 DMG 압축 중..."
    hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    rm -f "$DMG_TEMP"
    rm -rf "$DMG_DIR"
    echo "DMG 생성 완료: $DMG_PATH"
    ;;
esac
