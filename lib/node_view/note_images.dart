/// Images from the notes folder in the node view (#46), also SVG (#47).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart'
    as compiler;

import '../folder/org_files.dart';

/// The files of the chosen folder, for images in notes.
abstract interface class NoteFiles {
  /// Whether [path], relative to `roam/` and without `.` or `..` parts
  /// except leading `..` ([normalizePath]), is inside the chosen folder.
  /// Android's folder access cannot read above it.
  bool reaches(String path);

  /// The file at [path] (as for [reaches]); null if the folder has none
  /// there.
  FolderFile? find(String path);

  /// The bytes of [file]; null if it could not be read.
  Future<Uint8List?> read(FolderFile file);

  /// Changes when [file] may have changed: its modification time, or, for
  /// a file whose folder gives none (0), each scan of the folder.
  int version(FolderFile file);
}

/// The image files the app shows. Flutter decodes these itself, and
/// `flutter_svg` draws SVG (#47); AVIF needs a decoder Android's Flutter
/// does not have.
final _shownImage =
    RegExp(r'\.(?:png|jpe?g|gif|webp|bmp|svg)$', caseSensitive: false);

/// Whether [path] is an SVG file, which `flutter_svg` draws.
bool isSvg(String path) => path.toLowerCase().endsWith('.svg');

