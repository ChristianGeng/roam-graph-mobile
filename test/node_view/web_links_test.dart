import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/node_view/web_links.dart';

void main() {
  test('web, mail and phone links open outside the app (#108)', () {
    String? target(String location) => externalLinkTarget(location)?.toString();
    expect(target('https://example.com/a?b=c#d'), 'https://example.com/a?b=c#d');
    expect(target('HTTP://example.com'), 'http://example.com');
    expect(target('mailto:a@example.org'), 'mailto:a@example.org');
    expect(target('tel:+4930123'), 'tel:+4930123');
    // As Org opens doi: links.
    expect(target('doi:10.1000/182'), 'https://doi.org/10.1000/182');
    for (final kept in [
      'id:abc',
      'file:img/a.png',
      './img/a.png',
      '*Heading',
      'ftp://x.org/f',
      'javascript:alert(1)',
      'intent://x#Intent;end',
      'https://',
      'https:///path',
      'mailto:',
      'tel:',
      'doi:',
      '',
    ]) {
      expect(target(kept), isNull, reason: kept);
    }
  });
}
