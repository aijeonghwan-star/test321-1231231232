# 목소리 흉내 연습 (Voice Match)

흉내 내고 싶은 목소리를 고르고 따라 말하면, **실시간 그래프**로 내 목소리와 타깃 목소리를 비교해
어떻게 바꿔야 비슷해지는지 알려 주는 Flutter 앱입니다 (안드로이드·iOS).
분석은 전부 **폰 안에서** 하고, 음성은 어디로도 전송되지 않습니다.

## 화면 구성

**① 흉내 연습 탭 (메인)**
- 타깃 목소리 선택 + ▶ 듣기
- **음높이 곡선**: 타깃 곡선(회색) 위에 내 목소리 곡선(보라)이 말하는 동안 20ms마다 그려집니다.
  타깃 길이만큼 그리면 처음부터 다시 그려서 반복 연습할 수 있어요.
- **게이지 3개**: 가운데 선이 타깃, 동그라미가 나 (최근 2초 기준). 초록 구간에 들어오면 OK
  - 음높이: 목소리 높낮이 (반음 단위)
  - 억양 폭: 말할 때 음이 얼마나 오르내리는지
  - 음색 밝기: 소리가 밝고 날카로운지, 어둡고 둥근지
- **조언**: "반음 3개만큼 더 높게", "더 어둡게: 입 안을 넓히고…" 처럼 바로 따라 할 수 있는 문장
- **AI 음색 유사도(%)**: 1.5초마다 최근 3초를 화자 인식 AI로 타깃과 비교한 점수

**② 닮은꼴 찾기 탭**
- 한 번 녹음하면 등록된 목소리 DB에서 가장 닮은 목소리 순위를 보여 줍니다

## 기술 구성

| 항목 | 방법 | 파일 |
|---|---|---|
| 음높이 | YIN 알고리즘 (60~500Hz) | `lib/dsp.dart` |
| 음색 밝기 | FFT 스펙트럼 무게중심 (0~4kHz) | `lib/dsp.dart` |
| 음색 유사도 | WeSpeaker ResNet34 화자 임베딩 + 코사인 유사도 (sherpa-onnx) | `lib/matcher.dart` |
| 화면 | 흉내 연습 / 목소리 추가 / 닮은꼴 찾기 | `lib/imitate_screen.dart`, `lib/add_target_screen.dart`, `lib/match_screen.dart` |
| 파일 디코딩·내부 소리 녹음 | MediaCodec, AudioPlaybackCapture (안드로이드 네이티브) | `native/android/*.kt` |

AI 모델은 별도 isolate에서 한 번만 올려 두고 재사용하기 때문에 실시간 그래프가 끊기지 않습니다.

## 1. 흉내 낼 목소리 넣기

**앱에서 바로 추가 (안드로이드)**: 흉내 연습 화면의 ⊕ 버튼을 눌러요.
- **폰 소리 녹음**: 유튜브 등에서 재생되는 소리를 그대로 녹음 (안드로이드 10+, 최대 2분).
  유튜브 앱이 녹음을 막으면 Chrome에서 youtube.com으로 재생해 보세요
- **파일에서 가져오기**: mp3, m4a, wav, mp4 영상 등
- **마이크로 녹음**: 아이폰에서도 됩니다
- 가져온 뒤 파형을 보며 5~20초 구간을 골라 미리 듣고 저장합니다. 추가한 목소리는 앱에 계속 남고, 삭제도 할 수 있어요

**앱에 기본으로 넣기**: PC에 ffmpeg와 파이썬이 있으면:

```bash
pip install numpy
python tools/prepare_targets.py 대사.mp3
python tools/prepare_targets.py 영화.mp4 --name "주인공 명대사" --start 62 --end 70
```

`assets/targets/`에 16kHz WAV로 변환돼 들어가고, 파일 이름이 앱 목록에 표시됩니다.
지금은 테스트용 합성 음성 2개(남성/여성)가 들어 있어요. 지워도 됩니다.

- 배경음악·효과음 없이 대사만 나오는 3~10초 구간이 가장 좋습니다
- 직접 16kHz 모노 16bit WAV로 만들어 넣어도 됩니다

## 2. (선택) 닮은꼴 찾기 DB 만들기

`voices/카테고리/이름/`에 한 명당 음성 3~10개를 넣고:

```bash
pip install sherpa-onnx numpy soundfile
python tools/build_db.py
```

## 3-A. 컴퓨터 없이 APK 받기 (안드로이드, 가장 쉬움)

1. GitHub에 새 저장소를 만들고 이 폴더를 통째로 올립니다 (`main` 브랜치)
2. 저장소의 **Actions** 탭에서 "Build Android APK"가 끝날 때까지 기다립니다 (약 10분)
3. 완료된 실행을 열고 **voice-match-apk**를 내려받아 폰에 설치합니다
   (폰에서 "출처를 알 수 없는 앱 설치"를 허용해야 합니다)

타깃 목소리를 바꾸려면 `assets/targets/`의 파일을 바꿔서 다시 올리면 새 APK가 만들어집니다.

## 3-B. 내 컴퓨터에서 빌드하기

[Flutter](https://docs.flutter.dev/get-started/install)와 Android Studio(아이폰은 Mac + Xcode)를 설치한 뒤:

```bash
bash tools/setup_platforms.sh   # 처음 한 번만 (android/ios 폴더 생성 + 마이크 권한)
flutter run --release           # USB로 연결한 폰에 설치·실행
```

아이폰은 Xcode에서 `ios/Runner.xcworkspace`를 열고 Signing에 본인 Apple ID 팀을 지정해야 설치됩니다.

## 연습 팁과 한계

- **이어폰**을 끼고 타깃을 들으면서 따라 하면 좋습니다 (스피커 소리가 마이크로 들어가면 그래프가 섞여요)
- 음색 밝기는 마이크와 방 울림에 영향을 받습니다. 같은 장소에서 연습하면 비교가 일정해요
- AI 유사도는 "같은 사람처럼 들리는 정도"라 흉내로 80% 이상 올리기는 어렵습니다. 점수의 **변화**를 보면서 연습하세요
- 점수 계산식은 `lib/matcher.dart`의 `similarityPercent`, 조언 기준은 `lib/dsp.dart`의 `adviseFor`에서 바꿀 수 있어요
- 실제 배우·성우·유명인의 음성을 넣은 앱을 스토어에 공개하려면 저작권과 퍼블리시티권 검토가 필요합니다
