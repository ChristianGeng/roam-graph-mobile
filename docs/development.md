# Development

Tools for developers, which a user of the app does not need. How to build
the app is in the [README](../README.md#build-locally); how releases are
made is in [releases.md](releases.md).

The commands below need Flutter (for Dart), Python 3 and
[uv](https://docs.astral.sh/uv/), and run from the repository's root.
`<org-roam.db>` is the database Emacs keeps (the file
`org-roam-db-location` names), and `<notes folder>` is the folder
org-roam indexes (`org-roam-directory`). Emacs's database is opened
read-only, and nothing leaves the machine.

## Check the parser against org-roam

The app builds the graph from the org files itself. To compare it with the
`org-roam.db` Emacs keeps:

```
uv run tool/org_roam_parity.py check <org-roam.db> <notes folder>
```

It prints the counts of files, nodes, `id:` links, tags, aliases and refs on
both sides, and every difference; for a link, also the file and line where
only one side finds it, with the lines around it. The exit code is 0 when
there are no differences.

CI runs the same comparison on the sample files in `test/fixtures/roam/`,
against a database real org-roam built from them
(`tool/org_roam_parity/build-fixture-expectations.sh`).

## Check the database against org-roam

The app keeps the graph in an SQLite database with org-roam's tables and
encoding. To build the same database and compare every table with Emacs's,
first run `M-x org-roam-db-sync` in Emacs, so its database is current, then:

```
flutter pub get
uv run tool/org_roam_parity.py check-db <org-roam.db> <notes folder>
```

## Build the app's database

To get the database itself, for example to run the org-roam MCP server's
queries on it:

```
dart run tool/build_roam_db.dart <notes folder> /tmp/app-org-roam.db
```

Point the MCP server's database path at `/tmp/app-org-roam.db`; its
read-only queries should return the same results as on `org-roam.db`.
Running the command again reads only new and changed files.

The script `tool/org_roam_parity.py` lists its other commands (`export`,
`compare`, `export-tables`, `compare-tables`) in its first lines.
