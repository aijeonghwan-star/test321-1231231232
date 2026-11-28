import 'dart:math' as math;
import 'dart:typed_data';

/// 실시간 음성 특징 추출 (16kHz 기준).
/// 프레임 64ms(1024샘플), 20ms(320샘플)마다 한 번씩 계산합니다.
const int kSr = 16000;
const int kWin = 1024;
const int kHop = 320;
const double kMinF0 = 60;
const double kMaxF0 = 500;
const double kSilenceDb = -45;

/// 한 프레임의 특징. f0 == 0이면 무성음/무음.
class Frame {
  const Frame(this.time, this.f0, this.db, this.centroid);
  final double time; // 초
  final double f0; // Hz
  final double db; // 음량 (dBFS)
  final double centroid; // 음색 밝기 (Hz)
  bool get voiced => f0 > 0;
  /// 음높이를 반음 단위(MIDI 번호)로. A4(440Hz) = 69
  double get semitone => 12 * math.log(f0 / 440) / math.ln2 + 69;
}

/// 마이크 조각을 계속 넣으면 20ms마다 Frame을 만들어 줍니다.
class FeatureExtractor {
  final List<double> _buf = [];
  int _frameIndex = 0;
  final Float64List _hann = Float64List.fromList(
      List.generate(kWin, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * i / (kWin - 1))));

  void reset() {
    _buf.clear();
    _frameIndex = 0;
  }

  List<Frame> add(List<double> samples) {
    _buf.addAll(samples);
    final out = <Frame>[];
    while (_buf.length >= kWin) {
      final fr = Float64List.fromList(_buf.sublist(0, kWin));
      out.add(analyze(fr, _frameIndex * kHop / kSr));
      _buf.removeRange(0, kHop);
      _frameIndex++;
    }
    return out;
  }

  Frame analyze(Float64List fr, double time) {
    double sum = 0;
    for (final v in fr) {
      sum += v * v;
    }
    final db = 10 * math.log(sum / kWin + 1e-18) / math.ln10;
    if (db < kSilenceDb) return Frame(time, 0, db, 0);
    final f0 = _yin(fr);
    final centroid = f0 > 0 ? _centroid(fr) : 0.0;
    return Frame(time, f0, db, centroid);
  }

  /// YIN 음높이 추정
  double _yin(Float64List x) {
    const half = kWin ~/ 2;
    final tMin = kSr ~/ kMaxF0;
    final tMax = kSr ~/ kMinF0;
    final d = Float64List(tMax + 2);
    for (int t = 1; t < d.length; t++) {
      double s = 0;
      for (int i = 0; i < half; i++) {
        final diff = x[i] - x[i + t];
        s += diff * diff;
      }
      d[t] = s;
    }
    final cm = Float64List(d.length)..[0] = 1;
    double run = 0;
    for (int t = 1; t < d.length; t++) {
      run += d[t];
      cm[t] = run > 0 ? d[t] * t / run : 1;
    }
    for (int t = tMin; t < tMax; t++) {
      if (cm[t] < 0.15) {
        while (t + 1 < tMax && cm[t + 1] < cm[t]) {
          t++;
        }
        final a = cm[t - 1], b = cm[t], c = cm[t + 1];
        final den = a - 2 * b + c;
        final tt = t + (den.abs() > 1e-12 ? 0.5 * (a - c) / den : 0);
        return kSr / tt;
      }
    }
    return 0;
  }

  /// 스펙트럼 무게중심 (0~4kHz). 값이 클수록 밝고 날카로운 소리.
  double _centroid(Float64List x) {
    final re = Float64List(kWin), im = Float64List(kWin);
    for (int i = 0; i < kWin; i++) {
      re[i] = x[i] * _hann[i];
    }
    fft(re, im);
    final maxBin = 4000 * kWin ~/ kSr;
    double num = 0, den = 0;
    for (int k = 1; k <= maxBin; k++) {
      final mag = math.sqrt(re[k] * re[k] + im[k] * im[k]);
      num += k * kSr / kWin * mag;
      den += mag;
    }
    return den > 0 ? num / den : 0;
  }
}

