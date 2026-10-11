# AGENTS.md

Instructions for AI coding assistants working in this repository.

## The project

An Android app for my tablet and my phone that browses my org-roam knowledge
graph offline, without Emacs. It reads the org files that Syncthing copies to
the device, builds the graph itself, shows it with graph-algorithm views,
renders nodes, and opens them in Orgro. From v2 it also creates new nodes.
The laptop keeps using Emacs and org-roam on the same files; the Syncthing
folder is the only connection.

## Read first

1. `docs/decisions.md`: what is decided, why, and what is open. Do not
   propose an approach that contradicts a decision there without saying so
   and giving a reason.
2. The GitHub issues and milestones: v1 browse (read-only), v2 capture,
   v3 MCP (only a decision so far). The issue numbers follow the build order.

## How we work

- **Spec before code.** The next step is to decide the stack (#1), then
  write the spec to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`,
  then an implementation plan. No product code before the spec is approved.
- **Never put my real notes in the repo.** It is public. Tests use synthetic
  org files under the test directory. Comparisons with my real data are
  local scripts that read the files and the laptop `org-roam.db` from my
  disk and print differences.
- **The APK comes from GitHub Actions.** Releases carry the signed APK; the
  signing key is a repository secret, never a file in the repo.
- **Match org-roam exactly** where the app imitates it: which files are
  nodes, how titles, tags, aliases, refs and links are read, how values are
  stored (Emacs Lisp quoted strings), and how new files are named. When
  unsure, read org-roam's source rather than guessing.
- Plain, literal English in docs, commit messages and issues: the reader's
  first language may not be English.
