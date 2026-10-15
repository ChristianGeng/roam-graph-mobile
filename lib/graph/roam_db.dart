/// The graph in a SQLite database with org-roam's schema and encoding (#5).
///
/// Same tables, columns and indices as org-roam's `org-roam.db`, the same
/// `user_version`, and every value printed as Emacs Lisp the way emacsql
/// prints it, so the queries of the org-roam MCP server work on it
/// unchanged.
///
/// Pure Dart (no Flutter), so the tools in `tool/` can build the same
/// database on the laptop.
library;

import 'package:sqlite3/sqlite3.dart';

import 'elisp.dart';
import 'roam_graph.dart';

/// org-roam's `org-roam-db-version`.
const orgRoamDbVersion = 20;

/// org-roam's schema, as org-roam creates it (copied from an `org-roam.db`).
const _schema = [
  'CREATE TABLE files (file UNIQUE PRIMARY KEY, title , hash NOT NULL, '
      'atime NOT NULL, mtime NOT NULL)',
  'CREATE TABLE nodes (id NOT NULL PRIMARY KEY, file NOT NULL, '
      'level NOT NULL, pos NOT NULL, todo , priority , scheduled text, '
      'deadline text, title , properties , olp , FOREIGN KEY (file) '
      'REFERENCES files (file) ON DELETE CASCADE)',
  'CREATE TABLE aliases (node_id NOT NULL, alias , FOREIGN KEY (node_id) '
      'REFERENCES nodes (id) ON DELETE CASCADE)',
  'CREATE TABLE citations (node_id NOT NULL, cite_key NOT NULL, '
      'pos NOT NULL, properties , FOREIGN KEY (node_id) REFERENCES nodes '
      '(id) ON DELETE CASCADE)',
  'CREATE TABLE refs (node_id NOT NULL, ref NOT NULL, type NOT NULL, '
      'FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE CASCADE)',
  'CREATE TABLE tags (node_id NOT NULL, tag , FOREIGN KEY (node_id) '
      'REFERENCES nodes (id) ON DELETE CASCADE)',
  'CREATE TABLE links (pos NOT NULL, source NOT NULL, dest NOT NULL, '
      'type NOT NULL, properties NOT NULL, FOREIGN KEY (source) REFERENCES '
      'nodes (id) ON DELETE CASCADE)',
  'CREATE INDEX alias_node_id ON aliases (node_id )',
  'CREATE INDEX refs_node_id ON refs (node_id )',
  'CREATE INDEX tags_node_id ON tags (node_id )',
];

/// org-roam's tables, in the order of its schema.
const roamTables = [
  'files', 'nodes', 'aliases', 'citations', 'refs', 'tags', 'links', //
];

/// What the database knows about a stored file.
typedef StoredFile = ({String hash, int mtime});

/// An org-roam database. [root] is the folder the stored paths start with;
/// org-roam stores absolute paths.
class RoamDatabase {
  RoamDatabase._(this._db, this.root) {
    // org-roam's tables delete a file's rows by foreign key cascades.
    _db.execute('PRAGMA foreign_keys = ON');
    final exists = _db
        .select("SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'files'")
        .isNotEmpty;
    if (!exists) {
      // One transaction, so an interrupted setup leaves no half schema.
      transaction(() {
        for (final sql in _schema) {
          _db.execute(sql);
        }
        _db.userVersion = orgRoamDbVersion;
      });
    }
  }

  /// SQLite's `user_version`, which org-roam sets to its schema version.
  int get userVersion => _db.userVersion;

  /// The column names of [table], as SQLite reports them.
  List<String> columns(String table) => [
        for (final row in _db.select('SELECT name FROM pragma_table_info(?)',
            [table]).rows)
          row[0]! as String,
      ];

  /// Opens the database at [path], creating it if needed.
  factory RoamDatabase.open(String path, {required String root}) =>
      RoamDatabase._(sqlite3.open(path), root);

  /// A database that lives only in memory, for tests.
  factory RoamDatabase.inMemory({required String root}) =>
      RoamDatabase._(sqlite3.openInMemory(), root);

  final Database _db;
  final String root;

  void close() => _db.dispose();

  /// Runs [body] in one transaction.
  T transaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String _absolute(String path) => '$root/$path';

  /// The path relative to [root] of a stored `file` value, or null if it is
  /// not below [root].
  String? _relative(Object? stored) {
    if (stored is! String) return null;
    final path = decodeElispString(stored);
    final prefix = '$root/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : null;
  }

