import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 안드로이드 네이티브 기능 (native/android/*.kt) 연결
class NativeAudio {
  static const _ch = MethodChannel('voice_match/native');

  static bool get fileImportSupported => Platform.isAndroid;

  static Future<bool> captureSupported() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('captureSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 파일 선택 창을 열어 오디오/영상 파일을 16kHz 모노로 가져옵니다. 취소하면 null.
  static Future<(String, Float32List)?> pickAudio() async {
    final r = await _ch.invokeMapMethod<String, dynamic>('pickAudio');
    if (r == null) return null;
    return (r['name'] as String, pcm16ToFloat(r['pcm'] as Uint8List));
  }

  /// 내부 소리 녹음 시작. 사용자가 허용 창에서 거절하면 false.
  static Future<bool> startCapture() async =>
      await _ch.invokeMethod<bool>('startCapture') ?? false;

  /// 내부 소리 녹음을 멈추고 녹음된 소리를 돌려줍니다.
  static Future<Float32List> stopCapture() async {
    final b = await _ch.invokeMethod<Uint8List>('stopCapture');
    return b == null ? Float32List(0) : pcm16ToFloat(b);
  }

  static Future<bool> isCapturing() async =>
      await _ch.invokeMethod<bool>('isCapturing') ?? false;
}

Float32List pcm16ToFloat(Uint8List b) {
  final bd = ByteData.sublistView(b);
  final out = Float32List(b.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
