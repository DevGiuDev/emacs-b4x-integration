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

(defconst b4x-project--platform-exts
  '(("b4j" . b4j) ("b4a" . b4a) ("b4i" . b4i) ("b4r" . b4r))
  "Project-file extension -> platform symbol.")

(defconst b4x-project--platform-folders
  '("B4J" "B4A" "B4i" "B4R")
  "Folder names that denote a platform subfolder of a B4X project root.")


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

(defun b4x-project--root-of-dir (dir)
  "If DIR is a platform folder, return its parent; else return DIR."
  (let ((base (file-name-nondirectory (directory-file-name dir))))
    (if (member base b4x-project--platform-folders)
        (file-name-directory (directory-file-name dir))
      dir)))

(defun b4x-project--root-from-file (project-file)
  "Compute the logical project root for PROJECT-FILE."
  (directory-file-name
   (b4x-project--root-of-dir (file-name-directory project-file))))


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
         (root-dir (b4x-project--root-from-file project-file))
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
