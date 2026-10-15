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

/// A microphone the user can pick, when the system default is the wrong one.
class VoiceInputDevice {
  const VoiceInputDevice({required this.id, required this.label});
  final String id;
  final String label;
}

/// Microphone capture, behind a seam.
///
/// The real one needs a device; a test needs neither a microphone nor a
/// speaker to check that a cancelled recording is never transcribed.
abstract class VoiceRecorder {
  Future<bool> hasPermission();

  /// The microphones there are to pick from.
  Future<List<VoiceInputDevice>> inputDevices();

  /// Begin capturing to a file this recorder owns, from [deviceId] or the
  /// system default when null.
  Future<void> start(String path, {String? deviceId});

  /// Stop and return what was captured, or null if nothing was.
  Future<Uint8List?> stop();

  Future<void> cancel();
  Future<void> dispose();
}

/// Speaker output, behind the same kind of seam.
abstract class VoicePlayer {
  /// Play [audio] and complete once it has finished or been stopped — not when
  /// it starts, or "speaking" would end long before the sound does.
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
    Future<String?> Function()? inputDeviceId,
  }) : _deepgram = deepgram,
       _recorder = recorder ?? _RecordPackageRecorder(),
       _player = player ?? _AudioPlayersPlayer(),
       _tempDir = tempDir ?? (() async => (await getTemporaryDirectory()).path),
       _inputDeviceId = inputDeviceId ?? (() async => null);

  final DeepgramService _deepgram;
  final VoiceRecorder _recorder;
  final VoicePlayer _player;
  final Future<String> Function() _tempDir;

  /// The microphone picked in Archon settings, or null for the default.
  final Future<String?> Function() _inputDeviceId;

  /// Bumped by every [speak] and [stopSpeaking], so a reply spoken in pieces
  /// stops at the next piece once it has been cut short.
  int _speech = 0;

  /// Deepgram refuses to speak more than 2000 characters in one request.
  static const maxSpeechChars = 1900;

  /// Below this a take is silence. A muted or switched-off mic delivers exact
  /// zeros; a live one in a quiet room still peaks in the hundreds.
  static const silencePeak = 32;

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

  /// The microphones the recorder can see.
  Future<List<VoiceInputDevice>> inputDevices() => _recorder.inputDevices();

  /// Start capturing a voice message. Talking over Archon stops it first.
  Future<void> startRecording() async {
    if (_state == ArchonVoiceState.speaking) await stopSpeaking();
    if (_state != ArchonVoiceState.idle) return;
    if (!await _recorder.hasPermission()) {
      throw StateError(
        'Microphone access is off — allow it for AgentPlantation to talk to Archon.',
      );
    }
    final dir = await _tempDir();
    final path = p.join(
      dir,
      'archon-${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await _recorder.start(path, deviceId: await _pickDevice());
    _to(ArchonVoiceState.recording);
  }

  /// The saved microphone, if it is still plugged in. One that has gone away
  /// falls back to the default rather than failing every take.
  Future<String?> _pickDevice() async {
    final String? wanted;
    try {
      wanted = await _inputDeviceId();
    } catch (e) {
      SafeLog.d('archon mic preference unreadable', e);
      return null;
    }
    if (wanted == null || wanted.isEmpty) return null;
    try {
      final devices = await _recorder.inputDevices();
      return devices.any((d) => d.id == wanted) ? wanted : null;
    } catch (e) {
      SafeLog.d('archon mic list failed', e);
      return null;
    }
  }

  /// Stop and transcribe. Returns the text, or empty when nothing was said —
  /// releasing the mic without speaking is normal, not an error.
  ///
  /// A take that is pure silence is different: that is a mic that is muted,
  /// off, or not the one being talked into, and "nothing heard" would hide
  /// it. That throws instead, and nothing is sent to Deepgram.
  Future<String> stopAndTranscribe() async {
    if (_state != ArchonVoiceState.recording) return '';
    _to(ArchonVoiceState.transcribing);
    try {
      final audio = await _recorder.stop();
      if (audio == null || audio.isEmpty) return '';
      final wav = WavInfo.parse(audio);
      if (wav != null && wav.seconds >= 0.5 && wav.peak() < silencePeak) {
        throw StateError(
          'The microphone sent only silence — check it is not muted, or pick '
          'another one in Archon settings.',
        );
      }
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

  /// Say [text] aloud, completing once it has been said. Silent when there is
  /// nothing to say.
  ///
  /// Markdown is read as prose rather than punctuation, and a reply longer
  /// than Deepgram takes in one request is spoken in pieces — the next piece
  /// is fetched while the current one plays, so there is no gap between them.
  Future<void> speak(String text) async {
    final pieces = splitForSpeech(speakable(text));
    if (pieces.isEmpty) return;
    if (_state == ArchonVoiceState.speaking) await stopSpeaking();
    if (_state != ArchonVoiceState.idle) return;
    final speech = ++_speech;
    _to(ArchonVoiceState.speaking);
    try {
      var next = _deepgram.speak(pieces.first);
      for (var i = 0; i < pieces.length; i++) {
        final audio = await next;
        if (speech != _speech) return;
        if (i + 1 < pieces.length) {
          next = _deepgram.speak(pieces[i + 1]);
          // Awaited on its turn; if the reply is cut short first, its failure
          // must not surface as an unhandled error.
          unawaited(next.then((_) {}, onError: (_) {}));
        }
        if (audio.isEmpty) continue;
        await _player.play(audio, mimeType: 'audio/wav');
        if (speech != _speech) return;
      }
    } finally {
      if (speech == _speech) _to(ArchonVoiceState.idle);
    }
  }

  /// Cut a reply short — the user talking over Archon should stop it.
  Future<void> stopSpeaking() async {
    if (_state != ArchonVoiceState.speaking) return;
    _speech++;
    try {
      await _player.stop();
    } finally {
      _to(ArchonVoiceState.idle);
    }
  }

  /// [markdown] as something worth hearing: code blocks and URLs are not read
  /// out character by character, and markup is not read at all.
  static String speakable(String markdown) {
    var s = markdown.replaceAll('\r\n', '\n');
    s = s.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ');
    s = s.replaceAllMapped(
      RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
      (m) => m[1] ?? '',
    );
    s = s.replaceAll(RegExp(r'https?://\S+'), 'a link');
    s = s.replaceAll('`', '');
    s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s*([-*+]|\d+[.)])\s+', multiLine: true), '');
    // Table rules (|---|:--:|) carry nothing; cell borders become pauses.
    s = s.replaceAll(RegExp(r'^[\s|:-]*-[\s|:-]*$', multiLine: true), '');
    s = s.replaceAll('|', ', ');
    s = s.replaceAll(RegExp(r'\*\*|__|~~|\*'), '');
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n+'), '\n');
    return s.trim();
  }

  /// [text] in pieces Deepgram will accept, broken at sentence ends where it
  /// can be, and never mid-word.
  static List<String> splitForSpeech(String text, {int max = maxSpeechChars}) {
    final pieces = <String>[];
    var rest = text.trim();
    while (rest.isNotEmpty) {
      if (rest.length <= max) {
        pieces.add(rest);
        break;
      }
      final window = rest.substring(0, max);
      var cut = -1;
      for (final m in RegExp(r'[.!?\n](\s|$)').allMatches(window)) {
        cut = m.start + 1;
      }
      if (cut < max ~/ 3) cut = window.lastIndexOf(' ');
      if (cut <= 0) cut = max;
      pieces.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    return pieces.where((p) => p.isNotEmpty).toList();
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
  Future<List<VoiceInputDevice>> inputDevices() async => [
    for (final d in await _recorder.listInputDevices())
      VoiceInputDevice(id: d.id, label: d.label),
  ];

  @override
  Future<void> start(String path, {String? deviceId}) async {
    _path = path;
    // 16 kHz mono PCM: what Deepgram wants, and a fraction of the bytes of
    // anything richer, which matters on a phone connection.
    await _recorder.start(
      rec.RecordConfig(
        encoder: rec.AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        device: deviceId == null
            ? null
            : rec.InputDevice(id: deviceId, label: deviceId),
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
      unawaited(
        file.delete().catchError((Object e) {
          SafeLog.d('archon recording cleanup failed', e);
          return file;
        }),
      );
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
  Completer<void>? _done;

  @override
  Future<void> play(Uint8List audio, {required String mimeType}) async {
    _finish();
    final done = _done = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) => _finish());
    // A player that never reports finishing must not leave Archon "speaking"
    // for good — that would also stop a conversation taking the next turn.
    final seconds = WavInfo.parse(audio)?.seconds ?? 60;
    try {
      await _player.play(BytesSource(audio, mimeType: mimeType));
      await done.future.timeout(
        Duration(milliseconds: (seconds * 1000).round() + 3000),
        onTimeout: () {},
      );
    } finally {
      await sub.cancel();
      if (identical(_done, done)) _done = null;
    }
  }

  void _finish() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } finally {
      _finish();
    }
  }

  @override
  Future<void> dispose() => _player.dispose();
}

/// Just enough of a 16-bit PCM WAV to know how long it is and whether there
/// is anything in it. Anything else parses to null.
class WavInfo {
  WavInfo._(
    this._bytes,
    this.sampleRate,
    this.channels,
    this._start,
    this._length,
  );

  final Uint8List _bytes;
  final int sampleRate;
  final int channels;
  final int _start;
  final int _length;

  double get seconds => _length / (sampleRate * channels * 2);

  static WavInfo? parse(Uint8List bytes) {
    if (bytes.length < 44) return null;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
    if (String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') return null;
    final data = ByteData.sublistView(bytes);
    int? rate, channels;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        final format = data.getUint16(body, Endian.little);
        final bits = data.getUint16(body + 14, Endian.little);
        if ((format != 1 && format != 0xFFFE) || bits != 16) return null;
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
      } else if (id == 'data') {
        if (rate == null || channels == null || rate == 0 || channels == 0) {
          return null;
        }
        // A streamed WAV declares a size it never had; trust the bytes.
        final length = (bytes.length - body).clamp(0, size) & ~1;
        return WavInfo._(bytes, rate, channels, body, length);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// The loudest sample after the first [skip] — some devices click as they
  /// open, and a click is not speech.
  int peak({Duration skip = const Duration(milliseconds: 200)}) {
    final data = ByteData.sublistView(_bytes);
    final frame = channels * 2;
    final from = _start + (skip.inMicroseconds * sampleRate ~/ 1000000) * frame;
    var peak = 0;
    for (var i = from; i + 1 < _start + _length; i += 2) {
      final s = data.getInt16(i, Endian.little).abs();
      if (s > peak) peak = s;
    }
    return peak;
  }
}
