import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as rec;

import '../data/secure/safe_log.dart';
import 'deepgram_service.dart';

/// Recording a voice message, as the UI sees it.
enum ArchonVoiceState { idle, recording, transcribing, speaking }

/// Microphone capture, behind a seam.
///
/// The real one needs a device; a test needs neither a microphone nor a
/// speaker to check that a cancelled recording is never transcribed.
abstract class VoiceRecorder {
  Future<bool> hasPermission();

  /// Begin capturing to a file this recorder owns.
  Future<void> start(String path);

  /// Stop and return what was captured, or null if nothing was.
  Future<Uint8List?> stop();

  Future<void> cancel();
  Future<void> dispose();
}

/// Speaker output, behind the same kind of seam.
abstract class VoicePlayer {
  Future<void> play(Uint8List audio, {required String mimeType});
  Future<void> stop();
  Future<void> dispose();
}

/// Archon's voice: what you say becomes text, what it says becomes sound.
///
/// Deepgram does the converting in both directions. The reply itself comes
/// from Archon's agent session — nothing here decides what is said.
class ArchonVoice {
  ArchonVoice({
    required DeepgramService deepgram,
    VoiceRecorder? recorder,
    VoicePlayer? player,
    Future<String> Function()? tempDir,
  }) : _deepgram = deepgram,
       _recorder = recorder ?? _RecordPackageRecorder(),
       _player = player ?? _AudioPlayersPlayer(),
       _tempDir =
           tempDir ??
           (() async => (await getTemporaryDirectory()).path);

  final DeepgramService _deepgram;
  final VoiceRecorder _recorder;
  final VoicePlayer _player;
  final Future<String> Function() _tempDir;

  ArchonVoiceState _state = ArchonVoiceState.idle;
  ArchonVoiceState get state => _state;
  bool get isBusy => _state != ArchonVoiceState.idle;

  final _states = StreamController<ArchonVoiceState>.broadcast();
  Stream<ArchonVoiceState> get states => _states.stream;

  void _to(ArchonVoiceState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// Start capturing a voice message.
  Future<void> startRecording() async {
    if (_state != ArchonVoiceState.idle) return;
    if (!await _recorder.hasPermission()) {
      throw StateError(
        'Microphone access is off — allow it for Agent Dock to talk to Archon.',
      );
    }
    final dir = await _tempDir();
    final path = p.join(
      dir,
      'archon-${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await _recorder.start(path);
    _to(ArchonVoiceState.recording);
  }

  /// Stop and transcribe. Returns the text, or empty when nothing was said —
  /// releasing the mic without speaking is normal, not an error.
  Future<String> stopAndTranscribe() async {
    if (_state != ArchonVoiceState.recording) return '';
    _to(ArchonVoiceState.transcribing);
    try {
      final audio = await _recorder.stop();
      if (audio == null || audio.isEmpty) return '';
      return await _deepgram.transcribe(audio);
    } finally {
      _to(ArchonVoiceState.idle);
    }
  }

  /// Drop the recording without transcribing it. Nothing is sent to Deepgram,
  /// which is the point: a cancelled message never leaves the device.
  Future<void> cancelRecording() async {
    if (_state != ArchonVoiceState.recording) return;
    try {
      await _recorder.cancel();
    } finally {
      _to(ArchonVoiceState.idle);
    }
  }

  /// Say [text] aloud. Silent when there is nothing to say.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _to(ArchonVoiceState.speaking);
    try {
      final audio = await _deepgram.speak(text);
      if (audio.isEmpty) return;
      await _player.play(audio, mimeType: 'audio/wav');
    } finally {
      _to(ArchonVoiceState.idle);
    }
  }

  /// Cut a reply short — the user talking over Archon should stop it.
  Future<void> stopSpeaking() async {
    if (_state != ArchonVoiceState.speaking) return;
    try {
      await _player.stop();
    } finally {
      _to(ArchonVoiceState.idle);
    }
  }

  Future<void> dispose() async {
    await _states.close();
    await _recorder.dispose();
    await _player.dispose();
  }
}

class _RecordPackageRecorder implements VoiceRecorder {
  final rec.AudioRecorder _recorder = rec.AudioRecorder();
  String? _path;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(String path) async {
    _path = path;
    // 16 kHz mono PCM: what Deepgram wants, and a fraction of the bytes of
    // anything richer, which matters on a phone connection.
    await _recorder.start(
      const rec.RecordConfig(
        encoder: rec.AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
  }

  @override
  Future<Uint8List?> stop() async {
    final path = await _recorder.stop() ?? _path;
    if (path == null) return null;
    final file = File(path);
    try {
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } finally {
      unawaited(file.delete().catchError((Object e) {
        SafeLog.d('archon recording cleanup failed', e);
        return file;
      }));
    }
  }

  @override
  Future<void> cancel() async {
    await _recorder.cancel();
    final path = _path;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      SafeLog.d('archon recording cleanup failed', e);
    }
  }

  @override
  Future<void> dispose() async => _recorder.dispose();
}

class _AudioPlayersPlayer implements VoicePlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> play(Uint8List audio, {required String mimeType}) async {
    await _player.play(BytesSource(audio, mimeType: mimeType));
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}
