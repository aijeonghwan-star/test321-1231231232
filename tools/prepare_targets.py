#!/usr/bin/env python3
"""흉내 낼 타깃 목소리를 앱용 WAV(16kHz, 모노, 16bit)로 변환해 assets/targets/에 넣습니다.

사용법:
    python tools/prepare_targets.py 원본.mp3 [원본2.m4a ...]
    python tools/prepare_targets.py 원본.mp4 --name "캐릭터 대사1" --start 12.5 --end 20

- 파일 이름(또는 --name)이 앱의 목록에 그대로 표시됩니다.
- 앞뒤 무음은 자동으로 잘라 내고, 최대 15초까지만 씁니다.
- 배경음악 없이 대사만 있는 3~10초 구간이 가장 좋습니다.
- ffmpeg가 필요합니다.
"""
import argparse
import subprocess
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SR = 16000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--name", help="표시 이름 (파일 1개일 때)")
    ap.add_argument("--start", type=float, help="시작 시각(초)")
    ap.add_argument("--end", type=float, help="끝 시각(초)")
    ap.add_argument("--max", type=float, default=15.0, help="최대 길이(초)")
    args = ap.parse_args()

    out_dir = ROOT / "assets/targets"
    out_dir.mkdir(parents=True, exist_ok=True)
    for f in args.files:
        cmd = ["ffmpeg", "-v", "error"]
        if args.start is not None:
            cmd += ["-ss", str(args.start)]
        if args.end is not None:
            cmd += ["-to", str(args.end)]
        cmd += ["-i", f, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"]
        x = np.frombuffer(subprocess.run(cmd, capture_output=True, check=True).stdout, np.float32)

        # 앞뒤 무음 자르기
        frame = 320
        n = len(x) // frame
        rms = np.sqrt((x[: n * frame].reshape(n, frame) ** 2).mean(1) + 1e-12)
        loud = np.where(20 * np.log10(rms / rms.max()) > -35)[0]
        if len(loud):
            x = x[max(0, loud[0] - 5) * frame: (loud[-1] + 5) * frame]
        x = x[: int(args.max * SR)]
        # 음량 맞추기 (최대 -1dBFS)
        x = x / (np.abs(x).max() + 1e-9) * 0.89

        name = args.name if (args.name and len(args.files) == 1) else Path(f).stem
        dst = out_dir / f"{name}.wav"
        with wave.open(str(dst), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((x * 32767).astype("<i2").tobytes())
        print(f"{dst.relative_to(ROOT)}  ({len(x) / SR:.1f}초)")


if __name__ == "__main__":
    main()
