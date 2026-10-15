;;; slugs.el --- What org-roam makes of titles in file names (#11) -*- lexical-binding: t -*-

;; Usage:
;;   emacs --batch -l slugs.el DEPS-DIR > test/fixtures/org_roam_slugs.json
;;
;; DEPS-DIR holds org-roam and its dependencies, as for build-db.el; Doom
;; Emacs's straight build folder works too. Prints a JSON object from
;; title to `org-roam-node-slugify' of it, which names new files
;; (`<%Y%m%d%H%M%S>-<slug>.org'); the app must name them the same.

(let ((deps (expand-file-name (car command-line-args-left))))
  (setq command-line-args-left nil)
  (dolist (dir '("compat" "dash" "dash.el" "llama" "cond-let" "emacsql"
                 "magit-section" "magit/lisp" "org-roam"))
    (add-to-list 'load-path (expand-file-name dir deps)))
  (require 'org-roam-node)
  (require 'json)
  (let ((titles
         '("Attention" "Hello, World!" "Über Ärger" "Crème brûlée"
           "naïve café" "日本語のノート" "C++ & Rust"
           "  leading and trailing  " "Ångström" "Señor Ñandú" "Đorđe"
           "Straße" "x² + y²" "é decomposed" "Kotlin/Java"
           "TODO: fix #42" "emoji 🙂 note" "a__b" "İstanbul" "Œuvre"
           "ﬁ ligature" "１２３ fullwidth" "Ǆ digraph" "ÆØÅ" "Ελληνικά"
           "Привет мир" "Tiếng Việt" "half½" "---" "")))
    (princ (json-encode
            (mapcar (lambda (title) (cons title (org-roam-node-slugify title)))
                    titles)))
    (terpri)))
