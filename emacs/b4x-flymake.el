;;; b4x-flymake.el --- Flymake diagnostics for B4X -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Native `flymake' backend for B4X.  Ports the diagnostics that the VSCode
;; extension's LSP server published (`server/server.js' :: publishDiagnostics):
;;
;;   1. Duplicate-symbol detection across modules.  A non-private symbol
;;      defined in more than one file is the classic B4X footgun — the compiler
;;      may resolve to the wrong one.  Flagged as a warning.
;;
;;   2. Type-placement heuristic.  A `Type' must live inside Class_Globals or
;;      Process_Globals; we look back a few lines for such a section header.
;;      Flagged as a warning (heuristic).
;;
;; The current buffer's symbols are parsed from the LIVE buffer text (so
;; diagnostics reflect unsaved edits); every other file's symbols come from the
;; cached project symbol table (`b4x-nav-table').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'flymake)
(require 'b4x-nav)
(require 'b4x-project)

(defcustom b4x-flymake-duplicate-symbols t
  "If non-nil, warn about symbols defined in more than one module."
  :group 'b4x
  :type 'boolean)

(defcustom b4x-flymake-type-placement t
  "If non-nil, warn about `Type' declarations outside Class/Process_Globals."
  :group 'b4x
  :type 'boolean)

(defconst b4x-flymake--lookback 6
  "Lines to scan backwards when locating an enclosing globals section.")


;;; Backend entry point

;;;###autoload
(defun b4x-flymake (report-fn &rest _args)
  "B4X flymake backend.  Collects diagnostics and reports them via REPORT-FN.

Never raises: on any error it reports an empty list so flymake keeps working."
  (condition-case _err
      (funcall report-fn (b4x-flymake--collect))
    (error
     (funcall report-fn nil))))

(defun b4x-flymake--collect ()
  "Return a list of flymake diagnostics for the current B4X buffer."
  (if (or (not (derived-mode-p 'b4x-mode))
          (not (b4x-nav-current-project)))
      nil
    (let* ((this-file (or (buffer-file-name) default-directory))
           (live-syms (b4x-nav--parse-source (buffer-string) this-file))
           (disk-tab  (b4x-nav-table))
           (lines     (split-string (buffer-string) "\n"))
           diags)
      (when b4x-flymake-duplicate-symbols
        (dolist (d (b4x-flymake--dup-diagnostics live-syms this-file disk-tab))
          (push d diags)))
      (when b4x-flymake-type-placement
        (dolist (d (b4x-flymake--type-diagnostics live-syms lines))
          (push d diags)))
      (nreverse diags))))


;;; Duplicate-symbol detection (pure + testable)

(defun b4x-flymake--dup-diagnostics (live-syms this-file disk-tab)
  "Return flymake diagnostics for LIVE-SYMS duplicated in other files.

LIVE-SYMS are the current buffer's symbols.  THIS-FILE is the buffer's path.
DISK-TAB is the project symbol table (for symbols in OTHER files)."
  (let (diags)
    (dolist (s live-syms)
      ;; Skip private subs — they are intentionally module-local.
      (unless (b4x-flymake--private-sub-p s)
        (let ((others (b4x-flymake--foreign-dups s this-file disk-tab)))
          (when others
            (when-let ((span (b4x-flymake--name-span
                              (b4x-sym-line s) (b4x-sym-name s))))
              (push (flymake-make-diagnostic
                     (current-buffer) (car span) (cdr span) :warning
                     (format "Symbol '%s' is also defined in other files (%s)"
                             (b4x-sym-name s)
                             (mapconcat #'b4x-sym-file others ", ")))
                    diags))))))
    (nreverse diags)))

(defun b4x-flymake--foreign-dups (sym this-file disk-tab)
  "Return symbols with the same name as SYM in files other than THIS-FILE.

Excludes private subs and same-file matches.  DISK-TAB supplies the others."
  (delq nil
        (mapcar
         (lambda (o)
           (cond
            ((b4x-flymake--private-sub-p o) nil)
            ((b4x-flymake--same-file-p (b4x-sym-file o) this-file) nil)
            (t o)))
         (b4x-nav-lookup disk-tab (b4x-sym-name sym)))))

(defun b4x-flymake--same-file-p (a b)
  "Non-nil if paths A and B refer to the same file.
Compares normalized paths; uses `file-equal-p' when both exist (handles symlinks)."
  (let ((na (expand-file-name a)) (nb (expand-file-name b)))
    (or (equal na nb)
        (and (file-exists-p a) (file-exists-p b) (file-equal-p a b)))))

(defun b4x-flymake--private-sub-p (sym)
  "Non-nil if SYM is a `private' Sub."
  (and (eq (b4x-sym-kind sym) 'sub)
       (eq (b4x-sym-visibility sym) 'private)))


;;; Type-placement heuristic (pure + testable)

(defun b4x-flymake--type-diagnostics (live-syms lines)
  "Return flymake diagnostics for misplaced `Type' declarations.

LIVE-SYMS are the current buffer's symbols; LINES is the buffer split by line.
Looks back `b4x-flymake--lookback' lines for a Class_Globals/Process_Globals
header; flags the Type if none is found."
  (let (diags)
    (dolist (s live-syms)
      (when (eq (b4x-sym-kind s) 'type)
        (unless (b4x-flymake--inside-globals-p (b4x-sym-line s) lines)
          (when-let ((span (b4x-flymake--name-span
                            (b4x-sym-line s) (b4x-sym-name s))))
            (push (flymake-make-diagnostic
                   (current-buffer) (car span) (cdr span) :warning
                   (format "Type '%s' appears outside Class_Globals/Process_Globals (heuristic)"
                           (b4x-sym-name s)))
                  diags)))))
    (nreverse diags)))

(defun b4x-flymake--inside-globals-p (line lines)
  "Non-nil if LINE (1-based) sits inside a Class_Globals/Process_Globals block.
Scans LINES backwards up to `b4x-flymake--lookback'."
  (let ((start (max 0 (- line b4x-flymake--lookback 1)))
        (i 0)
        (found nil))
    (setq i start)
    (while (and (not found) (< i line))
      (let ((l (nth i lines)))
        (when (and l
                   (string-match-p
                    (rx line-start (* space) "Sub" (+ space)
                        (or "Class_Globals" "Process_Globals"))
                    l))
          (setq found t)))
      (setq i (1+ i)))
    found))


;;; Position helpers

(defun b4x-flymake--name-span (line name)
  "Return (BEG . END) for the first occurrence of NAME on LINE in this buffer.
Returns nil if NAME is not found on LINE (e.g. the buffer shifted)."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- line))
      (let ((eol (line-end-position)))
        (when (re-search-forward (regexp-quote name) eol t)
          (cons (match-beginning 0) (match-end 0)))))))

(provide 'b4x-flymake)
;;; b4x-flymake.el ends here
