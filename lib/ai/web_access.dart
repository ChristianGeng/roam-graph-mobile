/// Web access for the AI chat (#137): `fetch_web_page`, the app's own
/// tool for every provider, and the limit on web searches for one
/// message, which Anthropic's built-in `web_search` shares.
///
/// A page is fetched from the phone: only `https:`, never an address in
/// the own network (also after a redirect and after the name is
/// resolved), no cookies, a time and a size limit.
///
/// Pure Dart (no Flutter); the network goes through [HostResolver] and
/// [PageGet], which tests replace.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ai_tools.dart';

/// The tool as the model sees it.
const fetchWebPageTool = AiTool(
  'fetch_web_page',
  'Fetch a web page over https and return its readable text (HTML without '
      'scripts, styles and markup). Use it for addresses you know or found '
      'in a search. Each call counts as one of the web searches allowed for '
      'one message.',
  {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': 'The page\'s full address, starting with https://',
      },
    },
    'required': ['url'],
  },
);

/// The longest text `fetch_web_page` returns, in characters; the rest is
/// cut, with a line that says so.
const maxPageText = 100000;

/// The most bytes read of a page; the text of more would be cut anyway.
const maxPageBytes = 2 * 1024 * 1024;

/// The time one fetch may take, redirects included.
const pageTimeLimit = Duration(seconds: 20);

/// The most redirects followed, each checked as the first address.
const maxRedirects = 5;

/// The addresses a host name stands for; tests replace it.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> lookupWithDartIo(String host) =>
    InternetAddress.lookup(host);

/// A page as the server answered: no redirect is followed here.
class PageReply {
  const PageReply(this.status, {this.location, this.contentType, this.body = const []});

  final int status;

  /// The `Location` header of a redirect.
  final String? location;

  /// The `Content-Type` header.
  final String? contentType;

  /// At most [maxPageBytes] of the body.
  final List<int> body;
}

/// Gets [url] from [address], which the name was resolved to and checked;
/// tests replace it.
typedef PageGet = Future<PageReply> Function(Uri url, InternetAddress address);

/// [PageGet] with `dart:io`: the connection goes to [address] itself, so
/// the name cannot be resolved again to another address after the check;
/// TLS is checked for the URL's host name. No cookies, no stored logins,
/// a plain user agent, no redirects.
///
/// After [limit] [TimeoutException] is thrown, and the connection is
/// closed, also while the body is still coming; only the socket of a TLS
/// handshake that never ends can stay open (see [connectSecure]). Tests
/// replace [connect].
Future<PageReply> getWithPinnedAddress(Uri url, InternetAddress address,
    {Duration limit = pageTimeLimit,
    Future<Socket> Function(InternetAddress address, Uri url, Duration limit)
        connect = connectSecure}) async {
  final client = HttpClient()
    ..connectionTimeout = limit
    ..userAgent = 'RoamGraph'
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, proxyHost, proxyPort) async =>
        ConnectionTask.fromSocket(connect(address, uri, limit), () {});
  var late = false;
  final timer = Timer(limit, () {
    late = true;
    client.close(force: true);
  });
  TimeoutException tooLate() =>
      TimeoutException('The page did not load in time.', limit);
  try {
    final request = await client.getUrl(url);
    request.followRedirects = false;
    request.headers.set('accept',
        'text/html, application/xhtml+xml, text/plain;q=0.9, */*;q=0.5');
    final response = await request.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length >= maxPageBytes) break;
    }
    if (late) throw tooLate();
    return PageReply(
      response.statusCode,
      location: response.headers.value('location'),
      contentType: response.headers.value('content-type'),
      body: bytes.takeBytes(),
    );
  } catch (e) {
    if (late && e is! TimeoutException) throw tooLate();
    rethrow;
  } finally {
    timer.cancel();
    client.close(force: true);
  }
}

/// A TLS connection to [address], checked for [url]'s host name. The
/// handshake has the same time limit as the connect, so the call gives up
/// in time. Known limit (decision 82): once `SecureSocket.secure` has taken
/// over the socket, `dart:io` offers no way to close it; a server that
/// never finishes the handshake keeps that one socket open until it closes
/// it itself.
Future<Socket> connectSecure(
    InternetAddress address, Uri url, Duration limit) async {
  final raw = await Socket.connect(address, url.port, timeout: limit);
  final secure = SecureSocket.secure(raw, host: url.host);
  try {
    return await secure.timeout(limit);
  } catch (_) {
    // If the handshake still ends later, its socket is closed and its error
    // caught; if it never ends, the socket stays open (the known limit).
    unawaited(secure.then((socket) => socket.destroy(),
        onError: (Object _) {}));
    try {
      raw.destroy();
    } catch (_) {
      // Taken over by the handshake: closed only if the handshake still
      // ends (above); see the known limit in the doc comment.
    }
    rethrow;
  }
}