/// [path] with `.` parts and empty parts removed, and each `..` taking away
/// the part before it. A `..` with nothing before it stays, so the path can
/// lead above where it starts: `../a/./b/../c.png` is `../a/c.png`.
String normalizePath(String path) {
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && parts.isNotEmpty && parts.last != '..') {
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

/// The path, relative to `roam/`, of the image file that a link with
/// [location] in the note [note] (relative to `roam/`) shows; null if the
/// app shows it as a link.
///
/// As in Org, a file link (`file:./img/a.png`, `./img/a.png`,
/// `../include/a.png`) is relative to the note's directory. Absolute and
/// `~/` paths cannot be read through Android's folder access, and web
/// images are not loaded (the app is offline, decisions 2 and 14), so
/// those stay links; so do `attachment:` links and other schemes.
String? linkedImagePath(String note, String location) {
  final OrgFileLink link;
  try {
    link = OrgFileLink.parse(location);
  } on Object {
    // Not a file link: a web image, `data:` or another scheme.
    return null;
  }
  if (link.scheme != null && link.scheme != 'file:') return null;
  final body = link.body;
  if (body.isEmpty || body.startsWith('/') || body.startsWith('~')) {
    return null;
  }
  if (!_shownImage.hasMatch(body)) return null;
  final slash = note.lastIndexOf('/');
  final dir = slash < 0 ? '' : note.substring(0, slash + 1);
  return normalizePath('$dir$body');
}

/// The width Org shows an image at: [pixels], or [fraction] of the text
/// width. Neither means the image's own width.
typedef OrgImageWidth = ({double? pixels, double? fraction});

/// The `:width` Org gives the image of [link] in [root], with my Emacs
/// settings (`org-image-actual-width` nil), as
/// `org-display-inline-image--width` in Org 9.7 reads it:
///
/// - From the `#+ATTR_ORG:` lines of the link's paragraph; if they have no
///   readable `:width`, from the first other `#+ATTR_...:` line that has
///   one.
/// - `300px` and `300` are 300 pixels (Emacs reads the leading number);
///   `50%` and `0.5` are half the text width, as is any decimal number from
///   0 to 2. `t`, or no readable width, is the image's own width.
///
/// A width wider than the text column is narrowed to it ([NoteImage]);
/// Emacs, with these settings, does not narrow it.
OrgImageWidth? orgImageWidth(OrgTree root, OrgLink link) {
  final attributes = _attributes(root, link);
  final orgWidth = _plistValue(attributes['_org'] ?? const [], ':width');
  String? width;
  if (_readableWidth(orgWidth)) {
    width = orgWidth;
  } else {
    for (final MapEntry(:key, :value) in attributes.entries) {
      if (key == '_org') continue;
      final other = _plistValue(value, ':width');
      if (_readableWidth(other)) {
        width = other;
        break;
      }
    }
  }
  if (width == null || width == 't') return null;
  final number = _emacsNumber(width);
  if (number == null) return null;
  final percent = RegExp(r'^[[+]?[0-9.]+%').hasMatch(width);
  final value = percent ? number.value / 100 : number.value;
  if ((percent || number.isFloat) && value >= 0 && value <= 2) {
    return (pixels: null, fraction: value);
  }
  return value > 0 ? (pixels: value, fraction: null) : null;
}

/// The `#+ATTR_<backend>:` lines right above the paragraph of [link], by
/// backend in lower case (`_org`), as plist tokens, the lines of one
/// backend joined in order, as `org-export-read-attribute` joins them.
Map<String, List<String>> _attributes(OrgTree root, OrgLink link) {
  var zipper = root.editNode(link);
  while (zipper != null && zipper.node is! OrgParagraph) {
    zipper = zipper.canGoUp() ? zipper.goUp() : null;
  }
  if (zipper == null) return const {};
  // Affiliated keywords are the keyword lines right before the paragraph.
  final lines = <OrgMeta>[];
  while (zipper!.canGoLeft()) {
    zipper = zipper.goLeft();
    final node = zipper.node;
    // A blank line after a keyword line ends the affiliation, as in Org.
    if (node is! OrgMeta || '\n'.allMatches(node.trailing).length > 1) break;
    lines.insert(0, node);
  }
  final attributes = <String, List<String>>{};
  for (final line in lines) {
    final match = _attrKey.firstMatch(line.key);
    if (match == null) continue;
    (attributes[match.group(1)!.toLowerCase()] ??= [])
        .addAll(_tokens(line.value?.toMarkup() ?? ''));
  }
  return attributes;
}

final _attrKey = RegExp(r'^#\+attr(_[-_a-z0-9]+):$', caseSensitive: false);

List<String> _tokens(String plist) =>
    plist.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

/// The value after [key] in [tokens], as `plist-get` finds the first; the
/// tokens up to the next keyword, joined by spaces, as Org reads them.
String? _plistValue(List<String> tokens, String key) {
  final i = tokens.indexWhere((token) => token.toLowerCase() == key);
  if (i < 0) return null;
  final value = [
    for (final token in tokens.skip(i + 1).takeWhile((t) => !t.startsWith(':')))
      token,
  ];
  return value.isEmpty ? null : value.join(' ');
}

/// Org's `width-unreadable?`, negated: `t`, or a string that starts with a
/// number, unless that number is a decimal outside 0 to 2.
bool _readableWidth(String? value) {
  if (value == null) return false;
  if (value == 't') return true;
  if (!RegExp(r'^\+?\.?[0-9]').hasMatch(value)) return false;
  final number = _emacsNumber(value);
  return number != null && !(number.isFloat && (number.value < 0 || number.value > 2));
}

/// The number at the start of [text], as Emacs's `string-to-number` reads
/// it: `300px` is the integer 300, `0.5` and `1e3` are decimals.
({double value, bool isFloat})? _emacsNumber(String text) {
  final match =
      RegExp(r'^[ \t]*([-+]?(?:[0-9]+(\.[0-9]+)?|\.[0-9]+)(e[-+]?[0-9]+)?)')
          .firstMatch(text);
  if (match == null) return null;
  final isFloat = match.group(1)!.startsWith(RegExp(r'[-+]?\.')) ||
      match.group(2) != null ||
      match.group(3) != null;
  return (value: double.parse(match.group(1)!), isFloat: isFloat);
}

/// An image file of the chosen folder, read through the folder access,
/// decoded at most [width] pixels wide (never enlarged), so large images
/// use little memory. Keyed by the file's URI, its [NoteFiles.version] and
/// [width], so Flutter's image cache keeps it, and a changed file is read
/// again.
@immutable
class FolderImage extends ImageProvider<FolderImage> {
  FolderImage(this.file, this.files, {this.width})
      : version = files.version(file);

  final FolderFile file;
  final NoteFiles files;

  /// [NoteFiles.version] of [file] when the image was made.
  final int version;

  /// The widest the image is decoded, in pixels; null for its own width.
  final int? width;

  @override
  Future<FolderImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          FolderImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, decode),
        scale: 1,
        debugLabel: file.path,
      );

  Future<ui.Codec> _load(FolderImage key, ImageDecoderCallback decode) async {
    final bytes = await files.read(file);
    if (bytes == null || bytes.isEmpty) {
      // Try again next time, for example after Syncthing has finished.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      throw StateError('Could not read ${file.path}.');
    }
    return decode(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (imageWidth, imageHeight) => switch (width) {
        // Only the width: the height keeps the aspect ratio.
        final width? when width < imageWidth =>
          ui.TargetImageSize(width: width),
        _ => const ui.TargetImageSize(),
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FolderImage &&
      other.file.uri == file.uri &&
      other.version == version &&
      other.width == width;

  @override
  int get hashCode => Object.hash(file.uri, version, width);
}

/// SVG files compiled for drawing, by URI and [NoteFiles.version], so a
/// note shown again does not parse its SVGs again. The oldest are dropped
/// beyond [_maxCompiled]; one that failed is tried again next time.
final _compiled = <(String, int), Future<ByteData>>{};
const _maxCompiled = 32;

/// [file], an SVG, compiled by `vector_graphics_compiler` on another
/// isolate, as `flutter_svg` compiles it. Fails if it cannot be read or
/// parsed.
///
/// The app compiles it itself, instead of giving `SvgPicture` a loader,
/// because `vector_graphics` leaves a failed load as an uncaught error.
Future<ByteData> compiledSvg(FolderFile file, NoteFiles files) {
  final key = (file.uri, files.version(file));
  if (_compiled[key] case final compiled?) return compiled;
  final result = () async {
    final bytes = await files.read(file);
    if (bytes == null) throw StateError('Could not read ${file.path}.');
    return compute(_compileSvg, utf8.decode(bytes, allowMalformed: true));
  }();
  _compiled[key] = result;
  if (_compiled.length > _maxCompiled) _compiled.remove(_compiled.keys.first);
  result.then<void>((_) {}, onError: (Object _) {
    if (_compiled[key] == result) _compiled.remove(key);
  });
  return result;
}

ByteData _compileSvg(String xml) => compiler
    .encodeSvg(
      xml: xml,
      debugName: 'note image',
      // As flutter_svg's own loaders.
      enableClippingOptimizer: false,
      enableMaskingOptimizer: false,
      enableOverdrawOptimizer: false,
    )
    .buffer
    .asByteData();

/// Already compiled SVG bytes, for `SvgPicture`.
class _CompiledSvg extends BytesLoader {
  const _CompiledSvg(this.bytes, this.key);

  final ByteData bytes;
  final Object key;

  @override
  Future<ByteData> loadBytes(BuildContext? context) =>
      SynchronousFuture(bytes);

  @override
  Object cacheKey(BuildContext? context) => key;
}

/// An SVG file of the chosen folder (#47), drawn with `flutter_svg`; on a
/// light background in dark mode. [error] is shown if it cannot be read
/// or parsed.
class FolderSvg extends StatefulWidget {
  const FolderSvg({
    super.key,
    required this.file,
    required this.files,
    required this.error,
  });

  final FolderFile file;
  final NoteFiles files;
  final WidgetBuilder error;

  @override
  State<FolderSvg> createState() => _FolderSvgState();
}

class _FolderSvgState extends State<FolderSvg> {
  late Future<ByteData> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = compiledSvg(widget.file, widget.files);
  }

  @override
  void didUpdateWidget(FolderSvg old) {
    super.didUpdateWidget(old);
    if (old.file.uri != widget.file.uri ||
        old.files.version(old.file) != widget.files.version(widget.file)) {
      _bytes = compiledSvg(widget.file, widget.files);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ByteData>(
        future: _bytes,
        builder: (context, snapshot) {
          if (snapshot.hasError) return widget.error(context);
          final bytes = snapshot.data;
          if (bytes == null) return const SizedBox.shrink();
          return SvgPicture(
            _CompiledSvg(
                bytes, (widget.file.uri, widget.files.version(widget.file))),
            semanticsLabel: widget.file.path.split('/').last,
            imageBuilder: (context, svg) => _onLightBackground(context, svg),
          );
        },
      );
}

/// [svg] on a light background in dark mode: many SVGs have a transparent
/// background and black lines, which cannot be read on a dark page. Emacs
/// shows them on the buffer's background, which is light on the laptop.
Widget _onLightBackground(BuildContext context, Widget svg) =>
    Theme.of(context).brightness == Brightness.dark
        ? ColoredBox(color: Colors.white, child: svg)
        : svg;

/// The `loadImage` of the node view for the note [note] (relative to
/// `roam/`), shown as [root]: the image of a link, or null to show the link
/// as text.
Widget? loadNoteImage(
  NoteFiles files,
  String note,
  OrgTree root,
  OrgLink link,
) {
  final path = linkedImagePath(note, link.location);
  if (path == null || !files.reaches(path)) return null;
  final file = files.find(path);
  if (file == null) {
    return BrokenImage(link, reason: 'There is no file $path in the folder.');
  }
  return NoteImage(
    link: link,
    file: file,
    files: files,
    width: orgImageWidth(root, link),
  );
}

/// An image in the node view, at its Org width ([orgImageWidth]) and never
/// wider than the text column, keeping its aspect ratio. Tapping it shows
/// it alone, with zoom ([ImagePage]).
class NoteImage extends StatelessWidget {
  const NoteImage({
    super.key,
    required this.link,
    required this.file,
    required this.files,
    this.width,
  });

  final OrgLink link;
  final FolderFile file;
  final NoteFiles files;
  final OrgImageWidth? width;

  @override
  Widget build(BuildContext context) {
    final image = isSvg(file.path) ? _svg(context) : _raster(context);
    return GestureDetector(
      onTap: () => ImagePage.open(context, file, files),
      child: image,
    );
  }

  /// An SVG at its Org width, else its own (its `width` attribute or
  /// `viewBox`). The width is set from outside, so `SvgPicture` keeps the
  /// aspect ratio, and the text column narrows it.
  Widget _svg(BuildContext context) {
    final picture = FolderSvg(
      file: file,
      files: files,
      error: (context) =>
          BrokenImage(link, reason: 'Could not show ${file.path}.'),
    );
    if (width?.pixels case final pixels?) {
      return SizedBox(width: pixels, child: picture);
    }
    if (width?.fraction case final fraction?) {
      return FractionallySizedBox(
          widthFactor: fraction.clamp(0, 1), child: picture);
    }
    return picture;
  }

  Widget _raster(BuildContext context) {
    final media = MediaQuery.of(context);
    final pixels = width?.pixels;
    // Decoded no wider than shown, in device pixels. The text column is at
    // most the screen's width; a fraction is of that width.
    final screen = media.size.width;
    final shown = pixels ?? screen * (width?.fraction ?? 1).clamp(0, 1);
    final decodeWidth =
        (shown.clamp(1, screen) * media.devicePixelRatio).ceil();
    Widget image = Image(
      image: FolderImage(file, files, width: decodeWidth),
      width: pixels,
      fit: BoxFit.contain,
      semanticLabel: file.path.split('/').last,
      errorBuilder: (context, error, stackTrace) =>
          BrokenImage(link, reason: 'Could not read ${file.path}.'),
    );
    if (width?.fraction case final fraction?) {
      image = FractionallySizedBox(
        widthFactor: fraction.clamp(0, 1),
        child: image,
      );
    }
    return image;
  }
}

/// A link whose image cannot be shown: a broken-image icon and the link as
/// text, as Orgro shows it. [reason] is the icon's tooltip.
class BrokenImage extends StatelessWidget {
  const BrokenImage(this.link, {super.key, required this.reason});

  final OrgLink link;
  final String reason;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: reason,
            child: const Icon(Icons.broken_image_outlined),
          ),
          const SizedBox(width: 4),
          Flexible(child: OrgLinkWidget(link)),
        ],
      );
}