  /// The stored files, by path relative to [root].
  Map<String, StoredFile> storedFiles() => {
        for (final row in _db.select('SELECT file, hash, mtime FROM files').rows)
          ?_relative(row[0]): (
            hash: decodeElispString(row[1]! as String),
            mtime: _parseTime(row[2]),
          ),
      };

  /// Replaces what is stored for [file]. [hash] is the SHA-1 of the file's
  /// bytes and [mtime] its modification time in milliseconds.
  ///
  /// Returns the IDs that another node already has, with that node's file:
  /// org-roam keeps only the first node of an ID.
  Map<String, String> putFile(
    RoamFileData file, {
    required String hash,
    required int mtime,
  }) {
    final duplicates = <String, String>{};
    removeFile(file.path);
    final path = elispString(_absolute(file.path));
    _db.execute('INSERT INTO files VALUES (?, ?, ?, ?, ?)', [
      path,
      elispString(file.title),
      elispString(hash),
      // atime: Android's folder access gives no access time, so the
      // modification time stands in for it.
      _emacsTime(mtime),
      _emacsTime(mtime),
    ]);
    final nodes = _db.prepare(
      // A duplicate ID fails in org-roam with a warning; the first stays.
      'INSERT OR IGNORE INTO nodes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    );
    final tags = _db.prepare('INSERT INTO tags VALUES (?, ?)');
    final aliases = _db.prepare('INSERT INTO aliases VALUES (?, ?)');
    final refs = _db.prepare('INSERT INTO refs VALUES (?, ?, ?)');
    final links = _db.prepare('INSERT INTO links VALUES (?, ?, ?, ?, ?)');
    final citations = _db.prepare('INSERT INTO citations VALUES (?, ?, ?, ?)');
    try {
      for (final node in file.nodes) {
        final id = elispString(node.id);
        nodes.execute([
          id,
          path,
          node.level,
          node.pos,
          _stringOrNull(node.todo),
          node.priority,
          _stringOrNull(node.scheduled),
          _stringOrNull(node.deadline),
          elispString(node.title),
          node.properties,
          node.olp.isEmpty ? null : elispList(node.olp),
        ]);
        if (_db.updatedRows == 0) {
          final other = _db.select('SELECT file FROM nodes WHERE id = ?', [id]);
          duplicates[node.id] =
              other.isEmpty ? file.path : _relative(other.rows.first[0]) ?? file.path;
        }
        for (final tag in node.tags) {
          tags.execute([id, elispString(tag)]);
        }
        for (final alias in node.aliases) {
          aliases.execute([id, elispString(alias)]);
        }
        for (final ref in node.refs) {
          refs.execute([id, elispString(ref.ref), elispString(ref.type)]);
        }
      }
      for (final link in file.links) {
        links.execute([
          link.pos,
          elispString(link.source),
          elispString(link.dest),
          elispString(link.type),
          _outlineProperties(link.outline, link.searchOption),
        ]);
      }
      for (final citation in file.citations) {
        citations.execute([
          elispString(citation.nodeId),
          elispString(citation.key),
          citation.pos,
          _outlineProperties(citation.outline, null),
        ]);
      }
    } finally {
      for (final statement in [nodes, tags, aliases, refs, links, citations]) {
        statement.dispose();
      }
    }
    return duplicates;
  }

  /// Records a new modification time for a file whose content is unchanged.
  void touchFile(String path, int mtime) {
    final time = _emacsTime(mtime);
    _db.execute('UPDATE files SET atime = ?, mtime = ? WHERE file = ?',
        [time, time, elispString(_absolute(path))]);
  }

  /// Removes a file and, by cascade, its nodes and their rows.
  void removeFile(String path) {
    _db.execute(
        'DELETE FROM files WHERE file = ?', [elispString(_absolute(path))]);
  }

  /// Removes everything, for a full rebuild. Run it inside [transaction]
  /// with the rebuild, so a failed rebuild keeps the old rows.
  void clear() {
    for (final table in roamTables.reversed) {
      _db.execute('DELETE FROM $table');
    }
  }

  /// The graph as stored. Lines are not stored, so they are 0; [extra]
  /// adds files that are not stored, such as files org-roam would skip, and
  /// [duplicateIds] IDs found twice while storing.
  RoamGraph loadGraph({
    Iterable<RoamFileData> extra = const [],
    Map<String, List<String>> duplicateIds = const {},
  }) {
    final files = <String, String>{}; // stored file -> relative path
    final titles = <String, String>{};
    for (final row in _db.select('SELECT file, title FROM files').rows) {
      final path = _relative(row[0]);
      if (path == null) continue;
      files[row[0]! as String] = path;
      titles[path] = row[1] is String ? decodeElispString(row[1]! as String) : '';
    }
    Map<String, List<List<Object?>>> byNode(String sql) {
      final result = <String, List<List<Object?>>>{};
      for (final row in _db.select(sql).rows) {
        result.putIfAbsent(row[0]! as String, () => []).add(row);
      }
      return result;
    }

    final tags = byNode('SELECT node_id, tag FROM tags');
    final aliases = byNode('SELECT node_id, alias FROM aliases');
    final refs = byNode('SELECT node_id, ref, type FROM refs');
    final links = byNode(
        "SELECT source, dest, pos, properties FROM links "
        "WHERE type = '\"id\"'");

    final nodesOfFile = <String, List<RoamNode>>{};
    final linksOfFile = <String, List<RoamLink>>{};
    for (final row in _db
        .select('SELECT id, file, level, pos, title FROM nodes')
        .rows) {
      final path = files[row[1]];
      if (path == null) continue;
      final storedId = row[0]! as String;
      final id = decodeElispString(storedId);
      nodesOfFile.putIfAbsent(path, () => []).add(RoamNode(
            id: id,
            file: path,
            level: row[2]! as int,
            title: row[4] is String ? decodeElispString(row[4]! as String) : '',
            line: 0,
            pos: row[3]! as int,
            tags: [
              for (final r in tags[storedId] ?? const <List<Object?>>[])
                decodeElispString(r[1]! as String),
            ],
            aliases: [
              for (final r in aliases[storedId] ?? const <List<Object?>>[])
                decodeElispString(r[1]! as String),
            ],
            refs: [
              for (final r in refs[storedId] ?? const <List<Object?>>[])
                RoamRef(decodeElispString(r[1]! as String),
                    decodeElispString(r[2]! as String)),
            ],
          ));
      for (final r in links[storedId] ?? const <List<Object?>>[]) {
        linksOfFile.putIfAbsent(path, () => []).add(RoamLink(
              source: id,
              dest: decodeElispString(r[1]! as String),
              file: path,
              line: 0,
              pos: r[2]! as int,
              outline:
                  decodeElispPlistStrings(r[3] as String? ?? '', ':outline'),
            ));
      }
    }
    return RoamGraph.fromFiles([
      for (final path in files.values)
        RoamFileData(
          path: path,
          title: titles[path] ?? '',
          nodes: nodesOfFile[path] ?? const [],
          links: linksOfFile[path] ?? const [],
        ),
      ...extra,
    ], duplicateIds: duplicateIds);
  }

  /// Every row of every table, without the access and modification times,
  /// for comparing with org-roam's database.
  Map<String, List<List<Object?>>> dumpTables() => {
        for (final table in roamTables)
          table: _db
              .select(table == 'files'
                  ? 'SELECT file, title, hash FROM files'
                  : 'SELECT * FROM $table')
              .rows,
      };
}

String? _stringOrNull(String? value) =>
    value == null ? null : elispString(value);

/// `(:outline ("A" "B"))`, with `:search-option` if there is one.
String _outlineProperties(List<String> outline, String? searchOption) {
  final option =
      searchOption == null ? '' : ' :search-option ${elispString(searchOption)}';
  return '(:outline ${elispList(outline)}$option)';
}

/// A time as Emacs prints it: `(HIGH LOW MICRO PICO)`.
String _emacsTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final micros = (milliseconds % 1000) * 1000;
  return '(${seconds >> 16} ${seconds & 0xFFFF} $micros 0)';
}

/// Milliseconds of a time as Emacs prints it; 0 if it is not one.
int _parseTime(Object? value) {
  if (value is! String) return 0;
  final m = RegExp(r'^\((\d+) (\d+)(?: (\d+))?').firstMatch(value);
  if (m == null) return 0;
  final seconds = (int.parse(m.group(1)!) << 16) + int.parse(m.group(2)!);
  final micros = int.parse(m.group(3) ?? '0');
  return seconds * 1000 + micros ~/ 1000;
}
