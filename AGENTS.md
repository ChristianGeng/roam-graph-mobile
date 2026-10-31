# AGENTS.md

Instructions for AI coding assistants working in this repository.

## The project

An Android app for my tablet and my phone that browses my org-roam knowledge
graph offline, without Emacs. It reads the org files that Syncthing copies to
the device, builds the graph itself, shows it with graph-algorithm views,
renders nodes, and opens them in another app. From v2 it also creates new nodes.
The laptop keeps using Emacs and org-roam on the same files; the Syncthing
folder is the only connection.

## Read first

1. `docs/decisions.md`: what is decided, why, and what is open. Do not
   propose an approach that contradicts a decision there without saying so
   and giving a reason.
2. The GitHub issues and milestones: v1 browse (read-only), v2 capture,
   v3 MCP (only a decision so far). The issue numbers follow the build order.

## How we work

- **The issue is the spec.** Each change starts as a GitHub issue that
  says what to build, what stays as it is, and how it is tested; the owner
  agrees to it in the conversation. A pull request adds a decision entry
  to `docs/decisions.md` (numbered, before "## Recommended, not
  decided") that records what was decided and why. No separate spec or
  plan files.
- **Never put my real notes in the repo.** It is public. Tests use synthetic
  org files under the test directory. Comparisons with my real data are
  local scripts that read the files and the laptop `org-roam.db` from my
  disk and print differences.
- **The APK comes from GitHub Actions.** Releases carry the signed APK; the
  signing key is a repository secret, never a file in the repo.
- **Every pull request adds a CHANGELOG.md entry** at the top:
  `## YYYY-MM-DD: <short title> ([#PR](<PR URL>))`, then 1 to 4 lines on
  what changed for the user (Added / Changed / Fixed) and the issue it
  closes. No version number in a new entry: the release text adds it.
  (The entries written before the changelog existed name their release;
  they stay as they are.) CI fails a pull request that changes `lib/` or
  `android/` without a new entry heading; the label
  `skip-changelog` lets a change through that users do not see
  (decision 48).
- **Match org-roam exactly** where the app imitates it: which files are
  nodes, how titles, tags, aliases, refs and links are read, how values are
  stored (Emacs Lisp quoted strings), and how new files are named. When
  unsure, read org-roam's source rather than guessing.
- Plain, literal English in docs, commit messages and issues: the reader's
  first language may not be English.

## The flow of one change

1. **Plan:** the owner and Claude agree on the change; Claude writes the
   issue.
2. **Build:** Devin, in a new session for each issue, started with a
   prompt that names the issue and the rules of this file; or Claude,
   when the owner says so. One pull request per issue, with
   "Closes #<issue>". Devin does not merge.
3. **Review:** CI (Android build with all tests, Linux, Windows, macOS,
   changelog, org-roam) and the review bots (Gitar, Sourcery, Devin).
   Every finding is fixed or answered. Findings for Devin go to Devin as a
   pull request comment that starts with `@devin`; Devin answers such
   comments from users with write access.
4. **Merge:** with a merge commit, only when CI is green and every
   comment is dealt with. A merge to `main` builds an Android
   pre-release (the APK only, `v0.2.1-dev.<run>`), which Obtainium
   installs; the owner is told when it is out.
5. **Full release:** only when the owner asks. A manual run of the Build
   workflow on `main` with "release" checked builds all four platforms
   (APK, Linux, Windows, macOS) and publishes the next semantic version
   (`v0.3.0`), with the notes since the last full release. How to start
   it: `docs/releases.md`.

Things to know:

- **Flutter runs only in CI**, not in the cloud sessions: CI is the test
  run. Read a failure from the check run's annotations.
- **macOS runners are sometimes not available** on GitHub ("not acquired
  by Runner"); the job is then cancelled. Run that job again; a full
  release waits for it.
- **Open points are issues**, so a new session finds them; nothing is
  kept only in a conversation.

