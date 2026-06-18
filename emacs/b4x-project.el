;;; b4x-project.el --- B4X project model (.b4j/.b4a parsing, module resolution) -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Pure-data model of a B4X project.  Parses the header of a `.b4j'/`.b4a' file
;; (everything up to `@EndOfDesignText@'), resolves `ModuleN=' entries to real
;; host files, collects `LibraryN=' references, and extracts the embedded
;; "Main" code so navigation can index it.
;;
;; Depends on `b4x-wine' for path translation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'dom)
(require 'xml)
(require 'b4x-wine)


;;; Types

(cl-defstruct b4x-project
  "Parsed model of a B4X project."
  project-file              ; absolute host path of the .b4j/.b4a
  project-dir               ; directory containing the project file (platform folder)
  root-dir                  ; logical project root (parent of a B4J/B4A folder, else project-dir)
  platform                  ; `b4j' or `b4a'
  app-type                  ; string ("StandardJava"/"JavaFX"/...) or nil
  version                   ; string or nil
  header                    ; alist of raw KEY . VALUE (ordered)
  libraries                 ; list of library names (as written)
  module-specs              ; list of raw (kind . path) as declared
  modules                   ; list of resolved module host paths
  external-modules          ; subset of MODULES outside ROOT-DIR
  shared-modules-folder     ; host path or nil
  ini-path                  ; b4xV5.ini path if known, else nil
  main-code)                ; source after @EndOfDesignText@ (string, may be "")

(cl-defstruct b4x-library
  "Library discovered in a core or Additional Libs folder."
  name                      ; display name / header value candidate
  canonical-name            ; downcased `name' for case-insensitive lookup
  source                    ; `core' or `additional'
  kind                      ; `xml', `jar', `aar', or `b4xlib'
  path)                     ; absolute host path of the backing artifact

(cl-defstruct b4x-library-parameter
  "One parameter declared in a library XML method/property."
  name
  type)

(cl-defstruct b4x-library-member
  "One method/property/event declared in a library XML class."
  name
  kind                      ; `method', `property', or `event'
  signature                 ; raw/signature text when directly available
  returntype
  parameters                ; list of `b4x-library-parameter'
  comment)

(cl-defstruct b4x-library-class
  "API metadata for one wrapper class declared by a B4X library XML."
  shortname                 ; B4X-facing short type name
  full-name                 ; JVM class name
  objectwrapper             ; wrapped implementation class, if any
  comment                   ; class comment/docstring
  owner                     ; B4X owner scope, if any
  methods                   ; list of method names
  properties                ; list of property names
  events                    ; list of event names
  method-details            ; list of `b4x-library-member'
  property-details          ; list of `b4x-library-member'
  event-details)            ; list of `b4x-library-member'

(cl-defstruct b4x-library-api
  "Parsed API metadata for one B4X library."
  library                   ; `b4x-library' source object
  xml-path                  ; XML file used as metadata source
  version                   ; library version string, if any
  author                    ; author string, if any
  classes)                  ; list of `b4x-library-class'

(cl-defstruct b4x-library-pom
  "Parsed Maven POM metadata discovered in library folders."
  path
  source                    ; `core' or `additional'
  group-id
  artifact-id
  version
  packaging
  name
  description)

(defconst b4x-project--platform-exts
  '(("b4j" . b4j) ("b4a" . b4a) ("b4i" . b4i) ("b4r" . b4r))
  "Project-file extension -> platform symbol.")

(defconst b4x-project--platform-folders
  '("B4J" "B4A" "B4i" "B4R")
  "Folder names that denote a platform subfolder of a B4X project root.")

(defconst b4x-project--library-exts '("xml" "jar" "aar" "b4xlib")
  "Library artifact extensions scanned in core / Additional Libs folders.")

(defconst b4x-project--library-kind-priority
  '((b4xlib . 4) (xml . 3) (aar . 2) (jar . 1))
  "Preference order when several artifacts resolve to the same library name.")