/// Whether [address] is in the own network or the phone itself: loopback,
/// private, link-local, carrier-grade NAT, unspecified and multicast
/// ranges, also as IPv4 inside IPv6.
bool isOwnNetwork(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && b.length == 4) {
    return _ownIpv4(b);
  }
  if (address.type != InternetAddressType.IPv6 || b.length != 16) return true;
  // ::ffff:a.b.c.d (IPv4-mapped) and ::a.b.c.d (IPv4-compatible).
  final zeros = b.sublist(0, 10).every((x) => x == 0);
  if (zeros && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0))) {
    final v4 = b.sublist(12);
    // :: and ::1.
    if (b[10] == 0 && v4.sublist(0, 3).every((x) => x == 0) && v4[3] <= 1) {
      return true;
    }
    return _ownIpv4(v4);
  }
  return (b[0] & 0xfe) == 0xfc || // fc00::/7, unique local
      (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || // fe80::/10, link-local
      (b[0] == 0xfe && (b[1] & 0xc0) == 0xc0) || // fec0::/10, old site-local
      b[0] == 0xff; // multicast
}

bool _ownIpv4(List<int> b) =>
    b[0] == 0 || // 0/8, "this network"
    b[0] == 10 || // 10/8
    b[0] == 127 || // 127/8, loopback
    (b[0] == 100 && (b[1] & 0xc0) == 64) || // 100.64/10, carrier-grade NAT
    (b[0] == 169 && b[1] == 254) || // 169.254/16, link-local
    (b[0] == 172 && (b[1] & 0xf0) == 16) || // 172.16/12
    (b[0] == 192 && b[1] == 168) || // 192.168/16
    b[0] >= 224; // multicast and reserved

/// A page the app does not fetch, or could not; the model gets the
/// message.
class WebPageError implements Exception {
  const WebPageError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The readable text of the page at [url], for the model: at most
/// [maxPageText] characters, with a line that says when it was cut.
/// Throws [WebPageError] in plain words.
Future<String> fetchWebPage(String url,
    {HostResolver resolve = lookupWithDartIo,
    PageGet get = getWithPinnedAddress}) async {
  try {
    return await _fetch(url, resolve, get).timeout(pageTimeLimit);
  } on TimeoutException {
    throw WebPageError('The page did not load within '
        '${pageTimeLimit.inSeconds} seconds.');
  } on SocketException catch (e) {
    throw WebPageError('No connection: ${e.message}.');
  } on HandshakeException catch (e) {
    throw WebPageError('No secure connection: ${e.message}.');
  } on HttpException catch (e) {
    throw WebPageError('The connection failed: ${e.message}.');
  }
}

Future<String> _fetch(String url, HostResolver resolve, PageGet get) async {
  var uri = Uri.tryParse(url.trim());
  for (var redirects = 0;; redirects++) {
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw WebPageError('"$url" is not a full web address.');
    }
    if (uri.scheme != 'https') {
      throw WebPageError('Only https:// addresses are fetched, not '
          '${uri.scheme}:.');
    }
    final address = await _checkedAddress(uri.host, resolve);
    final reply = await get(uri.removeFragment(), address);
    if (reply.status >= 300 && reply.status < 400) {
      final location = reply.location;
      if (location == null) {
        throw WebPageError('The server answered with a redirect (HTTP '
            '${reply.status}) without an address.');
      }
      if (redirects >= maxRedirects) {
        throw const WebPageError('Too many redirects.');
      }
      final next = Uri.tryParse(location);
      uri = next == null ? null : uri.resolveUri(next);
      continue;
    }
    if (reply.status != 200) {
      throw WebPageError('The server answered with HTTP ${reply.status}.');
    }
    return _readable(uri.toString(), reply);
  }
}

