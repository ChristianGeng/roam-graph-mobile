#!/usr/bin/env bash
# Fetches org-roam and its dependencies, pinned, into DIR: the versions
# the parity test (build-fixture-expectations.sh) and the Emacs tests
# (emacs/run-tests.sh) run with.
#
# Usage: tool/org_roam_parity/fetch-deps.sh DIR
set -euo pipefail

work=${1:?usage: fetch-deps.sh DIR}
mkdir -p "$work"

fetch() { # repository, commit, folder
  git -C "$work" init -q "$3"
  git -C "$work/$3" fetch -q --depth 1 "https://github.com/$1" "$2"
  git -C "$work/$3" checkout -q FETCH_HEAD
}
fetch org-roam/org-roam 903bd4ec56d29247990d005ed9052c201e18b812 org-roam
fetch magit/emacsql 7a4c607912c8fdd1fca4def4915d68f43b12d4da emacsql
fetch magnars/dash.el d746dd9edcb67a108818beb0cdc78dc1cb466832 dash.el
fetch magit/magit be42a74513f15221dc364aa668822e05890e3a2f magit
fetch emacs-compat/compat 90880f81419577e1d3f68424d2a3adf31e6d663e compat
fetch tarsius/llama 6850d0c91b629da14fdff2300c222289d1a0029a llama
fetch tarsius/cond-let 09292a77001434f59ab55c775dec2b98cb18d028 cond-let
