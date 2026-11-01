import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/audio_info.dart';

/// Synthetic audio files: only the headers that give the length, and
/// silence (zero bytes) for the rest.

Uint8List u32le(int n) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, n, Endian.little);
Uint8List u32be(int n) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, n, Endian.big);

Uint8List join(List<List<int>> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);

/// A mono 16-bit WAV file of silence.
Uint8List wav(double seconds, {int rate = 8000, int? declaredSize}) {
  final data = (seconds * rate * 2).round();
  return join([
    ascii.encode('RIFF'),
    u32le(36 + data),
    ascii.encode('WAVE'),
    ascii.encode('fmt '),
    u32le(16),
    [1, 0, 1, 0],
    u32le(rate),
    u32le(rate * 2),
    [2, 0, 16, 0],
    ascii.encode('data'),
    u32le(declaredSize ?? data),
    Uint8List(data),
  ]);
}

/// An MPEG-1 Layer III file of 128 kbit/s, 44.1 kHz frames of silence.
Uint8List mp3(int frames, {int? xingFrames, List<int> before = const []}) {
  const frameBytes = 417;
  final out = <int>[...before];
  for (var i = 0; i < frames; i++) {
    final frame = Uint8List(frameBytes)..setAll(0, [0xFF, 0xFB, 0x90, 0x00]);
    if (i == 0 && xingFrames != null) {
      frame.setAll(36, [...ascii.encode('Xing'), ...u32be(1), ...u32be(xingFrames)]);
    }
    out.addAll(frame);
  }
  return Uint8List.fromList(out);
}

List<int> box(String type, List<int> content) =>
    [...u32be(8 + content.length), ...ascii.encode(type), ...content];

/// An M4A file: ftyp, then moov with mvhd.
Uint8List m4a(int timescale, int duration) => join([
      box('ftyp', [...ascii.encode('M4A '), ...u32be(0)]),
      box('mdat', Uint8List(20)),
      box('moov', box('mvhd', [
        0, 0, 0, 0, //
        ...u32be(0), ...u32be(0), ...u32be(timescale), ...u32be(duration),
        ...Uint8List(80),
      ])),
    ]);

/// A FLAC file with only the STREAMINFO block: 44.1 kHz, 3 seconds.
Uint8List flac() {
  final info = Uint8List(34);
  info.setAll(10, [0x0A, 0xC4, 0x40, 0x00, 0x00, 0x02, 0x04, 0xCC]);
  return join([
    ascii.encode('fLaC'),
    [0x80, 0, 0, 34],
    info,
  ]);
}

List<int> oggPage(int granule, List<int> payload) => [
      ...ascii.encode('OggS'),
      0, 0,
      ...u32le(granule), ...u32le(0),
      ...u32le(1), ...u32le(0), ...u32le(0),
      1, payload.length,
      ...payload,
    ];

/// An Ogg Opus file of 4 seconds, with a pre-skip of 312 samples.
Uint8List opus() => join([
      oggPage(0, [
        ...ascii.encode('OpusHead'),
        1, 1, 312 & 0xFF, 312 >> 8,
        ...u32le(48000), 0, 0, 0, //
      ]),
      oggPage(48000 * 4 + 312, Uint8List(40)),
    ]);

/// An Ogg Vorbis file of 2 seconds at 16 kHz.
Uint8List vorbis() => join([
      oggPage(0, [
        1, ...ascii.encode('vorbis'),
        ...u32le(0), 1, ...u32le(16000), ...Uint8List(20), //
      ]),
      oggPage(32000, Uint8List(40)),
    ]);

/// A WebM file of 6.5 seconds.
Uint8List webm() => join([
      [0x1A, 0x45, 0xDF, 0xA3, 0x80],
      // Segment, size not known.
      [0x18, 0x53, 0x80, 0x67, 0xFF],
      [0x15, 0x49, 0xA9, 0x66, 0x8E],
      // TimecodeScale 1000000.
      [0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40],
      // Duration 6500.0 (float32).
      [0x44, 0x89, 0x84, 0x45, 0xCB, 0x20, 0x00],
      // A cluster.
      [0x1F, 0x43, 0xB6, 0x75, 0x80],
    ]);

