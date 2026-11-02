;;; roam-graph-follow-test.el --- Tests for roam-graph-follow.el -*- lexical-binding: t; -*-

;; Run with emacs/run-tests.sh, which puts org-roam on the load path.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-roam)
(require 'roam-graph-follow)

(defconst roam-graph-follow-test--note
  ":PROPERTIES:
:ID:       file-node-id
:END:
#+title: A note

Text of the file node.

* A heading node
:PROPERTIES:
:ID:       heading-node-id
:END:
Text of the heading node.

** A plain subheading
Text under a heading that is no node.

* An excluded heading
:PROPERTIES:
:ID:       excluded-id
:ROAM_EXCLUDE: t
:END:
Text of an excluded heading.
"
  "A note with a file node, a heading node and an excluded heading.")

(defmacro roam-graph-follow-test--in-note (&rest body)
  "Run BODY in the test note, a file in a temporary `org-roam-directory'."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "roam-graph-follow" t))
          (org-roam-directory dir)
          (file (expand-file-name "note.org" dir)))
     (unwind-protect
         (progn
           (with-temp-file file (insert roam-graph-follow-test--note))
           (with-current-buffer (find-file-noselect file)
             (unwind-protect (progn ,@body)
               (set-buffer-modified-p nil)
               (kill-buffer))))
       (delete-directory dir t))))

(defun roam-graph-follow-test--id-at (text)
  "The ID sent with point at the start of TEXT in the test note."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (match-beginning 0))
  (roam-graph-follow--id-here))

(ert-deftest roam-graph-follow-file-and-heading-nodes ()
  "The node at point is the one `org-roam-id-at-point' gives."
  (roam-graph-follow-test--in-note
    (should (equal (roam-graph-follow-test--id-at "Text of the file node")
                   "file-node-id"))
    (should (equal (roam-graph-follow-test--id-at "Text of the heading node")
                   "heading-node-id"))
    ;; A heading that is no node belongs to the node above it.
    (should (equal (roam-graph-follow-test--id-at "Text under a heading")
                   "heading-node-id"))
    ;; An excluded heading is no node: its text belongs to the file node.
    (should (equal (roam-graph-follow-test--id-at "Text of an excluded")
                   "file-node-id"))))

(ert-deftest roam-graph-follow-not-in-other-buffers ()
  "Outside an org-roam file, nothing is sent."
  (with-temp-buffer
    (should-not (roam-graph-follow--id-here)))
  (let ((dir (make-temp-file "roam-graph-follow-other" t))
        (org-roam-directory (make-temp-file "roam-graph-follow-roam" t)))
    (unwind-protect
        (let ((file (expand-file-name "elsewhere.org" dir)))
          (with-temp-file file (insert roam-graph-follow-test--note))
          (with-current-buffer (find-file-noselect file)
            (unwind-protect (should-not (roam-graph-follow--id-here))
              (kill-buffer))))
      (delete-directory dir t)
      (delete-directory org-roam-directory t))))

