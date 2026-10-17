/// The difference between two texts, line by line (#38), as `diff -u`
/// shows it: removed and added lines with a few lines of context.
library;

enum DiffKind { same, removed, added }

/// One line of a diff. [oldLine] and [newLine] are 1-based line numbers in
/// the old and new text; null where the line is not in that text.
class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldLine, this.newLine});

  final DiffKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;

  @override
  String toString() =>
      '${switch (kind) { DiffKind.same => ' ', DiffKind.removed => '-', DiffKind.added => '+' }}$text';
}

/// A run of changes with its context, as a hunk of `diff -u`.
class DiffHunk {
  const DiffHunk(this.lines);

  final List<DiffLine> lines;

  /// The first line of the hunk in the old text, 1-based.
  int get oldStart =>
      lines.firstWhere((l) => l.oldLine != null,
              orElse: () => const DiffLine(DiffKind.same, '', oldLine: 0))
          .oldLine!;

  /// The first line of the hunk in the new text, 1-based.
  int get newStart =>
      lines.firstWhere((l) => l.newLine != null,
              orElse: () => const DiffLine(DiffKind.same, '', newLine: 0))
          .newLine!;
}

List<String> _lines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split(RegExp(r'\r?\n'));
  // A final newline ends the last line; it starts no new one.
  if (lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// The most edits [diffLines] looks for. Beyond it, the texts share too
/// little for a line-by-line view to help, and the search would need too
/// much memory on a phone.
const maxDiffEdits = 2000;

/// Every line of [before] and [after], marked same, removed or added, in
/// order: the shortest edit script, found with Myers' algorithm, which
/// `diff` also uses. Removed lines come before the added lines that
/// replace them. Null if more than [maxEdits] lines are removed and added
/// in all.
List<DiffLine>? diffLines(String before, String after,
    {int maxEdits = maxDiffEdits}) {
  final a = _lines(before), b = _lines(after);
  final n = a.length, m = b.length;
  final max = n + m;
  final offset = max + 1;
  final v = List<int>.filled(2 * max + 3, 0);
  // For each step d, the part of v that step reads: k from -d to d. So the
  // trace grows with d², not with d times the length of the texts.
  final trace = <List<int>>[];
  var found = false;
  for (var d = 0; d <= max && !found; d++) {
    if (d > maxEdits) return null;
    trace.add(v.sublist(offset - d, offset + d + 1));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        found = true;
        break;
      }
    }
  }
  // Walk the trace back from the end, collecting the script in reverse.
  final script = <DiffLine>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d >= 0; d--) {
    final vd = trace[d];
    int at(int k) => vd[k + d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && at(k - 1) < at(k + 1))) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = d == 0 ? 0 : at(prevK);
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      script.add(DiffLine(DiffKind.same, a[x - 1], oldLine: x, newLine: y));
      x--;
      y--;
    }
    if (d == 0) break;
    if (x == prevX) {
      script.add(DiffLine(DiffKind.added, b[y - 1], newLine: y));
      y--;
    } else {
      script.add(DiffLine(DiffKind.removed, a[x - 1], oldLine: x));
      x--;
    }
  }
  final lines = script.reversed.toList();
  // Within each run of changes, removed lines first, as diff shows them.
  final ordered = <DiffLine>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind == DiffKind.same) {
      ordered.add(lines[i++]);
      continue;
    }
    final run = <DiffLine>[];
    while (i < lines.length && lines[i].kind != DiffKind.same) {
      run.add(lines[i++]);
    }
    ordered
      ..addAll(run.where((l) => l.kind == DiffKind.removed))
      ..addAll(run.where((l) => l.kind == DiffKind.added));
  }
  return ordered;
}

/// The changes between [before] and [after], each with up to [context]
/// unchanged lines around it; changes closer than twice that share a
/// hunk, as in `diff -u`. Empty if the texts have the same lines; null if
/// they differ too much (see [diffLines]).
List<DiffHunk>? diffHunks(String before, String after, {int context = 3}) {
  final lines = diffLines(before, after);
  return lines == null ? null : hunksOf(lines, context: context);
}

/// The hunks of [lines], the result of [diffLines].
List<DiffHunk> hunksOf(List<DiffLine> lines, {int context = 3}) {
  final changed = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].kind != DiffKind.same) i,
  ];
  if (changed.isEmpty) return const [];
  final hunks = <DiffHunk>[];
  var start = (changed.first - context).clamp(0, lines.length);
  var end = (changed.first + context + 1).clamp(0, lines.length);
  for (final i in changed.skip(1)) {
    if (i - context <= end) {
      end = (i + context + 1).clamp(0, lines.length);
    } else {
      hunks.add(DiffHunk(lines.sublist(start, end)));
      start = (i - context).clamp(0, lines.length);
      end = (i + context + 1).clamp(0, lines.length);
    }
  }
  hunks.add(DiffHunk(lines.sublist(start, end)));
  return hunks;
}
