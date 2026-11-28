import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'dsp.dart';
import 'matcher.dart';

/// 흉내 낼 목소리 하나
class Target {
  Target(this.name, this.asset, this.samples, this.frames, this.stats);
  final String name;
  final String asset; // assets/targets/xxx.wav
  final Float32List samples;
  final List<Frame> frames;
  final VoiceStats? stats;
  Float32List? embedding;
  double get duration => samples.length / kSr;
}

Future<List<Target>> loadTargets() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assets = manifest
      .listAssets()
      .where((a) => a.startsWith('assets/targets/') && a.toLowerCase().endsWith('.wav'))
      .toList()
    ..sort();
  final out = <Target>[];
  for (final a in assets) {
    final data = await rootBundle.load(a);
    final samples = decodeWav16k(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final frames = await _analyzeInBackground(samples);
    var file = a.split('/').last;
    try {
      file = Uri.decodeComponent(file);
    } catch (_) {}
    final name = file.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '');
    out.add(Target(name, a, samples, frames, VoiceStats.of(frames)));
  }
  return out;
}

/// 클로저가 samples만 붙잡도록 최상위 함수로 분리 (isolate로 보낼 수 있게)
Future<List<Frame>> _analyzeInBackground(Float32List samples) =>
    Isolate.run(() => smoothPitch(FeatureExtractor().add(samples)));

class ImitateScreen extends StatefulWidget {
  const ImitateScreen({super.key});

  @override
  State<ImitateScreen> createState() => _ImitateScreenState();
}

class _ImitateScreenState extends State<ImitateScreen> {
  static const _adviceWindow = 2.0; // 최근 2초로 조언 계산
  static const _embedWindowSec = 3; // 최근 3초로 음색 유사도 계산

  List<Target> _targets = [];
  Target? _target;
  String? _error;
  EmbeddingWorker? _worker;

  final _player = AudioPlayer();
  bool _playing = false;

  final _recorder = AudioRecorder();
  final _fx = FeatureExtractor();
  StreamSubscription<Uint8List>? _sub;
  Timer? _embedTimer;
  bool _recording = false;
  bool _embedBusy = false;

