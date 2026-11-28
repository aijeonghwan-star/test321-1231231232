import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'dsp.dart';
import 'native_audio.dart';
import 'target_store.dart';

/// 새 타깃 목소리 추가: 파일 / 폰 내부 소리(유튜브 등) / 마이크 → 구간 자르기 → 저장
class AddTargetScreen extends StatefulWidget {
  const AddTargetScreen({super.key});

  @override
  State<AddTargetScreen> createState() => _AddTargetScreenState();
}

enum _Mode { choose, capturing, mic, loading, edit }

class _AddTargetScreenState extends State<AddTargetScreen> with WidgetsBindingObserver {
  _Mode _mode = _Mode.choose;
  bool _captureOk = false;
  String? _error;

  // 녹음 중
  DateTime? _recStart;
  Timer? _tick;
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  final List<double> _micBuf = [];

  // 편집
  Float32List? _audio;
  List<double> _peaks = [];
  double _start = 0; // 초
  double _len = 10; // 초
  final _name = TextEditingController();
  final _player = AudioPlayer();
  bool _previewing = false;
  bool _saving = false;

  static const _lengths = [5.0, 10.0, 15.0, 20.0];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeAudio.captureSupported().then((v) => setState(() => _captureOk = v));
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _previewing = false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _micSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    _name.dispose();
    if (_mode == _Mode.capturing) NativeAudio.stopCapture();
    super.dispose();
  }

  /// 유튜브에서 돌아왔을 때 화면 갱신 (2분이 지나 자동으로 멈췄는지 확인)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _mode == _Mode.capturing) {
      NativeAudio.isCapturing().then((rec) {
        if (!rec && mounted && _mode == _Mode.capturing) _stopCapture();
      });
    }
  }

  // ---------- 가져오기 ----------

  Future<void> _pickFile() async {
    setState(() {
      _mode = _Mode.loading;
      _error = null;
    });
    try {
      final r = await NativeAudio.pickAudio();
      if (r == null) {
        setState(() => _mode = _Mode.choose);
        return;
      }
      _openEditor(r.$2, r.$1);
    } catch (e) {
      setState(() {
        _mode = _Mode.choose;
        _error = '파일을 읽지 못했어요: $e';
      });
    }
  }

  Future<void> _startCapture() async {
    setState(() => _error = null);
    try {
      final ok = await NativeAudio.startCapture();
      if (!ok) return;
      _beginTimer(_Mode.capturing);
    } catch (e) {
      setState(() => _error = '내부 소리 녹음을 시작하지 못했어요: $e');
    }
  }

  Future<void> _stopCapture() async {
    _tick?.cancel();
    setState(() => _mode = _Mode.loading);
    final audio = await NativeAudio.stopCapture();
    _finishRecording(audio, isCapture: true);
  }

  Future<void> _startMic() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _error = '마이크 권한이 필요해요.');
      return;
    }
    _micBuf.clear();
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kSr,
      numChannels: 1,
    ));
    _micSub = stream.listen((b) => _micBuf.addAll(pcm16ToFloat(Uint8List.fromList(b))));
    _beginTimer(_Mode.mic);
  }

  Future<void> _stopMic() async {
    _tick?.cancel();
    await _recorder.stop();
    await _micSub?.cancel();
    _micSub = null;
    _finishRecording(Float32List.fromList(_micBuf), isCapture: false);
  }

  void _beginTimer(_Mode mode) {
    _recStart = DateTime.now();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {});
      if (_elapsed >= 120) mode == _Mode.mic ? _stopMic() : _stopCapture();
    });
    setState(() {
      _mode = mode;
      _error = null;
    });
  }

  int get _elapsed => _recStart == null ? 0 : DateTime.now().difference(_recStart!).inSeconds;

  void _finishRecording(Float32List audio, {required bool isCapture}) {
    double peak = 0;
    for (final v in audio) {
      if (v.abs() > peak) peak = v.abs();
    }
    if (audio.length < kSr * 2 || peak < 0.003) {
      setState(() {
        _mode = _Mode.choose;
        _error = isCapture
            ? '소리가 녹음되지 않았어요. 일부 앱은 소리 녹음을 막아 둬요.\n'
                '유튜브 앱이 안 되면 Chrome 브라우저에서 youtube.com으로 재생해 보세요.'
            : '소리가 너무 작거나 짧아요. 다시 녹음해 주세요.';
      });
      return;
    }
    _openEditor(audio, isCapture ? '녹음한 목소리' : '마이크 녹음');
  }

  // ---------- 편집 ----------

  void _openEditor(Float32List audio, String name) {
    final total = audio.length / kSr;
    // 처음으로 소리가 커지는 곳부터 시작
    double peak = 0;
    for (final v in audio) {
      if (v.abs() > peak) peak = v.abs();
    }
    int first = 0;
    while (first < audio.length && audio[first].abs() < peak * 0.1) {
      first++;
    }
    final len = total <= 20 ? total : 10.0;
    _audio = audio;
    _peaks = _computePeaks(audio, 300);
    _len = len;
    _start = math.max(0.0, math.min(first / kSr - 0.2, total - len));
    _name.text = name;
    setState(() => _mode = _Mode.edit);
  }

  List<double> _computePeaks(Float32List x, int buckets) {
    final per = math.max(1, x.length ~/ buckets);
    final out = <double>[];
    for (int i = 0; i < x.length; i += per) {
      double m = 0;
      for (int j = i; j < math.min(x.length, i + per); j++) {
        if (x[j].abs() > m) m = x[j].abs();
      }
      out.add(m);
    }
    return out;
  }

  double get _total => (_audio?.length ?? 0) / kSr;

  Float32List _segment() {
    final a = _audio!;
    final s = (_start * kSr).round().clamp(0, a.length);
    final e = ((_start + _len) * kSr).round().clamp(s, a.length);
    final seg = Float32List.fromList(a.sublist(s, e));
    double peak = 0;
    for (final v in seg) {
      if (v.abs() > peak) peak = v.abs();
    }
    if (peak > 0) {
      for (int i = 0; i < seg.length; i++) {
        seg[i] = seg[i] / peak * 0.89;
      }
    }
    return seg;
  }

  void _setStart(double v) {
    _start = v.clamp(0.0, math.max(0.0, _total - _len));
    if (_previewing) {
      _player.stop();
      _previewing = false;
    }
    setState(() {});
  }

  Future<void> _togglePreview() async {
    if (_previewing) {
      await _player.stop();
      setState(() => _previewing = false);
      return;
    }
    final path = await TargetStore.writeTemp(_segment());
    await _player.play(DeviceFileSource(path));
    setState(() => _previewing = true);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final seg = _segment();
    final frames = await analyzeInBackground(seg);
    if (VoiceStats.of(frames) == null) {
      setState(() {
        _saving = false;
        _error = '이 구간에는 목소리가 거의 없어요. 대사가 있는 곳으로 옮겨 주세요.';
      });
      return;
    }
    final t = await TargetStore.save(_name.text, seg);
    if (mounted) Navigator.of(context).pop(t);
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('새 목소리 추가')),
      body: SafeArea(
        child: switch (_mode) {
          _Mode.choose => _chooseView(),
          _Mode.capturing => _recordingView(
              '폰 소리를 녹음하는 중',
              '1. 유튜브를 열어 따라 하고 싶은 장면을 재생하세요\n'
                  '2. 다 들으면 이 앱으로 돌아와서 "녹음 끝"을 누르세요\n'
                  '(최대 2분, 이 앱 밖에 있어도 계속 녹음돼요)',
              _stopCapture),
          _Mode.mic => _recordingView('마이크로 녹음하는 중', '따라 하고 싶은 목소리를 마이크 가까이에서 들려주세요', _stopMic),
          _Mode.loading => const Center(child: CircularProgressIndicator()),
          _Mode.edit => _editView(),
        },
      ),
    );
  }

  Widget _chooseView() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SourceCard(
          icon: Icons.smartphone,
          title: '폰 소리 녹음 (유튜브 등)',
          body: _captureOk
              ? '유튜브·브라우저 등에서 재생되는 소리를 그대로 녹음해요. "녹음 시작" 확인 창이 뜨면 허용해 주세요.'
              : '안드로이드 10 이상에서만 쓸 수 있어요.',
          onTap: _captureOk ? _startCapture : null,
        ),
        _SourceCard(
          icon: Icons.folder_open,
          title: '파일에서 가져오기',
          body: NativeAudio.fileImportSupported
              ? 'mp3, m4a, wav, mp4 영상 등 폰에 저장된 파일에서 소리를 가져와요.'
              : '지금은 안드로이드에서만 쓸 수 있어요.',
          onTap: NativeAudio.fileImportSupported ? _pickFile : null,
        ),
        _SourceCard(
          icon: Icons.mic,
          title: '마이크로 녹음',
          body: '다른 기기에서 재생하거나 다른 사람이 말하는 소리를 마이크로 녹음해요.',
          onTap: _startMic,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: TextStyle(color: cs.error)),
          ),
      ],
    );
  }

  Widget _recordingView(String title, String guide, VoidCallback onStop) {
    final s = _elapsed;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        const SizedBox(height: 24),
        const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 40),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
            style: Theme.of(context).textTheme.displayMedium),
        const SizedBox(height: 16),
        Text(guide, textAlign: TextAlign.center),
        const Spacer(),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56), backgroundColor: Colors.redAccent),
          onPressed: onStop,
          icon: const Icon(Icons.stop_rounded),
          label: const Text('녹음 끝'),
        ),
      ]),
    );
  }

  Widget _editView() {
    final cs = Theme.of(context).colorScheme;
    final total = _total;
    final lengths = total <= 20 ? [total] : _lengths;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('따라 할 구간을 고르세요', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('대사만 또렷하게 나오는 구간이 가장 좋아요 (전체 ${total.toStringAsFixed(1)}초)',
            style: TextStyle(color: cs.outline, fontSize: 12)),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          return GestureDetector(
            // 파형을 누르면 그 위치가 구간 가운데가 되도록 이동
            onTapDown: (d) => _setStart(d.localPosition.dx / c.maxWidth * total - _len / 2),
            child: Container(
              height: 90,
              decoration: BoxDecoration(
                  color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
              child: CustomPaint(
                painter: _WavePainter(_peaks, _start / total, (_start + _len) / total, cs.primary,
                    cs.outlineVariant),
                child: const SizedBox.expand(),
              ),
            ),
          );
        }),
        if (total > _len)
          Slider(
            value: _start.clamp(0.0, total - _len),
            max: total - _len,
            onChanged: _setStart,
          ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: () => _setStart(_start - 1), icon: const Icon(Icons.keyboard_double_arrow_left)),
          IconButton(onPressed: () => _setStart(_start - 0.2), icon: const Icon(Icons.chevron_left)),
          Text('${_start.toStringAsFixed(1)}초 ~ ${(_start + _len).toStringAsFixed(1)}초'),
          IconButton(onPressed: () => _setStart(_start + 0.2), icon: const Icon(Icons.chevron_right)),
          IconButton(onPressed: () => _setStart(_start + 1), icon: const Icon(Icons.keyboard_double_arrow_right)),
        ]),
        if (lengths.length > 1)
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final l in lengths)
                ChoiceChip(
                  label: Text('${l.round()}초'),
                  selected: _len == l,
                  onSelected: (_) {
                    _len = l;
                    _setStart(_start);
                  },
                ),
            ],
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _togglePreview,
          icon: Icon(_previewing ? Icons.stop_rounded : Icons.play_arrow_rounded),
          label: Text(_previewing ? '멈추기' : '이 구간 들어보기'),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '목소리 이름', border: OutlineInputBorder()),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: cs.error)),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check),
          label: const Text('저장하고 연습하기'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _mode = _Mode.choose;
            _audio = null;
            _error = null;
          }),
          child: const Text('다른 소리로 다시 고르기'),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.icon, required this.title, required this.body, this.onTap});
  final IconData icon;
  final String title, body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(body, style: const TextStyle(fontSize: 13)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.peaks, this.selStart, this.selEnd, this.selColor, this.color);
  final List<double> peaks;
  final double selStart, selEnd;
  final Color selColor, color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final maxP = peaks.reduce(math.max) + 1e-9;
    final w = size.width / peaks.length;
    final mid = size.height / 2;
    canvas.drawRect(
        Rect.fromLTRB(selStart * size.width, 0, selEnd * size.width, size.height),
        Paint()..color = selColor.withValues(alpha: 0.12));
    for (int i = 0; i < peaks.length; i++) {
      final x = i * w + w / 2;
      final frac = i / peaks.length;
      final h = peaks[i] / maxP * (mid - 6);
      canvas.drawLine(
        Offset(x, mid - h),
        Offset(x, mid + h),
        Paint()
          ..color = (frac >= selStart && frac <= selEnd) ? selColor : color
          ..strokeWidth = math.max(1.0, w * 0.7),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => true;
}
