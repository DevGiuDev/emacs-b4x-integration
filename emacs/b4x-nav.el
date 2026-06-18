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

(cl-defstruct b4x-nav-b4xlib-index
  "Indexed contents of one `.b4xlib' archive."
  library
  extract-dir
  module-files                  ; alist of (module-name . extracted .bas path)
  symtab)

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

(defvar b4x-nav--b4xlib-cache (make-hash-table :test 'equal)
  "Cache of indexed `.b4xlib' archives, keyed by path + mtime.")

(defvar b4x-nav--type-candidates-cache (make-hash-table :test 'equal)
  "Cache of contextual type member candidates keyed by project + type.")

(defvar b4x-nav--type-names-cache (make-hash-table :test 'equal)
  "Cache of type-name completions keyed by project file.")

(defvar b4x-nav--b4xlib-symbol-index-cache (make-hash-table :test 'equal)
  "Cache of per-project `.b4xlib' completion/doc indexes.")

(defconst b4x-nav--implicit-platform-libraries
  '((b4j . ("jCore"))
    (b4a . ("Core"))
    (b4i . ("iCore")))
  "Platform libraries that are implicitly available for completion.")

(defconst b4x-nav--builtin-type-names
  '("String" "Int" "Long" "Double" "Float" "Boolean" "Byte" "Short"
    "Char" "Object" "Map" "List" "Array" "Byte()" "String()" "Object()")
  "Builtin B4X type names offered after `As'.")

(defconst b4x-nav--builtin-type-members
  '(("string" . ("CharAt" "CompareTo" "Contains" "EndsWith" "IndexOf"
                  "LastIndexOf" "Length" "Replace" "ReplaceAll" "Split"
                  "StartsWith" "SubString" "SubString2" "ToLowerCase"
                  "ToUpperCase" "Trim"))
    ("string()" . ("Length"))
    ("byte()" . ("Length"))
    ("object()" . ("Length"))
    ("array" . ("Length"))
    ("list" . ("Add" "AddAll" "Clear" "Get" "IndexOf" "Initialize"
                "InsertAt" "IsInitialized" "RemoveAt" "Set" "Size"
                "Sort" "SortCaseInsensitive" "SortType"))
    ("map" . ("Clear" "ContainsKey" "Get" "GetDefault" "Initialize"
               "IsInitialized" "Keys" "Put" "PutAll" "Remove" "Size"
               "Values")))
  "Builtin member candidates for core B4X types not covered by XML libs.")

(defun b4x-nav--b4xlib-cache-key (library)
  "Return the cache key for b4xlib LIBRARY." 
  (let* ((path (b4x-library-path library))
         (attrs (file-attributes path))
         (mtime (and attrs (file-attribute-modification-time attrs))))
    (format "%s::%s" path mtime)))

(defun b4x-nav--b4xlib-root-dir ()
  "Return the temp root used to extract `.b4xlib' archives."
  (expand-file-name "b4x-b4xlib" temporary-file-directory))

(defun b4x-nav--b4xlib-extract-dir (library)
  "Return the extraction directory for b4xlib LIBRARY."
  (expand-file-name (md5 (b4x-nav--b4xlib-cache-key library))
                    (b4x-nav--b4xlib-root-dir)))

(defun b4x-nav--ensure-b4xlib-extracted (library)
  "Extract b4xlib LIBRARY to a temp directory and return that directory."
  (unless (executable-find "unzip")
    (user-error "`unzip' is required to index .b4xlib archives"))
  (let ((dir (b4x-nav--b4xlib-extract-dir library)))
    (unless (file-directory-p dir)
      (make-directory dir t)
      (with-temp-buffer
        (unless (eq 0 (call-process "unzip" nil t nil
                                    "-o" "-q"
                                    (b4x-library-path library)
                                    "-d" dir))
          (error "Failed to extract %s: %s"
                 (b4x-library-path library)
                 (string-trim (buffer-string))))))
    dir))

