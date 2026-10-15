import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remembers the node opened last, so the graph starts centred on it (#6).
///
/// An interface so the graph screen can be tested without files.
abstract interface class NodeMemory {
  /// The ID of the node opened last, or null.
  Future<String?> lastNode();

  Future<void> remember(String id);
}

/// [NodeMemory] in the file `last-node` in the app's support folder, next
/// to the database. Errors are ignored: the graph then starts elsewhere.
class FileNodeMemory implements NodeMemory {
  const FileNodeMemory({this.path});

  /// Where the file is; by default in the app's support folder.
  final String? path;

  Future<File> _file() async => File(
      path ?? '${(await getApplicationSupportDirectory()).path}/last-node');

  @override
  Future<String?> lastNode() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final id = file.readAsStringSync();
      return id.isEmpty ? null : id;
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> remember(String id) async {
    try {
      (await _file()).writeAsStringSync(id);
    } on Exception {
      // Not worth an error message: only the next start is affected.
    }
  }
}

