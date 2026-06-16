;;; b4x-nav.el --- B4X symbol table + xref/capf/imenu/eldoc backends -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Builds an in-memory symbol table for a B4X project (Subs, Types, and globals
;; declared inside Process_Globals / Globals / Class_Globals) by scanning the
;; project's resolved module files plus the embedded Main source.
;;
;; Exposes native Emacs intelligence backends:
;;   * `b4x-imenu-index'              -> imenu
;;   * `b4x-completion-at-point'      -> completion-at-point
;;   * `b4x-xref-backend' + methods   -> xref (definitions + references)
;;   * `b4x-eldoc-function'           -> eldoc
;;
;; The parser is a port of the VSCode extension's `fileSymbolParser.js'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'imenu)
(require 'xref)
(require 'b4x-project)


;;; Symbol table

(cl-defstruct (b4x-sym (:type list))
  "A B4X symbol."
  name kind file line visibility)

(cl-defstruct b4x-symtab
  "Symbol table for a B4X project."
  project                        ; the b4x-project this table was built from
  (by-name (make-hash-table :test 'equal)) ; downcased name -> list of b4x-sym
  files)                         ; list of files indexed (host paths, incl. main)

(defconst b4x-nav--global-sections
  '("process_globals" "globals" "class_globals")
  "Sub names whose bodies hold global declarations.")

(defconst b4x-nav--sub-re
  (rx line-start (* space)
      (optional (or "Public" "Private") (+ space))
      "Sub" (+ space)
      (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_")))))
  "Regexp matching a `Sub NAME' header (with optional visibility).")

(defconst b4x-nav--type-re
  (rx line-start (* space) "Type" (+ space)
      (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_")))))
  "Regexp matching a `Type NAME' declaration.")

(defconst b4x-nav--end-sub-re
  (rx line-start (* space) "End" (+ space) "Sub" word-boundary)
  "Regexp matching `End Sub'.")

(defconst b4x-nav--decl-re
  (rx line-start (* space)
      (or "Dim" "Public" "Private") (+ space)
      (group (+ nonl)))
  "Regexp matching a top-level Dim/Public/Private declaration line.")

(defun b4x-nav--declared-names (tail)
  "Extract declared identifier names from a declaration TAIL.
Splits on commas and takes the first identifier of each segment,
never mistreating `As' as a name."
  (let (names)
    (dolist (part (split-string tail ","))
      (when (string-match (rx (* space) (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_"))))) part)
        (let ((n (match-string 1 part)))
          (when (and n (not (string-empty-p n)))
            (push n names)))))
    (nreverse names)))

(defun b4x-nav--parse-source (text file)
  "Parse TEXT (from FILE) into a list of `b4x-sym' structs.  Lines are 1-based."
  (let ((lines (split-string text "\r?\n"))
        (syms nil)
        (in-globals nil))
    (cl-loop for i from 1 for line in lines do
             (cond
              ;; Sub header.
              ((string-match b4x-nav--sub-re line)
               (let ((name (match-string 1 line))
                     (vis (b4x-nav--visibility line)))
                 (if (member (downcase name) b4x-nav--global-sections)
                     (setq in-globals t)
                   (setq in-globals nil)
                   (push (make-b4x-sym :name name :kind 'sub
                                       :file file :line i :visibility vis)
                         syms))))
              ;; End Sub closes a globals section.
              ((string-match b4x-nav--end-sub-re line)
               (setq in-globals nil))
              ;; Type declaration.
              ((string-match b4x-nav--type-re line)
               (push (make-b4x-sym :name (match-string 1 line) :kind 'type
                                   :file file :line i)
                     syms))
              ;; Global variable declarations.
              (in-globals
               (when (string-match b4x-nav--decl-re line)
                 (dolist (n (b4x-nav--declared-names (match-string 1 line)))
                   (push (make-b4x-sym :name n :kind 'variable
                                       :file file :line i)
                         syms))))))
    (nreverse syms)))

(defun b4x-nav--visibility (line)
  "Return the visibility keyword (`public'/`private'/`default') from a Sub LINE."
  (cond
   ((string-match (rx line-start (* space) "Public") line) 'public)
   ((string-match (rx line-start (* space) "Private") line) 'private)
   (t 'default)))

(defun b4x-nav--add-sym (tab sym)
  "Add SYM to table TAB, keyed by its downcased name."
  (let ((key (downcase (b4x-sym-name sym))))
    (puthash key (cons sym (gethash key (b4x-symtab-by-name tab) nil))
             (b4x-symtab-by-name tab))))

(defun b4x-nav--index-file (tab file)
  "Index FILE into TAB.  Returns non-nil if the file was readable."
  (when (file-readable-p file)
    (let ((text (with-temp-buffer
                  (insert-file-contents file)
                  (buffer-string))))
      (dolist (s (b4x-nav--parse-source text file))
        (b4x-nav--add-sym tab s))
      t)))

(defun b4x-nav-build-table (project)
  "Build a fresh `b4x-symtab' for PROJECT (resolved modules + embedded Main)."
  (let ((tab (make-b4x-symtab :project project))
        (files nil))
    ;; Resolved module files.
    (dolist (m (b4x-project-modules project))
      (when (b4x-nav--index-file tab m)
        (push m files)))
    ;; Embedded Main code as a virtual module (the project file itself).
    (let ((main (b4x-project-main-code project))
          (pf (b4x-project-project-file project)))
      (when (and main (not (string-empty-p main)))
        (dolist (s (b4x-nav--parse-source main pf))
          (b4x-nav--add-sym tab s))
        (push pf files)))
    (setf (b4x-symtab-files tab) (nreverse files))
    tab))

(defun b4x-nav-lookup (tab name)
  "Return all symbols named NAME (case-insensitive) in TAB."
  (gethash (downcase name) (b4x-symtab-by-name tab) nil))

(defun b4x-nav-all-names (tab)
  "Return a list of all distinct symbol names in TAB."
  (let (names)
    (maphash (lambda (_k syms)
               (dolist (s syms) (push (b4x-sym-name s) names)))
             (b4x-symtab-by-name tab))
    names))


;;; Project + table lookup (cache)

(defvar b4x-nav--table-cache nil
  "Cons (PROJECT-FILE . SYMTAB) caching the last built symbol table.")

(defun b4x-nav-current-project ()
  "Return the `b4x-project' for the current buffer, or nil.

Looks for a project file by walking up from the buffer's file (or its
platform subfolder)."
  (let* ((buf-file (or (buffer-file-name) default-directory))
         (proj-file (b4x-nav--locate-project-file buf-file)))
    (when proj-file
      (b4x-load-project proj-file))))

(defun b4x-nav--locate-project-file (start)
  "Walk up from START to find a B4X project file, or nil."
  (let ((dir (if (file-directory-p start) start (file-name-directory start)))
        (seen nil))
    (catch 'found
      (while (and dir (not (member dir seen)))
        (push dir seen)
        ;; Project file directly in this dir.
        (dolist (f (directory-files dir t "\\`[^.].*\\.b4[aijr]\\'" t))
          (throw 'found f))
        ;; Project file in a platform subfolder (B4J/, B4A/, ...).
        (dolist (sub '("B4J" "B4A" "B4i" "B4R"))
          (let ((d (expand-file-name sub dir)))
            (when (file-directory-p d)
              (dolist (f (directory-files d t "\\`[^.].*\\.b4[aijr]\\'" t))
                (throw 'found f)))))
        (let ((parent (file-name-directory (directory-file-name dir))))
          (when (or (null parent) (string= parent dir)) (cl-return nil))
          (setq dir (directory-file-name parent))))
      nil)))

(defun b4x-nav-table (&optional no-cache)
  "Return the symbol table for the current buffer's project.

Uses a per-project-file cache; pass NO-CACHE to force a rebuild."
  (when-let ((proj (b4x-nav-current-project)))
    (let ((pf (b4x-project-project-file proj)))
      (if (and (not no-cache)
               (eq (car b4x-nav--table-cache) pf))
          (cdr b4x-nav--table-cache)
        (let ((tab (b4x-nav-build-table proj)))
          (setq b4x-nav--table-cache (cons pf tab))
          tab)))))

(defun b4x-nav--clear-cache ()
  "Forget the cached symbol table (e.g. after editing)."
  (setq b4x-nav--table-cache nil))


;;; Word at point

(defun b4x-nav--symbol-at-point ()
  "Return the B4X symbol name at point, or nil."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (and bounds (buffer-substring-no-properties
                 (car bounds) (cdr bounds)))))


;;; xref backend

(defconst b4x-xref-backend 'b4x
  "Identifier for the B4X xref backend.")

(cl-defmethod xref-backend-interface ((_backend (eql b4x)))
  "Return the list of xref capabilities for the B4X backend."
  '(:definitions :references))

(cl-defmethod xref-backend-definitions ((_backend (eql b4x)) _identifier)
  "Return xref items defining the symbol at point."
  (when-let ((tab (b4x-nav-table)))
    (when-let ((name (b4x-nav--symbol-at-point)))
      (mapcar #'b4x-nav--sym->xref (b4x-nav-lookup tab name)))))

(cl-defmethod xref-backend-references ((_backend (eql b4x)) _identifier)
  "Return xref items referencing the symbol at point across project modules."
  (when-let ((tab (b4x-nav-table)))
    (when-let ((name (b4x-nav--symbol-at-point)))
      (b4x-nav--find-references tab name))))

(defun b4x-nav--sym->xref (sym)
  "Convert a `b4x-sym' SYM into an xref item."
  (xref-make (b4x-sym-name sym)
             (xref-make-file-location (b4x-sym-file sym)
                                      (b4x-sym-line sym) 0)))

(defun b4x-nav--find-references (tab name)
  "Scan indexed files in TAB for word-boundary occurrences of NAME."
  (let ((re (concat "\\_<" (regexp-quote name) "\\_>"))
        (lower (downcase name))
        items)
    (dolist (file (b4x-symtab-files tab))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward re nil t)
            (let ((line (line-number-at-pos))
                  (col (- (match-end 0) (line-beginning-position))))
              (unless (b4x-nav--in-string-or-comment-p)
                (push (xref-make
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))
                       (xref-make-file-location file line col))
                      items)))))))
    ;; Also flag definition sites so xref shows where it is declared.
    (dolist (sym (b4x-nav-lookup tab lower))
      (push (b4x-nav--sym->xref sym) items))
    (nreverse items)))

(defun b4x-nav--in-string-or-comment-p ()
  "Non-nil if point is inside a B4X string literal or comment."
  (let ((bol (line-beginning-position)))
    (save-excursion
      (or (nth 3 (syntax-ppss))                 ; string
          (let ((line (buffer-substring-no-properties bol (point))))
            (or (string-match-p (rx (or "'" "//")) line)
                (string-match-p (rx "'") line)))))))


;;; completion-at-point

(defun b4x-completion-at-point ()
  "B4X completion candidates (project symbols + keywords)."
  (when-let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when (derived-mode-p 'b4x-mode)
      (let ((beg (car bounds))
            (end (cdr bounds)))
        (when-let ((tab (b4x-nav-table)))
          (list beg end
                (append (b4x-nav-all-names tab) b4x-nav--keywords)
                :company-kind (lambda (_c) 'function)))))))

(defconst b4x-nav--keywords
  '("Sub" "End Sub" "End If" "If" "Then" "Else" "Else If"
    "For" "Next" "Do" "Loop" "While" "Dim" "As" "Return"
    "Private" "Public" "Type" "End Type" "Select" "Case"
    "Try" "Catch" "End Try" "Exit" "Continue" "True" "False" "Null")
  "Built-in B4X keywords offered alongside project symbols.")


;;; imenu

(defun b4x-imenu-index ()
  "Return an imenu index for the current B4X buffer (Subs + Types + Globals).

imenu is per-buffer; this indexes only the file currently visited."
  (when (derived-mode-p 'b4x-mode)
    (let* ((file (or (buffer-file-name) default-directory))
           (syms (b4x-nav--parse-source (buffer-string) file))
           (subs nil) (types nil) (globals nil))
      (dolist (s syms)
        (let ((entry (cons (b4x-sym-name s)
                           (b4x-nav--line-pos (b4x-sym-line s)))))
          (pcase (b4x-sym-kind s)
            ('sub (push entry subs))
            ('type (push entry types))
            ('variable (push entry globals)))))
      (delq nil
            (list (when subs (cons "Subs" (nreverse subs)))
                  (when types (cons "Types" (nreverse types)))
                  (when globals (cons "Globals" (nreverse globals))))))))

(defun b4x-nav--line-pos (line)
  "Return the buffer position at the start of LINE (1-based) in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))


;;; eldoc

(defun b4x-eldoc-function ()
  "Return an eldoc string for the Sub at point, or nil."
  (when-let ((name (b4x-nav--symbol-at-point)))
    (when-let ((tab (b4x-nav-table)))
      (when-let ((syms (b4x-nav-lookup tab name)))
        (let ((s (car syms)))
          (when (eq (b4x-sym-kind s) 'sub)
            (b4x-nav--sub-signature s)))))))

(defun b4x-nav--sub-signature (sym)
  "Return a one-line signature for Sub SYM from its source file."
  (when (file-readable-p (b4x-sym-file sym))
    (with-temp-buffer
      (insert-file-contents (b4x-sym-file sym))
      (goto-char (point-min))
      (forward-line (1- (b4x-sym-line sym)))
      (string-trim (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))))))

(provide 'b4x-nav)
;;; b4x-nav.el ends here