(defun b4x-nav--index-b4xlib (library)
  "Return a cached index for b4xlib LIBRARY, or nil."
  (when (and (eq (b4x-library-kind library) 'b4xlib)
             (file-readable-p (b4x-library-path library)))
    (let ((key (b4x-nav--b4xlib-cache-key library)))
      (or (gethash key b4x-nav--b4xlib-cache)
          (let* ((dir (b4x-nav--ensure-b4xlib-extracted library))
                 (files (directory-files-recursively dir "\\.bas\\'" t))
                 (tab (make-b4x-symtab))
                 (module-files nil))
            (dolist (file files)
              (when (b4x-nav--index-file tab file)
                (push file (b4x-symtab-files tab))
                (push (cons (file-name-base file) file) module-files)))
            (setf (b4x-symtab-files tab) (nreverse (b4x-symtab-files tab)))
            (let ((index (make-b4x-nav-b4xlib-index
                          :library library
                          :extract-dir dir
                          :module-files (nreverse module-files)
                          :symtab tab)))
              (puthash key index b4x-nav--b4xlib-cache)
              index))))))

(defun b4x-nav--project-b4xlib-indices (project)
  "Return indexed `.b4xlib' archives referenced by PROJECT." 
  (delq nil
        (mapcar (lambda (name)
                  (when-let ((lib (b4x-project-find-available-library project name)))
                    (ignore-errors (b4x-nav--index-b4xlib lib))))
                (b4x-project-libraries project))))

(defun b4x-nav--project-b4xlib-candidates (project)
  "Return completion candidates contributed by PROJECT's `.b4xlib' libraries." 
  (plist-get (b4x-nav--b4xlib-symbol-index project) :candidates))

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
          (if (or (null parent) (string= parent dir))
              (setq dir nil)
            (setq dir (directory-file-name parent)))))
      nil)))

(defun b4x-nav-table (&optional no-cache)
  "Return the symbol table for the current buffer's project.

Uses a per-project-file cache; pass NO-CACHE to force a rebuild."
  (when-let ((proj (b4x-nav-current-project)))
    (let ((pf (b4x-project-project-file proj)))
      (if (and (not no-cache)
               (equal (car b4x-nav--table-cache) pf))
          (cdr b4x-nav--table-cache)
        (let ((tab (b4x-nav-build-table proj)))
          (setq b4x-nav--table-cache (cons pf tab))
          tab)))))

