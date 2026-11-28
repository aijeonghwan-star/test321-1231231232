#!/usr/bin/env python3
"""비교 대상 목소리 DB 만들기.

폴더 구조:
    voices/
      캐릭터/
        도라에몽/            <- 폴더 이름이 앱에 표시되는 이름
          01.wav
          02.mp3
      영화/
        ...
      유명인/
        ...

사용법:
    pip install sherpa-onnx numpy soundfile
    python tools/build_db.py                # voices/ -> assets/voice_db.json

각 사람/캐릭터마다 다른 장면의 깨끗한 음성 3~10개(각 5~20초)를 넣으면
정확도가 좋아집니다. 배경음악이 없는 대사 구간이 가장 좋습니다.
wav가 아닌 파일(mp3, m4a 등)은 ffmpeg가 설치되어 있어야 합니다.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import sherpa_onnx

ROOT = Path(__file__).resolve().parent.parent
SR = 16000
AUDIO_EXT = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".webm", ".mp4"}


def load_audio(path: Path) -> np.ndarray:
    """오디오를 16kHz 모노 float32로 읽기."""
    if shutil.which("ffmpeg"):
        out = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR),
             "-f", "f32le", "-"],
            capture_output=True, check=True,
        ).stdout
        return np.frombuffer(out, dtype=np.float32)
    import soundfile as sf
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    data = data.mean(axis=1)
    if sr != SR:
        # 간단한 선형 보간 리샘플링 (ffmpeg가 없을 때만 사용)
        n = int(len(data) * SR / sr)
        data = np.interp(np.linspace(0, len(data) - 1, n), np.arange(len(data)), data)
    return data.astype(np.float32)


def trim_silence(x: np.ndarray, frame=400, thresh_db=-40.0) -> np.ndarray:
    """앞뒤/중간의 무음 프레임 제거."""
    if len(x) < frame:
        return x
    n = len(x) // frame
    frames = x[: n * frame].reshape(n, frame)
    rms = np.sqrt((frames ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms / (rms.max() + 1e-12))
    keep = frames[db > thresh_db]
    return keep.reshape(-1) if len(keep) else x


def embed(extractor, samples: np.ndarray) -> np.ndarray:
    s = extractor.create_stream()
    s.accept_waveform(SR, samples)
    s.input_finished()
    e = np.array(extractor.compute(s), dtype=np.float32)
    return e / (np.linalg.norm(e) + 1e-9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voices", default=str(ROOT / "voices"))
    ap.add_argument("--model", default=str(ROOT / "assets/models/speaker.onnx"))
    ap.add_argument("--out", default=str(ROOT / "assets/voice_db.json"))
    args = ap.parse_args()

    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
        sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=args.model, num_threads=2)
    )
    voices = Path(args.voices)
    entries = []
    # voices/<카테고리>/<이름>/파일  또는  voices/<이름>/파일
    person_dirs = []
    for d in sorted(p for p in voices.iterdir() if p.is_dir()):
        subdirs = [p for p in d.iterdir() if p.is_dir()]
        if subdirs:
            person_dirs += [(d.name, p) for p in sorted(subdirs)]
        else:
            person_dirs.append(("기타", d))

    for category, pdir in person_dirs:
        files = sorted(f for f in pdir.iterdir() if f.suffix.lower() in AUDIO_EXT)
        embs = []
        for f in files:
            try:
                x = trim_silence(load_audio(f))
            except Exception as ex:  # noqa: BLE001
                print(f"  ! {f.name} 읽기 실패: {ex}")
                continue
            if len(x) < SR * 1.5:
                print(f"  ! {f.name} 너무 짧음 (1.5초 이상 필요)")
                continue
            embs.append(embed(extractor, x))
        if not embs:
            print(f"- {category}/{pdir.name}: 사용할 수 있는 음성 없음, 건너뜀")
            continue
        mean = np.mean(embs, axis=0)
        mean /= np.linalg.norm(mean) + 1e-9
        entries.append({
            "name": pdir.name,
            "category": category,
            "samples": len(embs),
            "embedding": [round(float(v), 5) for v in mean],
        })
        print(f"- {category}/{pdir.name}: 음성 {len(embs)}개")

    if not entries:
        sys.exit("목소리가 하나도 없습니다. voices/ 폴더 구조를 확인하세요.")
    db = {"version": 1, "dim": extractor.dim, "entries": entries}
    Path(args.out).write_text(json.dumps(db, ensure_ascii=False), encoding="utf-8")
    print(f"\n완료: {len(entries)}명 -> {args.out}")


if __name__ == "__main__":
    main()
