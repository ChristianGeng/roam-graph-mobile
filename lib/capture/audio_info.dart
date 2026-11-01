/// What the app reads from an audio file without a decoder (#221): its
/// length, from the headers of WAV, MP3, M4A/MP4, FLAC, OGG (Opus and
/// Vorbis) and WebM files. Used to refuse a recording that is too long
/// before anything is sent.
///
/// Pure Dart (no Flutter), like `text_files.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The file name extensions of audio files, in lower case.
const audioFileExtensions = [
  'mp3',
  'm4a',
  'aac',
  'mp4',
  'wav',
  'flac',
  'ogg',
  'oga',
  'opus',
  'webm',
  'weba',
];

/// True if [name] has an extension of [audioFileExtensions].
bool hasAudioExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 &&
      audioFileExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// True if the file is taken as an audio file: by its MIME type
/// (`audio/*`, and `video/webm` or `video/mp4`, which some recorders send
/// for sound), or by its name.
bool isAudioFile(String name, String? mimeType) {
  final type = mimeType?.split(';').first.trim().toLowerCase() ?? '';
  return type.startsWith('audio/') ||
      type == 'video/webm' ||
      type == 'video/mp4' ||
      hasAudioExtension(name);
}

/// The MIME type to send a file of [name] with: from its extension, or
/// [sent] if the extension is not known and the sender gave an audio type.
String audioMimeType(String name, [String? sent]) {
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  return switch (extension) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' => 'audio/aac',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'webm' || 'weba' => 'audio/webm',
    _ => sent != null && sent.toLowerCase().startsWith('audio/')
        ? sent.split(';').first.trim()
        : 'application/octet-stream',
  };
}

/// The length of the audio in [bytes], or null if it cannot be told: an
/// unknown format, or a file that is cut short or has no usable header.
Duration? audioDuration(Uint8List bytes) {
  try {
    final seconds = _seconds(bytes);
    if (seconds == null || seconds.isNaN || seconds.isInfinite) return null;
    if (seconds < 0) return null;
    return Duration(microseconds: (seconds * 1000000).round());
  } on RangeError {
    return null;
  }
}

String _ascii(Uint8List b, int start, int length) =>
    start + length > b.length
        ? ''
        : latin1.decode(b.sublist(start, start + length));