/// An image alone on its page, with pinch zoom. Back returns to the node.
class ImagePage extends StatelessWidget {
  const ImagePage({super.key, required this.file, required this.files});

  final FolderFile file;
  final NoteFiles files;

  static Future<void> open(
          BuildContext context, FolderFile file, NoteFiles files) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => ImagePage(file: file, files: files),
        ),
      );

  /// How far the page zooms in.
  static const maxScale = 8.0;

  /// The widest the page decodes an image, in device pixels: enough to
  /// zoom in four times on the screen's long side, and at most 4096, so
  /// a very large photo does not use hundreds of megabytes.
  static int decodeWidth(MediaQueryData media) =>
      (media.size.longestSide * media.devicePixelRatio * 4)
          .clamp(1, 4096)
          .ceil();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(file.path.split('/').last)),
        body: InteractiveViewer(
          maxScale: maxScale,
          child: Center(
            // An SVG is drawn anew at each zoom, so it stays sharp.
            child: isSvg(file.path)
                ? FolderSvg(
                    file: file,
                    files: files,
                    error: (context) => Text('Could not show ${file.path}.'),
                  )
                : Image(
                    image: FolderImage(file, files,
                        width: decodeWidth(MediaQuery.of(context))),
                    errorBuilder: (context, error, stackTrace) =>
                        Text('Could not read ${file.path}.'),
                  ),
          ),
        ),
      );
}
