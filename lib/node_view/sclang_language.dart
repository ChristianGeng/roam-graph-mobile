// The `highlighting` package has no public export for `Language`; the
// languages it ships import it the same way.
// ignore: implementation_imports
import 'package:highlighting/src/language.dart';
import 'package:highlighting/highlighting.dart';
import 'package:highlighting/languages/all.dart';

/// A highlight.js grammar for SuperCollider's language, sclang (#147).
///
/// highlight.js has no SuperCollider grammar in its core, and the
/// `highlighting` package ports only the core. This one follows
/// `highlightjs-supercollider` by Brian Heim
/// (https://github.com/highlightjs/highlightjs-supercollider, MIT licence,
/// Copyright (c) 2019 Brian Heim), changed to colour what Emacs's
/// `sclang-mode` colours, with the classes org_flutter's light and dark
/// themes have a colour for:
///
/// - classes, words that start with a capital letter (`SinOsc`): `type`;
/// - symbols, `\freq` and `'name'`, and characters, `$a`: `symbol`
///   (`font-lock-constant-face`);
/// - environment variables, `~bus`: `variable`;
/// - `var`, `arg`, `classvar`, `const`, `this`, `super`, `thisProcess`,
///   `thisFunction`, `thisFunctionDef`, `thisMethod`, `thisThread`:
///   `keyword`, as in `sclang-font-lock-keyword-list`;
/// - `nil`, `true`, `false`, `inf`: `built_in`, as in
///   `sclang-font-lock-builtin-list`;
/// - numbers (`440`, `0.5`, `1e3`, `2pi`, `0x1F`, `16rFF`, `2s`): `number`;
///   in `-12` only `12`, as the minus sign may also be a subtraction;
/// - strings with escapes: `string`;
/// - comments, `// …` and `/* … */`, which nest in sclang: `comment`.
///
/// highlight.js's `title.class` would be the usual class for classes, but
/// org_flutter's themes have no colour for it; `type` is Emacs's
/// `font-lock-type-face`, which `sclang-mode` uses for classes.
final sclang = Language(
  id: 'sclang',
  name: 'SuperCollider',
  refs: {},
  // Only for blocks marked `sclang`; never guessed for other text.
  disableAutodetect: true,
  keywords: {
    'keyword': [
      'var',
      'arg',
      'classvar',
      'const',
      'this',
      'super',
      'thisProcess',
      'thisFunction',
      'thisFunctionDef',
      'thisMethod',
      'thisThread',
    ],
    'built_in': ['nil', 'true', 'false', 'inf'],
  },
  contains: [
    Mode(scope: 'comment', begin: r'//', end: r'$', relevance: 0),
    Mode(
      scope: 'comment',
      begin: r'/\*',
      end: r'\*/',
      relevance: 0,
      // Block comments nest in sclang: `/* a /* b */ c */` is one comment.
      contains: [ModeSelfReference()],
    ),
    Mode(
      scope: 'string',
      begin: r'"',
      end: r'"',
      contains: [_escape],
      relevance: 0,
    ),
    // A character: `$a`, `$"`, `$\n`; sclang-mode colours it as a symbol.
    Mode(scope: 'symbol', begin: r'\$\\?.', relevance: 0),
    Mode(scope: 'variable', begin: r'~\w+', relevance: 0),
    Mode(
      scope: 'symbol',
      relevance: 0,
      variants: [
        Mode(begin: r'\\\w+'),
        Mode(begin: r"'", end: r"'", contains: [_escape]),
      ],
    ),
    Mode(scope: 'type', begin: r'\b[A-Z]\w*\b', relevance: 0),
    Mode(
      scope: 'number',
      relevance: 0,
      variants: [
        // Radix: 16rFF, 2r1010, 36rZIGZAG.1
        Mode(begin: r'\b\d+r[0-9a-zA-Z]+(\.[0-9a-zA-Z]+)?\b'),
        // Scale degrees: 2s, 3bb, 1s25.
        Mode(begin: r'\b\d+(s+|b+|[sb]\d+)\b'),
        Mode(begin: r'\b0x[0-9a-fA-F]+\b'),
        Mode(begin: r'\b(\d+(\.\d+)?([eE][-+]?\d+)?(pi)?|pi)\b'),
      ],
    ),
  ],
);

final _escape = Mode(begin: r'\\[\s\S]', relevance: 0);

var _registered = false;

/// Registers [sclang] under `sclang`, once: with the global `highlight`,
/// which colours source blocks, and in `allLanguages`, where org_flutter
/// and `highlightLanguage` look for a grammar. Calling it again does
/// nothing.
void registerSclang() {
  if (_registered) return;
  _registered = true;
  highlight.registerLanguage(sclang, id: 'sclang');
  allLanguages['sclang'] = sclang;
}