(defvar b4x-project--library-api-cache (make-hash-table :test 'equal)
  "Cache of parsed library XML metadata, keyed by absolute XML path.")

(defvar b4x-project--available-libraries-cache (make-hash-table :test 'equal)
  "Cache of scanned library folders keyed by folder paths and mtimes.")

(defvar b4x-project--library-symbol-index-cache (make-hash-table :test 'equal)
  "Cache of per-project library XML symbol indexes.")

(defvar b4x-project--library-pom-cache (make-hash-table :test 'equal)
  "Cache of parsed Maven POM metadata, keyed by absolute POM path.")

(defun b4x-project-clear-caches ()
  "Clear cached library/project metadata."
  (setq b4x-project--library-api-cache (make-hash-table :test 'equal))
  (setq b4x-project--available-libraries-cache (make-hash-table :test 'equal))
  (setq b4x-project--library-symbol-index-cache (make-hash-table :test 'equal))
  (setq b4x-project--library-pom-cache (make-hash-table :test 'equal)))


;;; Helpers

(defun b4x-project--platform-for-file (file)
  "Return the platform symbol for FILE, or nil."
  (let ((ext (downcase (or (file-name-extension file) ""))))
    (cdr (assoc ext b4x-project--platform-exts))))

(defun b4x-project-file-p (file)
  "Non-nil if FILE is a B4X project file (.b4j/.b4a/.b4i/.b4r)."
  (if-let ((ext (file-name-extension file)))
      (assoc (downcase ext) b4x-project--platform-exts)
    nil))

(defun b4x-project-root-of-dir (dir)
  "If DIR is a platform folder, return its parent; else return DIR."
  (let ((base (file-name-nondirectory (directory-file-name dir))))
    (if (member base b4x-project--platform-folders)
        (file-name-directory (directory-file-name dir))
      dir)))

(defun b4x-project-root-from-file (project-file)
  "Compute the logical project root for PROJECT-FILE."
  (directory-file-name
   (b4x-project-root-of-dir (file-name-directory project-file))))


;;; Header parsing

(defconst b4x-project--design-marker "@EndOfDesignText@"
  "Marker separating the project header from the embedded Main source.")

(defun b4x-project--parse-header (text)
  "Return (HEADER-ALIST . MAIN-CODE) parsed from TEXT."
  (let* ((marker-pos (string-match (regexp-quote b4x-project--design-marker) text))
         (header-text (if marker-pos (substring text 0 marker-pos) text))
         (main-text (if marker-pos
                        (substring text (match-end 0))
                      ""))
         (entries nil))
    (dolist (line (split-string header-text "\r?\n" t))
      (let ((trimmed (string-trim line)))
        ;; Strip a possible BOM / leading garbage.
        (when (string-prefix-p "﻿" trimmed)
          (setq trimmed (substring trimmed 1)))
        (when (and (not (string-prefix-p ";" trimmed))
                   (not (string-prefix-p "#" trimmed))
                   (string-match-p "=" trimmed))
          (let ((sep (string-match "=" trimmed)))
            (let ((key (string-trim (substring trimmed 0 sep)))
                  (val (string-trim (substring trimmed (1+ sep)))))
              ;; Strip surrounding quotes.
              (when (and (> (length val) 1)
                         (= (aref val 0) ?\")
                         (= (aref val (1- (length val))) ?\"))
                (setq val (substring val 1 -1)))
              (unless (string-empty-p val)
                (push (cons key val) entries)))))))
    (cons (nreverse entries) main-text)))

(defun b4x-project--index-value (prefix entry-key)
  "Return the numeric suffix of ENTRY-KEY (e.g. \"Module3\") for PREFIX, or nil."
  (when (string-match (rx-to-string
                        `(and bos ,(regexp-quote prefix)
                              (group (one-or-more digit)) eos))
                      entry-key)
    (string-to-number (match-string 1 entry-key))))

(defun b4x-project--collect-numbered (prefix header)
  "Return values of `<PREFIX>N' entries in HEADER, ordered by N."
  (let (collected)
    (dolist (entry header)
      (let ((n (b4x-project--index-value prefix (car entry))))
        (when n (push (cons n (cdr entry)) collected))))
    (mapcar #'cdr (sort collected (lambda (a b) (< (car a) (car b)))))))

(defun b4x-project--first-value (key header)
  "Return the value for the exact KEY in HEADER, or nil."
  (cdr (assoc key header)))


;;; Module spec parsing + resolution

(defun b4x-project--parse-module-spec (value)
  "Parse a `ModuleN=' VALUE into (KIND . PATH).
KIND is one of `relative', `absolute', `shared', or `plain'."
  (if (string-match
       (rx bos "|"
           (group (or "relative" "absolute" "shared"))
           "|" (group (* nonl)))
       value)
      (let ((kind (intern (downcase (match-string 1 value))))
            (rest (string-trim (match-string 2 value))))
        (cons kind rest))
    (cons 'plain (string-trim value))))

(defun b4x-project--resolve-existing (candidate)
  "Return CANDIDATE if it exists as a file, else CANDIDATE+\".bas\", else nil."
  (cond
   ((and candidate (file-regular-p candidate)) (expand-file-name candidate))
   ((and candidate (file-regular-p (concat candidate ".bas")))
    (expand-file-name (concat candidate ".bas")))
   (t nil)))

(defun b4x-project--resolve-module (spec project-dir shared-folder)
  "Resolve module SPEC against PROJECT-DIR (and optional SHARED-FOLDER)."
  (pcase-let ((`(,kind . ,p) spec))
    (cond
     ;; Absolute / Windows path: translate to host.
     ((or (eq kind 'absolute)
          (and p (b4x-windows-path-p p)))
      (b4x-wine-path-to-host p project-dir))
     ;; Shared: resolve against shared modules folder.
     ((eq kind 'shared)
      (when shared-folder
        (b4x-project--resolve-existing
         (b4x--join-path shared-folder p))))
     ;; Relative / plain: resolve against the project file's directory.
     (t
      (b4x-project--resolve-existing
       (b4x--join-path project-dir p))))))

(defun b4x--join-path (base rel)
  "Join REL onto BASE, accepting both `/ ' and `\\' separators in REL."
  (let ((segs (split-string rel (rx (one-or-more (or "/" "\\"))) t)))
    (expand-file-name (mapconcat #'identity segs "/") base)))


;;; Loading

;;;###autoload
(defun b4x-load-project (project-file &optional ini-path shared-modules-folder)
  "Load and return a `b4x-project' for PROJECT-FILE.

PROJECT-FILE is the host path of a `.b4j'/`.b4a' file.  When INI-PATH is nil
the platform `b4xV5.ini' is auto-discovered (if Wine is active).  SHARED-MODULES-FOLDER
overrides the shared modules folder from the INI."
  (unless (file-regular-p project-file)
    (error "B4X project file not found: %s" project-file))
  (let* ((platform (or (b4x-project--platform-for-file project-file)
                       (error "Not a B4X project file: %s" project-file)))
         (project-dir (file-name-directory project-file))
         (text (with-temp-buffer
                 (insert-file-contents project-file)
                 (buffer-string)))
         (parsed (b4x-project--parse-header text))
         (header (car parsed))
         (main-code (cdr parsed))
         (ini (or ini-path
                  (when (b4x-wine-active-p)
                    (b4x-find-wine-ini platform))))
         (ini-folders (when ini (b4x-ini-folders ini)))
         (shared-folder (or shared-modules-folder
                            (cdr (assq 'shared-modules-folder ini-folders))))
         (raw-module-values (b4x-project--collect-numbered "Module" header))
         (module-specs (mapcar #'b4x-project--parse-module-spec raw-module-values))
         (modules (delq nil
                        (mapcar (lambda (spec)
                                  (b4x-project--resolve-module
                                   spec project-dir shared-folder))
                                module-specs)))
         (root-dir (b4x-project-root-from-file project-file))
         (external-modules (delq nil
                                 (mapcar (lambda (m)
                                           (unless (string-prefix-p
                                                    (file-name-as-directory root-dir)
                                                    m)
                                             m))
                                         modules))))
    (make-b4x-project
     :project-file (expand-file-name project-file)
     :project-dir (directory-file-name project-dir)
     :root-dir root-dir
     :platform platform
     :app-type (b4x-project--first-value "AppType" header)
     :version (b4x-project--first-value "Version" header)
     :header header
     :libraries (b4x-project--collect-numbered "Library" header)
     :module-specs module-specs
     :modules modules
     :external-modules external-modules
     :shared-modules-folder shared-folder
     :ini-path ini
     :main-code main-code)))


;;; Minimal INI reader (folders only)

(defun b4x-ini-folders (ini-path)
  "Read INI-PATH and return an alist of translated folder keys.

Keys: `libraries-folder', `additional-libraries-folder',
`shared-modules-folder', `platform-folder', `javac-path', `java-bin'."
  (let ((entries (b4x-ini-read ini-path)))
    (list (b4x-ini--folder-entry 'libraries-folder "librariesfolder" entries)
          (b4x-ini--folder-entry 'additional-libraries-folder "additionallibrariesfolder" entries)
          (b4x-ini--folder-entry 'shared-modules-folder "sharedmodulesfolder" entries)
          (b4x-ini--folder-entry 'platform-folder "platformfolder" entries)
          (b4x-ini--folder-entry 'javac-path "javacpath" entries)
          (b4x-ini--folder-entry 'java-bin "javabin" entries))))

(defun b4x-ini--folder-entry (key ini-key entries)
  "Return (KEY . translated-host-path) for INI-KEY from ENTRIES."
  (cons key (b4x-wine-path-to-host (cdr (assoc ini-key entries)))))

(defun b4x-ini-read (ini-path)
  "Read INI-PATH into an alist of (DOWNCASED-KEY . VALUE)."
  (unless (file-regular-p ini-path)
    (error "INI file not found: %s" ini-path))
  (let (entries)
    (with-temp-buffer
      (insert-file-contents ini-path)
      (dolist (line (split-string (buffer-string) "\r?\n" t))
        (let ((trimmed (string-trim line)))
          (when (string-prefix-p "﻿" trimmed)
            (setq trimmed (substring trimmed 1)))
          (when (and (not (string-prefix-p ";" trimmed))
                     (not (string-prefix-p "#" trimmed))
                     (string-match-p "=" trimmed))
            (let ((sep (string-match "=" trimmed)))
              (let ((key (downcase (string-trim (substring trimmed 0 sep))))
                    (val (string-trim (substring trimmed (1+ sep)))))
                (when (and (> (length val) 1)
                           (= (aref val 0) ?\")
                           (= (aref val (1- (length val))) ?\"))
                  (setq val (substring val 1 -1)))
                (unless (string-empty-p val)
                  (push (cons key val) entries))))))))
    (nreverse entries)))


;;; Libraries

(defun b4x-project-library-dirs (project)
  "Return an alist of library directories known for PROJECT.

Keys are `core' and `additional'.  Values are absolute host paths or nil."
  (let* ((folders (and (b4x-project-ini-path project)
                       (b4x-ini-folders (b4x-project-ini-path project))))
         (core (or (cdr (assq 'libraries-folder folders))
                   (when-let ((install (and (b4x-wine-active-p)
                                            (b4x-find-wine-install-dir
                                             (b4x-project-platform project)))))
                     (expand-file-name "Libraries" install))))
         (additional (cdr (assq 'additional-libraries-folder folders))))
    (list (cons 'core core)
          (cons 'additional additional))))

(defun b4x-project--library-kind-rank (kind)
  "Return numeric preference for library KIND."
  (or (cdr (assq kind b4x-project--library-kind-priority)) 0))

(defun b4x-project--scan-library-dir (dir source)
  "Return libraries discovered in DIR for SOURCE.

Only top-level `.xml', `.jar', `.aar', and `.b4xlib' files are considered."
  (let ((table (make-hash-table :test 'equal)))
    (when (and dir (file-directory-p dir))
      (dolist (file (directory-files dir t "^[^.]" t))
        (when (file-regular-p file)
          (let ((ext (downcase (or (file-name-extension file) ""))))
            (when (member ext b4x-project--library-exts)
              (let* ((name (file-name-base file))
                     (canonical (downcase name))
                     (kind (intern ext))
                     (lib (make-b4x-library :name name
                                            :canonical-name canonical
                                            :source source
                                            :kind kind
                                            :path file))
                     (prev (gethash canonical table)))
                (when (or (null prev)
                          (> (b4x-project--library-kind-rank kind)
                             (b4x-project--library-kind-rank
                              (b4x-library-kind prev))))
                  (puthash canonical lib table))))))))
    (let (out)
      (maphash (lambda (_ lib) (push lib out)) table)
      (sort out (lambda (a b)
                  (string< (b4x-library-canonical-name a)
                           (b4x-library-canonical-name b)))))))

(defun b4x-project--library-dir-stamp (entry)
  "Return a cache stamp for library directory ENTRY.
ENTRY has the shape (SOURCE . DIR)."
  (pcase-let ((`(,source . ,dir) entry))
    (let* ((attrs (and dir (file-directory-p dir) (file-attributes dir)))
           (mtime (and attrs (file-attribute-modification-time attrs))))
      (list source dir mtime))))

(defun b4x-project-available-libraries (project)
  "Return libraries available to PROJECT from core and Additional Libs.

When the same library exists in both places, the Additional Libs entry wins.
Directory scans are cached and invalidated automatically when the library
folder mtimes change."
  (let* ((dirs (b4x-project-library-dirs project))
         (cache-key (mapcar #'b4x-project--library-dir-stamp dirs)))
    (or (gethash cache-key b4x-project--available-libraries-cache)
        (let ((table (make-hash-table :test 'equal)))
          (dolist (entry dirs)
            (pcase-let ((`(,source . ,dir) entry))
              (dolist (lib (b4x-project--scan-library-dir dir source))
                (let ((key (b4x-library-canonical-name lib))
                      (prev (gethash (b4x-library-canonical-name lib) table)))
                  (when (or (null prev)
                            (eq (b4x-library-source lib) 'additional))
                    (puthash key lib table))))))
          (let (out)
            (maphash (lambda (_ lib) (push lib out)) table)
            (setq out (sort out (lambda (a b)
                                  (string< (b4x-library-canonical-name a)
                                           (b4x-library-canonical-name b)))))
            (puthash cache-key out b4x-project--available-libraries-cache)
            out)))))

(defun b4x-project-find-available-library (project name)
  "Return the available library named NAME for PROJECT, or nil.

Lookup is case-insensitive."
  (let ((needle (downcase name)))
    (seq-find (lambda (lib)
                (string= (b4x-library-canonical-name lib) needle))
              (b4x-project-available-libraries project))))

(defun b4x-project-library-xml-path (library)
  "Return the XML metadata path associated with LIBRARY, or nil."
  (when library
    (pcase (b4x-library-kind library)
      ('xml (b4x-library-path library))
      (_ (let ((candidate (concat (file-name-sans-extension
                                   (b4x-library-path library))
                                  ".xml")))
           (and (file-regular-p candidate) candidate))))))

(defun b4x-project--dom-direct-children (node tag)
  "Return direct child DOM nodes of NODE matching TAG."
  (seq-filter (lambda (child)
                (and (listp child)
                     (eq (dom-tag child) tag)))
              (dom-children node)))

(defun b4x-project--dom-direct-child-text (node tag)
  "Return trimmed text of NODE's first direct child TAG, or nil."
  (when-let ((child (car (b4x-project--dom-direct-children node tag))))
    (string-trim (dom-text child))))

(defun b4x-project--dom-tag-local-name (node)
  "Return the local XML tag name of NODE as a string, or nil."
  (when-let ((tag (and (listp node) (dom-tag node))))
    (let ((s (format "%s" tag)))
      (if (string-match (rx (group (+ (not (any ":}")))) eos) s)
          (match-string 1 s)
        s))))

(defun b4x-project--dom-direct-children-local (node local-name)
  "Return direct child DOM nodes of NODE matching LOCAL-NAME.

LOCAL-NAME is compared against the XML local tag name, ignoring namespaces."
  (seq-filter (lambda (child)
                (and (listp child)
                     (string= (b4x-project--dom-tag-local-name child)
                              local-name)))
              (dom-children node)))

(defun b4x-project--dom-direct-child-text-local (node local-name)
  "Return trimmed text of NODE's first direct child LOCAL-NAME, or nil."
  (when-let ((child (car (b4x-project--dom-direct-children-local
                          node local-name))))
    (string-trim (dom-text child))))

(defun b4x-project--library-event-name (text)
  "Extract the event name from TEXT, or nil."
  (when (and text
             (string-match (rx bos (group (+ (any "A-Za-z_")
                                             (* (any "A-Za-z0-9_")))))
                           text))
    (match-string 1 text)))

(defun b4x-project--friendly-type-name (type)
  "Return a short display name for TYPE."
  (when type
    (let ((trimmed (string-trim type)))
      (if (string-match (rx (group (+ (not (any "." "$")))) eos) trimmed)
          (match-string 1 trimmed)
        trimmed))))

(defun b4x-project--parse-library-parameter (node)
  "Parse one XML parameter NODE into `b4x-library-parameter'."
  (make-b4x-library-parameter
   :name (b4x-project--dom-direct-child-text node 'name)
   :type (b4x-project--dom-direct-child-text node 'type)))

(defun b4x-project--parse-library-member (node kind)
  "Parse one XML library member NODE of KIND."
  (let ((signature (string-trim (dom-text node))))
    (make-b4x-library-member
     :name (or (b4x-project--dom-direct-child-text node 'name)
               (and (eq kind 'event)
                    (b4x-project--library-event-name signature)))
     :kind kind
     :signature (unless (string-empty-p signature) signature)
     :returntype (b4x-project--dom-direct-child-text node 'returntype)
     :parameters (mapcar #'b4x-project--parse-library-parameter
                         (b4x-project--dom-direct-children node 'parameter))
     :comment (b4x-project--dom-direct-child-text node 'comment))))

(defun b4x-project--parse-library-class (node)
  "Parse one library XML class NODE into `b4x-library-class'."
  (let* ((method-details (delq nil
                               (mapcar (lambda (method)
                                         (b4x-project--parse-library-member method 'method))
                                       (b4x-project--dom-direct-children node 'method))))
         (property-details (delq nil
                                 (mapcar (lambda (property)
                                           (b4x-project--parse-library-member property 'property))
                                         (b4x-project--dom-direct-children node 'property))))
         (event-details (delq nil
                              (mapcar (lambda (event)
                                        (b4x-project--parse-library-member event 'event))
                                      (b4x-project--dom-direct-children node 'event)))))
    (make-b4x-library-class
     :shortname (b4x-project--dom-direct-child-text node 'shortname)
     :full-name (b4x-project--dom-direct-child-text node 'name)
     :objectwrapper (b4x-project--dom-direct-child-text node 'objectwrapper)
     :comment (b4x-project--dom-direct-child-text node 'comment)
     :owner (b4x-project--dom-direct-child-text node 'owner)
     :methods (delete-dups (delq nil (mapcar #'b4x-library-member-name method-details)))
     :properties (delete-dups (delq nil (mapcar #'b4x-library-member-name property-details)))
     :events (delete-dups (delq nil (mapcar #'b4x-library-member-name event-details)))
     :method-details method-details
     :property-details property-details
     :event-details event-details)))

(defun b4x-project--parse-xml-root (xml-path)
  "Parse XML-PATH and return its DOM root node."
  (with-temp-buffer
    (insert-file-contents xml-path)
    (let ((parsed (if (fboundp 'libxml-parse-xml-region)
                      (libxml-parse-xml-region (point-min) (point-max))
                    (xml-parse-region (point-min) (point-max)))))
      (if (and (listp parsed)
               (not (eq (car-safe parsed) 'root))
               (listp (car-safe parsed)))
          (car parsed)
        parsed))))

(defun b4x-project-parse-library-api (library)
  "Parse XML metadata for LIBRARY and return a `b4x-library-api', or nil."
  (when-let ((xml-path (b4x-project-library-xml-path library)))
    (or (gethash xml-path b4x-project--library-api-cache)
        (let* ((root (b4x-project--parse-xml-root xml-path))
               (api (make-b4x-library-api
                     :library library
                     :xml-path xml-path
                     :version (b4x-project--dom-direct-child-text root 'version)
                     :author (b4x-project--dom-direct-child-text root 'author)
                     :classes (delq nil
                                    (mapcar #'b4x-project--parse-library-class
                                            (b4x-project--dom-direct-children
                                             root 'class))))))
          (puthash xml-path api b4x-project--library-api-cache)
          api))))

(defun b4x-project-library-apis (project)
  "Return parsed XML metadata for the libraries referenced by PROJECT."
  (delq nil
        (mapcar (lambda (name)
                  (when-let ((lib (b4x-project-find-available-library project name)))
                    (b4x-project-parse-library-api lib)))
                (b4x-project-libraries project))))

(defun b4x-project--library-api-stamp (api)
  "Return a cache stamp for parsed library API API."
  (let* ((xml (b4x-library-api-xml-path api))
         (attrs (and xml (file-attributes xml)))
         (mtime (and attrs (file-attribute-modification-time attrs))))
    (list xml mtime)))

(defun b4x-project--library-symbol-index (project)
  "Return cached XML library completion/doc index for PROJECT.

The result is a plist with `:candidates' and `:infos' (downcased symbol name ->
list of metadata plists).  It avoids repeatedly walking every XML class/member
while completion UIs ask for annotations and documentation as the user moves
between candidates."
  (let* ((apis (b4x-project-library-apis project))
         (key (list (b4x-project-project-file project)
                    (b4x-project-libraries project)
                    (mapcar #'b4x-project--library-api-stamp apis))))
    (or (gethash key b4x-project--library-symbol-index-cache)
        (let ((infos (make-hash-table :test 'equal))
              candidates)
          (dolist (api apis)
            (dolist (class (b4x-library-api-classes api))
              (when-let ((shortname (b4x-library-class-shortname class)))
                (push shortname candidates)
                (push (list :kind 'class
                            :name shortname
                            :signature (format "%s" shortname)
                            :comment (b4x-library-class-comment class)
                            :class class
                            :library (b4x-library-api-library api))
                      (gethash (downcase shortname) infos)))
              (dolist (member (append (b4x-library-class-method-details class)
                                      (b4x-library-class-property-details class)
                                      (b4x-library-class-event-details class)))
                (when-let ((member-name (b4x-library-member-name member)))
                  (push member-name candidates)
                  (push (list :kind (b4x-library-member-kind member)
                              :name member-name
                              :signature (b4x-project-format-library-member-signature member class)
                              :comment (b4x-library-member-comment member)
                              :class class
                              :library (b4x-library-api-library api)
                              :member member)
                        (gethash (downcase member-name) infos))))))
          (maphash (lambda (name entries)
                     (puthash name (nreverse entries) infos))
                   infos)
          (let ((index (list :candidates (delete-dups (delq nil candidates))
                             :infos infos)))
            (puthash key index b4x-project--library-symbol-index-cache)
            index)))))

(defun b4x-project-library-completion-candidates (project)
  "Return completion candidates contributed by PROJECT's library XML metadata."
  (plist-get (b4x-project--library-symbol-index project) :candidates))

(defun b4x-project-library-class-names (project)
  "Return the short class/type names exported by PROJECT's referenced libraries."
  (delete-dups
   (delq nil
         (mapcan (lambda (api)
                   (mapcar #'b4x-library-class-shortname
                           (b4x-library-api-classes api)))
                 (b4x-project-library-apis project)))))

(defun b4x-project--format-library-parameters (parameters)
  "Format library member PARAMETERS for display."
  (mapconcat (lambda (param)
               (if-let ((name (b4x-library-parameter-name param)))
                   (format "%s As %s"
                           name
                           (or (b4x-project--friendly-type-name
                                (b4x-library-parameter-type param))
                               "Object"))
                 (or (b4x-project--friendly-type-name
                      (b4x-library-parameter-type param))
                     "Object")))
             parameters ", "))

(defun b4x-project-format-library-member-signature (member &optional class)
  "Return a human-readable signature for library MEMBER.

Optional CLASS is a `b4x-library-class' used to qualify class names in docs."
  (pcase (b4x-library-member-kind member)
    ('event (or (b4x-library-member-signature member)
                (b4x-library-member-name member)))
    ('property
     (format "%s%s"
             (b4x-library-member-name member)
             (if-let ((type (b4x-library-member-returntype member)))
                 (format " As %s" (b4x-project--friendly-type-name type))
               "")))
    (_
     (format "%s(%s)%s"
             (b4x-library-member-name member)
             (b4x-project--format-library-parameters
              (b4x-library-member-parameters member))
             (if-let ((type (b4x-library-member-returntype member)))
                 (if (string= (downcase type) "void")
                     ""
                   (format " As %s" (b4x-project--friendly-type-name type)))
               "")))))

(defun b4x-project--first-doc-line (text)
  "Return TEXT collapsed to its first non-empty line, or nil."
  (when text
    (car (seq-filter (lambda (line) (not (string-empty-p line)))
                     (mapcar #'string-trim (split-string text "\r?\n" t))))))

(defun b4x-project-library-symbol-infos (project name)
  "Return library XML metadata entries for symbol NAME in PROJECT.

Each entry is a plist with keys including `:kind', `:signature', `:comment',
`:class', and `:library'."
  (copy-sequence
   (gethash (downcase name)
            (plist-get (b4x-project--library-symbol-index project) :infos))))

(defun b4x-project-library-symbol-info (project name)
  "Return the first library XML metadata entry for symbol NAME in PROJECT." 
  (car (b4x-project-library-symbol-infos project name)))

(defun b4x-project-library-symbol-annotation (project name)
  "Return a short completion annotation for symbol NAME in PROJECT, or nil."
  (when-let ((info (b4x-project-library-symbol-info project name)))
    (format " [%s%s]"
            (plist-get info :kind)
            (if-let ((class (and (not (eq (plist-get info :kind) 'class))
                                 (b4x-library-class-shortname
                                  (plist-get info :class)))))
                (format ":%s" class)
              ""))))

(defun b4x-project-library-symbol-doc (project name &optional multiline)
  "Return library XML documentation for symbol NAME in PROJECT, or nil.

When MULTILINE is non-nil, keep the full comment body; otherwise keep the first
line only." 
  (when-let ((info (b4x-project-library-symbol-info project name)))
    (let* ((signature (plist-get info :signature))
           (comment (plist-get info :comment))
           (summary (if multiline comment (b4x-project--first-doc-line comment)))
           (lib (plist-get info :library))
           (libname (and lib (b4x-library-name lib))))
      (string-join
       (delq nil (list signature
                       (and summary (if multiline
                                        summary
                                      (format "— %s" summary)))
                       (and multiline libname (format "\nLibrary: %s" libname))))
       (if multiline "\n" " ")))))

(defun b4x-project--find-pom-files (dir)
  "Return Maven POM files found recursively under DIR."
  (when (and dir (file-directory-p dir))
    (directory-files-recursively dir (rx (or "pom.xml" (+ (not (any "/"))) ".pom") eos)
                                 nil nil t)))

(defun b4x-project--pom-value (root local-name)
  "Return the direct LOCAL-NAME text from Maven POM ROOT, or nil."
  (b4x-project--dom-direct-child-text-local root local-name))

(defun b4x-project--parse-pom-root (pom-path)
  "Parse POM-PATH and return its DOM root node."
  (b4x-project--parse-xml-root pom-path))

(defun b4x-project-parse-library-pom (pom-path source)
  "Parse Maven POM-PATH discovered in SOURCE and return `b4x-library-pom'."
  (or (gethash pom-path b4x-project--library-pom-cache)
      (let* ((root (b4x-project--parse-pom-root pom-path))
             (parent (car (b4x-project--dom-direct-children-local root "parent")))
             (pom (make-b4x-library-pom
                   :path pom-path
                   :source source
                   :group-id (or (b4x-project--pom-value root "groupId")
                                 (and parent (b4x-project--pom-value parent "groupId")))
                   :artifact-id (b4x-project--pom-value root "artifactId")
                   :version (or (b4x-project--pom-value root "version")
                                (and parent (b4x-project--pom-value parent "version")))
                   :packaging (b4x-project--pom-value root "packaging")
                   :name (b4x-project--pom-value root "name")
                   :description (b4x-project--pom-value root "description"))))
        (puthash pom-path pom b4x-project--library-pom-cache)
        pom)))

(defun b4x-project-library-poms (project)
  "Return all Maven POM metadata discovered for PROJECT's library folders."
  (let ((seen (make-hash-table :test 'equal))
        out)
    (dolist (entry (b4x-project-library-dirs project))
      (pcase-let ((`(,source . ,dir) entry))
        (dolist (pom (or (b4x-project--find-pom-files dir) nil))
          (unless (gethash pom seen)
            (puthash pom t seen)
            (push (b4x-project-parse-library-pom pom source) out)))))
    (sort (delq nil out)
          (lambda (a b)
            (string< (or (b4x-library-pom-artifact-id a)
                         (file-name-nondirectory (b4x-library-pom-path a)))
                     (or (b4x-library-pom-artifact-id b)
                         (file-name-nondirectory (b4x-library-pom-path b))))))))

(defun b4x-project-find-library-pom (project library-or-name)
  "Return the Maven POM best matching LIBRARY-OR-NAME in PROJECT, or nil."
  (let* ((name (downcase (if (b4x-library-p library-or-name)
                             (b4x-library-name library-or-name)
                           library-or-name)))
         (library (if (b4x-library-p library-or-name)
                      library-or-name
                    (b4x-project-find-available-library project library-or-name)))
         (base (and library (downcase (file-name-base (b4x-library-path library))))))
    (seq-find (lambda (pom)
                (let ((artifact (and (b4x-library-pom-artifact-id pom)
                                     (downcase (b4x-library-pom-artifact-id pom))))
                      (pom-base (downcase (file-name-base (b4x-library-pom-path pom)))))
                  (or (and artifact (or (string= artifact name)
                                        (and base (string= artifact base))))
                      (string= pom-base name)
                      (and base (string= pom-base base)))))
              (b4x-project-library-poms project))))


;;; Layouts & Files

(defconst b4x-project--layout-exts
  '((b4j . "bjl") (b4a . "bal") (b4i . "bil"))
  "Layout-file extension per B4X platform (B4R has no layouts).")

(defun b4x-project-layout-ext (project)
  "Return the layout file extension for PROJECT's platform (without dot)."
  (cdr (assq (b4x-project-platform project) b4x-project--layout-exts)))

(defun b4x-project-files-dir (project)
  "Return the `Files/' directory of PROJECT's platform folder, or nil."
  (let ((dir (expand-file-name "Files" (b4x-project-project-dir project))))
    (and (file-directory-p dir) dir)))

(defun b4x-project-layout-files (project)
  "Return a list of (NAME . PATH) for layout files of PROJECT.

NAME is the layout name without extension (as referenced by
`LoadLayout').  PATH is the absolute host path.  Sources: the
`FileN=' header entries plus any `.<ext>' file found in the
platform `Files/' directory on disk."
  (let* ((ext (b4x-project-layout-ext project))
         (files-dir (b4x-project-files-dir project))
         (result (make-hash-table :test 'equal)))
    ;; From header FileN= entries (e.g. "MainPage.bjl").
    (dolist (raw (b4x-project--collect-numbered
                  "File" (b4x-project-header project)))
      (when (and ext (string-match (concat (regexp-quote ext) "\\'") raw))
        (let* ((name (file-name-base raw))
               (path (and files-dir
                          (expand-file-name raw files-dir))))
          (when (or (null path) (file-regular-p path))
            (puthash name (or path name) result)))))
    ;; From disk (covers layouts not listed in the header, or missing ext).
    (when files-dir
      (dolist (f (directory-files
                  files-dir t
                  (concat "\\." (or ext "\\(bjl\\|bal\\|bil\\)") "\\'") t))
        (puthash (file-name-base f) f result)))
    (let (out)
      (maphash (lambda (k v) (push (cons k v) out)) result)
      (sort out (lambda (a b) (string< (car a) (car b)))))))

(defun b4x-project-find-layout (project name)
  "Return the host path of layout NAME in PROJECT, or nil.

NAME is matched case-insensitively against declared/disk layouts."
  (let ((target (downcase name)))
    (cl-some (lambda (entry)
               (when (string= (downcase (car entry)) target)
                 (cdr entry)))
             (b4x-project-layout-files project))))

(provide 'b4x-project)
;;; b4x-project.el ends here