/// The address to connect to for [host]: refused when it, or any address
/// the name stands for, is in the own network.
Future<InternetAddress> _checkedAddress(
    String host, HostResolver resolve) async {
  final name = host.toLowerCase();
  if (name == 'localhost' || name.endsWith('.localhost')) {
    throw const WebPageError('Addresses on the phone itself are not '
        'fetched.');
  }
  final literal = InternetAddress.tryParse(
      name.startsWith('[') && name.endsWith(']')
          ? name.substring(1, name.length - 1)
          : name);
  final addresses = literal != null ? [literal] : await resolve(name);
  if (addresses.isEmpty) throw WebPageError('$host was not found.');
  if (addresses.any(isOwnNetwork)) {
    throw WebPageError('$host is in the own network or on the phone '
        'itself; such addresses are not fetched.');
  }
  return addresses.first;
}

String _readable(String url, PageReply reply) {
  final type = (reply.contentType ?? 'text/html').toLowerCase();
  final mime = type.split(';').first.trim();
  final html = mime == 'text/html' || mime == 'application/xhtml+xml';
  final text = html ||
      mime.startsWith('text/') ||
      mime == 'application/json' ||
      mime == 'application/xml' ||
      mime.endsWith('+json') ||
      mime.endsWith('+xml');
  if (!text) {
    throw WebPageError('The page is $mime, not text; it is not read.');
  }
  final charset =
      RegExp(r'charset="?([\w-]+)').firstMatch(type)?.group(1) ?? 'utf-8';
  final decoded = (charset == 'iso-8859-1' || charset == 'latin1' ||
          charset == 'windows-1252')
      ? latin1.decode(reply.body)
      : utf8.decode(reply.body, allowMalformed: true);
  var body = html ? htmlToText(decoded) : decoded.trim();
  final cut = body.length > maxPageText ||
      reply.body.length >= maxPageBytes;
  if (body.length > maxPageText) body = body.substring(0, maxPageText);
  return [
    'Page $url:',
    '',
    body,
    if (cut) '\n(The page was cut here: the app returns at most '
        '$maxPageText characters of a page.)',
  ].join('\n');
}

const _entities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
  'ndash': '–', 'mdash': '—', 'hellip': '…', 'copy': '©', 'reg': '®',
  'laquo': '«', 'raquo': '»', 'lsquo': '‘', 'rsquo': '’', 'ldquo': '“',
  'rdquo': '”', 'euro': '€', 'auml': 'ä', 'ouml': 'ö', 'uuml': 'ü',
  'Auml': 'Ä', 'Ouml': 'Ö', 'Uuml': 'Ü', 'szlig': 'ß', 'eacute': 'é',
  'egrave': 'è', 'agrave': 'à', 'ccedil': 'ç', 'deg': '°', 'middot': '·',
};

/// The readable text of an HTML page: without scripts, styles, comments
/// and markup; blocks on lines of their own; entities decoded.
String htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(
          RegExp(r'<(script|style|noscript|template|svg|head|iframe|object)\b'
              r'.*?</\1\s*>',
              caseSensitive: false, dotAll: true),
          ' ');
  // The title, from the head that was just removed.
  final title = RegExp(r'<title\b[^>]*>(.*?)</title\s*>',
          caseSensitive: false, dotAll: true)
      .firstMatch(html)
      ?.group(1);
  s = s
      .replaceAll(
          RegExp(r'<(br|hr)\b[^>]*>', caseSensitive: false), '\n')
      .replaceAll(
          RegExp(r'</?(p|div|section|article|header|footer|main|nav|aside|'
              r'h[1-6]|ul|ol|li|dl|dt|dd|table|tr|blockquote|pre|figure|'
              r'figcaption|form)\b[^>]*>',
              caseSensitive: false),
          '\n')
      .replaceAll(RegExp(r'</t[dh]\s*>', caseSensitive: false), '\t')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  s = decodeEntities(s);
  final lines = [
    for (final line in s.split('\n'))
      if (line.replaceAll(RegExp(r'\s+'), ' ').trim() case final l
          when l.isNotEmpty)
        l,
  ];
  final head = title == null
      ? null
      : decodeEntities(title.replaceAll(RegExp(r'<[^>]*>'), ''))
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
  return [
    if (head != null && head.isNotEmpty) 'Title: $head',
    ...lines,
  ].join('\n');
}

/// [text] with HTML entities (named, decimal, hexadecimal) decoded.
String decodeEntities(String text) => text.replaceAllMapped(
      RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);'),
      (m) {
        final name = m.group(1)!;
        if (name.startsWith('#')) {
          final code = name[1] == 'x' || name[1] == 'X'
              ? int.tryParse(name.substring(2), radix: 16)
              : int.tryParse(name.substring(1));
          if (code == null || code <= 0 || code > 0x10ffff) return m.group(0)!;
          return String.fromCharCode(code);
        }
        return _entities[name] ?? m.group(0)!;
      },
    );

