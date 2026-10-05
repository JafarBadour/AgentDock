import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../services/archon_voice.dart';

/// What Archon should do with the reply to a spoken turn.
///
/// The bar only records; the reply comes back through the chat session, so
/// this is the caller's instruction — reported, never acted on here.
enum ArchonVoiceMode {
  /// Dictation. The mic writes a message; the answer is read, not heard.
  text,

  /// Spoken answer that is still written into the transcript.
  talkAndText,

  /// Speech both ways — hands and eyes free.
  voiceOnly,
}

extension ArchonVoiceModeLabel on ArchonVoiceMode {
  String get label => switch (this) {
    ArchonVoiceMode.text => 'Written replies',
    ArchonVoiceMode.talkAndText => 'Talk and text',
    ArchonVoiceMode.voiceOnly => 'Voice only',
  };

  /// Said in the bar at rest, so the mode is never a mystery icon.
  String get hint => switch (this) {
    ArchonVoiceMode.text => 'Hold the mic to dictate',
    ArchonVoiceMode.talkAndText => 'Archon speaks and writes',
    ArchonVoiceMode.voiceOnly => 'Archon speaks its reply',
  };

  IconData get icon => switch (this) {
    ArchonVoiceMode.text => Icons.notes_outlined,
    ArchonVoiceMode.talkAndText => Icons.record_voice_over_outlined,
    ArchonVoiceMode.voiceOnly => Icons.headset_mic_outlined,
  };
}

/// The voice controls for Archon's composer: a hold-to-talk mic and the two
/// audio-chat modes.
///
/// Takes its [ArchonVoice] and callbacks rather than reading providers, so a
/// test can drive the whole bar with a fake recorder and no device.
///
/// Recording is hold-to-talk with slide-away-to-cancel, the phone idiom: a
/// take you never release is a take that never reaches Deepgram, which is the
/// privacy promise [ArchonVoice.cancelRecording] makes.
class ArchonVoiceBar extends StatefulWidget {
  const ArchonVoiceBar({
    super.key,
    required this.voice,
    required this.onTranscribed,
    this.initialMode = ArchonVoiceMode.text,
    this.onModeChanged,
    this.onError,
    this.enabled = true,
    this.animate = true,
  });

  final ArchonVoice voice;

  /// The spoken message, trimmed and never empty. Silence reports nothing.
  final ValueChanged<String> onTranscribed;

  final ArchonVoiceMode initialMode;

  /// Told whenever the user picks a mode, so the caller knows whether to
  /// speak the next reply.
  final ValueChanged<ArchonVoiceMode>? onModeChanged;

  /// A second channel for failures the bar already shows inline — for a
  /// snackbar, say. Optional: the bar is readable without it.
  final ValueChanged<String>? onError;

  /// Off while the session cannot accept a message.
  final bool enabled;

  /// Off in tests: the recording ring and the transcribing spinner repeat
  /// forever, and `pumpAndSettle` never returns while a ticker is alive.
  final bool animate;

  /// Lets a test grab the mic without depending on which icon it wears.
  static const micKey = ValueKey<String>('archon-voice-mic');

  /// The hands-free toggle, for the same reason.
  static const conversationKey = ValueKey<String>('archon-voice-conversation');

  /// How far the finger must travel off the mic to abandon the take. Roughly
  /// a thumb's width, so a shaky hold does not throw the message away.
  static const cancelDistance = 56.0;

  @override
  State<ArchonVoiceBar> createState() => _ArchonVoiceBarState();
}

/// What the bar is doing. Distinct from [ArchonVoiceState] because the bar
/// also knows that a held recording is *about* to be thrown away.
enum _Phase { idle, recording, cancelling, transcribing }

class _ArchonVoiceBarState extends State<ArchonVoiceBar> {
  late ArchonVoiceMode _mode = widget.initialMode;
  _Phase _phase = _Phase.idle;
  bool _speaking = false;
  String? _message;
  bool _messageIsError = false;

  /// Hands-free. The mic latches instead of being held, and the next take
  /// arms itself as soon as Archon stops speaking, so a back-and-forth costs
  /// one tap per turn instead of a thumb held down through all of it.
  bool _conversing = false;

  Offset _origin = Offset.zero;

  /// `startRecording` is async, and a quick tap can release before it lands.
  /// The release is remembered rather than dropped, or the mic would stay hot.
  bool _starting = false;
  bool _releaseRequested = false;
  bool _releaseWasCancel = false;

