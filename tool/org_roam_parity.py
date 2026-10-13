#!/usr/bin/env python3
"""Compare the app's org-roam parser with org-roam's own database.

The app builds the graph from the org files itself (#4). This script checks
that it finds the same nodes, id: links, tags, aliases and refs as org-roam.
It needs only Python 3; `check` also needs Dart (Flutter) to run the parser.

Commands:

  check DB ROAM_DIR
      Read org-roam.db, run the app's parser on ROAM_DIR
      (`dart run tool/roam_graph_dump.dart ROAM_DIR`), and print the
      differences. Exit code 0 if there are none, 1 otherwise.

  export DB ROAM_DIR
      Print the database's content for the files under ROAM_DIR as
      normalized JSON (the format roam_graph_dump.dart prints).

  compare EXPECTED.json ACTUAL.json
      Compare two normalized JSON files.

Example, on the laptop:

  python3 tool/org_roam_parity.py check \\
      ~/doom-emacs/.local/cache/org-roam.db ~/work/cgeng/org/roam

The database is opened read-only. Nothing is written anywhere, and nothing
from the notes leaves the machine.
"""

import collections
import json
import os
import re
import sqlite3
import subprocess
import sys

CATEGORIES = ("files", "nodes", "links", "tags", "aliases", "refs")
MAX_SHOWN = 20

_LISP_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"', re.S)


def lisp_string(value):
    """Decode a value org-roam stored as an Emacs Lisp string.

    org-roam stores strings printed by Emacs, quotes included: an ID is
    "abc", not abc. A string with text properties is printed as
    #("abc" 0 3 (...)); the string is its first literal.
    """
    if not isinstance(value, str):
        return value
    match = _LISP_STRING.search(value)
    if not match:
        return value
    return re.sub(r"\\(.)", r"\1", match.group(1), flags=re.S)


def export(db_path, roam_dir):
    """The normalized content of DB for the files under ROAM_DIR."""
    roam = os.path.realpath(os.path.expanduser(roam_dir))
    uri = "file:%s?mode=ro" % os.path.abspath(os.path.expanduser(db_path))
    con = sqlite3.connect(uri, uri=True)
    try:
        def relative(lisp_path):
            path = os.path.realpath(lisp_string(lisp_path))
            if path == roam or not path.startswith(roam + os.sep):
                return None
            return os.path.relpath(path, roam).replace(os.sep, "/")

        files = sorted(
            r for r in (relative(row[0]) for row in con.execute("SELECT file FROM files"))
            if r is not None
        )

        node_file = {}
        nodes = []
        for node_id, file, level, title in con.execute(
            "SELECT id, file, level, title FROM nodes"
        ):
            rel = relative(file)
            if rel is None:
                continue
            node_id = lisp_string(node_id)
            node_file[node_id] = rel
            nodes.append([node_id, rel, level, lisp_string(title) or ""])

        def rows(sql):
            for row in con.execute(sql):
                values = [lisp_string(v) for v in row]
                if values[0] in node_file:
                    yield values

        links = list(rows(
            "SELECT source, dest FROM links WHERE type = '\"id\"'"
        ))
        tags = list(rows("SELECT node_id, tag FROM tags"))
        aliases = list(rows("SELECT node_id, alias FROM aliases"))
        refs = list(rows("SELECT node_id, ref, type FROM refs"))
    finally:
        con.close()

    return {
        "files": files,
        "nodes": sorted(nodes),
        "links": sorted(links),
        "tags": sorted(tags),
        "aliases": sorted(aliases),
        "refs": sorted(refs),
    }


def run_parser(roam_dir):
    """Run the app's parser on ROAM_DIR and return its normalized JSON."""
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    result = subprocess.run(
        ["dart", "run", "tool/roam_graph_dump.dart", os.path.expanduser(roam_dir)],
        cwd=repo,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return json.loads(result.stdout)


def _key(category, row):
    # Nodes are matched by ID, so a changed title or level shows as a
    # difference of that node rather than as one missing and one extra.
    return row[0] if category == "nodes" else tuple(row) if isinstance(row, list) else row


def compare(expected, actual, out=sys.stdout):
    """Print the differences. Returns True if there are none."""
    same = True
    out.write("%-8s %10s %10s\n" % ("", "org-roam", "app"))
    for category in CATEGORIES:
        exp = expected.get(category, [])
        act = actual.get(category, [])
        out.write("%-8s %10d %10d\n" % (category, len(exp), len(act)))

    for category in CATEGORIES:
        exp = expected.get(category, [])
        act = actual.get(category, [])
        if category == "nodes":
            exp_by_id = {row[0]: row for row in exp}
            act_by_id = {row[0]: row for row in act}
            missing = [exp_by_id[k] for k in sorted(exp_by_id.keys() - act_by_id.keys())]
            extra = [act_by_id[k] for k in sorted(act_by_id.keys() - exp_by_id.keys())]
            changed = [
                (exp_by_id[k], act_by_id[k])
                for k in sorted(exp_by_id.keys() & act_by_id.keys())
                if list(exp_by_id[k]) != list(act_by_id[k])
            ]
        else:
            exp_count = collections.Counter(_key(category, r) for r in exp)
            act_count = collections.Counter(_key(category, r) for r in act)
            missing = sorted((exp_count - act_count).elements())
            extra = sorted((act_count - exp_count).elements())
            changed = []

        if missing or extra or changed:
            same = False
            out.write("\n%s:\n" % category)
            for label, items in (("only in org-roam", missing), ("only in the app", extra)):
                if items:
                    out.write("  %s (%d):\n" % (label, len(items)))
                    for item in items[:MAX_SHOWN]:
                        out.write("    %s\n" % (json.dumps(item, ensure_ascii=False),))
                    if len(items) > MAX_SHOWN:
                        out.write("    ... %d more\n" % (len(items) - MAX_SHOWN))
            if changed:
                out.write("  different (%d), org-roam then app:\n" % len(changed))
                for exp_row, act_row in changed[:MAX_SHOWN]:
                    out.write("    %s\n    %s\n" % (
                        json.dumps(exp_row, ensure_ascii=False),
                        json.dumps(act_row, ensure_ascii=False),
                    ))
                if len(changed) > MAX_SHOWN:
                    out.write("    ... %d more\n" % (len(changed) - MAX_SHOWN))

    out.write("\n%s\n" % ("No differences." if same else "Differences found."))
    return same


def main(argv):
    if len(argv) == 4 and argv[1] == "check":
        same = compare(export(argv[2], argv[3]), run_parser(argv[3]))
        return 0 if same else 1
    if len(argv) == 4 and argv[1] == "export":
        json.dump(export(argv[2], argv[3]), sys.stdout, ensure_ascii=False, indent=1)
        sys.stdout.write("\n")
        return 0
    if len(argv) == 4 and argv[1] == "compare":
        with open(argv[2], encoding="utf-8") as f:
            expected = json.load(f)
        with open(argv[3], encoding="utf-8") as f:
            actual = json.load(f)
        return 0 if compare(expected, actual) else 1
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