/// The search tool of the app (#233): it asks the Brave Search API with
/// the user's own key, for every provider. It is called `web_search`, like
/// Anthropic's built-in tool, and the two are never offered together (see
/// [makeWebAccess]).
const braveSearchTool = AiTool(
  'web_search',
  'Search the web and return the best results: for each its title, '
      'address and a short description. Then read the pages you want with '
      'fetch_web_page. Each search counts as one of the web searches '
      'allowed for one message. The search words go to Brave Search.',
  {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'The search words.',
      },
      'count': {
        'type': 'integer',
        'description': 'How many results, 1 to 10. Default 5.',
      },
      'freshness': {
        'type': 'string',
        'enum': ['pd', 'pw', 'pm', 'py'],
        'description': 'Only pages from the last day (pd), week (pw), '
            'month (pm) or year (py). Optional.',
      },
      'country': {
        'type': 'string',
        'description': 'A two-letter country code such as DE or US, to '
            'prefer results from there. Optional.',
      },
      'search_lang': {
        'type': 'string',
        'description': 'The language of the results as a code such as en '
            'or de. Optional.',
      },
    },
    'required': ['query'],
  },
);

/// The Brave Search API's address.
final braveSearchUrl = Uri.https('api.search.brave.com', '/res/v1/web/search');

/// The most results one search returns to the model.
const maxSearchResults = 10;

/// The results returned when the model gives no `count`.
const defaultSearchResults = 5;

/// The time one search may take.
const searchTimeLimit = Duration(seconds: 20);

/// The most bytes read of a search answer.
const maxSearchBytes = 1024 * 1024;

/// What the Brave Search API answered.
class SearchReply {
  const SearchReply(this.status, this.body);

  final int status;
  final String body;
}

/// Sends the search [url] with [headers]; tests replace it.
typedef SearchGet = Future<SearchReply> Function(
    Uri url, Map<String, String> headers);

/// [SearchGet] with `dart:io`: no cookies, a time and a size limit.
Future<SearchReply> getSearchWithDartIo(
    Uri url, Map<String, String> headers) async {
  final client = HttpClient()
    ..connectionTimeout = searchTimeLimit
    ..userAgent = 'RoamGraph';
  try {
    final request = await client.getUrl(url).timeout(searchTimeLimit);
    // A redirect must not carry the key to another address.
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(searchTimeLimit);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(searchTimeLimit)) {
      bytes.add(chunk);
      if (bytes.length >= maxSearchBytes) break;
    }
    return SearchReply(
        response.statusCode, utf8.decode(bytes.takeBytes(), allowMalformed: true));
  } finally {
    client.close(force: true);
  }
}

/// The search for the model (#233): asks Brave for [input]'s `query` with
/// [key], and returns the results as numbered text, at most
/// [maxSearchResults]. Throws [WebPageError] in plain words when the key
/// is not accepted, a limit is reached, the network fails or the answer is
/// not understood; the message never contains the key.
Future<String> braveSearch(Map<String, Object?> input,
    {required String key, SearchGet get = getSearchWithDartIo}) async {
  final query = input['query'];
  if (query is! String || query.trim().isEmpty) {
    throw const WebPageError('query is missing.');
  }
  final asked = input['count'];
  final count = (asked is num ? asked.toInt() : defaultSearchResults)
      .clamp(1, maxSearchResults)
      .toInt();
  final freshness = input['freshness'];
  final country = input['country'];
  final lang = input['search_lang'];
  final url = braveSearchUrl.replace(queryParameters: {
    'q': query.trim(),
    'count': '$count',
    if (freshness is String && const {'pd', 'pw', 'pm', 'py'}.contains(freshness))
      'freshness': freshness,
    if (country is String && RegExp(r'^[A-Za-z]{2}$').hasMatch(country.trim()))
      'country': country.trim().toUpperCase(),
    if (lang is String &&
        RegExp(r'^[A-Za-z]{2}(-[A-Za-z]{2,4})?$').hasMatch(lang.trim()))
      'search_lang': lang.trim().toLowerCase(),
  });
  final SearchReply reply;
  try {
    reply = await get(url, {
      'X-Subscription-Token': key,
      'Accept': 'application/json',
    }).timeout(searchTimeLimit);
  } on TimeoutException {
    throw WebPageError('The search did not answer within '
        '${searchTimeLimit.inSeconds} seconds.');
  } on SocketException catch (e) {
    throw WebPageError('No connection to Brave Search: ${e.message}.');
  } on HandshakeException catch (e) {
    throw WebPageError('No secure connection to Brave Search: '
        '${e.message}.');
  } on HttpException catch (e) {
    throw WebPageError('The connection to Brave Search failed: '
        '${e.message}.');
  }
  switch (reply.status) {
    case 200:
      break;
    case 401 || 403:
      throw WebPageError('Brave Search did not accept the key (HTTP '
          '${reply.status}). The key may be wrong or expired. Answer '
          'without a web search.');
    case 429:
      throw const WebPageError('Brave Search refused the search: the rate '
          'or quota limit is reached (HTTP 429). Answer without a web '
          'search, or try again later.');
    default:
      throw WebPageError('Brave Search answered with HTTP ${reply.status}. '
          'Answer without a web search.');
  }
  return _searchText(query.trim(), reply.body, count);
}

