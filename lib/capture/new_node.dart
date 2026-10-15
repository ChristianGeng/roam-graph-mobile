/// A new node, as org-roam's default capture template makes it (#11).
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'dart:math';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// The combining marks `org-roam-node-slugify` removes: accents and the
/// like, so `Crème brûlée` becomes `creme_brulee`.
const _slugTrimChars = {
  0x300, 0x301, 0x302, 0x303, 0x304, 0x306, 0x307, //
  0x308, 0x309, 0x30A, 0x30B, 0x30C, 0x31B, 0x323,
  0x324, 0x325, 0x327, 0x32D, 0x32E, 0x330, 0x331,
};

/// What Emacs's `[:alnum:]` matches: letters and decimal digits.
final _notAlnum = RegExp(r'[^\p{L}\p{Nd}]', unicode: true);

/// The slug of [title], as `org-roam-node-slugify` makes it: accents
/// removed, everything but letters and digits turned into `_`, no `_` at
/// the ends or twice in a row, lower case.
String slugify(String title) {
  final decomposed = unorm.nfd(title);
  final kept = String.fromCharCodes(
      decomposed.runes.where((rune) => !_slugTrimChars.contains(rune)));
  return unorm
      .nfc(kept)
      .replaceAll(_notAlnum, '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_'), '')
      .replaceAll(RegExp(r'_$'), '')
      .toLowerCase();
}

/// The file name org-roam's default capture template gives a node made at
/// [time]: `%<%Y%m%d%H%M%S>-${slug}.org`, in local time.
String nodeFileName(DateTime time, String title) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${time.year.toString().padLeft(4, '0')}${two(time.month)}'
      '${two(time.day)}${two(time.hour)}${two(time.minute)}${two(time.second)}';
  return '$stamp-${slugify(title)}.org';
}

/// A new ID, as `org-id-new` makes one with `org-id-method` `uuid`: a
/// random (version 4) UUID in lower case, like `uuidgen`'s.
String newOrgId([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')]
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The tags in [text], separated by spaces, commas or colons. Org tags
/// cannot contain these, so `org, roam` and `:org:roam:` give the same.
List<String> parseTags(String text) => [
      for (final tag in text.split(RegExp(r'[\s,:]+')))
        if (tag.isNotEmpty) tag,
    ];

/// One line: a title with line breaks in it would end `#+title:` early.
String oneLine(String text) => text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

/// An `id:` link to [id], as Org's `org-link-make-string` writes it:
/// - The target is escaped as `org-link-escape` does: `[` and `]` get a
///   backslash, and backslashes before them, or at the end, are doubled.
/// - The description cannot end the link early: if it ends with `]`, a
///   zero-width space follows; then each pair `]]`, from the left and not
///   overlapping, gets a zero-width space between its brackets.
String orgLink(String id, String description) {
  const space = '\u200B';
  var text = oneLine(description);
  if (text.endsWith(']')) text = '$text$space';
  text = text.replaceAll(']]', ']$space]');
  return '[[${orgLinkEscape('id:$id')}][$text]]';
}

/// [link] escaped as Org's `org-link-escape` does it.
String orgLinkEscape(String link) => link.replaceAllMapped(
      RegExp(r'(\\*)([\[\]]|$)'),
      (m) => '${m[1]}${m[1]}${m[2]!.isEmpty ? '' : '\\'}${m[2]}',
    );

/// The text of a new node's file, as org-roam writes it: the `:ID:`
/// property in a drawer at the top (`org-id-get-create`), then the default
/// template's `#+title:`, then `#+filetags:` as `org-roam-tag-add` writes
/// it, then a link to [linkTo] (#12), then [body].
String nodeFileText({
  required String id,
  required String title,
  List<String> tags = const [],
  String body = '',
  ({String id, String title})? linkTo,
}) {
  final text = StringBuffer()
    ..writeln(':PROPERTIES:')
    ..writeln(':ID:       $id')
    ..writeln(':END:')
    ..writeln('#+title: ${oneLine(title)}');
  if (tags.isNotEmpty) text.writeln('#+filetags: :${tags.join(':')}:');
  final parts = [
    if (linkTo != null) orgLink(linkTo.id, linkTo.title),
    if (body.trimRight() case final trimmed when trimmed.isNotEmpty) trimmed,
  ];
  for (final part in parts) {
    text
      ..writeln()
      ..writeln(part);
  }
  return text.toString();
}
