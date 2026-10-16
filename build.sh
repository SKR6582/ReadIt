#!/bin/bash
# LiveCaption.app 빌드 스크립트
#   ./build.sh          → build/LiveCaption.app 생성
#   ./build.sh run      → 빌드 후 실행 (기존 인스턴스 종료)
#   ./build.sh install  → 빌드 후 /Applications 에 설치하고 실행
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LiveCaption"
APP="build/${APP_NAME}.app"

echo "▶ Swift 빌드 (release)…"
swift build -c release

echo "▶ 앱 번들 구성…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"

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

echo "✅ 완료: $APP"

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
    echo "✅ /Applications/${APP_NAME}.app 설치 완료"
    ;;
esac