String _plain(Object? value) => decodeEntities(
        '${value ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), ''))
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _searchText(String query, String body, int count) {
  Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    throw const WebPageError('Brave Search gave an answer the app cannot '
        'read.');
  }
  final web = json is Map ? json['web'] : null;
  final results = web is Map ? web['results'] : null;
  if (results is! List || results.whereType<Map>().isEmpty) {
    return 'No results for "$query".';
  }
  final lines = <String>['Results for "$query":'];
  var number = 0;
  for (final result in results.whereType<Map>().take(count)) {
    number++;
    final title = _plain(result['title']);
    final description = _plain(result['description']);
    lines
      ..add('')
      ..add('$number. ${title.isEmpty ? '(no title)' : title}')
      ..add('   ${result['url'] ?? ''}');
    if (description.isNotEmpty) lines.add('   $description');
  }
  return lines.join('\n');
}

/// What the chat may do on the web for one chat (#137): read pages with
/// [fetchWebPageTool], and search, either with the provider's built-in
/// tool ([search]) or with the app's own [braveSearchTool] ([searchBrave]);
/// together at most [limit] times for one message.
class WebAccess {
  const WebAccess({
    required this.limit,
    this.search = false,
    this.fetch = fetchWebPage,
    this.searchBrave,
  });

  /// "Most web searches for one message".
  final int limit;

  /// Whether the provider's built-in web search is offered (Anthropic).
  final bool search;

  final Future<String> Function(String url) fetch;

  /// The app's own search with Brave (#233), or null when it is not
  /// offered. Never set together with [search]: both tools are called
  /// `web_search`.
  final Future<String> Function(Map<String, Object?> input)? searchBrave;

  /// Whether the model can search at all.
  bool get canSearch => search || searchBrave != null;
}

/// "Search with" (#233) in the settings: [anthropicSearch] or [braveSearch].
const anthropicSearch = 'anthropic';
const braveSearchChoice = 'brave';

/// The web access of one chat (#233). Where the provider has its own
/// search ([providerSearch]) and the settings choose it, that is offered;
/// otherwise, with a Brave [braveKey], the app's own search. Never both,
/// because both tools are called `web_search`. With Brave chosen but no
/// key, Anthropic's search stays, so the chat does not lose it.
WebAccess makeWebAccess({
  required int limit,
  required bool providerSearch,
  required String searchWith,
  required String braveKey,
  SearchGet get = getSearchWithDartIo,
}) {
  final key = braveKey.trim();
  final brave = key.isNotEmpty &&
      (!providerSearch || searchWith == braveSearchChoice);
  return WebAccess(
    limit: limit,
    search: providerSearch && !brave,
    searchBrave: brave
        ? (input) => braveSearch(input, key: key, get: get)
        : null,
  );
}

/// What the system prompt says with web access on.
String webAccessPrompt({required bool search}) =>
    '${search ? 'You can search the web with web_search and read pages '
        'with fetch_web_page. ' : 'You can read web pages with '
        'fetch_web_page. '}'
    'If the user gives a web address, read it with fetch_web_page; never '
    'say you have no web access when you have these tools. '
    'Name the sources of what you found on the web, as links. When you '
    'write or change a note with facts from the web, put the sources in it '
    'as Org links: [[<URL>][<title>]].';