(ert-deftest roam-graph-follow-message ()
  "A message is one line of JSON with the token and the ID."
  (let ((line (roam-graph-follow--message "an-id" "a-token")))
    (should (string-suffix-p "\n" line))
    (should (= 1 (cl-count ?\n line)))
    (let ((json-object-type 'alist) (json-key-type 'symbol))
      (should (equal (json-read-from-string line)
                     '((token . "a-token") (id . "an-id")))))))

(ert-deftest roam-graph-follow-config ()
  "The port file is read when it is as the app writes it, else ignored."
  (let ((roam-graph-follow-file (make-temp-file "follow" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file roam-graph-follow-file
            (insert "{\"port\": 41234, \"token\": \"secret\"}\n"))
          (should (equal (roam-graph-follow--read-config)
                         '(41234 . "secret")))
          (with-temp-file roam-graph-follow-file (insert "not json"))
          (should-not (roam-graph-follow--read-config))
          (with-temp-file roam-graph-follow-file
            (insert "{\"port\": \"41234\", \"token\": \"secret\"}"))
          (should-not (roam-graph-follow--read-config)))
      (delete-file roam-graph-follow-file)))
  (let ((roam-graph-follow-file "/nonexistent/follow.json"))
    (should-not (roam-graph-follow--read-config))
    ;; Without the app, sending is silent.
    (should-not (roam-graph-follow--send "an-id"))))

(ert-deftest roam-graph-follow-sends-to-the-app ()
  "The ID reaches a listener on the port in the file, with the token."
  (let* ((received "")
         (delivered nil)
         (server (make-network-process
                  :name "roam-graph-follow-test-server" :server t
                  :host "127.0.0.1" :service t :family 'ipv4 :noquery t
                  :filter (lambda (_process text)
                            (setq received (concat received text)))))
         (port (process-contact server :service))
         (roam-graph-follow-file (make-temp-file "follow" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file roam-graph-follow-file
            (insert (format "{\"port\": %d, \"token\": \"secret\"}" port)))
          (should (roam-graph-follow--send
                   "an-id" (lambda (port) (setq delivered port))))
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (string-suffix-p "\n" received))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (let ((json-object-type 'alist) (json-key-type 'symbol))
            (should (equal (json-read-from-string received)
                           '((token . "secret") (id . "an-id")))))
          (should (equal delivered port)))
      (delete-process server)
      (delete-file roam-graph-follow-file))))

(ert-deftest roam-graph-follow-refused-connection-is-silent ()
  "A port nobody listens on gives no error."
  (let* ((server (make-network-process
                  :name "roam-graph-follow-test-free" :server t
                  :host "127.0.0.1" :service t :family 'ipv4 :noquery t))
         (port (process-contact server :service))
         (roam-graph-follow-file (make-temp-file "follow" nil ".json")))
    ;; A port that was free a moment ago, now closed.
    (delete-process server)
    (unwind-protect
        (progn
          (with-temp-file roam-graph-follow-file
            (insert (format "{\"port\": %d, \"token\": \"secret\"}" port)))
          (should (roam-graph-follow--send "an-id"))
          (accept-process-output nil 0.3))
      (delete-file roam-graph-follow-file))))

(defmacro roam-graph-follow-test--sending (port delivered &rest body)
  "Run BODY with the app on PORT; a send arrives when DELIVERED is non-nil.
Return the IDs sent, in order."
  (declare (indent 2))
  `(let ((sent '())
         (roam-graph-follow--last nil))
     (cl-letf (((symbol-function 'roam-graph-follow--read-config)
                (lambda () (cons ,port "secret")))
               ((symbol-function 'roam-graph-follow--send)
                (lambda (id &optional on-sent)
                  (push id sent)
                  (when (and ,delivered on-sent) (funcall on-sent ,port))
                  t)))
       ,@body)
     (reverse sent)))

(ert-deftest roam-graph-follow-sends-a-node-once ()
  "The idle check sends a node only when it differs from the last one."
  (should
   (equal (roam-graph-follow-test--in-note
            (roam-graph-follow-test--sending 4000 t
              (roam-graph-follow-test--id-at "Text of the file node")
              (roam-graph-follow--check)
              (roam-graph-follow--check)
              (roam-graph-follow-test--id-at "Text of the heading node")
              (roam-graph-follow--check)
              ;; Visiting the file again sends its node again.
              (roam-graph-follow--visited)))
          '("file-node-id" "heading-node-id" "heading-node-id"))))

(ert-deftest roam-graph-follow-resends-what-did-not-arrive ()
  "A node that did not arrive is sent again; so is one for a new app."
  (should
   (equal (roam-graph-follow-test--in-note
            (roam-graph-follow-test--sending 4000 nil
              (roam-graph-follow-test--id-at "Text of the file node")
              (roam-graph-follow--check)
              (roam-graph-follow--check)))
          '("file-node-id" "file-node-id")))
  (roam-graph-follow-test--in-note
    (roam-graph-follow-test--id-at "Text of the file node")
    (let ((port 4000) (sent '()) (roam-graph-follow--last nil))
      (cl-letf (((symbol-function 'roam-graph-follow--read-config)
                 (lambda () (cons port "secret")))
                ((symbol-function 'roam-graph-follow--send)
                 (lambda (id &optional on-sent)
                   (push id sent) (funcall on-sent port) t)))
        (roam-graph-follow--check)
        (roam-graph-follow--check)
        ;; The app started again, on another port.
        (setq port 4001)
        (roam-graph-follow--check))
      (should (equal sent '("file-node-id" "file-node-id"))))))

(ert-deftest roam-graph-follow-nothing-without-the-app ()
  "Without the port file, nothing is sent and nothing is recorded."
  (roam-graph-follow-test--in-note
    (roam-graph-follow-test--id-at "Text of the file node")
    (let ((roam-graph-follow-file "/nonexistent/follow.json")
          (roam-graph-follow--last nil))
      (roam-graph-follow--check)
      (should-not roam-graph-follow--last))))

(ert-deftest roam-graph-follow-mode-on-and-off ()
  "The mode adds and removes its hook and timer."
  (unwind-protect
      (progn
        (roam-graph-follow-mode 1)
        (should (memq #'roam-graph-follow--visited org-roam-find-file-hook))
        (should (timerp roam-graph-follow--timer)))
    (roam-graph-follow-mode -1))
  (should-not (memq #'roam-graph-follow--visited org-roam-find-file-hook))
  (should-not roam-graph-follow--timer))

;;; roam-graph-follow-test.el ends here
