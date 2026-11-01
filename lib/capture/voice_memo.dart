/// A voice memo brought into the app (#221): the shared or dropped audio
/// file, read and checked before anything is sent.
///
/// Pure Dart (no Flutter), like `text_files.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import '../ai/speech.dart';
import 'audio_info.dart';
import 'text_files.dart';

/// A recording read from an [IncomingFile]: the audio to send, or the
/// reason it cannot be.
class LoadedRecording {
  const LoadedRecording({
    required this.name,
    required this.time,
    this.audio,
    this.problem,
  });

  /// The file name, without folders.
  final String name;

  /// When the recording was made as far as known: the file's change time,
  /// else now.
  final DateTime time;

  final SpeechAudio? audio;

  /// Why the file cannot be transcribed, in plain words.
  final String? problem;
}

const _advice = 'The app transcribes recordings of up to 30 minutes; '
    'transcribe longer ones on the computer and share the text.';

/// Reads [file]: from its bytes, or from its [IncomingFile.path]. The
/// length comes from the file's headers, else from what the sender told.
Future<LoadedRecording> loadRecording(
  IncomingFile file, {
  DateTime Function() now = DateTime.now,
}) async {
  final name = fileBaseName(file.name);
  final time = file.modified ?? now();
  LoadedRecording problem(String text) =>
      LoadedRecording(name: name, time: time, problem: text);
  if (file.error case final error?) {
    return problem('$name could not be read: $error');
  }
  final size = file.size ?? file.bytes?.length;
  if (size != null && size > maxRecordingBytes) {
    return problem('$name is ${formatSize(size)}. $_advice');
  }
  Uint8List? bytes = file.bytes;
  if (bytes == null) {
    final path = file.path;
    if (path == null) return problem('$name could not be read.');
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException catch (e) {
      return problem('$name could not be read: '
          '${e.osError?.message ?? e.message}');
    }
  }
  if (bytes.isEmpty) return problem('$name is empty.');
  if (bytes.length > maxRecordingBytes) {
    return problem('$name is ${formatSize(bytes.length)}. $_advice');
  }
  Duration? length = audioDuration(bytes);
  if (length == null && file.durationMs != null) {
    length = Duration(milliseconds: file.durationMs!);
  }
  return LoadedRecording(
    name: name,
    time: time,
    audio: SpeechAudio(
      name: name,
      bytes: bytes,
      mimeType: audioMimeType(name, file.mimeType),
      length: length,
    ),
  );
}

/// Deletes the app's copy of a shared recording on Android
/// ([IncomingFile.isCopy]); a file the user dropped or chose is never
/// deleted.
Future<void> discardCopy(IncomingFile file) async {
  final path = file.path;
  if (path == null || !file.isCopy) return;
  try {
    await File(path).delete();
  } on FileSystemException {
    // Gone already.
  }
}
