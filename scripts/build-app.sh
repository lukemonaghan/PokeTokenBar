#!/bin/bash
# PokeTokenBar.app 번들 조립 + /Applications 설치
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.5.1"
APP_NAME="PokeTokenBar"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

echo "==> $APP 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# 심볼 strip — 릴리스 바이너리 1.84MB → 0.80MB(-57%). codesign 전에 수행(서명 무효화 방지).
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || strip -rSx "$APP/Contents/MacOS/$APP_NAME"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.chattymin.poketokenbar</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Entry point for a trade invite link (poketokenbar://trade?server=&session=). Registration
         here is required for AppDelegate.application(_:open:) to receive the open event for this
         scheme from macOS. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>io.github.chattymin.poketokenbar.trade</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array><string>poketokenbar</string></array>
        </dict>
    </array>
    <!-- ATS 는 기본값이 이미 이렇지만 명시한다 — 감사자가 Info.plist 만 보고 "이 앱은 평문 HTTP 를
         쓰지 않는다"를 확인할 수 있어야 하고, 나중에 예외가 추가되면 diff 에 드러난다. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><false/>
        <key>NSAllowsArbitraryLoadsInWebContent</key><false/>
        <key>NSAllowsLocalNetworking</key><false/>
    </dict>
</dict>
</plist>
PLIST

# LaunchAgent 두 벌 — 정확히 하나만 등록된다(LoginItem.swift 가 전환).
#   1) …login          RunAtLoad 만. 기본값이자 구버전과 같은 label 이라 기존 등록이 그대로 유효하다.
#   2) …autorestart    RunAtLoad + KeepAlive. 크래시/OOM(exit≠0) 자동 재실행 — 설정에서 켤 때만.
# 지속성 수준을 사용자가 고르게 하려고 나눴다: "로그인 시 실행"과 "죽으면 되살아남"은 다른 약속이고,
# 후자는 엔드포인트 보안 도구가 주시하는 동작이다.
# ProgramArguments 는 설치 경로(/Applications) 고정. codesign 전에 생성해 서명 seal 에 포함.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/io.github.chattymin.poketokenbar.login.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>io.github.chattymin.poketokenbar.login</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENT

cat > "$APP/Contents/Library/LaunchAgents/io.github.chattymin.poketokenbar.autorestart.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>io.github.chattymin.poketokenbar.autorestart</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENT

echo "==> codesign (hardened runtime)"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Local}"
# --options runtime 을 붙이는 이유: 하드닝 런타임은 **라이브러리 검증**을 켠다 — 같은 팀 서명이 아닌
# dylib 은 프로세스에 로드되지 않고, DYLD_INSERT_LIBRARIES 류 주입도 무시된다. 이 앱은 살아있는
# Claude OAuth 토큰을 메모리에 들고 있으므로, 사용자 권한으로 도는 아무 코드나 이 프로세스에 붙을 수
# 있는 상태여서는 안 된다. 엔타이틀먼트는 일부러 하나도 주지 않는다(가장 제한적인 구성).
# 자체 서명 인증서로도 하드닝 런타임은 그대로 적용된다 — 공증(notarization)만 Developer ID 가 필요하다.
if security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    # 안정적 자체 서명 신원 → 재빌드해도 Keychain "항상 허용" 유지
    codesign --force --options runtime -s "$SIGN_IDENTITY" "$APP"
else
    # 인증서 없음 → ad-hoc (빌드마다 cdhash 변경 = Keychain 재프롬프트 가능)
    if [[ "${PTB_REQUIRE_STABLE_SIGN:-0}" == "1" ]]; then
        # 릴리스 경로(release.sh 가 세팅). ad-hoc 릴리스는 사용자 Keychain 승인을 깨므로 절대 금지.
        echo "   ✗ PTB_REQUIRE_STABLE_SIGN=1 인데 '$SIGN_IDENTITY' 유효 identity 없음 → ad-hoc 금지, 중단." >&2
        echo "     ./scripts/create-signing-cert.sh 실행 후 다시 시도하세요." >&2
        exit 1
    fi
    echo "   ('$SIGN_IDENTITY' 유효 codesigning identity 없음 → ad-hoc 서명 — 로컬 개발용)"
    echo "   반복 Keychain 허용 프롬프트를 줄이려면 ./scripts/create-signing-cert.sh 실행 후 다시 빌드하세요."
    codesign --force --options runtime -s - "$APP"
fi

# 서명 검증 — 하드닝 런타임 플래그가 실제로 붙었는지 확인한다. codesign 이 조용히 성공해 놓고
# 플래그가 빠지면 이 스크립트의 목적 자체가 사라지므로, 확인 없이 통과시키지 않는다.
echo "==> 서명 검증"
codesign --verify --strict --deep "$APP"
# `grep -q` 를 쓰지 않는다. -q 는 첫 매치에서 즉시 파이프를 닫아 codesign 에 SIGPIPE(141)를 주고,
# `set -o pipefail` 아래에서는 그 신호가 파이프라인 종료코드가 된다 → **검사에 통과한 빌드가
# 실패로 보고되고** 이 줄 아래의 설치가 통째로 건너뛰어진다(실측: 앱이 /Applications 에 안 깔림).
# -q 를 빼면 grep 이 입력을 끝까지 읽으므로 조기 close 가 없다.
if codesign -d --verbose=2 "$APP" 2>&1 | grep 'flags=.*runtime' >/dev/null; then
    echo "   ✓ hardened runtime 적용됨"
else
    echo "   ✗ hardened runtime 플래그가 없습니다 — 서명 단계를 확인하세요." >&2
    exit 1
fi

echo "==> 기존 인스턴스 종료 + /Applications 설치"
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" /Applications/

echo "완료: open /Applications/$APP_NAME.app"