void main() {
  double seconds(Uint8List bytes) =>
      audioDuration(bytes)!.inMicroseconds / 1e6;

  group('audioDuration (#221)', () {
    test('WAV: from the data size and the byte rate', () {
      expect(seconds(wav(2)), closeTo(2, 0.001));
      expect(seconds(wav(90, rate: 16000)), closeTo(90, 0.001));
    });

    test('WAV: a recorder that streams writes a size of 0', () {
      expect(seconds(wav(3, declaredSize: 0)), closeTo(3, 0.001));
      expect(seconds(wav(3, declaredSize: 0xFFFFFFFF)), closeTo(3, 0.001));
    });

    test('MP3: from the size and the bitrate of the first frame', () {
      expect(seconds(mp3(100)), closeTo(100 * 417 * 8 / 128000, 0.001));
      final tagged = mp3(100, before: [
        ...ascii.encode('ID3'),
        4, 0, 0, 0, 0, 0, 3, // 3 bytes of tag
        1, 2, 3,
      ]);
      expect(seconds(tagged), closeTo(100 * 417 * 8 / 128000, 0.001));
    });

    test('MP3: the frame count of a Xing header', () {
      expect(seconds(mp3(10, xingFrames: 1000)),
          closeTo(1000 * 1152 / 44100, 0.001));
    });

    test('M4A: from mvhd', () {
      expect(seconds(m4a(1000, 5500)), closeTo(5.5, 0.001));
      expect(seconds(m4a(44100, 44100 * 61)), closeTo(61, 0.001));
    });

    test('FLAC: from STREAMINFO', () {
      expect(seconds(flac()), closeTo(3, 0.001));
    });

    test('Ogg Opus: the last page, less the pre-skip', () {
      expect(seconds(opus()), closeTo(4, 0.001));
    });

    test('Ogg Vorbis: the last page over the sample rate', () {
      expect(seconds(vorbis()), closeTo(2, 0.001));
    });

    test('WebM: Duration times TimecodeScale', () {
      expect(seconds(webm()), closeTo(6.5, 0.001));
    });

    test('null for what is not audio, or is cut short', () {
      expect(audioDuration(Uint8List(0)), isNull);
      expect(audioDuration(Uint8List.fromList(utf8.encode('Just some text.'))),
          isNull);
      expect(audioDuration(wav(2).sublist(0, 20)), isNull);
      expect(audioDuration(Uint8List.fromList([...ascii.encode('OggS'), 0, 0, 0, 0, 0, 0, 0, 0])),
          isNull);
    });
  });

  group('audio files by name and type', () {
    test('isAudioFile', () {
      expect(isAudioFile('memo.m4a', null), isTrue);
      expect(isAudioFile('MEMO.MP3', 'application/octet-stream'), isTrue);
      expect(isAudioFile('content-1234', 'audio/ogg; codecs=opus'), isTrue);
      expect(isAudioFile('clip', 'video/webm'), isTrue);
      expect(isAudioFile('notes.txt', 'text/plain'), isFalse);
      expect(isAudioFile('photo.jpg', 'image/jpeg'), isFalse);
    });

    test('audioMimeType: from the extension, else the sent type', () {
      expect(audioMimeType('a.mp3'), 'audio/mpeg');
      expect(audioMimeType('a.M4A'), 'audio/mp4');
      expect(audioMimeType('a.opus'), 'audio/ogg');
      expect(audioMimeType('content-1', 'audio/x-foo; q=1'), 'audio/x-foo');
      expect(audioMimeType('content-1'), 'application/octet-stream');
    });
  });
}
