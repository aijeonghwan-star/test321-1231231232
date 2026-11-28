#!/usr/bin/env bash
# android/ios 폴더를 만들고 마이크 권한을 넣습니다. 프로젝트 폴더에서 한 번만 실행하세요.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --platforms=android,ios --org com.example --project-name voice_match .
rm -f test/widget_test.dart

# Android: 네이티브 코드(파일 디코딩, 내부 소리 녹음) 복사
KT=android/app/src/main/kotlin/com/example/voice_match
mkdir -p "$KT"
cp native/android/*.kt "$KT/"

# Android: 권한, 내부 소리 녹음 서비스, 앱 이름, 최소 SDK
M=android/app/src/main/AndroidManifest.xml
grep -q RECORD_AUDIO "$M" || perl -0pi -e 's#<application#<uses-permission android:name="android.permission.RECORD_AUDIO"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"/>\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n    <application#' "$M"
grep -q CaptureService "$M" || perl -0pi -e 's#</application>#    <service android:name=".CaptureService" android:exported="false" android:foregroundServiceType="mediaProjection"/>\n    </application>#' "$M"
perl -pi -e 's#android:label="voice_match"#android:label="목소리 흉내"#' "$M"
for G in android/app/build.gradle.kts android/app/build.gradle; do
  [ -f "$G" ] && perl -pi -e 's#minSdk\s*=\s*flutter\.minSdkVersion#minSdk = 24#; s#minSdkVersion flutter\.minSdkVersion#minSdkVersion 24#' "$G"
done
# 릴리스 빌드 때 lint 검사로 빌드가 멈추지 않게
if [ -f android/app/build.gradle.kts ] && ! grep -q checkReleaseBuilds android/app/build.gradle.kts; then
  printf '\nandroid {\n    lint {\n        checkReleaseBuilds = false\n    }\n}\n' >> android/app/build.gradle.kts
fi

# iOS: 마이크 권한 설명, 앱 이름
P=ios/Runner/Info.plist
grep -q NSMicrophoneUsageDescription "$P" || perl -0pi -e 's#<dict>#<dict>\n\t<key>NSMicrophoneUsageDescription</key>\n\t<string>목소리를 실시간으로 분석하려면 마이크가 필요해요. 음성은 기기 밖으로 전송되지 않아요.</string>#' "$P"
perl -0pi -e 's#(<key>CFBundleDisplayName</key>\s*<string>)[^<]*#${1}목소리 흉내#' "$P"

flutter pub get
echo "준비 완료. 폰을 연결하고 'flutter run --release' 를 실행하세요."
