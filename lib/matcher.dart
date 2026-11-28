import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const int kSampleRate = 16000;

class VoiceEntry {
  VoiceEntry(this.name, this.category, this.embedding);
  final String name;
  final String category;
  final Float32List embedding;
}

class MatchResult {
  MatchResult(this.entry, this.cosine);
  final VoiceEntry entry;
  final double cosine;
  int get percent => similarityPercent(cosine);
}

/// 화면 표시용 점수(0~100). 코사인 유사도 0.2 이하를 0%, 0.9 이상을 100%로 봅니다.
/// 같은 사람의 다른 녹음은 보통 0.7 이상, 전혀 다른 사람은 0.0~0.4 정도가 나옵니다.
int similarityPercent(double cos) => ((cos - 0.2) / 0.7 * 100).clamp(0, 100).round();

/// 모델 파일 경로 (앱 저장소로 복사된 위치)
Future<String> speakerModelPath() => _copyAsset('assets/models/speaker.onnx');

/// 닮은꼴 찾기용 DB
class VoiceMatcher {
  VoiceMatcher._(this.modelPath, this.entries);
  final String modelPath;
  final List<VoiceEntry> entries;

  static Future<VoiceMatcher> load() async {
    final modelPath = await speakerModelPath();
    final raw = await rootBundle.loadString('assets/voice_db.json');
    final db = jsonDecode(raw) as Map<String, dynamic>;
    final entries = (db['entries'] as List).map((e) {
      final m = e as Map<String, dynamic>;
      final emb = Float32List.fromList(
          (m['embedding'] as List).map((v) => (v as num).toDouble()).toList());
      return VoiceEntry(m['name'] as String, m['category'] as String? ?? '기타',
          normalize(emb));
    }).toList();
    return VoiceMatcher._(modelPath, entries);
  }

  /// 녹음된 음성(16kHz, -1~1 float)을 분석해 닮은 순서대로 돌려줍니다.
  Future<List<MatchResult>> match(Float32List samples) async {
    final emb = await EmbeddingWorker.instance(modelPath).embed(samples);
    return entries.map((e) => MatchResult(e, cosine(emb, e.embedding))).toList()
      ..sort((a, b) => b.cosine.compareTo(a.cosine));
  }
}

/// 화자 임베딩 모델을 별도 isolate에 한 번만 올려 두고 계속 재사용합니다.
/// 화면이 멈추지 않고, 실시간 비교에서 1~2초마다 호출해도 가볍습니다.
class EmbeddingWorker {
  EmbeddingWorker._(this._modelPath);
  static EmbeddingWorker? _instance;
  static EmbeddingWorker instance(String modelPath) =>
      _instance ??= EmbeddingWorker._(modelPath);

  final String _modelPath;
  SendPort? _send;
  Future<void>? _starting;
  int _nextId = 0;
  final Map<int, Completer<Float32List>> _pending = {};

  Future<void> _start() async {
    final rp = ReceivePort();
    await Isolate.spawn(_workerMain, [rp.sendPort, _modelPath]);
    final ready = Completer<void>();
    rp.listen((msg) {
      if (msg is SendPort) {
        _send = msg;
        ready.complete();
      } else if (msg is List) {
        final c = _pending.remove(msg[0] as int);
        if (msg[1] is Float32List) {
          c?.complete(msg[1] as Float32List);
        } else {
          c?.completeError(Exception(msg[1].toString()));
        }
      }
    });
    await ready.future;
  }

  /// 길이 1로 정규화된 임베딩을 돌려줍니다.
  Future<Float32List> embed(Float32List samples) async {
    await (_starting ??= _start());
    final id = _nextId++;
    final c = Completer<Float32List>();
    _pending[id] = c;
    _send!.send([id, samples]);
    return c.future;
  }
}

void _workerMain(List<dynamic> args) {
  final reply = args[0] as SendPort;
  final modelPath = args[1] as String;
  sherpa.initBindings();
  final extractor = sherpa.SpeakerEmbeddingExtractor(
    config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: modelPath, numThreads: 2, debug: false),
  );
  final rp = ReceivePort();
  reply.send(rp.sendPort);
  rp.listen((msg) {
    final m = msg as List;
    try {
      final stream = extractor.createStream();
      stream.acceptWaveform(
          samples: trimSilence(m[1] as Float32List), sampleRate: kSampleRate);
      stream.inputFinished();
      final emb = normalize(extractor.compute(stream));
      stream.free();
      reply.send([m[0], emb]);
    } catch (e) {
      reply.send([m[0], e.toString()]);
    }
  });
}

/// 조용한 구간(최대 음량 대비 -40dB 이하)을 잘라냅니다. build_db.py와 같은 방식.
Float32List trimSilence(Float32List x, {int frame = 400, double threshDb = -40}) {
  final n = x.length ~/ frame;
  if (n == 0) return x;
  final rms = List<double>.generate(n, (i) {
    double s = 0;
    for (int j = i * frame; j < (i + 1) * frame; j++) {
      s += x[j] * x[j];
    }
    return math.sqrt(s / frame + 1e-12);
  });
  final maxRms = rms.reduce(math.max) + 1e-12;
  final out = <double>[];
  for (int i = 0; i < n; i++) {
    if (20 * math.log(rms[i] / maxRms) / math.ln10 > threshDb) {
      out.addAll(x.sublist(i * frame, (i + 1) * frame));
    }
  }
  return out.isEmpty ? x : Float32List.fromList(out);
}

Float32List normalize(Float32List v) {
  double s = 0;
  for (final x in v) {
    s += x * x;
  }
  final n = math.sqrt(s) + 1e-9;
  return Float32List.fromList(v.map((x) => x / n).toList());
}

double cosine(Float32List a, Float32List b) {
  double s = 0;
  for (int i = 0; i < a.length && i < b.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

Future<String> _copyAsset(String src) async {
  final dir = await getApplicationSupportDirectory();
  final target = p.join(dir.path, p.basename(src));
  final data = await rootBundle.load(src);
  final f = File(target);
  if (!await f.exists() || await f.length() != data.lengthInBytes) {
    await f.create(recursive: true);
    await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }
  return target;
}
