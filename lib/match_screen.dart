import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'matcher.dart';

/// 닮은꼴 찾기: 녹음 한 번으로 DB에서 가장 닮은 목소리를 찾습니다.
enum Phase { loading, idle, recording, analyzing, done, error }

class MatchScreen extends StatefulWidget {
  const MatchScreen({super.key});

  @override
  State<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends State<MatchScreen> {
  static const minSeconds = 3;
  static const maxSeconds = 15;

  final _recorder = AudioRecorder();
  VoiceMatcher? _matcher;
  Phase _phase = Phase.loading;
  String _message = '';
  final List<double> _samples = [];
  StreamSubscription<Uint8List>? _sub;
  Timer? _timer;
  int _elapsed = 0;
  double _level = 0;
  List<MatchResult> _results = [];

  @override
  void initState() {
    super.initState();
    VoiceMatcher.load().then((m) {
      setState(() {
        _matcher = m;
        _phase = Phase.idle;
      });
    }).catchError((e) {
      setState(() {
        _phase = Phase.error;
        _message = '모델을 불러오지 못했어요: $e';
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _message = '마이크 권한이 필요해요. 설정에서 허용해 주세요.');
      return;
    }
    _samples.clear();
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kSampleRate,
      numChannels: 1,
    ));
    _sub = stream.listen((bytes) {
      final data = ByteData.sublistView(bytes);
      double peak = 0;
      for (int i = 0; i + 1 < bytes.length; i += 2) {
        final v = data.getInt16(i, Endian.little) / 32768.0;
        _samples.add(v);
        if (v.abs() > peak) peak = v.abs();
      }
      if (mounted) setState(() => _level = peak);
    });
    _elapsed = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed++);
      if (_elapsed >= maxSeconds) _stop();
    });
    setState(() {
      _phase = Phase.recording;
      _message = '';
    });
  }

  Future<void> _stop() async {
    _timer?.cancel();
    await _recorder.stop();
    await _sub?.cancel();
    _sub = null;
    if (_elapsed < minSeconds) {
      setState(() {
        _phase = Phase.idle;
        _message = '최소 $minSeconds초 이상 말해 주세요.';
      });
      return;
    }
    setState(() => _phase = Phase.analyzing);
    try {
      final results = await _matcher!.match(Float32List.fromList(_samples));
      setState(() {
        _results = results.take(5).toList();
        _phase = Phase.done;
      });
    } catch (e) {
      setState(() {
        _phase = Phase.idle;
        _message = '분석 중 문제가 생겼어요: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
          padding: const EdgeInsets.all(20),
          child: switch (_phase) {
            Phase.loading => const Center(child: CircularProgressIndicator()),
            Phase.error => Center(child: Text(_message, textAlign: TextAlign.center)),
            Phase.done => _ResultView(results: _results, onRetry: () {
                setState(() => _phase = Phase.idle);
              }),
            _ => _recordView(cs),
          },
    );
  }

  Widget _recordView(ColorScheme cs) {
    final recording = _phase == Phase.recording;
    final analyzing = _phase == Phase.analyzing;
    return Column(
      children: [
        const SizedBox(height: 24),
        Text(
          analyzing
              ? '목소리를 분석하고 있어요…'
              : recording
                  ? '편하게 말해 보세요 ($_elapsed / $maxSeconds초)'
                  : '버튼을 누르고 5~10초 정도\n아무 문장이나 말해 보세요',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text('등록된 목소리 ${_matcher?.entries.length ?? 0}개와 비교해요',
            style: TextStyle(color: cs.outline)),
        const Spacer(),
        if (analyzing)
          const CircularProgressIndicator()
        else
          GestureDetector(
            onTap: recording ? _stop : _start,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: 160 + (recording ? _level * 60 : 0),
              height: 160 + (recording ? _level * 60 : 0),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: recording ? Colors.redAccent : cs.primary,
                boxShadow: [
                  BoxShadow(
                      color: (recording ? Colors.redAccent : cs.primary)
                          .withValues(alpha: 0.35),
                      blurRadius: 30),
                ],
              ),
              child: Icon(recording ? Icons.stop_rounded : Icons.mic_rounded,
                  size: 72, color: Colors.white),
            ),
          ),
        const Spacer(),
        if (_message.isNotEmpty)
          Text(_message, style: TextStyle(color: cs.error), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text('음성은 폰 안에서만 분석되고 어디에도 전송되지 않아요.',
            style: TextStyle(color: cs.outline, fontSize: 12)),
      ],
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.results, required this.onRetry});
  final List<MatchResult> results;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final best = results.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: cs.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Text('당신의 목소리는'),
              const SizedBox(height: 8),
              Text(best.entry.name,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              Text(best.entry.category, style: TextStyle(color: cs.outline)),
              const SizedBox(height: 8),
              Text('${best.percent}% 닮았어요',
                  style: Theme.of(context).textTheme.titleLarge),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        const Text('다른 후보', style: TextStyle(fontWeight: FontWeight.bold)),
        Expanded(
          child: ListView(
            children: [
              for (final (i, r) in results.skip(1).indexed)
                ListTile(
                  leading: CircleAvatar(child: Text('${i + 2}')),
                  title: Text(r.entry.name),
                  subtitle: LinearProgressIndicator(value: r.percent / 100),
                  trailing: Text('${r.percent}%'),
                ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('다시 해보기'),
        ),
      ],
    );
  }
}