  final List<Frame> _pass = []; // 그래프에 그릴 이번 회차 프레임
  final List<Frame> _recent = []; // 조언용 최근 프레임
  final List<double> _recentSamples = [];
  double _passStart = 0;
  double _now = 0;
  Frame? _last;
  List<Advice> _advice = [];
  VoiceStats? _myStats;
  int? _similarity;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
    _init();
  }

  Future<void> _init() async {
    try {
      final targets = await loadTargets();
      final worker = EmbeddingWorker.instance(await speakerModelPath());
      setState(() {
        _targets = targets;
        _worker = worker;
        if (targets.isNotEmpty) _select(targets.first);
      });
    } catch (e) {
      setState(() => _error = '타깃 목소리를 불러오지 못했어요: $e');
    }
  }

  void _select(Target t) {
    _target = t;
    _resetLive();
    if (t.embedding == null) {
      _worker?.embed(t.samples).then((e) => t.embedding = e);
    }
  }

  void _resetLive() {
    _pass.clear();
    _recent.clear();
    _recentSamples.clear();
    _advice = [];
    _myStats = null;
    _similarity = null;
    _passStart = 0;
    _now = 0;
    _last = null;
  }

  @override
  void dispose() {
    _embedTimer?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final t = _target;
    if (t == null) return;
    if (_playing) {
      await _player.stop();
      setState(() => _playing = false);
    } else {
      await _player.play(AssetSource(t.asset.replaceFirst('assets/', '')));
      setState(() => _playing = true);
    }
  }

  Future<void> _toggleRecord() async => _recording ? _stop() : _start();

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _error = '마이크 권한이 필요해요. 설정에서 허용해 주세요.');
      return;
    }
    if (_playing) await _togglePlay();
    _fx.reset();
    setState(_resetLive);
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kSr,
      numChannels: 1,
      echoCancel: false,
      noiseSuppress: false,
      autoGain: false,
    ));
    _sub = stream.listen(_onAudio);
    _embedTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _updateSimilarity());
    setState(() {
      _recording = true;
      _error = null;
    });
  }

  Future<void> _stop() async {
    _embedTimer?.cancel();
    await _recorder.stop();
    await _sub?.cancel();
    _sub = null;
    setState(() => _recording = false);
  }

  void _onAudio(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final samples = List<double>.generate(
        bytes.length ~/ 2, (i) => bd.getInt16(i * 2, Endian.little) / 32768.0);
    _recentSamples.addAll(samples);
    final maxKeep = _embedWindowSec * kSr;
    if (_recentSamples.length > maxKeep) {
      _recentSamples.removeRange(0, _recentSamples.length - maxKeep);
    }
    final frames = _fx.add(samples);
    if (frames.isEmpty) return;
    final t = _target;
    final dur = math.max(t?.duration ?? 5.0, 3.0);
    for (final f in frames) {
      if (f.time - _passStart > dur) {
        _passStart = f.time; // 타깃 길이를 넘으면 처음부터 다시 그림
        _pass.clear();
      }
      _recent.add(f);
      _pass.add(f);
    }
    _now = frames.last.time;
    _recent.removeWhere((f) => f.time < _now - _adviceWindow);
    // 최근 5프레임 중앙값으로 부드럽게 표시
    final tail = smoothPitch(_pass.sublist(math.max(0, _pass.length - 9)));
    _pass.replaceRange(_pass.length - tail.length, _pass.length, tail);
    _last = _pass.last;
    final me = VoiceStats.of(_recent, minVoiced: 12);
    _myStats = me;
    if (me != null && t?.stats != null) _advice = adviseFor(me, t!.stats!);
    setState(() {});
  }

  Future<void> _updateSimilarity() async {
    final t = _target;
    if (_embedBusy || t?.embedding == null || _worker == null) return;
    if (_recentSamples.length < kSr * 1.5) return;
    if (_recent.where((f) => f.voiced).length < 20) return; // 말을 안 하는 중
    _embedBusy = true;
    try {
      final e = await _worker!.embed(Float32List.fromList(_recentSamples));
      final pct = similarityPercent(cosine(e, t!.embedding!));
      if (mounted && _recording) {
        // 점수가 너무 튀지 않게 이전 값과 섞기
        setState(() => _similarity = _similarity == null ? pct : ((_similarity! + pct) / 2).round());
      }
    } finally {
      _embedBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = _target;
    if (_error != null && _targets.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (t == null) {
      return Center(
        child: _targets.isEmpty && _worker != null
            ? const Text('assets/targets/ 폴더에 흉내 낼 목소리(wav)를 넣어 주세요.')
            : const CircularProgressIndicator(),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<Target>(
              value: t,
              decoration: const InputDecoration(labelText: '흉내 낼 목소리', border: OutlineInputBorder()),
              items: [for (final x in _targets) DropdownMenuItem(value: x, child: Text(x.name))],
              onChanged: _recording ? null : (x) => setState(() => _select(x!)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            iconSize: 32,
            onPressed: _togglePlay,
            icon: Icon(_playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
            tooltip: '타깃 목소리 듣기',
          ),
        ]),
        const SizedBox(height: 12),
        _SimilarityCard(similarity: _similarity, recording: _recording),
        const SizedBox(height: 12),
        Row(children: [
          const Text('음높이 곡선', style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          _legend(cs.outlineVariant, '타깃'),
          const SizedBox(width: 12),
          _legend(cs.primary, '나'),
        ]),
        const SizedBox(height: 6),
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: CustomPaint(
            painter: PitchPainter(
              target: t.frames,
              live: _pass,
              duration: math.max(t.duration, 3.0),
              center: t.stats?.pitch ?? 60,
              playhead: _recording ? _now - _passStart : null,
              targetColor: cs.outlineVariant,
              liveColor: cs.primary,
              gridColor: cs.outline.withValues(alpha: 0.2),
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _last?.voiced == true
              ? '지금 내 음높이: ${_last!.f0.round()}Hz (${noteName(_last!.semitone)})'
                  '   타깃: ${t.stats == null ? '-' : noteName(t.stats!.pitch)}'
              : '타깃 평균 음높이: ${t.stats == null ? '-' : noteName(t.stats!.pitch)}',
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
        const SizedBox(height: 16),
        _Gauge(
          label: '음높이',
          value: _myStats == null || t.stats == null ? null : (_myStats!.pitch - t.stats!.pitch) / 6,
          low: '낮음', high: '높음',
        ),
        _Gauge(
          label: '억양 폭',
          value: _myStats == null || t.stats == null
              ? null
              : math.log((_myStats!.range + 0.05) / (t.stats!.range + 0.05)) / math.ln2,
          low: '평평', high: '출렁',
        ),
        _Gauge(
          label: '음색 밝기',
          value: _myStats == null || t.stats == null
              ? null
              : math.log(_myStats!.brightness / t.stats!.brightness) / math.ln2 / 0.5,
          low: '어두움', high: '밝음',
        ),
        const SizedBox(height: 12),
        for (final a in _advice)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(a.ok ? Icons.check_circle : Icons.arrow_forward_rounded,
                color: a.ok ? Colors.green : cs.primary),
            title: Text(a.text),
            subtitle: Text(a.label),
          ),
        if (_recording && _advice.isEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('타깃 목소리처럼 말해 보세요. 2초 정도 말하면 조언이 나와요.', textAlign: TextAlign.center),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: _recording ? Colors.redAccent : null,
          ),
          onPressed: _toggleRecord,
          icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(_recording ? '그만하기' : '따라 말하기 시작'),
        ),
        const SizedBox(height: 8),
        Text('이어폰을 끼면 타깃 소리를 들으면서 연습할 수 있어요.',
            textAlign: TextAlign.center, style: TextStyle(color: cs.outline, fontSize: 12)),
        if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
      ],
    );
  }

  Widget _legend(Color c, String s) => Row(children: [
        Container(width: 14, height: 4, color: c),
        const SizedBox(width: 4),
        Text(s, style: const TextStyle(fontSize: 12)),
      ]);
}

String noteName(double semitone) {
  const names = ['도', '도#', '레', '레#', '미', '파', '파#', '솔', '솔#', '라', '라#', '시'];
  final n = semitone.round();
  return '${names[n % 12]}${n ~/ 12 - 1}';
}

class _SimilarityCard extends StatelessWidget {
  const _SimilarityCard({required this.similarity, required this.recording});
  final int? similarity;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = similarity;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(children: [
          const Expanded(child: Text('AI 음색 유사도', style: TextStyle(fontWeight: FontWeight.bold))),
          Text(
            s == null ? (recording ? '듣는 중…' : '-') : '$s%',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ]),
      ),
    );
  }
}

