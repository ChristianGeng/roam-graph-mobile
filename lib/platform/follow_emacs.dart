/// Follow Emacs (#117): on the desktop, Emacs tells the app which org-roam
/// node is at point, and the graph shows it, as org-roam-ui's "follow"
/// does. The Emacs side is `emacs/roam-graph-follow.el`.
///
/// The app listens on 127.0.0.1 only, on a port the system chooses, and
/// writes the port and a random token to `follow.json` in its own folder,
/// readable only by the user. Every message must carry the token, so no
/// other program, and no web page, can steer the app. A message is one
/// line of JSON, `{"token": "…", "id": "…"}`: it carries only an ID, and
/// nothing is written to the notes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// The IDs Emacs sends, for the graph view. Empty until [startFollowing]
/// runs, and on Android.
Stream<String> get emacsFollowRequests => _requests.stream;
final _requests = StreamController<String>.broadcast();

/// Starts the listener for the running app and writes its `follow.json`.
/// Errors are kept to the app: without the listener, following is off.
Future<FollowServer?> startFollowing() async {
  try {
    final folder = (await getApplicationSupportDirectory()).path;
    final server = await FollowServer.start(
      file: File('$folder${Platform.pathSeparator}follow.json'),
    );
    server.ids.listen(_requests.add);
    return server;
  } on Object {
    return null;
  }
}

/// The longest message read; an ID and a token are far shorter.
const _maxMessage = 4096;

/// How long a client may take to send its message.
const _deadline = Duration(seconds: 2);

/// The longest ID accepted. org-roam IDs are UUIDs, 36 characters.
const _maxId = 256;

/// A listener on 127.0.0.1 for the IDs Emacs sends.
class FollowServer {
  FollowServer._(this._socket, this.file, this.token);

  final ServerSocket _socket;

  /// Where the port and the token are written, for Emacs.
  final File file;

  /// The secret every message must carry.
  final String token;

  final _ids = StreamController<String>.broadcast();

  /// The address listened on: 127.0.0.1.
  InternetAddress get address => _socket.address;

  /// The port the system chose.
  int get port => _socket.port;

  /// The IDs of messages with the right token, in the order they came.
  Stream<String> get ids => _ids.stream;

  /// Listens on a free port of 127.0.0.1 and writes [file]. [random] is
  /// for tests; the token comes from a secure source otherwise.
  static Future<FollowServer> start({
    required File file,
    Random? random,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = FollowServer._(socket, file, _newToken(random));
    socket.listen(server._serve);
    try {
      await server._writeFile();
    } on Object {
      await socket.close();
      rethrow;
    }
    return server;
  }

  /// Stops listening and removes [file], so Emacs stops sending.
  Future<void> close() async {
    await _socket.close();
    await _ids.close();
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  static String _newToken(Random? random) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(24, (_) => source.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Writes the port and the token, readable only by the user: a new
  /// file, private from the moment it exists, then the content, then
  /// renamed into place, so the token is never readable by others and
  /// Emacs never reads half a file.
  Future<void> _writeFile() async {
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${_newToken(null).substring(0, 8)}.tmp',
    );
    if (Platform.isWindows) {
      // Windows keeps the user's %APPDATA% private already.
      await temporary.writeAsString('');
    } else {
      // Dart cannot set the mode when it creates a file: the shell does,
      // with umask 077, and refuses a name that exists (noclobber), so no
      // one can have it open before.
      final result = await Process.run('sh', [
        '-c',
        'umask 077 && set -C && : > "\$1"',
        'sh',
        temporary.path,
      ]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'cannot create a private file',
          temporary.path,
        );
      }
    }
    await temporary.writeAsString(
      '${jsonEncode({'port': port, 'token': token})}\n',
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _serve(Socket client) async {
    final bytes = <int>[];
    // One deadline for the whole message, not one per chunk, so a client
    // that sends a byte now and then cannot hold the connection open.
    var late = false;
    final cutoff = Timer(_deadline, () {
      late = true;
      client.destroy();
    });
    try {
      await for (final chunk in client) {
        bytes.addAll(chunk);
        if (bytes.contains(10) || bytes.length > _maxMessage) break;
      }
    } on Object {
      // A broken connection: nothing to do.
    } finally {
      cutoff.cancel();
    }
    client.destroy();
    if (late || bytes.length > _maxMessage) return;
    final newline = bytes.indexOf(10);
    final id = idOf(
      utf8.decode(
        newline < 0 ? bytes : bytes.sublist(0, newline),
        allowMalformed: true,
      ),
      token,
    );
    if (id != null && !_ids.isClosed) _ids.add(id);
  }
}

/// The ID in [line] when it is a message with [token]; null for anything
/// else: not JSON, a wrong or missing token, or an ID that is empty, too
/// long or holds control characters.
String? idOf(String line, String token) {
  Object? message;
  try {
    message = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (message is! Map) return null;
  final sent = message['token'];
  final id = message['id'];
  if (sent is! String || !_sameSecret(sent, token)) return null;
  if (id is! String) return null;
  final trimmed = id.trim();
  if (trimmed.isEmpty ||
      trimmed.length > _maxId ||
      trimmed.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  return trimmed;
}

/// Compares in the same time for any [a] of the length of [b], so the
/// token cannot be guessed from how fast a wrong one is refused.
bool _sameSecret(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
