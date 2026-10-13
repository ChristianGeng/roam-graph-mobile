;;; build-db.el --- Build an org-roam.db from a folder, for the parity test -*- lexical-binding: t -*-

;; Usage:
;;   emacs --batch -l build-db.el DEPS-DIR ROAM-DIR DB-FILE
;;
;; DEPS-DIR holds checkouts of org-roam and its dependencies (see
;; build-fixture-expectations.sh). Org is Emacs's own. The settings mirror
;; what matters on the laptop: Doom Emacs's TODO keywords, which decide
;; where a heading's title starts.

(let* ((args command-line-args-left)
       (deps (expand-file-name (nth 0 args)))
       (roam (expand-file-name (nth 1 args)))
       (db (expand-file-name (nth 2 args))))
  (setq command-line-args-left nil)
  (dolist (dir '("compat" "dash.el" "llama" "cond-let" "emacsql" "magit/lisp" "org-roam"))
    (add-to-list 'load-path (expand-file-name dir deps)))
  (require 'org)
  ;; Doom Emacs's default `org-todo-keywords' (modules/lang/org/config.el).
  (setq org-todo-keywords
        '((sequence "TODO(t)" "PROJ(p)" "LOOP(r)" "STRT(s)" "WAIT(w)" "HOLD(h)"
                    "IDEA(i)" "|" "DONE(d)" "KILL(k)")
          (sequence "[ ](T)" "[-](S)" "[?](W)" "|" "[X](D)")
          (sequence "|" "OKAY(o)" "YES(y)" "NO(n)")))
  (require 'org-roam)
  (setq org-roam-directory roam
        org-roam-db-location db)
  (org-roam-db-sync 'force)
  (message "org %s; link types: %s"
           (org-version)
           (mapconcat #'car org-link-parameters " ")))