/// 가운데가 타깃, 바늘이 나. value: -1(왼쪽 끝) ~ 1(오른쪽 끝)
class _Gauge extends StatelessWidget {
  const _Gauge({required this.label, required this.value, required this.low, required this.high});
  final String label;
  final double? value;
  final String low, high;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = value?.clamp(-1.0, 1.0);
    final ok = v != null && v.abs() < 0.17;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 64, child: Text(label, style: const TextStyle(fontSize: 13))),
        Text(low, style: TextStyle(fontSize: 11, color: cs.outline)),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: 24,
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              return Stack(alignment: Alignment.center, children: [
                Container(height: 6, decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(3))),
                Container(width: w * 0.17, height: 6, color: Colors.green.withValues(alpha: 0.4)),
                Container(width: 2, height: 20, color: cs.outline),
                if (v != null)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 150),
                    left: (v + 1) / 2 * (w - 16),
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: ok ? Colors.green : cs.primary),
                    ),
                  ),
              ]);
            }),
          ),
        ),
        const SizedBox(width: 6),
        Text(high, style: TextStyle(fontSize: 11, color: cs.outline)),
      ]),
    );
  }
}

/// 타깃 음높이 곡선(회색) 위에 내 곡선(색)을 겹쳐 그립니다.
class PitchPainter extends CustomPainter {
  PitchPainter({
    required this.target,
    required this.live,
    required this.duration,
    required this.center,
    required this.playhead,
    required this.targetColor,
    required this.liveColor,
    required this.gridColor,
  });
  final List<Frame> target;
  final List<Frame> live;
  final double duration;
  final double center; // 세로축 가운데 (타깃 평균, 반음)
  final double? playhead;
  final Color targetColor, liveColor, gridColor;
  static const span = 12.0; // 위아래 각 12반음(1옥타브)

  @override
  void paint(Canvas canvas, Size size) {
    double y(double st) => size.height / 2 - (st - center).clamp(-span, span) / span * (size.height / 2 - 8);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (int k = -12; k <= 12; k += 4) {
      canvas.drawLine(Offset(0, y(center + k)), Offset(size.width, y(center + k)), grid);
    }
    _curve(canvas, target, (t) => t / duration * size.width, y, targetColor, 5);
    if (live.isNotEmpty) {
      final t0 = live.first.time;
      _curve(canvas, live, (t) => (t - t0) / duration * size.width, y, liveColor, 3);
    }
    if (playhead != null) {
      final x = playhead! / duration * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid..strokeWidth = 2);
    }
  }

  void _curve(Canvas canvas, List<Frame> frames, double Function(double) x,
      double Function(double) y, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    Path? path;
    Frame? prev;
    for (final f in frames) {
      if (!f.voiced) {
        if (path != null) canvas.drawPath(path, paint);
        path = null;
      } else if (path == null || (prev != null && (f.semitone - prev.semitone).abs() > 7)) {
        if (path != null) canvas.drawPath(path, paint);
        path = Path()..moveTo(x(f.time), y(f.semitone));
        path.lineTo(x(f.time) + 0.5, y(f.semitone));
      } else {
        path.lineTo(x(f.time), y(f.semitone));
      }
      prev = f;
    }
    if (path != null) canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant PitchPainter old) => true;
}