/// 제자리 radix-2 FFT
void fft(Float64List re, Float64List im) {
  final n = re.length;
  for (int i = 1, j = 0; i < n; i++) {
    int bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (int len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (int i = 0; i < n; i += len) {
      double cr = 1, ci = 0;
      for (int k = 0; k < len ~/ 2; k++) {
        final ar = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
        final ai = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
        re[i + k + len ~/ 2] = re[i + k] - ar;
        im[i + k + len ~/ 2] = im[i + k] - ai;
        re[i + k] += ar;
        im[i + k] += ai;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

/// 여러 프레임을 요약한 목소리 특성
class VoiceStats {
  VoiceStats(this.pitch, this.range, this.brightness, this.voicedCount);
  final double pitch; // 음높이 중앙값 (반음)
  final double range; // 억양 폭 (반음 표준편차)
  final double brightness; // 밝기 중앙값 (Hz)
  final int voicedCount;

  static VoiceStats? of(Iterable<Frame> frames, {int minVoiced = 15}) {
    final v = frames.where((f) => f.voiced).toList();
    if (v.length < minVoiced) return null;
    final st = v.map((f) => f.semitone).toList();
    final mean = st.reduce((a, b) => a + b) / st.length;
    final sd = math.sqrt(st.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) / st.length);
    return VoiceStats(_median(st), sd, _median(v.map((f) => f.centroid).toList()), v.length);
  }
}

double _median(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

/// 음높이 곡선을 부드럽게 (5프레임 중앙값 필터, 옥타브 튐 제거용)
List<Frame> smoothPitch(List<Frame> frames) {
  final out = <Frame>[];
  for (int i = 0; i < frames.length; i++) {
    final f = frames[i];
    if (!f.voiced) {
      out.add(f);
      continue;
    }
    final win = <double>[];
    for (int j = math.max(0, i - 2); j <= math.min(frames.length - 1, i + 2); j++) {
      if (frames[j].voiced) win.add(frames[j].f0);
    }
    out.add(Frame(f.time, _median(win), f.db, f.centroid));
  }
  return out;
}

/// 어떻게 바꿔야 하는지 알려 주는 문장들
class Advice {
  Advice(this.label, this.text, this.ok);
  final String label;
  final String text;
  final bool ok;
}

List<Advice> adviseFor(VoiceStats me, VoiceStats target) {
  final out = <Advice>[];
  final dp = me.pitch - target.pitch;
  if (dp.abs() < 1) {
    out.add(Advice('음높이', '좋아요! 높이가 맞아요', true));
  } else {
    final n = dp.abs().round();
    out.add(Advice('음높이', dp < 0 ? '반음 $n개만큼 더 높게' : '반음 $n개만큼 더 낮게', false));
  }
  final rr = me.range / (target.range + 1e-6);
  if (rr < 0.7) {
    out.add(Advice('억양', '억양을 더 크게 오르내리세요', false));
  } else if (rr > 1.4) {
    out.add(Advice('억양', '억양을 더 평평하게 말하세요', false));
  } else {
    out.add(Advice('억양', '좋아요! 억양 폭이 비슷해요', true));
  }
  final br = me.brightness / (target.brightness + 1e-6);
  if (br < 0.87) {
    out.add(Advice('음색', '더 밝게: 입꼬리를 올리고 입 앞쪽에서 소리 내기', false));
  } else if (br > 1.15) {
    out.add(Advice('음색', '더 어둡게: 입 안을 넓히고 목 뒤쪽을 울리기', false));
  } else {
    out.add(Advice('음색', '좋아요! 밝기가 비슷해요', true));
  }
  return out;
}

/// PCM16 WAV 바이트 → 16kHz 모노 float (16kHz 모노 WAV만 지원; tools/prepare_targets.py로 변환)
Float32List decodeWav16k(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  int pos = 12;
  int channels = 1, sr = kSr, bits = 16;
  while (pos + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final size = bd.getUint32(pos + 4, Endian.little);
    if (id == 'fmt ') {
      channels = bd.getUint16(pos + 10, Endian.little);
      sr = bd.getUint32(pos + 12, Endian.little);
      bits = bd.getUint16(pos + 22, Endian.little);
    } else if (id == 'data') {
      if (bits != 16 || sr != kSr) {
        throw FormatException('16kHz 16bit WAV만 지원해요 (현재 ${sr}Hz ${bits}bit)');
      }
      final end = math.min(bytes.length, pos + 8 + size);
      final n = (end - pos - 8) ~/ (2 * channels);
      final out = Float32List(n);
      for (int i = 0; i < n; i++) {
        double s = 0;
        for (int c = 0; c < channels; c++) {
          s += bd.getInt16(pos + 8 + (i * channels + c) * 2, Endian.little);
        }
        out[i] = s / channels / 32768.0;
      }
      return out;
    }
    pos += 8 + size + (size & 1);
  }
  throw const FormatException('WAV 데이터가 없어요');
}

/// 16kHz 모노 float → PCM16 WAV 바이트
Uint8List encodeWav16k(Float32List x) {
  final n = x.length;
  final out = Uint8List(44 + n * 2);
  final bd = ByteData.sublistView(out);
  void str(int o, String s) {
    for (int i = 0; i < s.length; i++) {
      out[o + i] = s.codeUnitAt(i);
    }
  }

  str(0, 'RIFF');
  bd.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, 1, Endian.little); // mono
  bd.setUint32(24, kSr, Endian.little);
  bd.setUint32(28, kSr * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  str(36, 'data');
  bd.setUint32(40, n * 2, Endian.little);
  for (int i = 0; i < n; i++) {
    bd.setInt16(44 + i * 2, (x[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return out;
}
