;;; roam-graph-follow.el --- Let the Roam Graph desktop app follow Emacs -*- lexical-binding: t; -*-

;; URL: https://github.com/ChristianGeng/roam-graph-mobile
;; Package-Requires: ((emacs "27.1") (org-roam "2.2"))

;;; Commentary:

;; With `roam-graph-follow-mode' on, Emacs tells the Roam Graph desktop
;; app which org-roam node is at point, and the app shows that node in its
;; graph, as org-roam-ui's "follow" does (roam-graph-mobile #117).
;;
;; The node is the one `org-roam-id-at-point' gives: the nearest heading
;; at or above point that is an org-roam node, else the file node.  It is
;; sent when an org-roam file is visited (`org-roam-find-file-hook'), and
;; when Emacs has been idle for `roam-graph-follow-idle-delay' seconds
;; with another node at point than the one sent last.
;;
;; The app listens on 127.0.0.1 only.  It writes its port and a secret
;; token to `roam-graph-follow-file'; every message carries the token.  A
;; message is one line of JSON with the token and the ID; nothing else is
;; sent, and nothing is written.  Without the app, or without the file,
;; nothing is sent and no error is shown.
;;
;; The desktop app ships this file (#241): on Linux in
;; ~/.local/share/roam-graph/app/emacs/ (under $XDG_DATA_HOME if set), on
;; Windows in emacs\ next to the app, on macOS in the app's
;; Contents/Resources/emacs/.  Load it from there, so it matches the app;
;; Settings, "Copy Emacs snippet", gives the code.  On Linux:
;;
;;   (let ((dir (expand-file-name "roam-graph/app/emacs"
;;                                (or (getenv "XDG_DATA_HOME")
;;                                    "~/.local/share"))))
;;     (when (file-exists-p (expand-file-name "roam-graph-follow.el" dir))
;;       (add-to-list 'load-path dir)
;;       (with-eval-after-load 'org-roam
;;         (require 'roam-graph-follow)
;;         (roam-graph-follow-mode 1))))
;;
;; Load only one copy: with an older setup that loads this file from the
;; repository as well, whichever loads first wins.

;;; Code:

(require 'json)
(require 'subr-x)

(declare-function org-roam-id-at-point "org-roam-id")
(declare-function org-roam-file-p "org-roam")
(defvar org-roam-find-file-hook)

(defgroup roam-graph-follow nil
  "Let the Roam Graph desktop app follow the node at point."
  :group 'org-roam
  :prefix "roam-graph-follow-")

(defconst roam-graph-follow--app-id "io.github.christiangeng.roamgraph"
  "The app's ID, which names its folder on Linux and macOS.")

(defun roam-graph-follow--default-file ()
  "Where the app writes its port and token on this system.
The app's support folder, as Flutter's path_provider names it."
  (cond
   ((eq system-type 'windows-nt)
    (expand-file-name "io.github.christiangeng/Roam Graph/follow.json"
                      (or (getenv "APPDATA") "~")))
   ((eq system-type 'darwin)
    (expand-file-name
     (concat "Library/Application Support/" roam-graph-follow--app-id
             "/follow.json")
     "~"))
   (t
    (expand-file-name
     (concat roam-graph-follow--app-id "/follow.json")
     (or (getenv "XDG_DATA_HOME") "~/.local/share")))))

(defcustom roam-graph-follow-file (roam-graph-follow--default-file)
  "The file in which the Roam Graph app writes its port and token."
  :type 'file)

(defcustom roam-graph-follow-idle-delay 1.0
  "Seconds of idle time before the node at point is checked again."
  :type 'number)

(defvar roam-graph-follow--timer nil
  "The idle timer of `roam-graph-follow-mode'.")

(defvar roam-graph-follow--last nil
  "The (PORT . ID) delivered last, so the same node is not sent again.
Set only once the line is written to the app, so a node at point while
the app was closed is sent once it runs, and again to an app started
anew on another port.")

(defun roam-graph-follow--read-config ()
  "The app's port and token as (PORT . TOKEN), or nil.
Nil when the file is missing or not as the app writes it."
  (when (file-readable-p roam-graph-follow-file)
    (condition-case nil
        (let* ((json-object-type 'alist)
               (json-key-type 'symbol)
               (config (json-read-file roam-graph-follow-file))
               (port (alist-get 'port config))
               (token (alist-get 'token config)))
          (when (and (natnump port) (< 0 port 65536)
                     (stringp token) (not (string-empty-p token)))
            (cons port token)))
      (error nil))))

(defun roam-graph-follow--message (id token)
  "The line sent for ID with TOKEN."
  (concat (json-encode `((token . ,token) (id . ,id))) "\n"))

(defun roam-graph-follow--send (id &optional on-sent)
  "Send ID to the app, without waiting and without errors.
Call ON-SENT with the port once the line is written.  Return non-nil
when a connection was started; that alone does not mean it arrives."
  (when-let* ((config (roam-graph-follow--read-config)))
    (let ((line (roam-graph-follow--message id (cdr config))))
      (condition-case nil
          (let ((process
                 (make-network-process
                  :name "roam-graph-follow"
                  :host "127.0.0.1"
                  :service (car config)
                  :family 'ipv4
                  :nowait t
                  :noquery t
                  :coding 'utf-8
                  :sentinel
                  (lambda (process event)
                    (if (string-prefix-p "open" event)
                        (condition-case nil
                            (progn (process-send-string process line)
                                   (process-send-eof process)
                                   (when on-sent (funcall on-sent (car config))))
                          (error (delete-process process)))
                      (when (memq (process-status process)
                                  '(closed failed exit signal))
                        (delete-process process)))))))
            ;; Never left open: the app reads one line and closes.
            (run-at-time 3 nil (lambda ()
                                 (when (process-live-p process)
                                   (delete-process process))))
            t)
        (error nil)))))

(defun roam-graph-follow--id-here ()
  "The ID of the org-roam node at point, or nil."
  (when (and (derived-mode-p 'org-mode)
             buffer-file-name
             (fboundp 'org-roam-id-at-point)
             (fboundp 'org-roam-file-p)
             (org-roam-file-p))
    (condition-case nil
        (org-roam-id-at-point)
      (error nil))))

(defun roam-graph-follow--check ()
  "Send the node at point unless it was delivered last, to this app."
  (when-let* ((id (roam-graph-follow--id-here))
              (config (roam-graph-follow--read-config)))
    (unless (equal (cons (car config) id) roam-graph-follow--last)
      (roam-graph-follow--send
       id (lambda (port) (setq roam-graph-follow--last (cons port id)))))))

(defun roam-graph-follow--visited ()
  "Send the node at point of a just visited org-roam file."
  ;; A file opened again shows its node again, also if it was sent last.
  (setq roam-graph-follow--last nil)
  (roam-graph-follow--check))

;;;###autoload
(define-minor-mode roam-graph-follow-mode
  "Let the Roam Graph desktop app show the org-roam node at point."
  :global t
  :group 'roam-graph-follow
  (when roam-graph-follow--timer
    (cancel-timer roam-graph-follow--timer)
    (setq roam-graph-follow--timer nil))
  (remove-hook 'org-roam-find-file-hook #'roam-graph-follow--visited)
  (setq roam-graph-follow--last nil)
  (when roam-graph-follow-mode
    (add-hook 'org-roam-find-file-hook #'roam-graph-follow--visited)
    (setq roam-graph-follow--timer
          (run-with-idle-timer roam-graph-follow-idle-delay t
                               #'roam-graph-follow--check))))

(provide 'roam-graph-follow)
;;; roam-graph-follow.el ends here
