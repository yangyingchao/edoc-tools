;;; edoc-info.el --- Extract info from edoc-files via a helper process. -*- lexical-binding: t -*-

;; Copyright (C) 2013, 2014  Andreas Politz

;; Author: Andreas Politz <politza@fh-trier.de>
;; Keywords: files, multimedia

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This library represents the Lisp side of the kc server.  This
;; program works on a command/response basis, but there should be no
;; need to understand the protocol, since every command has a
;; corresponding Lisp-function (see below under `High level
;; interface').
;;
;; Most of these functions receive a file-or-buffer argument, which
;; may be what it says and defaults to the current buffer.  Also, most
;; functions return some sort of alist, with, in most cases,
;; straight-forward key-value-pairs.  Though some may be only
;; understandable in the context of Adobe's PDF spec \(Adobe
;; PDF32000\) or the poppler documentation (e.g. annotation flags).
;;
;; If the poppler library is fairly recent (>= 0.19.4, older versions
;; have a bug, which may corrupt the document), annotations maybe
;; modified to a certain degree, deleted and text-annotations created.
;; The state of these modifications is held in the server.  In order
;; to realize, annotations retrieved or created are referenced by a
;; unique symbol.  Saving these changes creates a new file, the
;; original document is never touched.

;;; Todo:
;;
;; + Close documents at some time (e.g. when the buffer is killed)
;;

;;; Code:

(require 'json)
(require 'tq)
(require 'cl-lib)



;; * ================================================================== *
;; * Customizations
;; * ================================================================== *

(defgroup edoc-info nil
  "Extract infos from edoc-files via a helper process."
  :group 'edoc-tools)

(defcustom edoc-info-kc-program
  (executable-find "kc")
  "Filename of the kc executable."
  :type 'file)

(defcustom edoc-info-kc-error-filename nil
  "Filename for error output of the kc executable.

If nil, discard any error messages.  Useful for debugging."
  :type `(choice (const :tag "None" nil)
                 ,@(when (file-directory-p "/tmp/")
                     '((const "/tmp/kc.log")))
                 (file)))

(defcustom edoc-info-log nil
  "Whether to log the communication with the server.

If this is non-nil, all communication with the kc program
will be logged to the buffer \"*edoc-info-log*\"."
  :type 'boolean)

(defcustom edoc-info-log-entry-max 512
  "Maximum number of characters in a single log entry.

This variable has no effect if `edoc-info-log' is nil."
  :type 'integer)

(defcustom edoc-info-restart-process-p 'ask
  "What to do when the kc server died.

This should be one of
nil -- do nothing,
t   -- automatically restart it or
ask -- ask whether to restart or not.

If it is `ask', the server quits and you answer no, this variable
is set to nil."
  :type '(choice (const :tag "Do nothing" nil)
                 (const :tag "Restart silently" t)
                 (const :tag "Always ask" ask)))

(defcustom edoc-info-close-document-hook nil
  "A hook ran after a document was closed in the server.

The hook is run in the documents buffer, if it exists. Otherwise
in a `with-temp-buffer' form."
  :type 'hook)



(defcustom edoc-info-required-formats '("pdf")
  "Backends the kc server must provide.

Names are the BACKEND column of \=`kc doc-server list\=', e.g.
\"pdf\", \"word\", \"slides\".  The check is skipped when kc does
not know that subcommand, and disabled entirely when this is nil."
  :type '(repeat string))

;; * ================================================================== *
;; * Variables
;; * ================================================================== *

(defvar edoc-info-asynchronous nil
  "If non-nil process queries asynchronously.

More specifically the value should be a function of at 2
arguments \(fn STATUS RESPONSE\), where STATUS is either nil, for
a successful query, or the symbol error.  RESPONSE is either the
command's response or the error message.  This does not work
recursive, i.e. if function wants to make another asynchronous
query it has to rebind this variable.

Alternatively it may be a list \(FN . ARGS\), in which case FN
will be invoked like \(apply FN STATUS RESPONSE ARGS\).

Also, all edoc-info functions normally returning a response return
nil.

This variable should only be let-bound.")

(defconst edoc-info-edoc-date-regexp
  ;; Adobe PDF32000.book, 7.9.4 Dates
  (eval-when-compile
    (concat
     ;; allow for preceding garbage
     ;;"\\`"
     "[dD]:"
     "\\([0-9]\\{4\\}\\)"          ;year
     "\\(?:"
     "\\([0-9]\\{2\\}\\)"          ;month
     "\\(?:"
     "\\([0-9]\\{2\\}\\)"          ;day
     "\\(?:"
     "\\([0-9]\\{2\\}\\)"          ;hour
     "\\(?:"
     "\\([0-9]\\{2\\}\\)"          ;minutes
     "\\(?:"
     "\\([0-9]\\{2\\}\\)"          ;seconds
     "\\)?\\)?\\)?\\)?\\)?"
     "\\(?:"
     "\\([+-Zz]\\)"                ;UT delta char
     "\\(?:"
     "\\([0-9]\\{2\\}\\)"          ;UT delta hours
     "\\(?:"
     "'"
     "\\([0-9]\\{2\\}\\)"          ;UT delta minutes
     "\\)?\\)?\\)?"
     ;; "\\'"
     ;; allow for trailing garbage
     )))

(defvar edoc-info--queue t
  "Internally used transmission-queue for the server.

This variable is initially t, telling the code starting the
server, that it never ran.")


;; * ================================================================== *
;; * Process handling
;; * ================================================================== *

(defconst edoc-info-empty-page-data
  (eval-when-compile
    (concat
     "%PDF-1.0\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0"
     " obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</"
     "Type/Page/MediaBox[0 0 3 3]>>endobj\nxref\n0 4\n00000000"
     "0065535 f\n0000000010 00000 n\n0000000053 00000 n\n00000"
     "00102 00000 n\ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n149\n%EOF"))
  "PDF data of an empty page.")

(defun edoc-info-process ()
  "Return the process object or nil."
  (and edoc-info--queue
       (not (eq t edoc-info--queue))
       (tq-process edoc-info--queue)))

(defun edoc-info-check-kc (&optional interactive-p)
  "Check if the server should be working properly.

Signal an error if some problem was found.  Message a
confirmation, if INTERACTIVE-P is non-nil and no problems were
found.

Returns nil."
  (interactive "p")
  (let ((executable edoc-info-kc-program))
    (unless (stringp executable)
      (error "edoc-info-kc-program is unset or not a string"))
    (unless (file-executable-p executable)
      (error "edoc-info-kc-program is not executable"))
    (when edoc-info-kc-error-filename
      (unless (and (stringp edoc-info-kc-error-filename)
                   (file-writable-p edoc-info-kc-error-filename))
        (error "edoc-info-kc-error-filename should contain writable filename")))
    (let* ((default-directory (expand-file-name "~/"))
           (cmdfile (make-temp-file "commands"))
           (pdffile (make-temp-file "empty.pdf"))
           (tempdir (make-temp-file "tmpdir" t))
           (process-environment (cons (concat "TMPDIR=" tempdir)
                                      process-environment)))
      (unwind-protect
          (with-temp-buffer
            (with-temp-file pdffile
              (set-buffer-multibyte nil)
              (insert edoc-info-empty-page-data))
            (with-temp-file cmdfile
              (insert (format "renderpage:%s:1:100\nquit\n"
                              (edoc-info-query--escape pdffile))))
            (unless (= 0 (apply #'call-process
                                executable cmdfile (current-buffer)
                                nil "doc-server" "run"
                                (when edoc-info-kc-error-filename
                                  (list edoc-info-kc-error-filename))))
              (error "Error running `%s': %s"
                     edoc-info-kc-program
                     (buffer-string))))
        (when (file-exists-p cmdfile)
          (delete-file cmdfile))
        (when (file-exists-p pdffile)
          (delete-file pdffile))
        (when (file-exists-p tempdir)
          (delete-directory tempdir t)))))
  (edoc-info--check-required-formats)
  (when interactive-p
    (message "The kc program appears to be working."))
  nil)

(defun edoc-info--run-list ()
  "Run \=`kc doc-server list --json\' and return the parsed entries.

The result is a list of alists with the keys \=`backend\' and
\=`extension\'.  Nil means the capabilities are unknown: kc may be
too old to have the subcommand, or its output did not parse."
  (when (and (stringp edoc-info-kc-program)
             (file-executable-p edoc-info-kc-program))
    (let ((default-directory (expand-file-name "~/"))
          (buffer (get-buffer-create " *edoc-info-list*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (erase-buffer))
            (when (zerop (ignore-errors
                           (call-process edoc-info-kc-program nil buffer nil
                                         "doc-server" "list" "--json")))
              (ignore-errors
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (append (json-read) nil)))))
        (kill-buffer buffer)))))

(defun edoc-info--check-required-formats ()
  "Warn about required backends the kc server does not provide.

Do nothing when kc cannot report its capabilities."
  (when edoc-info-required-formats
    (let ((entries (edoc-info--run-list)))
      (when entries
        (let* ((present (delete-dups
                         (delq nil
                               (mapcar (lambda (entry)
                                         (cdr (assq 'backend entry)))
                                       entries))))
               (missing (seq-remove (lambda (backend)
                                      (member backend present))
                                    edoc-info-required-formats)))
          (when missing
            (display-warning
             'edoc-info
             (format "kc does not provide the required backend(s): %s (it has: %s)"
                     (mapconcat #'identity missing ", ")
                     (if present (mapconcat #'identity present ", ") "none"))
             :warning)))))))

(defun edoc-info-list-supported-formats ()
  "Show the document types the kc server supports.

The list comes from \=`kc doc-server list --json\'; the file types kc
can render are reported by the server itself, so this is also a way
to check whether a backend is missing."
  (interactive)
  (let* ((entries (edoc-info--run-list))
         (buffer (get-buffer-create "*edoc-info-supported-formats*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null entries)
            (insert "kc does not report its supported document types.\n")
          (dolist (entry entries)
            (insert (format "%-8s %s\n"
                            (or (cdr (assq 'backend entry)) "?")
                            (or (cdr (assq 'extension entry)) "?"))))
          (insert "\n"))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)))

(defun edoc-info-process-assert-running (&optional force)
  "Assert a running process.

If it never ran, i.e. `edoc-info-process' is t, start it
unconditionally.

Otherwise, if FORCE is non-nil start it, if it is not running.
Else restart it with respect to the variable
`edoc-info-restart-process-p', which see.

If getting the process to run fails, this function throws an
error."
  (interactive "P")
  (unless (and (processp (edoc-info-process))
               (eq (process-status (edoc-info-process))
                   'run))
    (when (edoc-info-process)
      (tq-close edoc-info--queue)
      (setq edoc-info--queue nil))
    (unless (or force
                (eq edoc-info--queue t)
                (and (eq edoc-info-restart-process-p 'ask)
                     (not noninteractive)
                     (y-or-n-p "The kc server quit, restart it ? "))
                (and edoc-info-restart-process-p
                     (not (eq edoc-info-restart-process-p 'ask))))

      (when (eq edoc-info-restart-process-p 'ask)
        (setq edoc-info-restart-process-p nil))
      (error "The kc server quit"))
    (edoc-info-check-kc)
    (let* ((process-connection-type)    ;Avoid 4096 Byte bug #12440.
           (default-directory "~")
           (proc (apply #'start-process
                        "kc" " *kc*" edoc-info-kc-program
                        "doc-server" "run"
                        (when edoc-info-kc-error-filename
                          (list edoc-info-kc-error-filename)))))
      (with-current-buffer " *kc*"
        (erase-buffer))
      (set-process-query-on-exit-flag proc nil)
      (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
      (setq edoc-info--queue (tq-create proc))))
  edoc-info--queue)

(when (< emacs-major-version 27)
  (advice-add 'tq-process-buffer :around #'edoc-info--tq-workaround))

(defun edoc-info--tq-workaround (orig-fun tq &rest args)
  "Fix a bug in trunk where the wrong callback gets called.

ORIG-FUN is the callback that should be called. TQ and ARGS are
the transmission-queue and arguments to the callback."
  ;; FIXME: Make me iterative.
  (if (not (equal (car (process-command (tq-process tq)))
                  edoc-info-kc-program))
      (apply orig-fun tq args)
    (let ((buffer (tq-buffer tq))
          done)
      (when (buffer-live-p buffer)
        (set-buffer buffer)
        (while (and (not done)
                    (> (buffer-size) 0))
          (setq done t)
          (if (tq-queue-empty tq)
              (let ((buf (generate-new-buffer "*spurious*")))
                (copy-to-buffer buf (point-min) (point-max))
                (delete-region (point-min) (point))
                (pop-to-buffer buf nil)
                (error "Spurious communication from process %s, see buffer %s"
                       (process-name (tq-process tq))
                       (buffer-name buf)))
            (goto-char (point-min))
            (when (re-search-forward (tq-queue-head-regexp tq) nil t)
              (setq done nil)
              (let ((answer (buffer-substring (point-min) (point)))
                    (fn (tq-queue-head-fn tq))
                    (closure (tq-queue-head-closure tq)))
                (delete-region (point-min) (point))
                (tq-queue-pop tq)
                (condition-case-unless-debug err
                    (funcall fn closure answer)
                  (error
                   (message "Error while processing tq callback: %s"
                            (error-message-string err))))))))))))


;; * ================================================================== *
;; * Sending and receiving
;; * ================================================================== *

(defun edoc-info-query (cmd &rest args)
  "Query the server using CMD and ARGS."
  (edoc-info-process-assert-running)
  (unless (symbolp cmd)
    (setq cmd (intern cmd)))
  (let* ((query (concat (mapconcat #'edoc-info-query--escape
                                   (cons cmd args) ":")
                        "\n"))
         (callback
          (lambda (closure response)
            (cl-destructuring-bind (status &rest result)
                (edoc-info-query--parse-response cmd response)
              (edoc-info-query--log response)
              (let* (edoc-info-asynchronous)
                (if (functionp closure)
                    (funcall closure status result)
                  (apply (car closure) status result (cdr closure)))))))
         response status done
         (closure (or edoc-info-asynchronous
                      (lambda (s r)
                        (setq status s response r done t)))))
    (edoc-info-query--log query t)
    (tq-enqueue
     edoc-info--queue query "^\\.\n" closure callback)
    (unless edoc-info-asynchronous
      (while (and (not done)
                  (eq (process-status (edoc-info-process))
                      'run))
        (accept-process-output (edoc-info-process) 0.01))
      (when (and (not done)
                 (not (eq (process-status (edoc-info-process))
                          'run))
                 (not (eq cmd 'quit)))
        (error "The kc server quit unexpectedly"))
      (cond
       ((null status) response)
       ((eq status 'error)
        (error "kc: %s" response))
       ((eq status 'interrupted)
        (error "kc: Command was interrupted"))
       (t
        (error "Internal error: invalid response status"))))))

(defun edoc-info-interrupt ()
  "FIXME: This command does currently nothing."
  (when (and (processp (edoc-info-process))
             (eq (process-status (edoc-info-process))
                 'run))
    (signal-process (edoc-info-process) 'SIGUSR1)))

(defun edoc-info-query--escape (arg)
  "Escape ARG for transmission to the server."
  (if (null arg)
      (string)
    (with-current-buffer (get-buffer-create " *edoc-info-query--escape*")
      (erase-buffer)
      (insert (format "%s" arg))
      (goto-char 1)
      (while (not (eobp))
        (cond
         ((memq (char-after) '(?\\ ?:))
          (insert ?\\))
         ((eq (char-after) ?\n)
          (delete-char 1)
          (insert ?\\ ?n)
          (backward-char)))
        (forward-char))
      (buffer-substring-no-properties 1 (point-max)))))

(defmacro edoc-info-query--read-record ()
  "Read a single record of the response in current buffer."
  `(let (records done (beg (point)))
     (while (not done)
       (cl-case (char-after)
         (?\\
          (delete-char 1)
          (if (not (eq (char-after) ?n))
              (forward-char)
            (delete-char 1)
            (insert ?\n)))
         ((?: ?\n)
          (push (buffer-substring-no-properties
                 beg (point)) records)
          (forward-char)
          (setq beg (point)
                done (bolp)))
         (t (forward-char))))
     (nreverse records)))

(defun edoc-info-query--parse-response (cmd response)
  "Parse one kc RESPONSE to CMD.

Returns a cons \(STATUS . RESULT\), where STATUS is one of nil
for a regular response, error for an error \(RESULT contains the
error message\) or interrupted, i.e. the command was
interrupted."
  (with-current-buffer
      (get-buffer-create " *edoc-info-query--parse-response*")
    (erase-buffer)
    (insert response)
    (goto-char 1)
    (cond
     ((looking-at "ERR\n")
      (forward-line)
      (cons 'error (buffer-substring-no-properties
                    (point)
                    (progn
                      (re-search-forward "^\\.\n")
                      (1- (match-beginning 0))))))
     ((looking-at "OK\n")
      (let (result)
        (forward-line)
        (while (not (and (= (char-after) ?.)
                         (= (char-after (1+ (point))) ?\n)))
          (push (edoc-info-query--read-record) result))
        (cons nil (edoc-info-query--transform-response
                   cmd (nreverse result)))))
     ((looking-at "INT\n")
      (cons 'interrupted nil))
     (t
      (cons 'error "Invalid server response")))))

(defun edoc-info-query--transform-response (cmd response)
  "Transform a RESPONSE to CMD into a Lisp form."
  (cl-case cmd
    (open nil)
    (close (equal "1" (caar response)))
    (number-of-pages (string-to-number (caar response)))
    (charlayout
     (mapcar (lambda (elt)
               (cl-assert (= 1 (length (cadr elt))) t)
               `(,(aref (cadr elt) 0)
                 ,(mapcar #'string-to-number
                          (split-string (car elt) " " t))))
             response))
    (regexp-flags
     (mapcar (lambda (elt)
               (cons (intern (car elt))
                     (string-to-number (cadr elt))))
             response))
    ((search-string search-regexp)
     (mapcar
      (lambda (r)
        `((page . ,(string-to-number (nth 0 r)))
          (text . ,(let (case-fold-search)
                     (edoc-util-highlight-regexp-in-string
                      (regexp-quote (nth 1 r)) (nth 2 r))))
          (edges . ,(mapcar (lambda (m)
                              (mapcar #'string-to-number
                                      (split-string m " " t)))
                            (cddr (cdr r))))))
      response))
    (outline
     (mapcar (lambda (r)
               `((depth . ,(string-to-number (pop r)))
                 ,@(edoc-info-query--transform-action r)))
             response))
    (pagelinks
     (mapcar (lambda (r)
               `((edges .
                        ,(mapcar #'string-to-number ;area
                                 (split-string (pop r) " " t)))
                 ,@(edoc-info-query--transform-action r)))
             response))
    (metadata
     (let ((md (car response)))
       (if (= 1 (length md))
           (list (cons 'title (car md)))
         (list
          (cons 'title (pop md))
          (cons 'author (pop md))
          (cons 'subject (pop md))
          (cons 'keywords-raw (car md))
          (cons 'keywords (split-string (pop md) "[\t\n ]*,[\t\n ]*" t))
          (cons 'creator (pop md))
          (cons 'producer (pop md))
          (cons 'format (pop md))
          (cons 'created (pop md))
          (cons 'modified (pop md))))))
    (gettext
     (or (caar response) ""))
    (getselection
     (mapcar (lambda (line)
               (mapcar #'string-to-number
                       (split-string (car line) " " t)))
             response))
    (features (mapcar #'intern (car response)))
    (pagesize
     (setq response (car response))
     (cons (round (string-to-number (car response)))
           (round (string-to-number (cadr response)))))
    ((getannot editannot addannot)
     (edoc-info-query--transform-annotation (car response)))
    (getannots
     (mapcar #'edoc-info-query--transform-annotation response))
    (getattachments
     (mapcar #'edoc-info-query--transform-attachment response))
    ((getattachment-from-annot)
     (edoc-info-query--transform-attachment (car response)))
    (boundingbox
     (mapcar #'string-to-number (car response)))
    (synctex-forward-search
     (let ((list (mapcar #'string-to-number (car response))))
       `((page . ,(car list))
         (edges . ,(cdr list)))))
    (synctex-backward-search
     `((filename . ,(caar response))
       (line . ,(string-to-number (cadr (car response))))
       (column . ,(string-to-number (cadr (cdar response))))))
    (delannot nil)
    ((save) (caar response))
    ((renderpage renderpage-text-regions renderpage-highlight)
     (edoc-util-munch-file (caar response)))
    ((setoptions getoptions)
     (let (options)
       (dolist (key-value response)
         (let ((key (intern (car key-value)))
               (value (cadr key-value)))
           (cl-case key
             ((:render/printed)
              (setq value (equal value "1")))
             ((:render/usecolors)
              (setq value (ignore-errors
                            (let ((int-val (cl-parse-integer value)))
                              (if (> 3 int-val 0)
                                  int-val
                                0))))))
           (push value options)
           (push key options)))
       options))
    (pagelabels (mapcar #'car response))
    (ping (caar response))
    (t response)))


(defun edoc-info-query--transform-action (action)
  "Transform ACTION response into a Lisp form."
  (let ((type (intern (pop action))))
    `((type . ,type)
      (title . ,(pop action))
      ,@(cl-case type
          (goto-dest
           `((page . ,(string-to-number (pop action)))
             (top . ,(and (> (length (car action)) 0)
                          (string-to-number (pop action))))))
          (goto-remote
           `((filename . ,(pop action))
             (page . ,(string-to-number (pop action)))
             (top . ,(and (> (length (car action)) 0)
                          (string-to-number (pop action))))))
          (t `((uri . ,(pop action))))))))

(defun edoc-info-query--transform-annotation (a)
  (cl-labels ((not-empty (s)
                (if (not (equal s "")) s)))
    (let (a1 a2 a3)
      (cl-destructuring-bind (page edges type id flags color contents modified &rest rest)
          a
        (setq a1 `((page . ,(string-to-number page))
                   (edges . ,(mapcar #'string-to-number
                                     (split-string edges " " t)))
                   (type . ,(intern type))
                   (id . ,(intern id))
                   (flags . ,(string-to-number flags))
                   (color . ,(not-empty color))
                   (contents . ,contents)
                   (modified . ,(edoc-info-parse-edoc-date modified))))
        (when rest
          (cl-destructuring-bind (label subject opacity popup-edges popup-is-open created
                                        &rest rest)
              rest
            (setq a2
                  `((label . ,(not-empty label))
                    (subject . ,(not-empty subject))
                    (opacity . ,(let ((o (not-empty opacity)))
                                  (and o (string-to-number o))))
                    (popup-edges . ,(let ((p (not-empty popup-edges)))
                                      (when p
                                        (mapcar #'string-to-number
                                                (split-string p " " t)))))
                    (popup-is-open . ,(equal popup-is-open "1"))
                    (created . ,(edoc-info-parse-edoc-date (not-empty created)))))
            (cond
             ((eq (cdr (assoc 'type a1)) 'text)
              (cl-destructuring-bind (icon state is-open)
                  rest
                (setq a3
                      `((icon . ,(not-empty icon))
                        (state . ,(not-empty state))
                        (is-open . ,(equal is-open "1"))))))
             ((memq (cdr (assoc 'type a1))
                    '(squiggly highlight underline strike-out))
              (setq a3 `((markup-edges
                          . ,(mapcar (lambda (r)
                                       (mapcar #'string-to-number
                                               (split-string r " " t)))
                                     rest)))))))))
      (append a1 a2 a3))))

(defun edoc-info-query--transform-attachment (a)
  (cl-labels ((not-empty (s)
                (if (not (equal s "")) s)))
    (cl-destructuring-bind (id filename description size modified
                               created checksum file)
        a
      `((id . ,(intern id))
        (filename . ,(not-empty filename))
        (description . ,(not-empty description))
        (size . ,(let ((n (string-to-number size)))
                   (and (>= n 0) n)))
        (modified . ,(not-empty modified))
        (created . ,(not-empty created))
        (checksum . ,(not-empty checksum))
        (file . ,(not-empty file))))))

(defun edoc-info-query--log (string &optional query-p)
  "Log STRING as query/response, depending on QUERY-P.

This is a no-op, if `edoc-info-log' is nil."
  (when edoc-info-log
    (with-current-buffer (get-buffer-create "*edoc-info-log*")
      (buffer-disable-undo)
      (let ((pos (point-max))
            (window (get-buffer-window)))
        (save-excursion
          (goto-char (point-max))
          (unless (bolp)
            (insert ?\n))
          (insert
           (propertize
            (format-time-string "%H:%M:%S ")
            'face
            (if query-p
                'font-lock-keyword-face
              'font-lock-function-name-face))
           (if (and (numberp edoc-info-log-entry-max)
                    (> (length string)
                       edoc-info-log-entry-max))
               (concat (substring string 0 edoc-info-log-entry-max)
                       "...[truncated]\n")
             string)))
        (when (and (window-live-p window)
                   (= pos (window-point window)))
          (set-window-point window (point-max)))))))



;; * ================================================================== *
;; * Utility functions
;; * ================================================================== *

(defvar doc-view-buffer-file-name)
(defvar doc-view--buffer-file-name)

(defun edoc-info--normalize-file-or-buffer (file-or-buffer)
  "Return the PDF file corresponding to FILE-OR-BUFFER.

FILE-OR-BUFFER may be nil, a PDF buffer, the name of a PDF buffer
or a PDF file."
  (unless file-or-buffer
    (setq file-or-buffer
          (current-buffer)))
  (when (bufferp file-or-buffer)
    (unless (buffer-live-p file-or-buffer)
      (error "Buffer is not live :%s" file-or-buffer))
    (with-current-buffer file-or-buffer
      (unless (setq file-or-buffer
                    (cl-case major-mode
                      (doc-view-mode
                       (cond ((boundp 'doc-view-buffer-file-name)
                              doc-view-buffer-file-name)
                             ((boundp 'doc-view--buffer-file-name)
                              doc-view--buffer-file-name)))
                      (edoc-view-mode (edoc-view-buffer-file-name))
                      (t (buffer-file-name))))
        (error "Buffer is not associated with any file :%s" (buffer-name)))))
  (unless (stringp file-or-buffer)
    (signal 'wrong-type-argument
            (list 'stringp 'bufferp 'null file-or-buffer)))
  ;; is file
  (when (file-remote-p file-or-buffer)
    (error "Processing remote files not supported :%s"
           file-or-buffer))
  ;; (unless (file-readable-p file-or-buffer)
  ;;   (error "File not readable :%s" file-or-buffer))
  (expand-file-name file-or-buffer))

(defun edoc-info-valid-page-spec-p (pages)
  "The type predicate for a valid page-spec."
  (not (not (ignore-errors (edoc-info-normalize-page-range pages)))))

(defun edoc-info-normalize-page-range (pages)
  "Normalize PAGES for sending to the server.

PAGES may be a single page number, a cons \(FIRST . LAST\), or
nil, which stands for all pages.

The result is a cons \(FIRST . LAST\), where LAST may be 0
representing the final page."
  (cond
   ((natnump pages)
    (cons pages pages))
   ((null pages)
    (cons 1 0))
   ((and (natnump (car pages))
         (natnump (cdr pages)))
    pages)
   (t
    (signal 'wrong-type-argument
            (list 'edoc-info-valid-page-spec-p pages)))))

(defun edoc-info-parse-edoc-date (date)
  (when (and date
             (string-match edoc-info-edoc-date-regexp date))
    (let ((year (match-string 1 date))
          (month (match-string 2 date))
          (day (match-string 3 date))
          (hour (match-string 4 date))
          (min (match-string 5 date))
          (sec (match-string 6 date))
          (ut-char (match-string 7 date))
          (ut-hour (match-string 8 date))
          (ut-min (match-string 9 date))
          (tz 0))
      (when (or (equal ut-char "+")
                (equal ut-char "-"))
        (when ut-hour
          (setq tz (* 3600 (string-to-number ut-hour))))
        (when ut-min
          (setq tz (+ tz (* 60 (string-to-number ut-min)))))
        (when (equal ut-char "-")
          (setq tz (- tz))))
      (encode-time
       (if sec (string-to-number sec) 0)
       (if min (string-to-number min) 0)
       (if hour (string-to-number hour) 0)
       (if day (string-to-number day) 1)
       (if month (string-to-number month) 1)
       (string-to-number year)
       tz))))

(defmacro edoc-info-compose-queries (let-forms &rest body)
  "Let-bind each VAR to QUERIES results and evaluate BODY.

All queries in each QUERIES form are run by the server in the
order they appear and the results collected in a list, which is
bound to VAR.  Then BODY is evaluated and its value becomes the
final result of all queries, unless at least one of them provoked
an error.  In this case BODY is ignored and the error is the
result.

This macro handles synchronous and asynchronous calls,
i.e. `edoc-info-asynchronous' is non-nil, transparently.

\(FN \(\(VAR QUERIES\)...\) BODY\)"
  (declare (indent 1)
           (debug ((&rest &or
                          (symbolp &optional form)
                          symbolp)
                   body)))
  (unless (cl-every (lambda (form)
                      (when (symbolp form)
                        (setq form (list form)))
                      (and (consp form)
                           (symbolp (car form))
                           (listp (cdr form))))
                    let-forms)
    (error "Invalid let-form: %s" let-forms))

  (setq let-forms (mapcar (lambda (form)
                            (if (symbolp form)
                                (list form)
                              form))
                          let-forms))
  (let* ((status (make-symbol "status"))
         (response (make-symbol "response"))
         (first-error (make-symbol "first-error"))
         (done (make-symbol "done"))
         (callback (make-symbol "callback"))
         (results (make-symbol "results"))
         (push-fn (make-symbol "push-fn"))
         (terminal-fn (make-symbol "terminal-fn"))
         (buffer (make-symbol "buffer")))
    `(let* (,status
            ,response ,first-error ,done
            (,buffer (current-buffer))
            (,callback edoc-info-asynchronous)
            ;; Ensure a new alist on every invocation.
            (,results (mapcar 'copy-sequence
                              ',(cl-mapcar (lambda (form)
                                             (list (car form)))
                                           let-forms)))
            (,push-fn (lambda (status result var)
                        ;; Store result in alist RESULTS under key
                        ;; VAR.
                        (if status
                            (unless ,first-error
                              (setq ,first-error result))
                          (let ((elt (assq var ,results)))
                            (setcdr elt (append (cdr elt)
                                                (list result)))))))
            (,terminal-fn
             (lambda (&rest _)
               ;; Let-bind responses corresponding to their variables,
               ;; i.e. keys in alist RESULTS.
               (let (,@(mapcar (lambda (var)
                                 `(,var (cdr (assq ',var ,results))))
                               (mapcar #'car let-forms)))
                 (setq ,status (not (not ,first-error))
                       ,response (or ,first-error
                                     (with-current-buffer ,buffer
                                       ,@body))
                       ,done t)
                 ;; Maybe invoke the CALLBACK (which was bound to
                 ;; edoc-info-asynchronous).
                 (when ,callback
                   (if (functionp ,callback)
                       (funcall ,callback ,status ,response)
                     (apply (car ,callback)
                       ,status ,response (cdr ,callback))))))))
       ;; Wrap each query in an asynchronous call, with its VAR as
       ;; callback argument, so the PUSH-FN can put it in the alist
       ;; RESULTS.
       ,@(mapcar (lambda (form)
                   (list 'let (list
                               (list 'edoc-info-asynchronous
                                     (list 'list push-fn (list 'quote (car form)))))
                         (cadr form)))
                 let-forms)
       ;; Request a no-op, just so we know that we are finished.
       (let ((edoc-info-asynchronous ,terminal-fn))
         (edoc-info-ping))
       ;; CALLBACK is the original value of edoc-info-asynchronous.  If
       ;; nil, this is a synchronous query.
       (unless ,callback
         (while (and (not ,done)
                     (eq (process-status (edoc-info-process))
                         'run))
           (accept-process-output (edoc-info-process) 0.01))
         (when (and (not ,done)
                    (not (eq (process-status (edoc-info-process))
                             'run)))
           (error "The kc server quit unexpectedly"))
         (when ,status
           (error "kc: %s" ,response))
         ,response))))


;; * ================================================================== *
;; * Buffer local server instances
;; * ================================================================== *

(put 'edoc-info--queue 'permanent-local t)

(defun edoc-info-make-local-server (&optional buffer force-restart-p)
  "Create a server instance local to BUFFER.

Does nothing if BUFFER already has a local instance.  Unless
FORCE-RESTART-P is non-nil, then quit a potential process and
restart it."
  (unless buffer
    (setq buffer (current-buffer)))
  (with-current-buffer buffer
    (unless (and
             (not force-restart-p)
             (local-variable-p 'edoc-info--queue)
             (processp (edoc-info-process))
             (eq (process-status (edoc-info-process))
                 'run))
      (when (and (local-variable-p 'edoc-info--queue)
                 (processp (edoc-info-process)))
        (tq-close edoc-info--queue))
      (set (make-local-variable 'edoc-info--queue) nil)
      (edoc-info-process-assert-running t)
      (add-hook 'kill-buffer-hook #'edoc-info-kill-local-server nil t)
      edoc-info--queue)))

(defun edoc-info-kill-local-server (&optional buffer)
  "Kill the local server in BUFFER.

A No-op, if BUFFER has not running server instance."
  (save-current-buffer
    (when buffer
      (set-buffer buffer))
    (when (local-variable-p 'edoc-info--queue)
      (edoc-info-kill)
      (kill-local-variable 'edoc-info--queue)
      t)))

(defun edoc-info-local-server-p (&optional buffer)
  "Return non-nil, if BUFFER has a running server instance."
  (unless buffer
    (setq buffer (current-buffer)))
  (setq buffer (get-buffer buffer))
  (and (buffer-live-p buffer)
       (local-variable-p 'edoc-info--queue buffer)))

(defun edoc-info-local-batch-query (producer-fn
                                   consumer-fn
                                   sentinel-fn
                                   args)
  "Process a set of queries asynchronously in a local instance."
  (unless (edoc-info-local-server-p)
    (error "Create a local server first"))
  (let* ((buffer (current-buffer))
         (producer-symbol (make-symbol "producer"))
         (consumer-symbol (make-symbol "consumer"))
         (producer
          (lambda (args)
            (if (null args)
                (funcall sentinel-fn 'finished buffer)
              (let ((edoc-info-asynchronous
                     (apply-partially
                      (symbol-function consumer-symbol)
                      args)))
                (cond
                 ((edoc-info-local-server-p buffer)
                  (with-current-buffer buffer
                    (apply producer-fn (car args))))
                 (t
                  (funcall sentinel-fn 'error buffer)))))))
         (consumer (lambda (args status result)
                     (if (not (edoc-info-local-server-p buffer))
                         (funcall sentinel-fn 'error buffer)
                       (with-current-buffer buffer
                         (apply consumer-fn status result (car args)))
                       (funcall (symbol-function producer-symbol)
                                (cdr args))))))
    (fset producer-symbol producer)
    (fset consumer-symbol consumer)
    (funcall producer args)))



;; * ================================================================== *
;; * High level interface
;; * ================================================================== *

(defvar edoc-info-features nil)

(defun edoc-info-features ()
  "Return a list of symbols describing compile-time features."
  (or edoc-info-features
      (setq edoc-info-features
            (let (edoc-info-asynchronous)
              (edoc-info-query 'features)))))

(defun edoc-info-writable-annotations-p ()
  (not (null (memq 'writable-annotations (edoc-info-features)))))

(defun edoc-info-markup-annotations-p ()
  (not (null (memq 'markup-annotations (edoc-info-features)))))

(defmacro edoc-info-assert-writable-annotations ()
  `(unless (memq 'writable-annotations (edoc-info-features))
     (error "Writing annotations is not supported by this version of kc")))

(defmacro edoc-info-assert-markup-annotations ()
  `(unless (memq 'markup-annotations (edoc-info-features))
     (error "Creating markup annotations is not supported by this version of kc")))

(defun edoc-info-creatable-annotation-types ()
  (let ((features (edoc-info-features)))
    (cond
     ((not (memq 'writable-annotations features)) nil)
     ((memq 'markup-annotations features)
      (list 'text 'squiggly 'underline 'strike-out 'highlight))
     (t (list 'text)))))

(defun edoc-info-open (&optional file-or-buffer password)
  "Open the document FILE-OR-BUFFER using PASSWORD.

Generally, documents are opened and closed automatically on
demand, so this function is rarely needed, unless a PASSWORD is
set on the document.

Manually opened documents are never closed automatically."

  (edoc-info-query
   'open (edoc-info--normalize-file-or-buffer file-or-buffer)
   password))

(defun edoc-info-close (&optional file-or-buffer)
  "Close the document FILE-OR-BUFFER.

Returns t, if the document was actually open, otherwise nil.
This command is rarely needed, see also `edoc-info-open'."
  (let* ((pdf (edoc-info--normalize-file-or-buffer file-or-buffer))
         (buffer (cond
                  ((not file-or-buffer) (current-buffer))
                  ((bufferp file-or-buffer) file-or-buffer)
                  ((stringp file-or-buffer)
                   (find-buffer-visiting file-or-buffer)))))
    (prog1
        (edoc-info-query 'close pdf)
      (if (buffer-live-p buffer)
          (with-current-buffer buffer
            (run-hooks 'edoc-info-close-document-hook))
        (with-temp-buffer
          (run-hooks 'edoc-info-close-document-hook))))))

(defun edoc-info-encrypted-p (&optional file-or-buffer)
  "Return non-nil if FILE-OR-BUFFER requires a password.

Note: This function returns nil, if the document is encrypted,
but was already opened (presumably using a password)."

  (condition-case err
      (edoc-info-open
       (edoc-info--normalize-file-or-buffer file-or-buffer))
    (error (or (string-match-p
                ":Document is encrypted\\'" (cadr err))
               (signal (car err) (cdr err))))))

(defun edoc-info-metadata (&optional file-or-buffer)
  "Extract the metadata from the document FILE-OR-BUFFER.

This returns an alist containing some information about the
document."
  (edoc-info-query
   'metadata
   (edoc-info--normalize-file-or-buffer file-or-buffer)))

(defun edoc-info-search-string (string &optional pages file-or-buffer)
  "Search for STRING in PAGES of document FILE-OR-BUFFER.

See `edoc-info-normalize-page-range' for valid PAGES formats.

This function returns a list of matches.  Each item is an alist
containing keys PAGE, TEXT and EDGES, where PAGE and TEXT are the
matched page resp. line. EDGES is a list containing a single
edges element \(LEFT TOP RIGHT BOTTOM\). This is for consistency
with `edoc-info-search-regexp', which may return matches with
multiple edges.

The TEXT contains `match' face properties on the matched parts.

Search is case-insensitive, unless `case-fold-search' is nil and
searching case-sensitive is supported by the server."

  (let ((pages (edoc-info-normalize-page-range pages)))
    (edoc-info-query
     'search-string
     (edoc-info--normalize-file-or-buffer file-or-buffer)
     (car pages)
     (cdr pages)
     string
     (if case-fold-search 1 0))))

(defvar edoc-info-regexp-compile-flags nil
  "PCRE compile flags.

Don't use this, but the equally named function.")

(defvar edoc-info-regexp-match-flags nil
  "PCRE match flags.

Don't use this, but the equally named function.")

(defun edoc-info-regexp-compile-flags ()
  (or edoc-info-regexp-compile-flags
      (let* (edoc-info-asynchronous
             (flags (edoc-info-query 'regexp-flags))
             (match (cl-remove-if-not
                     (lambda (flag)
                       (string-match-p
                        "\\`match-" (symbol-name (car flag))))
                     flags))
             (compile (cl-set-difference flags match)))
        (setq edoc-info-regexp-compile-flags compile
              edoc-info-regexp-match-flags match)
        edoc-info-regexp-compile-flags)))

(defun edoc-info-regexp-match-flags ()
  (or edoc-info-regexp-match-flags
      (progn
        (edoc-info-regexp-compile-flags)
        edoc-info-regexp-match-flags)))

(defvar edoc-info-regexp-flags '(multiline)
  "Compile- and match-flags for the PCRE engine.

This is a list of symbols denoting compile- and match-flags when
searching for regular expressions.

You should not change this directly, but rather `let'-bind it
around a call to `edoc-info-search-regexp'.

Valid compile-flags are:

newline-crlf, newline-lf, newline-cr, dupnames, optimize,
no-auto-capture, raw, ungreedy, dollar-endonly, anchored,
extended, dotall, multiline and caseless.

Note that the last one, caseless, is handled special, as it is
always added if `case-fold-search' is non-nil.

And valid match-flags:

match-anchored, match-notbol, match-noteol, match-notempty,
match-partial, match-newline-cr, match-newline-lf,
match-newline-crlf and match-newline-any.

See the glib documentation at url
`https://developer.gnome.org/glib/stable/glib-Perl-compatible-regular-expressions.html'.")

(defun edoc-info-search-regexp (pcre &optional pages
                                    no-error
                                    file-or-buffer)
  "Search for a PCRE on PAGES of document FILE-OR-BUFFER.

See `edoc-info-normalize-page-range' for valid PAGES formats and
`edoc-info-search-string' for its return value.

Uses the flags in `edoc-info-regexp-flags', which see.  If
`case-fold-search' is non-nil, the caseless flag is added.

If NO-ERROR is non-nil, catch errors due to invalid regexps and
return nil.  If it is the symbol `invalid-regexp', then re-signal
this kind of error as a `invalid-regexp' error."

  (cl-labels ((orflags (flags alist)
                (cl-reduce
                 (lambda (v flag)
                   (let ((n
                          (cdr (assq flag alist))))
                     (if n (logior n v) v)))
                 (cons 0 flags))))
    (let ((pages (edoc-info-normalize-page-range pages)))
      (condition-case err
          (edoc-info-query
           'search-regexp
           (edoc-info--normalize-file-or-buffer file-or-buffer)
           (car pages)
           (cdr pages)
           pcre
           (orflags `(,(if case-fold-search
                           'caseless)
                      ,@edoc-info-regexp-flags)
                    (edoc-info-regexp-compile-flags))
           (orflags edoc-info-regexp-flags
                    (edoc-info-regexp-match-flags)))
        (error
         (let ((re
                (concat "\\`kc: *Invalid *regexp: *"
                        ;; glib error
                        "\\(?:Error while compiling regular expression"
                        " *%s *\\)?\\(.*\\)")))
           (if (or (null no-error)
                   (not (string-match
                         (format re (regexp-quote pcre))
                         (cadr err))))
               (signal (car err) (cdr err))
             (if (eq no-error 'invalid-regexp)
                 (signal 'invalid-regexp
                         (list (match-string 1 (cadr err))))))))))))

(defun edoc-info-pagelinks (page &optional file-or-buffer)
  "Return a list of links on PAGE in document FILE-OR-BUFFER.

This function returns a list of alists with the following keys.
EDGES represents the relative bounding-box of the link , TYPE is
the type of the action, TITLE is a, possibly empty, name for this
action.

TYPE may be one of

goto-dest -- This is a internal link to some page.  Each element
contains additional keys PAGE and TOP, where PAGE is the page of
the link and TOP its vertical position.

goto-remote -- This a external link to some document.  Same as
goto-dest, with an additional FILENAME of the external PDF.

uri -- A link in form of some URI. Alist contains additional key
URI.

In the first two cases, PAGE may be 0 and TOP nil, which means
these data is unspecified."
  (cl-check-type page natnum)
  (edoc-info-query
   'pagelinks
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page))

(defun edoc-info-number-of-pages (&optional file-or-buffer)
  "Return the number of pages in document FILE-OR-BUFFER."
  (edoc-info-query 'number-of-pages
                  (edoc-info--normalize-file-or-buffer
                   file-or-buffer)))

(defun edoc-info-outline (&optional file-or-buffer)
  "Return the PDF outline of document FILE-OR-BUFFER.

This function returns a list of alists like `edoc-info-pagelinks'.
Additionally every alist has a DEPTH (>= 1) entry with the depth
of this element in the tree."

  (edoc-info-query
   'outline
   (edoc-info--normalize-file-or-buffer file-or-buffer)))

(defun edoc-info--selection-style (selection-style)
  "SELECTION-STYLE is the smallest unit of the selected region.

It must be one of glyph, word or line. If it is none of these, we
fallback to glyph."
  (cl-case selection-style
    (glyph 0)
    (word 1)
    (line 2)
    (t 0)))

(defun edoc-info-gettext (page edges &optional selection-style
                              file-or-buffer)
  "Get text on PAGE according to EDGES.

EDGES should contain relative coordinates.  The selection may
extend over multiple lines, which works similar to a Emacs
region. SELECTION-STYLE may be one of glyph, word or line and
determines the smallest unit of the selected region.

Return the text contained in the selection."

  (edoc-info-query
   'gettext
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page
   (mapconcat #'number-to-string edges " ")
   (edoc-info--selection-style selection-style)))

(defun edoc-info-getselection (page edges
                                   &optional selection-style file-or-buffer)
  "Return the edges of the selection EDGES on PAGE.

Arguments are the same as for `edoc-info-gettext'.  Return a list
of edges corresponding to the text that would be returned by the
aforementioned function, when called with the same arguments."
  (edoc-info-query
   'getselection
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page
   (mapconcat #'number-to-string edges " ")
   (edoc-info--selection-style selection-style)))

(defun edoc-info-textregions (page &optional file-or-buffer)
  "Return a list of edges describing PAGE's text-layout."
  (edoc-info-getselection
   page '(0 0 1 1) 'glyph file-or-buffer))

(defun edoc-info-charlayout (page &optional edges-or-pos file-or-buffer)
  "Return the layout of characters of PAGE in/at EDGES-OR-POS.

Returns a list of elements \(CHAR . \(LEFT TOP RIGHT BOT\)\) mapping
character to their corresponding relative bounding-boxes.

EDGES-OR-POS may be a region \(LEFT TOP RIGHT BOT\) restricting
the returned value to include only characters fully contained in
it.  Or a cons \(LEFT . TOP\) which means to only include the
character at this position.  In this case the return value
contains at most one element."

  ;; FIXME: Actually returns \(CHAR . LEFT ...\).

  (unless edges-or-pos
    (setq edges-or-pos '(0 0 1 1)))
  (when (numberp (cdr edges-or-pos))
    (setq edges-or-pos (list (car edges-or-pos)
                             (cdr edges-or-pos)
                             -1 -1)))
  (edoc-info-query
   'charlayout
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page
   (mapconcat #'number-to-string edges-or-pos " ")))

(defun edoc-info-pagesize (page &optional file-or-buffer)
  "Return the size of PAGE as a cons \(WIDTH . HEIGHT\)

The size is in PDF points."
  (edoc-info-query
   'pagesize
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page))

(defun edoc-info-running-p ()
  "Return non-nil, if the server is running."
  (and (processp (edoc-info-process))
       (eq (process-status (edoc-info-process))
           'run)))

(defun edoc-info-quit (&optional timeout)
  "Quit the kc server.

This blocks until all outstanding requests are answered.  Unless
TIMEOUT is non-nil, in which case we wait at most TIMEOUT seconds
before killing the server."
  (cl-check-type timeout (or null number))
  (when (edoc-info-running-p)
    (let ((edoc-info-asynchronous
           (if timeout (lambda (&rest _))
             edoc-info-asynchronous)))
      (edoc-info-query 'quit)
      (when timeout
        (setq timeout (+ (float-time) (max 0 timeout)))
        (while (and (edoc-info-running-p)
                    (> timeout (float-time)))
          (accept-process-output (edoc-info-process) 0.5 nil t)))))
  (when (processp (edoc-info-process))
    (tq-close edoc-info--queue))
  (setq edoc-info--queue nil))

(defun edoc-info-kill ()
  "Kill the kc server.

Immediately delete the server process, see also `edoc-info-quit',
for a more sane way to exit the program."
  (when (processp (edoc-info-process))
    (tq-close edoc-info--queue))
  (setq edoc-info--queue nil))

(defun edoc-info-getannots (&optional pages file-or-buffer)
  "Return the annotations on PAGE.

See `edoc-info-normalize-page-range' for valid PAGES formats.

This function returns the annotations for PAGES as a list of
alists.  Each element of this list describes one annotation and
contains the following keys.

page     - Its page number.
edges    - Its area.
type     - A symbol describing the annotation's type.
id       - A document-wide unique symbol referencing this annotation.
flags    - Its flags, binary encoded.
color    - Its color in standard Emacs notation.
contents - The text of this annotation.
modified - The last modification date of this annotation.

Additionally, if the annotation is a markup annotation, the
following keys are present.

label        - The annotation's label.
subject      - The subject addressed.
opacity      - The level of relative opacity.
popup-edges  - The edges of a associated popup window or nil.
popup-is-open - Whether this window should be displayed open.
created      - The date this markup annotation was created.

If the annotation is also a markup text annotation, the alist
contains the following keys.

text-icon  - A string describing the purpose of this annotation.
text-state - A string, e.g. accepted or rejected." ;FIXME: Use symbols ?

  (let ((pages (edoc-info-normalize-page-range pages)))
    (edoc-info-query
     'getannots
     (edoc-info--normalize-file-or-buffer file-or-buffer)
     (car pages)
     (cdr pages))))

(defun edoc-info-getannot (id &optional file-or-buffer)
  "Return the annotation for ID.

ID should be a symbol, which was previously returned in a
`edoc-info-getannots' query.  Signal an error, if an annotation
with ID is not available.

See `edoc-info-getannots' for the kind of return value of this
function."
  (edoc-info-query
   'getannot
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   id))

(defun edoc-info-addannot (page edges type
                               &optional selection-style file-or-buffer
                               &rest markup-edges)
  "Add a new annotation to PAGE with EDGES of TYPE.

FIXME: TYPE may be one of `text', `markup-highlight', ... .
FIXME: -1 = 24
See `edoc-info-getannots' for the kind of value of this function
returns."
  (edoc-info-assert-writable-annotations)
  (when (consp file-or-buffer)
    (push file-or-buffer markup-edges)
    (setq file-or-buffer nil))
  (apply
   #'edoc-info-query
   'addannot
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page
   type
   (edoc-info--selection-style selection-style)
   (mapconcat 'number-to-string edges " ")
   (mapcar (lambda (me)
             (mapconcat 'number-to-string me " "))
           markup-edges)))

(defun edoc-info-delannot (id &optional file-or-buffer)
  "Delete the annotation with ID in FILE-OR-BUFFER.

ID should be a symbol, which was previously returned in a
`edoc-info-getannots' query.  Signal an error, if annotation ID
does not exist."
  (edoc-info-assert-writable-annotations)
  (edoc-info-query
   'delannot
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   id))

(defun edoc-info-mvannot (id edges &optional file-or-buffer)
  "Move/Resize annotation ID to fit EDGES.

ID should be a symbol, which was previously returned in a
`edoc-info-getannots' query.  Signal an error, if annotation ID
does not exist.

EDGES should be a list \(LEFT TOP RIGHT BOT\).  RIGHT and/or BOT
may also be negative, which means to keep the width
resp. height."
  (edoc-info-editannot id `((edges . ,edges)) file-or-buffer))

(defun edoc-info-editannot (id modifications &optional file-or-buffer)
  "Edit annotation ID, applying MODIFICATIONS.

ID should be a symbol, which was previously returned in a
`edoc-info-getannots' query.

MODIFICATIONS is an alist of properties and their new values.

The server must support modifying annotations for this to work."

  (edoc-info-assert-writable-annotations)
  (let ((edits
         (mapcar
          (lambda (elt)
            (cl-case (car elt)
              (color
               (list (car elt)
                     (edoc-util-hexcolor (cdr elt))))
              (edges
               (list (car elt)
                     (mapconcat 'number-to-string (cdr elt) " ")))
              ((popup-is-open is-open)
               (list (car elt) (if (cdr elt) 1 0)))
              (t
               (list (car elt) (cdr elt)))))
          modifications)))
    (apply #'edoc-info-query
           'editannot
           (edoc-info--normalize-file-or-buffer file-or-buffer)
           id
           (apply #'append edits))))

(defun edoc-info-save (&optional file-or-buffer)
  "Save FILE-OR-BUFFER.

This saves the document to a new temporary file, which is
returned and owned by the caller."
  (edoc-info-assert-writable-annotations)
  (edoc-info-query
   'save
   (edoc-info--normalize-file-or-buffer file-or-buffer)))

(defun edoc-info-getattachment-from-annot (id &optional do-save file-or-buffer)
  "Return the attachment associated with annotation ID.

ID should be a symbol which was previously returned in a
`edoc-info-getannots' query, and referencing an attachment of type
`file', otherwise an error is signaled.

See `edoc-info-getattachments' for the kind of return value of this
function and the meaning of DO-SAVE."

  (edoc-info-query
   'getattachment-from-annot
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   id
   (if do-save 1 0)))

(defun edoc-info-getattachments (&optional do-save file-or-buffer)
  "Return all document level attachments.

If DO-SAVE is non-nil, save the attachments data to a local file,
which is then owned by the caller, see below.

This function returns a list of alists, where every element
contains the following keys.  All values, except for id, may be
nil, i.e. not present.

id          - A symbol uniquely identifying this attachment.
filename    - The filename of this attachment.
description - A description of this attachment.
size        - The size in bytes.
modified    - The last modification date.
created     - The date of creation.
checksum    - A MD5 checksum of this attachment's data.
file        - The name of a tempfile containing the data (only present if
              DO-SAVE is non-nil)."

  (edoc-info-query
   'getattachments
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   (if do-save 1 0)))

(defun edoc-info-synctex-forward-search (source &optional line column file-or-buffer)
  "Perform a forward search with synctex.

SOURCE should be a LaTeX buffer or the absolute filename of a
corresponding file.  LINE and COLUMN represent the position in
the buffer or file.  Finally FILE-OR-BUFFER corresponds to the
PDF document.

Returns an alist with entries PAGE and relative EDGES describing
the position in the PDF document corresponding to the SOURCE
location."

  (let ((source (if (buffer-live-p (get-buffer source))
                    (buffer-file-name (get-buffer source))
                  source)))
    (edoc-info-query
     'synctex-forward-search
     (edoc-info--normalize-file-or-buffer file-or-buffer)
     source
     (or line 1)
     (or column 1))))

(defun edoc-info-synctex-backward-search (page &optional x y file-or-buffer)
  "Perform a backward search with synctex.

Find the source location corresponding to the coordinates
\(X . Y\) on PAGE in FILE-OR-BUFFER.

Returns an alist with entries FILENAME, LINE and COLUMN."


  (edoc-info-query
   'synctex-backward-search
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page
   (or x 0)
   (or y 0)))

(defun edoc-info-renderpage (page width &optional file-or-buffer &rest commands)
  "Render PAGE with width WIDTH.

Return the data of the corresponding PNG image."
  (when (keywordp file-or-buffer)
    (push file-or-buffer commands)
    (setq file-or-buffer nil))
  (apply #'edoc-info-query
    'renderpage
    (edoc-info--normalize-file-or-buffer file-or-buffer)
    page
    (* width (edoc-util-frame-scale-factor))
    (let (transformed)
      (while (cdr commands)
        (let ((kw (pop commands))
              (value (pop commands)))
          (setq value
                (cl-case kw
                  ((:crop-to :highlight-line :highlight-region :highlight-text)
                   (mapconcat #'number-to-string value " "))
                  ((:foreground :background)
                   (edoc-util-hexcolor value))
                  (:alpha
                   (number-to-string value))
                  (:selection-style
                   (number-to-string (edoc-info--selection-style value)))
                  (otherwise value)))
          (push kw transformed)
          (push value transformed)))
      (when commands
        (error "Keyword is missing a value: %s" (car commands)))
      (nreverse transformed))))

(defun edoc-info-renderpage-text-regions (page width single-line-p
                                              &optional selection-style file-or-buffer
                                              &rest regions)
  "Highlight text on PAGE with width WIDTH using REGIONS.

REGIONS is a list determining foreground and background color and
the regions to render. So each element should look like \(FG BG
\(LEFT TOP RIGHT BOT\) \(LEFT TOP RIGHT BOT\) ... \) . The
rendering is text-aware and is controlled by SELECTION-STYLE.

If SINGLE-LINE-P is non-nil, the edges in REGIONS are each
supposed to be limited to a single line in the document.  Setting
this, if applicable, avoids rendering problems.

For the other args see `edoc-info-renderpage'.

Return the data of the corresponding PNG image."

  (when (consp file-or-buffer)
    (push file-or-buffer regions)
    (setq file-or-buffer nil))

  (apply #'edoc-info-renderpage
    page width file-or-buffer
    (apply #'append
      `(:selection-style ,selection-style)
      (mapcar (lambda (elt)
                `(:foreground ,(pop elt)
                  :background ,(pop elt)
                  ,@(cl-mapcan (lambda (edges)
                                 `(,(if single-line-p
                                        :highlight-line
                                      :highlight-text)
                                   ,edges))
                               elt)))
              regions))))

(defun edoc-info-renderpage-highlight (page width
                                           &optional file-or-buffer
                                           &rest regions)
  "Highlight regions on PAGE with width WIDTH using REGIONS.

REGIONS is a list determining the background color, a alpha value
and the regions to render. So each element should look like \(FILL-COLOR
STROKE-COLOR ALPHA \(LEFT TOP RIGHT BOT\) \(LEFT TOP RIGHT BOT\) ... \)
.

For the other args see `edoc-info-renderpage'.

Return the data of the corresponding PNG image."

  (when (consp file-or-buffer)
    (push file-or-buffer regions)
    (setq file-or-buffer nil))

  (apply #'edoc-info-renderpage
    page width file-or-buffer
    (apply #'append
      (mapcar (lambda (elt)
                `(:background ,(pop elt)
                  :foreground ,(pop elt)
                  :alpha ,(pop elt)
                  ,@(cl-mapcan (lambda (edges)
                                 `(:highlight-region ,edges))
                               elt)))
              regions))))

(defun edoc-info-boundingbox (page &optional file-or-buffer)
  "Return a bounding-box for PAGE.

Returns a list \(LEFT TOP RIGHT BOT\)."

  (edoc-info-query
   'boundingbox
   (edoc-info--normalize-file-or-buffer file-or-buffer)
   page))

(defun edoc-info-getoptions (&optional file-or-buffer)
  (edoc-info-query
   'getoptions
   (edoc-info--normalize-file-or-buffer file-or-buffer)))

(defun edoc-info-setoptions (&optional file-or-buffer &rest options)
  (when (symbolp file-or-buffer)
    (push file-or-buffer options)
    (setq file-or-buffer nil))
  (unless (= (% (length options) 2) 0)
    (error "Missing a option value"))
  (apply #'edoc-info-query
    'setoptions
    (edoc-info--normalize-file-or-buffer file-or-buffer)
    (let (soptions)
      (while options
        (let ((key (pop options))
              (value (pop options)))
          (unless (and (keywordp key)
                       (not (eq key :)))
            (error "Keyword expected: %s" key))
          (cl-case key
            ((:render/foreground :render/background)
             (push (edoc-util-hexcolor value)
                   soptions))
            ((:render/printed)
             (push (if value 1 0) soptions))
            ((:render/usecolors)
             ;; 0 -> original color
             ;; 1 -> recolor document to grayscale mapping black to
             ;;      :render/foreground and white to :render/background
             ;; 2 -> recolor document by inverting the perceived lightness
             ;;      preserving hue
             (push (if (and (integerp value) (> 3 value 0)) value 0)
                   soptions))
            (t (push value soptions)))
          (push key soptions)))
      soptions)))



(defun edoc-info-pagelabels (&optional file-or-buffer)
  "Return a list of pagelabels.

Returns a list of strings corresponding to the labels of the
pages in FILE-OR-BUFFER."

  (edoc-info-query
   'pagelabels
   (edoc-info--normalize-file-or-buffer file-or-buffer)))

(defun edoc-info-ping (&optional message)
  "Ping the server using MESSAGE.

Returns MESSAGE, which defaults to \"pong\"."
  (edoc-info-query 'ping (or message "pong")))

(provide 'edoc-info)

;;; edoc-info.el ends here
