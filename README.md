# 실시간 자막 (LiveSubs)

폰에서 재생 중인 **영어 음성**(YouTube 등 스트리밍 영상 포함)을 실시간으로 인식해 **한국어 자막**을 화면 위에 띄우는 안드로이드 앱입니다.

## 동작 구조

재생 소리 캡처(AudioPlaybackCapture) → 영어 음성 인식(Vosk, 온디바이스) → 한국어 번역(ML Kit, 온디바이스) → 오버레이 자막

## 빌드 방법

1. Android Studio(최신 버전)에서 이 폴더를 엽니다. Gradle Sync가 자동으로 진행됩니다.
   (Gradle 래퍼 파일은 포함하지 않았습니다. Studio가 안내하는 대로 진행하면 됩니다.)
2. 폰을 USB로 연결(개발자 옵션 + USB 디버깅)하고 Run ▶ 을 누릅니다. Android 10(API 29) 이상 필요.

## 사용 방법

1. 앱 실행 → **모델 준비** (최초 1회, Wi-Fi 권장. 음성 모델 약 40MB + 번역 모델 약 30MB)
2. **실시간 자막 시작** → 권한 안내를 순서대로 허용
   - 다른 앱 위에 표시
   - 녹음 (마이크가 아니라 재생음 캡처에 필요)
   - 화면 공유 팝업: **전체 화면** 선택
3. YouTube 등 영상 앱에서 재생하면 화면 아래에 자막이 뜹니다. 자막 바는 위아래로 드래그 가능.
4. 끝낼 때는 알림의 **중지** 버튼 또는 앱의 "자막 중지".

## 알아둘 점

- Netflix, Disney+ 등 DRM 앱이나 소리 캡처를 막아 둔 앱은 캡처되지 않습니다.
- 기본 Vosk 소형 모델은 가볍지만 인식 정확도가 중간 수준입니다. 더 정확하게 하려면
  `ModelManager.kt`의 `MODEL_NAME`을 `vosk-model-en-us-0.22-lgraph`(약 128MB)로 바꾸세요.
- 일부 기기에서 16kHz 모노 캡처가 거부되면 `CaptureService.kt`의 `SAMPLE_RATE`/채널 설정을 조정해야 할 수 있습니다.
- 인식 엔진을 Whisper 등으로 바꾸거나 번역을 Claude API로 바꾸고 싶다면
  `CaptureService.runRecognizer()`와 `present()` 두 곳만 교체하면 됩니다.
