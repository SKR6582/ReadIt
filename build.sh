#!/bin/bash
# ReadIt.app 빌드 스크립트
#   ./build.sh          → build/ReadIt.app 생성
#   ./build.sh run      → 빌드 후 실행 (기존 인스턴스 종료)
#   ./build.sh install  → 빌드 후 /Applications 에 설치하고 실행
#   ./build.sh dmg      → build/ReadIt.dmg 생성
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ReadIt"
APP="build/${APP_NAME}.app"

echo "▶ Swift 빌드 (release)…"
swift build -c release

echo "▶ 앱 번들 구성…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

# 권한(TCC)은 코드 서명에 묶인다. 고정된 개발자 인증서가 있으면 그걸로 서명해야
# 재빌드해도 손쉬운 사용/화면 기록 권한이 유지된다. 없으면 ad-hoc 서명.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -oE '"(Apple Development|Developer ID Application)[^"]*"' | tr -d '"' || true)
if [ -n "${IDENTITY}" ]; then
  echo "▶ 코드 서명: ${IDENTITY}"
  codesign --force --deep --sign "${IDENTITY}" "$APP"
else
  echo "▶ 코드 서명: ad-hoc (재빌드 시 권한을 다시 허용해야 할 수 있음)"
  codesign --force --deep --sign - "$APP"
fi

echo "완료: $APP"

case "${1:-}" in
  run)
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 0.3
    open "$APP"
    ;;
  install)
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 0.3
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "/Applications/${APP_NAME}.app 설치 완료"
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

    # SVG 배경 이미지를 고해상도 PNG로 변환
    if [ -f "Resources/dmg-background.svg" ]; then
      rsvg-convert -w 660 -h 400 Resources/dmg-background.svg -o "$DMG_DIR/.background/background.png"
      rsvg-convert -w 1320 -h 800 Resources/dmg-background.svg -o "$DMG_DIR/.background/background@2x.png"
    fi

    # Read-Write 임시 디스크 이미지 생성
    hdiutil create -srcfolder "$DMG_DIR" -volname "${APP_NAME}" -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" -format UDRW -size 200m "$DMG_TEMP"

    # 디스크 이미지 마운트
    DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP" | grep '^/dev/' | head -n 1 | awk '{print $1}')
    MOUNT_DIR=$(hdiutil info | grep -A 1 "$DEVICE" | grep '/Volumes/' | awk '{print $NF}')
    if [ -z "$MOUNT_DIR" ]; then
      MOUNT_DIR="/Volumes/${APP_NAME}"
    fi

    echo "마운트 위치: $MOUNT_DIR (Device: $DEVICE)"
    sleep 2

    # Finder를 이용해 창 크기, 위치, 배경 이미지 및 아이콘 좌표 설정
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

    # 볼륨 설정 동기화 및 언마운트
    sync || true
    hdiutil detach "$DEVICE" -force || true
    sleep 1

    # 최종 압축(UDZO) DMG 생성
    echo "최종 DMG 압축 중..."
    hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    rm -f "$DMG_TEMP"
    rm -rf "$DMG_DIR"
    echo "DMG 생성 완료: $DMG_PATH"
    ;;
esac
