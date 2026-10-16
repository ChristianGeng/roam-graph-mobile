import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_index.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';

void main() {
  test('the marker names the folder for the same parser', () {
    final marker = folderMarker('content://tree/org');
    expect(markedFolder(marker), 'content://tree/org');
  });

  test('an index from another parser is no index: it is rebuilt', () {
    // Before the parser version, the marker held the folder alone.
    expect(markedFolder('content://tree/org'), isNull);
    final plain = folderMarker(
        'content://tree/org', parserFingerprint(plainOrgRoamLinkTypes));
    expect(markedFolder(plain), isNull);
    expect(parserFingerprint(), contains('parser $parserVersion'));
  });
}