int _u16le(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
int _u32le(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
int _u32be(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
int _u64be(Uint8List b, int i) => (_u32be(b, i) << 32) | _u32be(b, i + 4);
int _u64le(Uint8List b, int i) => (_u32le(b, i + 4) << 32) | _u32le(b, i);

double? _seconds(Uint8List b) {
  if (b.length < 12) return null;
  if (_ascii(b, 0, 4) == 'RIFF' && _ascii(b, 8, 4) == 'WAVE') return _wav(b);
  if (_ascii(b, 0, 4) == 'fLaC') return _flac(b);
  if (_ascii(b, 0, 4) == 'OggS') return _ogg(b);
  if (_ascii(b, 4, 4) == 'ftyp') return _mp4(b);
  if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
    return _webm(b);
  }
  if (_ascii(b, 0, 3) == 'ID3' || (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0)) {
    return _mp3(b);
  }
  return null;
}

/// WAV: the data chunk's size over the byte rate of the `fmt ` chunk.
double? _wav(Uint8List b) {
  int? byteRate;
  var i = 12;
  while (i + 8 <= b.length) {
    final id = _ascii(b, i, 4);
    final size = _u32le(b, i + 4);
    final body = i + 8;
    if (id == 'fmt ' && body + 12 <= b.length) {
      byteRate = _u32le(b, body + 8);
    } else if (id == 'data') {
      if (byteRate == null || byteRate == 0) return null;
      // A recorder that streams writes 0 or 0xFFFFFFFF as the size.
      final left = b.length - body;
      final length = size == 0 || size == 0xFFFFFFFF || size > left
          ? left
          : size;
      return length / byteRate;
    }
    // Chunks are padded to an even size.
    i = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// FLAC: the total samples of the STREAMINFO block over its sample rate.
double? _flac(Uint8List b) {
  if (b.length < 4 + 4 + 34) return null;
  if ((b[4] & 0x7F) != 0) return null;
  final info = 8;
  final rate = (b[info + 10] << 12) | (b[info + 11] << 4) | (b[info + 12] >> 4);
  final samples = ((b[info + 13] & 0x0F) << 32) |
      (b[info + 14] << 24) |
      (b[info + 15] << 16) |
      (b[info + 16] << 8) |
      b[info + 17];
  if (rate == 0 || samples == 0) return null;
  return samples / rate;
}

/// OGG: the granule position of the last page over the sample rate; for
/// Opus, always 48 kHz, less the pre-skip.
double? _ogg(Uint8List b) {
  int? rate;
  var skip = 0;
  final head = b.length < 400 ? b.length : 400;
  final first = latin1.decode(b.sublist(0, head));
  final opus = first.indexOf('OpusHead');
  final vorbis = first.indexOf('\x01vorbis');
  if (opus >= 0 && opus + 12 <= b.length) {
    rate = 48000;
    skip = _u16le(b, opus + 10);
  } else if (vorbis >= 0 && vorbis + 16 <= b.length) {
    rate = _u32le(b, vorbis + 12);
  } else {
    return null;
  }
  if (rate == 0) return null;
  // The last page: the last "OggS" with a complete header.
  for (var i = b.length - 27; i >= 0; i--) {
    if (b[i] == 0x4F &&
        b[i + 1] == 0x67 &&
        b[i + 2] == 0x67 &&
        b[i + 3] == 0x53) {
      final granule = _u64le(b, i + 6);
      // -1 (all bits set) means no sample ends on this page.
      if (granule <= 0) continue;
      final samples = granule - skip;
      return samples <= 0 ? null : samples / rate;
    }
  }
  return null;
}

/// M4A and MP4: the duration in the `mvhd` box of `moov`.
double? _mp4(Uint8List b) {
  final moov = _findBox(b, 0, b.length, 'moov');
  if (moov == null) return null;
  final mvhd = _findBox(b, moov.$1, moov.$2, 'mvhd');
  if (mvhd == null) return null;
  final start = mvhd.$1;
  final version = b[start];
  final int scale, duration;
  if (version == 1) {
    scale = _u32be(b, start + 20);
    duration = _u64be(b, start + 24);
  } else {
    scale = _u32be(b, start + 12);
    duration = _u32be(b, start + 16);
  }
  if (scale == 0) return null;
  return duration / scale;
}

/// The content of the box [type] among the boxes between [from] and [to]:
/// its start and end; null if there is none.
(int, int)? _findBox(Uint8List b, int from, int to, String type) {
  var i = from;
  while (i + 8 <= to) {
    var size = _u32be(b, i);
    var header = 8;
    if (size == 1) {
      if (i + 16 > to) return null;
      size = _u64be(b, i + 8);
      header = 16;
    } else if (size == 0) {
      size = to - i;
    }
    if (size < header) return null;
    final end = i + size > to ? to : i + size;
    if (_ascii(b, i + 4, 4) == type) return (i + header, end);
    i += size;
  }
  return null;
}

/// MP3: the frame count of a Xing or Info header, else the size over the
/// bitrate of the first frame (right for constant bitrate).
double? _mp3(Uint8List b) {
  var start = 0;
  if (_ascii(b, 0, 3) == 'ID3') {
    if (b.length < 10) return null;
    start = 10 +
        ((b[6] & 0x7F) << 21) +
        ((b[7] & 0x7F) << 14) +
        ((b[8] & 0x7F) << 7) +
        (b[9] & 0x7F);
  }
  const bitratesV1 = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, //
  ];
  const bitratesV2 = [
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, //
  ];
  const ratesV1 = [44100, 48000, 32000];
  const ratesV2 = [22050, 24000, 16000];
  const ratesV25 = [11025, 12000, 8000];
  // The first frame header: eleven set bits, then a Layer III frame.
  for (var i = start; i + 4 <= b.length && i < start + 4096; i++) {
    if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
    final versionBits = (b[i + 1] >> 3) & 3;
    final layer = (b[i + 1] >> 1) & 3;
    final bitrateIndex = b[i + 2] >> 4;
    final rateIndex = (b[i + 2] >> 2) & 3;
    // Version 1 is not 01; layer III is 01; the indexes 15 and 3 are not
    // used.
    if (versionBits == 1 ||
        layer != 1 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15 ||
        rateIndex == 3) {
      continue;
    }
    final v1 = versionBits == 3;
    final rate = (v1 ? ratesV1 : versionBits == 2 ? ratesV2 : ratesV25)[
        rateIndex];
    final bitrate = (v1 ? bitratesV1 : bitratesV2)[bitrateIndex] * 1000;
    final mono = (b[i + 3] >> 6) == 3;
    final sideInfo = v1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final xing = i + 4 + sideInfo;
    final tag = _ascii(b, xing, 4);
    if ((tag == 'Xing' || tag == 'Info') && xing + 12 <= b.length) {
      final flags = _u32be(b, xing + 4);
      if (flags & 1 != 0) {
        final frames = _u32be(b, xing + 8);
        return frames * (v1 ? 1152 : 576) / rate;
      }
    }
    return (b.length - i) * 8 / bitrate;
  }
  return null;
}

/// WebM (Matroska): `Duration` in `Info`, in units of `TimecodeScale`
/// nanoseconds.
double? _webm(Uint8List b) {
  var i = 0;
  var scale = 1000000;
  double? duration;
  // Reads the element at [i]: its ID and the size of its content.
  (int, int, int)? element(int at) {
    if (at >= b.length) return null;
    final first = b[at];
    var idLength = 1;
    while (idLength <= 4 && (first & (0x80 >> (idLength - 1))) == 0) {
      idLength++;
    }
    if (idLength > 4 || at + idLength >= b.length) return null;
    var id = 0;
    for (var k = 0; k < idLength; k++) {
      id = (id << 8) | b[at + k];
    }
    final sizeAt = at + idLength;
    final sizeFirst = b[sizeAt];
    var sizeLength = 1;
    while (sizeLength <= 8 && (sizeFirst & (0x80 >> (sizeLength - 1))) == 0) {
      sizeLength++;
    }
    if (sizeLength > 8 || sizeAt + sizeLength > b.length) return null;
    var size = sizeFirst & (0xFF >> sizeLength);
    var unknown = size == (0xFF >> sizeLength);
    for (var k = 1; k < sizeLength; k++) {
      size = (size << 8) | b[sizeAt + k];
      if (b[sizeAt + k] != 0xFF) unknown = false;
    }
    return (id, sizeAt + sizeLength, unknown ? b.length - sizeAt : size);
  }

  var end = b.length;
  while (i < end) {
    final e = element(i);
    if (e == null) break;
    final (id, body, size) = e;
    switch (id) {
      // Segment and Info: look inside.
      case 0x18538067 || 0x1549A966:
        i = body;
        continue;
      case 0x2AD7B1:
        scale = _uint(b, body, size);
      case 0x4489:
        if (size == 4) {
          duration = ByteData.sublistView(b, body, body + 4)
              .getFloat32(0, Endian.big);
        } else if (size == 8) {
          duration = ByteData.sublistView(b, body, body + 8)
              .getFloat64(0, Endian.big);
        }
      // The clusters come after Info: stop at the first.
      case 0x1F43B675:
        end = i;
    }
    i = body + size;
  }
  if (duration == null) return null;
  return duration * scale / 1e9;
}

int _uint(Uint8List b, int start, int size) {
  var value = 0;
  for (var k = 0; k < size && k < 8; k++) {
    value = (value << 8) | b[start + k];
  }
  return value;
}
