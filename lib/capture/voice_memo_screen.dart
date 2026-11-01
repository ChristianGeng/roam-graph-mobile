import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ai/ai_chat.dart';
import '../ai/speech.dart';
import '../platform/voice_work.dart';

/// Transcribes one recording (#221): the file name, its length, a progress
/// line and Cancel. It goes on while the app is in the background, with
/// the service and the notification of [work]. Completes with the
/// [Transcript], or with null when cancelled. A failure shows the
/// provider's error in plain words and Try again.
class VoiceMemoScreen extends StatefulWidget {
  const VoiceMemoScreen({
    super.key,
    required this.config,
    required this.audio,
    this.post = postBytesWithDartIo,
    this.work = const NoVoiceWork(),
  });

  final SpeechConfig config;
  final SpeechAudio audio;

  /// Tests replace it.
  final AudioPost post;
  final VoiceWork work;

  @override
  State<VoiceMemoScreen> createState() => _VoiceMemoScreenState();
}

class _VoiceMemoScreenState extends State<VoiceMemoScreen>
    with WidgetsBindingObserver {
  var _token = CancelToken();
  AiError? _error;
  bool _foreground = true;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _token.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    _token = CancelToken();
    final token = _token;
    if (_error != null) setState(() => _error = null);
    await widget.work.started();
    try {
      final transcript = await transcribeAudio(widget.config, widget.audio,
          post: widget.post, cancel: token);
      await widget.work.finished();
      if (!mounted || token.cancelled) return;
      if (!_foreground) {
        await widget.work.notify(
            title: 'Voice memo ready',
            text: '${widget.audio.name} is transcribed. Open the app to '
                'review it.');
      }
      _done = true;
      if (mounted) Navigator.pop(context, transcript);
    } on SpeechCancelled {
      await widget.work.finished();
    } on Exception catch (e) {
      await widget.work.finished();
      if (!mounted || token.cancelled) return;
      final error = e is AiError
          ? e
          : AiError('The transcription failed: $e', passing: true);
      if (!_foreground) {
        await widget.work.notify(
            title: 'Voice memo failed',
            text: error.message.split('\n').first);
      }
      setState(() => _error = error);
    }
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    _token.cancel();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final audio = widget.audio;
    final text = Theme.of(context).textTheme;
    final error = _error;
    final length = audio.length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Voice memo')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text(audio.name,
                  key: const ValueKey('voice-file'), style: text.titleMedium),
              Text(
                  [
                    if (length != null) formatLength(length),
                    formatSize(audio.bytes.length),
                  ].join(' · '),
                  key: const ValueKey('voice-length')),
              if (error == null) ...[
                const LinearProgressIndicator(),
                Text(
                    'Sending the recording to ${widget.config.label} and '
                    'waiting for the text. You can leave the app; a '
                    'notification tells you when the text is ready.',
                    key: const ValueKey('voice-progress')),
                OutlinedButton(
                  key: const ValueKey('voice-cancel'),
                  onPressed: _cancel,
                  child: const Text('Cancel'),
                ),
              ] else ...[
                Text(error.message,
                    key: const ValueKey('voice-error'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
                Row(
                  spacing: 8,
                  children: [
                    FilledButton(
                      key: const ValueKey('voice-retry'),
                      onPressed: () => unawaited(_run()),
                      child: const Text('Try again'),
                    ),
                    TextButton(
                      key: const ValueKey('voice-close'),
                      onPressed: _cancel,
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