  StreamSubscription<ArchonVoiceState>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _speaking = widget.voice.state == ArchonVoiceState.speaking;
    _sub = widget.voice.states.listen((state) {
      if (!mounted) return;
      // Only speaking is watched: it is the one state the caller starts, so
      // it is the one the bar cannot learn from its own await.
      final speaking = state == ArchonVoiceState.speaking;
      if (speaking == _speaking) return;
      final replyEnded = _speaking && !speaking;
      setState(() => _speaking = speaking);
      // Archon has finished its answer — take the next turn without being
      // asked. This is the whole of what makes it a conversation.
      if (replyEnded && _conversing && _phase == _Phase.idle) {
        if (widget.enabled) unawaited(_start());
      }
    });
  }

  @override
  void didUpdateWidget(covariant ArchonVoiceBar old) {
    super.didUpdateWidget(old);
    if (old.voice != widget.voice) {
      _sub?.cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // Leaving on a live recording would hold the microphone for the session.
    if (_phase == _Phase.recording || _phase == _Phase.cancelling) {
      unawaited(widget.voice.cancelRecording());
    }
    super.dispose();
  }

  void _say(String? text, {bool error = false}) {
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  /// Deepgram and the mic both fail with a [StateError] carrying a sentence
  /// written for the user; anything else is unexpected and shown raw.
  static String _human(Object error) =>
      error is StateError ? error.message : '$error';

  void _pickMode(ArchonVoiceMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _message = null;
    });
    widget.onModeChanged?.call(mode);
  }

  /// Enter or leave hands-free.
  ///
  /// Turning it on also asks for spoken replies when the user was on written
  /// ones — a conversation where only one side talks is not one, and the
  /// auto-arm has nothing to wait for without a reply to finish. Turning it
  /// off leaves the reply mode alone rather than undoing a deliberate choice.
  void _toggleConversation() {
    if (!widget.enabled) return;
    if (_conversing) {
      setState(() {
        _conversing = false;
        _message = 'Conversation ended.';
      });
      if (_phase == _Phase.recording || _phase == _Phase.cancelling) {
        unawaited(_finish(cancel: true));
      }
      return;
    }
    if (_mode == ArchonVoiceMode.text) _pickMode(ArchonVoiceMode.talkAndText);
    setState(() {
      _conversing = true;
      _message = null;
      _messageIsError = false;
    });
    if (_phase == _Phase.idle && !_speaking) unawaited(_start());
  }

  Future<void> _start() async {
    if (!widget.enabled || _phase != _Phase.idle || _starting) return;
    _starting = true;
    setState(() {
      _phase = _Phase.recording;
      _message = null;
      _messageIsError = false;
    });
    try {
      await widget.voice.startRecording();
    } catch (e) {
      _starting = false;
      _releaseRequested = false;
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _fail(_human(e));
      return;
    }
    _starting = false;
    if (!mounted) return;
    if (_releaseRequested) {
      _releaseRequested = false;
      await _finish(cancel: _releaseWasCancel);
    }
  }

  Future<void> _finish({required bool cancel}) async {
    if (_starting) {
      _releaseRequested = true;
      _releaseWasCancel = cancel;
      return;
    }
    if (_phase != _Phase.recording && _phase != _Phase.cancelling) return;

    if (cancel) {
      setState(() => _phase = _Phase.idle);
      await widget.voice.cancelRecording();
      if (mounted) _say('Recording discarded.');
      return;
    }

    setState(() => _phase = _Phase.transcribing);
    String text;
    try {
      text = await widget.voice.stopAndTranscribe();
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _fail(_human(e));
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.idle);

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      // Releasing without speaking is ordinary, so this is a nudge, not a
      // failure: nothing is sent and nothing is coloured red.
      _say(
        _conversing
            ? 'Nothing heard — tap the mic and speak.'
            : 'Nothing heard — hold the mic and speak.',
      );
      return;
    }
    _say(null);
    widget.onTranscribed(trimmed);
  }

  void _fail(String message) {
    _say(message, error: true);
    widget.onError?.call(message);
  }

  void _pointerDown(PointerDownEvent event) {
    _origin = event.position;
    // Latched: the take starts and ends on taps, so nothing happens on press.
    if (_conversing) return;
    unawaited(_start());
  }

  void _pointerMove(PointerMoveEvent event) {
    // Slide-away-to-cancel belongs to the held take. Latched, the finger is
    // long gone by the time the user changes their mind.
    if (_conversing) return;
    if (_phase != _Phase.recording && _phase != _Phase.cancelling) return;
    final away =
        (event.position - _origin).distance > ArchonVoiceBar.cancelDistance;
    final next = away ? _Phase.cancelling : _Phase.recording;
    if (next != _phase) setState(() => _phase = next);
  }

  void _pointerUp(PointerUpEvent event) {
    if (_conversing) {
      if (_phase == _Phase.idle) {
        unawaited(_start());
      } else if (_phase == _Phase.recording) {
        unawaited(_finish(cancel: false));
      }
      return;
    }
    unawaited(_finish(cancel: _phase == _Phase.cancelling));
  }

  /// The system stealing the pointer (a scroll, a call) must not send a take
  /// the user never released. Latched takes are not held, so there is nothing
  /// for a stolen pointer to abandon.
  void _pointerCancel(PointerCancelEvent event) {
    if (_conversing) return;
    unawaited(_finish(cancel: true));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _phase == _Phase.recording || _phase == _Phase.cancelling;

    return Semantics(
      container: true,
      label: 'Archon voice',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            top: BorderSide(color: AppColors.outline.withValues(alpha: 0.4)),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            children: [
              // Hidden while recording: a half-pressed mode switch mid-take is
              // never what the user meant, and the status line needs the room.
              if (!recording)
                for (final mode in ArchonVoiceMode.values)
                  _ModeButton(
                    mode: mode,
                    selected: mode == _mode,
                    onPressed: widget.enabled ? () => _pickMode(mode) : null,
                  ),
              const SizedBox(width: 6),
              Expanded(child: _status(theme)),
              if (_speaking)
                IconButton(
                  tooltip: 'Stop speaking',
                  icon: const Icon(Icons.stop_circle_outlined),
                  color: AppColors.accent,
                  onPressed: () => unawaited(widget.voice.stopSpeaking()),
                ),
              _conversationButton(),
              const SizedBox(width: 4),
              _mic(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Hands-free, so the user is not holding anything and the ordinary
  /// "release to send" wording would be a lie.
  Widget _conversationButton() {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: _conversing,
      label: _conversing ? 'End conversation' : 'Start conversation',
      child: IconButton(
        key: ArchonVoiceBar.conversationKey,
        tooltip: _conversing
            ? 'End the hands-free conversation'
            : 'Talk with Archon hands-free',
        isSelected: _conversing,
        onPressed: widget.enabled ? _toggleConversation : null,
        iconSize: 22,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          backgroundColor: _conversing
              ? AppColors.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          foregroundColor: _conversing ? AppColors.accent : AppColors.chatMeta,
        ),
        icon: Icon(
          _conversing ? Icons.voice_chat : Icons.voice_chat_outlined,
        ),
      ),
    );
  }

  Widget _status(ThemeData theme) {
    final (text, color) = switch (_phase) {
      _Phase.cancelling => ('Release to discard', theme.colorScheme.error),
      _Phase.recording when _conversing => (
        'Listening… tap the mic to send',
        AppColors.mist,
      ),
      _Phase.recording => ('Recording… slide away to cancel', AppColors.mist),
      _Phase.transcribing => ('Transcribing…', AppColors.mist),
      _Phase.idle when _message != null => (
        _message!,
        _messageIsError ? theme.colorScheme.error : AppColors.chatMeta,
      ),
      _Phase.idle when _speaking => ('Archon is speaking…', AppColors.accent),
      _Phase.idle when _conversing => (
        'Your turn — tap the mic',
        AppColors.accent,
      ),
      _Phase.idle => (_mode.hint, AppColors.chatMeta),
    };
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(color: color),
    );
  }

  Widget _mic(ThemeData theme) {
    final cancelling = _phase == _Phase.cancelling;
    final recording = _phase == _Phase.recording;
    final transcribing = _phase == _Phase.transcribing;

    final fill = switch (_phase) {
      _Phase.cancelling => theme.colorScheme.error,
      _Phase.recording => AppColors.accent,
      _ => AppColors.surfaceHigh,
    };
    final foreground = switch (_phase) {
      _Phase.cancelling || _Phase.recording => AppColors.deep,
      _ => widget.enabled ? AppColors.mist : AppColors.chatMeta,
    };

    final Widget glyph = transcribing
        ? (widget.animate
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                )
              : Icon(Icons.hourglass_empty, color: foreground, size: 22))
        : Icon(
            cancelling
                ? Icons.delete_outline
                : recording
                ? Icons.mic
                : Icons.mic_none,
            color: foreground,
            size: 26,
          );

    final button = Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(
          color: recording || cancelling
              ? Colors.transparent
              : AppColors.outline.withValues(alpha: 0.6),
        ),
      ),
      child: glyph,
    );

    final label = switch ((_conversing, recording || cancelling)) {
      (true, true) => 'Tap to send',
      (true, false) => 'Tap to talk',
      (false, true) => 'Release to send',
      (false, false) => 'Hold to talk',
    };

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      child: Listener(
        key: ArchonVoiceBar.micKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.enabled ? _pointerDown : null,
        onPointerMove: widget.enabled ? _pointerMove : null,
        onPointerUp: widget.enabled ? _pointerUp : null,
        onPointerCancel: widget.enabled ? _pointerCancel : null,
        child: widget.animate && (recording || cancelling)
            ? _PulseRing(color: fill, child: button)
            : button,
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.selected,
    required this.onPressed,
  });

  final ArchonVoiceMode mode;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: mode.label,
      isSelected: selected,
      onPressed: onPressed,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? AppColors.accent.withValues(alpha: 0.18)
            : Colors.transparent,
        foregroundColor: selected ? AppColors.accent : AppColors.chatMeta,
      ),
      icon: Icon(mode.icon),
    );
  }
}

/// A halo that breathes while the mic is live, so "it is listening" reads
/// from across the room.
class _PulseRing extends StatefulWidget {
  const _PulseRing({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(
                alpha: 0.10 + 0.25 * _controller.value,
              ),
              blurRadius: 4 + 10 * _controller.value,
              spreadRadius: 2 + 6 * _controller.value,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}
