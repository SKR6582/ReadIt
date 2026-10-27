#!/bin/bash
# ReadIt 릴리즈 패키지(DMG + Sparkle appcast.xml) 생성 및 배포 스크립트
# 사용법:
#   ./release.sh [버전] [릴리즈 노트] [--publish]
# 예시:
#   ./release.sh 1.3.0 "자동 업데이트 지원 추가"
#   ./release.sh 1.3.0 "자동 업데이트 지원 추가" --publish
set -euo pipefail
cd "$(dirname "$0")"

PUBLISH=false
POSITIONAL=()
for arg in "$@"; do
  if [ "$arg" = "--publish" ]; then
    PUBLISH=true
  else
    POSITIONAL+=("$arg")
  fi
done

PLIST="Resources/Info.plist"
NEW_VERSION="${POSITIONAL[0]:-}"
RELEASE_NOTES="${POSITIONAL[1]:-}"

if [ -n "$NEW_VERSION" ]; then
  NEW_VERSION="${NEW_VERSION#v}"
  CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
  NEXT_BUILD=$((CUR_BUILD + 1))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" "$PLIST"
  echo "▶ Info.plist 버전 갱신: v${NEW_VERSION} (build ${NEXT_BUILD})"
fi

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
TAG="v${SHORT_VERSION}"

echo "▶ 릴리즈 빌드 시작: ${TAG} (build ${BUILD_VERSION})"
./build.sh dmg

GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
  echo "오류: generate_appcast 도구를 찾을 수 없습니다 ($GENERATE_APPCAST)" >&2
  exit 1
fi

APPCAST_DIR="build/appcast_src"
rm -rf "$APPCAST_DIR" build/appcast.xml
mkdir -p "$APPCAST_DIR"
cp "build/ReadIt.dmg" "$APPCAST_DIR/ReadIt.dmg"

if [ -n "$RELEASE_NOTES" ]; then
  printf "%s\n" "$RELEASE_NOTES" > "$APPCAST_DIR/ReadIt.md"
fi

rm -rf ~/Library/Caches/Sparkle_generate_appcast

DOWNLOAD_PREFIX="https://github.com/SKR6582/ReadIt/releases/download/${TAG}/"
"$GENERATE_APPCAST" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --maximum-deltas 0 \
  --link "https://github.com/SKR6582/ReadIt/releases/tag/${TAG}" \
  -o "build/appcast.xml" \
  "$APPCAST_DIR"

rm -rf "$APPCAST_DIR"

echo "완료:"
echo "  DMG:     build/ReadIt.dmg"
echo "  Appcast: build/appcast.xml"

if [ "$PUBLISH" = "true" ]; then
  NOTES_ARG="${RELEASE_NOTES:-Release ${TAG}}"
  gh release create "$TAG" "build/ReadIt.dmg" "build/appcast.xml" \
    --repo "SKR6582/ReadIt" \
    --title "ReadIt $TAG" \
    --notes "$NOTES_ARG"
  echo "GitHub Release 게시 완료: ${TAG}"
else
  echo ""
  echo "GitHub Releases에 업로드하려면 아래 명령어를 실행하세요:"
  echo "  gh release create ${TAG} build/ReadIt.dmg build/appcast.xml --repo SKR6582/ReadIt --title \"ReadIt ${TAG}\" --notes \"변경 사항\""
fi
