import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dsp.dart';

/// 흉내 낼 목소리 하나. 앱에 들어 있는 것(asset) 또는 사용자가 추가한 것(file).
class Target {
  Target(this.name, this.samples, this.frames, this.stats, {this.asset, this.file});
  final String name;
  final String? asset; // assets/targets/xxx.wav
  final String? file; // 앱 저장소의 wav 경로
  final Float32List samples;
  final List<Frame> frames;
  final VoiceStats? stats;
  Float32List? embedding;

  bool get isUser => file != null;
  double get duration => samples.length / kSr;
  Source get source =>
      file != null ? DeviceFileSource(file!) : AssetSource(asset!.replaceFirst('assets/', ''));
}

/// 클로저가 samples만 붙잡도록 최상위 함수로 분리 (isolate로 보낼 수 있게)
Future<List<Frame>> analyzeInBackground(Float32List samples) =>
    Isolate.run(() => smoothPitch(FeatureExtractor().add(samples)));

Future<Target> buildTarget(String name, Float32List samples, {String? asset, String? file}) async {
  final frames = await analyzeInBackground(samples);
  return Target(name, samples, frames, VoiceStats.of(frames), asset: asset, file: file);
}

class TargetStore {
  static Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'targets'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 내가 추가한 목소리(최근 것 먼저) + 앱 기본 목소리
  static Future<List<Target>> loadAll() async {
    final out = <Target>[];
    final d = await _dir();
    final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.wav')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final f in files) {
      try {
        final s = decodeWav16k(await f.readAsBytes());
        out.add(await buildTarget(p.basenameWithoutExtension(f.path), s, file: f.path));
      } catch (_) {}
    }
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((a) => a.startsWith('assets/targets/') && a.toLowerCase().endsWith('.wav'))
        .toList()
      ..sort();
    for (final a in assets) {
      final data = await rootBundle.load(a);
      final s = decodeWav16k(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      var file = a.split('/').last;
      try {
        file = Uri.decodeComponent(file);
      } catch (_) {}
      out.add(await buildTarget(file.replaceAll(RegExp(r'\.wav$', caseSensitive: false), ''), s, asset: a));
    }
    return out;
  }

  /// 새 목소리 저장. 같은 이름이 있으면 덮어씁니다.
  static Future<Target> save(String name, Float32List samples) async {
    final safe = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final f = File(p.join((await _dir()).path, '${safe.isEmpty ? '새 목소리' : safe}.wav'));
    await f.writeAsBytes(encodeWav16k(samples));
    return buildTarget(p.basenameWithoutExtension(f.path), samples, file: f.path);
  }

  static Future<void> delete(Target t) async {
    if (t.file != null) {
      final f = File(t.file!);
      if (await f.exists()) await f.delete();
    }
  }

  /// 미리듣기용 임시 wav
  static Future<String> writeTemp(Float32List samples) async {
    final f = File(p.join((await getTemporaryDirectory()).path, 'preview.wav'));
    await f.writeAsBytes(encodeWav16k(samples));
    return f.path;
  }
}
