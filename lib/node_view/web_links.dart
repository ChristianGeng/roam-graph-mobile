/// Web, mail and phone links in notes and in the chat (#108): they open in
/// the app Android has for them, the browser for `https:`. Other links,
/// such as `file:`, are not handed to other apps.
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/desktop.dart';

/// Opens [uri] in another app; false if no app can.
typedef UrlOpener = Future<bool> Function(Uri uri);

/// The schemes handed to other apps.
const externalSchemes = {'http', 'https', 'mailto', 'tel'};

/// Where Org opens `doi:` links (`org-link-doi-server-url`).
const doiServer = 'https://doi.org/';

/// The address an Org link [location] opens outside the app, or null if
/// the app does not hand it to other apps: only [externalSchemes], and a
/// web address must have a host. A `doi:` link opens at [doiServer], as in
/// Org.
Uri? externalLinkTarget(String location) {
  var target = location.trim();
  if (target.toLowerCase().startsWith('doi:') && target.length > 4) {
    target = '$doiServer${target.substring(4)}';
  }
  final uri = Uri.tryParse(target);
  if (uri == null || !externalSchemes.contains(uri.scheme.toLowerCase())) {
    return null;
  }
  if ((uri.scheme.toLowerCase() == 'http' ||
          uri.scheme.toLowerCase() == 'https') &&
      uri.host.isEmpty) {
    return null;
  }
  // `mailto:` or `tel:` with nothing after it.
  if (uri.toString().length <= uri.scheme.length + 1) return null;
  return uri;
}

const _channel = MethodChannel('roam_graph/folder');

/// [UrlOpener] through `openUrl` in `FolderAccess.kt`, Android's
/// `ACTION_VIEW`.
Future<bool> openUrlOnDevice(Uri uri) async {
  // The desktop's browser (#116).
  if (isDesktop) return openUrlOnDesktop(uri);
  try {
    return await _channel.invokeMethod<bool>(
            'openUrl', {'url': uri.toString()}) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Opens [uri] with [open] and says so in a snack bar that names the
/// address, with "Copy"; or that no app could open it.
Future<void> openExternalLink(
    BuildContext context, Uri uri, UrlOpener open) async {
  final messenger = ScaffoldMessenger.of(context);
  final address = uri.toString();
  final opened = await open(uri);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(opened ? 'Opening $address' : 'No app can open $address'),
      action: SnackBarAction(
        label: 'Copy',
        onPressed: () => Clipboard.setData(ClipboardData(text: address)),
      ),
    ));
}