(defun b4x-nav--clear-cache ()
  "Forget cached navigation/index tables (e.g. after editing)."
  (setq b4x-nav--table-cache nil)
  (setq b4x-nav--b4xlib-cache (make-hash-table :test 'equal))
  (setq b4x-nav--type-candidates-cache (make-hash-table :test 'equal))
  (setq b4x-nav--type-names-cache (make-hash-table :test 'equal))
  (setq b4x-nav--b4xlib-symbol-index-cache (make-hash-table :test 'equal)))


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

(defun b4x-nav--line-text-at (file line)
  "Return the text at LINE in FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (forward-line (1- line))
      (string-trim (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))))))

(defun b4x-nav--b4xlib-index-stamp (index)
  "Return a cache stamp for b4xlib INDEX."
  (let* ((lib (b4x-nav-b4xlib-index-library index))
         (path (and lib (b4x-library-path lib)))
         (attrs (and path (file-attributes path)))
         (mtime (and attrs (file-attribute-modification-time attrs))))
    (list path mtime)))

(defun b4x-nav--b4xlib-symbol-index (project)
  "Return cached `.b4xlib' completion/doc index for PROJECT."
  (let* ((indices (b4x-nav--project-b4xlib-indices project))
         (key (list (b4x-project-project-file project)
                    (b4x-project-libraries project)
                    (mapcar #'b4x-nav--b4xlib-index-stamp indices))))
    (or (gethash key b4x-nav--b4xlib-symbol-index-cache)
        (let ((infos (make-hash-table :test 'equal))
              candidates)
          (dolist (index indices)
            (dolist (module (b4x-nav-b4xlib-index-module-files index))
              (let ((name (car module)))
                (push name candidates)
                (push (list :kind 'module
                            :name name
                            :file (cdr module)
                            :library (b4x-nav-b4xlib-index-library index)
                            :signature (format "%s (b4xlib module)" name))
                      (gethash (downcase name) infos))))
            (maphash
             (lambda (_key syms)
               (dolist (sym syms)
                 (let ((name (b4x-sym-name sym)))
                   (push name candidates)
                   (push (list :kind (b4x-sym-kind sym)
                               :name name
                               :file (b4x-sym-file sym)
                               :line (b4x-sym-line sym)
                               :library (b4x-nav-b4xlib-index-library index)
                               :signature (pcase (b4x-sym-kind sym)
                                            ('sub (b4x-nav--sub-signature sym))
                                            (_ (b4x-nav--line-text-at
                                                (b4x-sym-file sym)
                                                (b4x-sym-line sym)))))
                         (gethash (downcase name) infos)))))
             (b4x-symtab-by-name (b4x-nav-b4xlib-index-symtab index))))
          (maphash (lambda (name entries)
                     (puthash name (nreverse entries) infos))
                   infos)
          (let ((index (list :candidates (delete-dups (delq nil candidates))
                             :infos infos)))
            (puthash key index b4x-nav--b4xlib-symbol-index-cache)
            index)))))

(defun b4x-nav--b4xlib-symbol-infos (project name)
  "Return `.b4xlib' metadata entries matching NAME in PROJECT." 
  (copy-sequence
   (gethash (downcase name)
            (plist-get (b4x-nav--b4xlib-symbol-index project) :infos))))

(defun b4x-nav--b4xlib-symbol-info (project name)
  "Return the first `.b4xlib' metadata entry for NAME in PROJECT." 
  (car (b4x-nav--b4xlib-symbol-infos project name)))

(defun b4x-nav--b4xlib-symbol-annotation (project name)
  "Return a short completion annotation for b4xlib symbol NAME." 
  (when-let ((info (b4x-nav--b4xlib-symbol-info project name)))
    (format " [b4xlib:%s]" (plist-get info :kind))))

(defun b4x-nav--b4xlib-symbol-doc (project name &optional multiline)
  "Return documentation string for b4xlib symbol NAME, or nil." 
  (when-let ((info (b4x-nav--b4xlib-symbol-info project name)))
    (let* ((sig (plist-get info :signature))
           (lib (plist-get info :library))
           (libname (and lib (b4x-library-name lib)))
           (module (and (plist-get info :file)
                        (file-name-base (plist-get info :file)))))
      (string-join
       (delq nil (list sig
                       (and libname multiline (format "Library: %s" libname))
                       (and module multiline (format "Module: %s" module))))
       (if multiline "\n" " — ")))))

(defun b4x-nav--symbol-before-position (pos)
  "Return the symbol immediately before POS, or nil."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward "A-Za-z0-9_")
    (let ((beg (point)))
      (and (< beg pos)
           (buffer-substring-no-properties beg pos)))))

(defun b4x-nav--type-context-p (beg)
  "Non-nil when BEG starts a type name position like `As Foo'."
  (save-excursion
    (goto-char beg)
    (let ((prefix (buffer-substring-no-properties (line-beginning-position) beg)))
      (string-match-p (rx bow "As" (* space) eos) prefix))))

(defun b4x-nav--completion-context ()
  "Return a plist describing completion context at point.

Keys include `:beg', `:end', and optionally `:receiver' for `obj.member'
contexts.  Supports an empty prefix immediately after `.'."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (cond
     ((and bounds (> (car bounds) (point-min))
           (eq (char-before (car bounds)) ?.))
      (list :beg (car bounds)
            :end (cdr bounds)
            :receiver (b4x-nav--symbol-before-position (1- (car bounds)))))
     ((eq (char-before) ?.)
      (list :beg (point)
            :end (point)
            :receiver (b4x-nav--symbol-before-position (1- (point)))))
     (bounds
      (list :beg (car bounds) :end (cdr bounds))))))

(defun b4x-nav--type-from-decl-tail (name tail)
  "Infer NAME's type from declaration TAIL, or nil.
Handles common initializers such as `Dim M As Map = CreateMap()'."
  (let ((case-fold-search t)
        (needle (downcase name))
        found)
    (dolist (part (split-string tail "," t))
      (let ((trimmed (string-trim part)))
        (when (and (null found)
                   (string-match
                    (rx bos (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_"))))
                        (* space) "As" (+ space)
                        (group (+ (any "A-Za-z0-9_.()")))
                        (or eos (and (+ space) (* nonl)) (and (* space) "=" (* nonl))))
                    trimmed)
                   (string= (downcase (match-string 1 trimmed)) needle))
          (setq found (match-string 2 trimmed)))))
    (or found
        (when (string-match
               (rx bos (* space) (group (+ nonl)) (+ space) "As" (+ space)
                   (group (+ (any "A-Za-z0-9_.()")))
                   (or eos (and (+ space) (* nonl)) (and (* space) "=" (* nonl))))
               tail)
          (let ((names (split-string (match-string 1 tail) "," t "[[:space:]]*"))
                (type (match-string 2 tail)))
            (when (member needle
                          (mapcar (lambda (s) (downcase (string-trim s))) names))
              type))))))

(defun b4x-nav--type-from-sub-params (name line)
  "Infer NAME's type from Sub parameter LINE, or nil."
  (let ((case-fold-search t))
    (when (and line (string-match (rx "(" (group (* nonl)) ")") line))
      (let ((params (match-string 1 line))
            (needle (downcase name))
            found)
        (dolist (part (split-string params "," t))
          (let ((trimmed (string-trim part)))
            (when (and (null found)
                       (string-match
                        (rx bos (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_"))))
                            (* space) "As" (+ space)
                            (group (+ (any "A-Za-z0-9_.()"))))
                        trimmed)
                       (string= (downcase (match-string 1 trimmed)) needle))
              (setq found (match-string 2 trimmed)))))
        found))))

(defun b4x-nav--infer-receiver-type (receiver)
  "Infer the B4X type of RECEIVER in the current buffer, or nil."
  (let ((case-fold-search t)
        (found nil))
    (save-excursion
      (goto-char (point-min))
      (while (and (not found)
                  (re-search-forward
                   (rx line-start (* space)
                       (or "Dim" "Public" "Private") (+ space)
                       (group (+ nonl)))
                   nil t))
        (setq found (b4x-nav--type-from-decl-tail receiver (match-string 1))))
      (goto-char (point-min))
      (while (and (not found)
                  (re-search-forward b4x-nav--sub-re nil t))
        (setq found (b4x-nav--type-from-sub-params
                     receiver
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))))
    (or found
        (when (string-match-p (rx bos (any "A-Z") (* (any "A-Za-z0-9_")) eos)
                              receiver)
          receiver))))

(defun b4x-nav--current-sub-bounds ()
  "Return `(START . END)' for the current Sub, or nil."
  (save-excursion
    (when (re-search-backward b4x-nav--sub-re nil t)
      (let ((start (line-beginning-position)))
        (when (re-search-forward b4x-nav--end-sub-re nil t)
          (cons start (line-end-position)))))))

(defun b4x-nav--sub-parameter-names (line)
  "Return parameter names declared in Sub header LINE."
  (let (names)
    (when (and line (string-match (rx "(" (group (* nonl)) ")") line))
      (dolist (part (split-string (match-string 1 line) "," t))
        (let ((trimmed (string-trim part)))
          (when (string-match
                 (rx bos (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_")))))
                 trimmed)
            (push (match-string 1 trimmed) names)))))
    (nreverse names)))

(defun b4x-nav--current-scope-local-candidates ()
  "Return parameter and local variable names visible in the current Sub."
  (when-let ((bounds (b4x-nav--current-sub-bounds)))
    (let ((start (car bounds))
          (end (cdr bounds))
          names)
      (save-excursion
        (goto-char start)
        (let ((header-line (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))))
          (setq names (append (b4x-nav--sub-parameter-names header-line) names)))
        (goto-char start)
        (while (re-search-forward
                (rx line-start (* space) "Dim" (+ space) (group (+ nonl)))
                end t)
          (setq names (append (b4x-nav--declared-names (match-string 1)) names))))
      (delete-dups (delq nil names)))))

(defun b4x-nav--current-buffer-symbol-candidates ()
  "Return live symbol candidates from the current buffer, including locals." 
  (let* ((file (or (buffer-file-name) default-directory))
         (syms (b4x-nav--parse-source (buffer-string) file)))
    (delete-dups
     (append (mapcar #'b4x-sym-name syms)
             (b4x-nav--current-scope-local-candidates)))))

(defun b4x-nav--project-type-names (project tab)
  "Return type/module names available to PROJECT and TAB."
  (let ((key (b4x-project-project-file project)))
    (or (gethash key b4x-nav--type-names-cache)
        (let (names)
          (setq names (append b4x-nav--builtin-type-names names))
          (dolist (file (b4x-symtab-files tab))
            (push (file-name-base file) names))
          (maphash (lambda (_k syms)
                     (dolist (sym syms)
                       (when (eq (b4x-sym-kind sym) 'type)
                         (push (b4x-sym-name sym) names))))
                   (b4x-symtab-by-name tab))
          (dolist (api (append (b4x-project-library-apis project)
                               (b4x-nav--implicit-library-apis project)))
            (dolist (class (b4x-library-api-classes api))
              (when (b4x-library-class-shortname class)
                (push (b4x-library-class-shortname class) names))))
          (dolist (index (b4x-nav--project-b4xlib-indices project))
            (dolist (module (b4x-nav-b4xlib-index-module-files index))
              (push (car module) names)))
          (setq names (delete-dups (delq nil names)))
          (puthash key names b4x-nav--type-names-cache)
          names))))

(defun b4x-nav--implicit-library-apis (project)
  "Return implicitly available XML library APIs for PROJECT."
  (let ((names (alist-get (b4x-project-platform project)
                          b4x-nav--implicit-platform-libraries)))
    (delq nil
          (mapcar (lambda (name)
                    (when-let ((lib (b4x-project-find-available-library project name)))
                      (b4x-project-parse-library-api lib)))
                  names))))

(defun b4x-nav--normalize-type-name (type-name)
  "Return a normalized key for TYPE-NAME used in member lookup."
  (when type-name
    (downcase (string-trim type-name))))

(defun b4x-nav--builtin-type-candidates (type-name)
  "Return builtin member candidates for TYPE-NAME, or nil."
  (copy-sequence
   (alist-get (b4x-nav--normalize-type-name type-name)
              b4x-nav--builtin-type-members nil nil #'string=)))

(defun b4x-nav--project-type-candidates (tab type-name)
  "Return project candidates for TYPE-NAME from the current symtab TAB."
  (let ((needle (b4x-nav--normalize-type-name type-name))
        out)
    (dolist (file (b4x-symtab-files tab))
      (when (string= (downcase (file-name-base file)) needle)
        (setq out (append (mapcar #'b4x-sym-name
                                  (b4x-nav--parse-source
                                   (with-temp-buffer
                                     (insert-file-contents file)
                                     (buffer-string))
                                   file))
                          out))))
    (delete-dups (delq nil out))))

(defun b4x-nav--xml-type-candidates (project type-name)
  "Return library XML member candidates for TYPE-NAME in PROJECT."
  (let ((needle (b4x-nav--normalize-type-name type-name))
        out)
    (dolist (api (append (b4x-project-library-apis project)
                         (b4x-nav--implicit-library-apis project)))
      (dolist (class (b4x-library-api-classes api))
        (when (and (b4x-library-class-shortname class)
                   (string= (downcase (b4x-library-class-shortname class)) needle))
          (setq out (append (b4x-library-class-methods class)
                            (b4x-library-class-properties class)
                            out)))))
    (delete-dups (delq nil out))))

(defun b4x-nav--b4xlib-type-candidates (project type-name)
  "Return `.b4xlib' member candidates for TYPE-NAME in PROJECT."
  (let ((needle (b4x-nav--normalize-type-name type-name))
        out)
    (dolist (index (b4x-nav--project-b4xlib-indices project))
      (dolist (module (b4x-nav-b4xlib-index-module-files index))
        (when (string= (downcase (car module)) needle)
          (setq out (append (mapcar #'b4x-sym-name
                                    (b4x-nav--parse-source
                                     (with-temp-buffer
                                       (insert-file-contents (cdr module))
                                       (buffer-string))
                                     (cdr module)))
                            out)))))
    (delete-dups (delq nil out))))

(defun b4x-nav--contextual-candidates (project tab receiver)
  "Return contextual completion candidates for RECEIVER, or nil."
  (when-let ((type-name (b4x-nav--infer-receiver-type receiver)))
    (let ((key (list (b4x-project-project-file project)
                     (b4x-nav--normalize-type-name type-name))))
      (or (gethash key b4x-nav--type-candidates-cache)
          (let ((cands (delete-dups
                        (append (b4x-nav--builtin-type-candidates type-name)
                                (b4x-nav--xml-type-candidates project type-name)
                                (b4x-nav--b4xlib-type-candidates project type-name)
                                (b4x-nav--project-type-candidates tab type-name)))))
            (puthash key cands b4x-nav--type-candidates-cache)
            cands)))))

(defun b4x-completion-at-point ()
  "B4X completion candidates (global, type-aware, or contextual after `.`)."
  (when-let ((ctx (b4x-nav--completion-context)))
    (when (derived-mode-p 'b4x-mode)
      (let ((beg (plist-get ctx :beg))
            (end (plist-get ctx :end)))
        (when-let* ((tab (b4x-nav-table))
                    (project (b4x-symtab-project tab)))
          (let* ((receiver (plist-get ctx :receiver))
                 (candidates
                  (cond
                   (receiver
                    (b4x-nav--contextual-candidates project tab receiver))
                   ((b4x-nav--type-context-p beg)
                    (b4x-nav--project-type-names project tab))
                   (t
                    (delete-dups
                     (append (b4x-nav--current-buffer-symbol-candidates)
                             (b4x-nav-all-names tab)
                             (b4x-project-library-completion-candidates project)
                             (b4x-nav--project-b4xlib-candidates project)
                             b4x-nav--keywords))))))
            (when candidates
              (list beg end
                    candidates
                    :category 'b4x
                    :annotation-function
                    (lambda (cand)
                      (or (b4x-project-library-symbol-annotation project cand)
                          (b4x-nav--b4xlib-symbol-annotation project cand)))
                    :company-doc-buffer
                    (lambda (cand)
                      (when-let ((doc (or (b4x-project-library-symbol-doc project cand t)
                                          (b4x-nav--b4xlib-symbol-doc project cand t))))
                        (with-current-buffer (get-buffer-create " *b4x-capf-doc*")
                          (erase-buffer)
                          (insert doc)
                          (current-buffer))))
                    :company-kind (lambda (_c) 'function)))))))))

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

(defun b4x-eldoc-function (&optional callback)
  "Eldoc backend: show project or library XML docs for the symbol at point.

Follows the `eldoc-documentation-functions' protocol (Emacs 28+): when
CALLBACK is passed we call it with the docstring; otherwise we return the
string (for older callers)."
  (when-let ((doc (b4x-eldoc--doc-string)))
    (if callback
        (funcall callback doc :thing (b4x-nav--symbol-at-point))
      doc)))

(defun b4x-eldoc--doc-string ()
  "Return the best eldoc string at point from project or library metadata."
  (or (b4x-eldoc--sub-string)
      (b4x-eldoc--library-string)
      (b4x-eldoc--b4xlib-string)))

(defun b4x-eldoc--sub-string ()
  "Return the signature string of the project Sub at point, or nil."
  (when-let ((name (b4x-nav--symbol-at-point)))
    (when-let ((tab (b4x-nav-table)))
      (when-let ((syms (b4x-nav-lookup tab name)))
        (let ((s (car syms)))
          (when (eq (b4x-sym-kind s) 'sub)
            (b4x-nav--sub-signature s)))))))

(defun b4x-eldoc--library-string ()
  "Return one-line library XML documentation for the symbol at point, or nil."
  (when-let ((name (b4x-nav--symbol-at-point)))
    (when-let* ((tab (b4x-nav-table))
                (project (b4x-symtab-project tab)))
      (b4x-project-library-symbol-doc project name))))

(defun b4x-eldoc--b4xlib-string ()
  "Return one-line `.b4xlib' documentation for the symbol at point, or nil."
  (when-let ((name (b4x-nav--symbol-at-point)))
    (when-let* ((tab (b4x-nav-table))
                (project (b4x-symtab-project tab)))
      (b4x-nav--b4xlib-symbol-doc project name))))

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
