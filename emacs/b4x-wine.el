;;; b4x-wine.el --- Wine prefix discovery and path translation -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; Author: emacs-b4x-integration
;; Keywords: languages, tools
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Linux/Wine foundation for B4X.  Resolves the active Wine prefix, translates
;; Windows paths to host paths (via the prefix's `dosdevices' symlinks, no
;; `wine' subprocess needed), translates host paths back to Windows paths
;; (preferring `winepath -w'), and discovers `b4xV5.ini' / install dirs under a
;; prefix.
;;
;; Nothing here touches buffers, modes, or the editor; it is a pure data layer.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'seq)


;;; Customization

(defcustom b4x-wine-enabled 'auto
  "Whether to translate B4X Windows paths through a Wine prefix.

`auto' enables Wine on non-Windows hosts when a prefix is found.
Set to nil to force native interpretation, or t to force Wine."
  :group 'b4x
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "On" t)
                 (const :tag "Off" nil)))

(defcustom b4x-wine-prefix nil
  "Wine prefix holding the B4X install (e.g. `~/.wine_b4x').

When nil, fall back to `WINEPREFIX' then to `~/.wine_b4x'."
  :group 'b4x
  :type '(choice (const :tag "Auto" nil) directory))

(defcustom b4x-wine-binary "wine"
  "Executable used to run B4X builders under Wine."
  :group 'b4x
  :type 'string)

(defcustom b4x-winepath-binary "winepath"
  "Executable used to convert host paths to Windows paths."
  :group 'b4x
  :type 'string)


;;; Prefix + enablement

(defun b4x--on-windows-p ()
  "Non-nil when Emacs runs on a native Windows host."
  (eq system-type 'windows-nt))

(defun b4x-wine-resolve-prefix ()
  "Return the absolute Wine prefix currently in effect."
  (let ((raw (or (and b4x-wine-prefix
                      (file-name-as-directory b4x-wine-prefix))
                 (getenv "WINEPREFIX")
                 "~/.wine_b4x")))
    (directory-file-name (expand-file-name raw))))

(defun b4x-wine-active-p ()
  "Non-nil if Wine path translation should be attempted."
  (pcase b4x-wine-enabled
    ('t t)
    ('nil nil)
    ('auto (not (b4x--on-windows-p)))))


;;; Windows path detection

(defconst b4x--windows-drive-re
  (rx bos (any "A-Za-z") ":" (or "/" "\\"))
  "Regexp matching a Windows drive path like `C:\\\\' or `Z:/...'.")

(defun b4x-windows-path-p (path)
  "Non-nil if PATH looks like a Windows drive path (`C:\\...' or `C:/...')."
  (and (stringp path)
       (or (string-match-p b4x--windows-drive-re path)
           (string-match-p (rx bos (any "A-Za-z") ":" eos) path))))


;;; Windows -> host

(defun b4x-wine--drive-root (prefix drive-letter)
  "Return host root directory for DRIVE-LETTER (a character) under PREFIX.

Uses the prefix's `dosdevices' symlinks; deterministic fallbacks for
`C:' (-> `drive_c') and `Z:' (-> host root)."
  (let* ((drive (downcase (char-to-string drive-letter)))
         (link (expand-file-name (concat drive ":")
                                 (expand-file-name "dosdevices" prefix))))
    (cond
     ((file-exists-p link) (file-truename link))
     ((string= drive "c")
      (let ((fb (expand-file-name "drive_c" prefix)))
        (and (file-exists-p fb) fb)))
     ((string= drive "z")
      (expand-file-name "/"))            ; host root
     (t nil))))

(defun b4x-wine--split-segments (path)
  "Split the directory portion of a Windows PATH into segments."
  (let ((body (if (string-match (rx bos (any "A-Za-z") ":" (optional (or "/" "\\")))
                                path)
                  (substring path (match-end 0))
                path)))
    (split-string body (rx (one-or-more (or "/" "\\"))) t)))

(defun b4x-wine-path-to-host (path &optional base-dir)
  "Translate PATH (possibly a Windows/Wine path) to a host path.

Absolute POSIX paths are normalized.  Windows drive paths are resolved through
the active Wine prefix.  Relative paths resolve against BASE-DIR when given.
Returns nil when a Windows path cannot be mapped and no base is available."
  (cond
   ((or (null path) (string-empty-p path)) nil)
   ;; Absolute POSIX path.
   ((string-prefix-p "/" path) (expand-file-name path))
   ;; Windows drive path: translate via dosdevices when Wine is active.
   ((and (b4x-windows-path-p path) (b4x-wine-active-p))
    (let ((root (b4x-wine--drive-root (b4x-wine-resolve-prefix) (aref path 0))))
      (and root
           (let ((segs (b4x-wine--split-segments path)))
             (expand-file-name (mapconcat #'identity segs "/") root)))))
   ;; Relative-looking path.
   (base-dir
    (let ((segs (split-string path (rx (one-or-more (or "/" "\\"))) t)))
      (expand-file-name (mapconcat #'identity segs "/") base-dir)))
   (t (expand-file-name path))))


;;; Host -> Windows

(defun b4x-host-to-wine-path (host-path)
  "Translate HOST-PATH to a Windows (Wine) path.

Prefers `winepath -w' for correctness; falls back to a deterministic
`drive_c' -> `C:' / everything-else -> `Z:' mapping."
  (if (not (b4x-wine-active-p))
      host-path
    (let* ((host (expand-file-name host-path))
           (prefix (b4x-wine-resolve-prefix))
           (raw (b4x-wine--winepath-windows host prefix)))
      (if (and raw (not (string-empty-p raw)))
          raw
        (b4x-wine--host-to-wine-fallback host prefix)))))

(defun b4x-wine--winepath-windows (host prefix)
  "Call `winepath -w' on HOST under PREFIX; return the trimmed result or nil."
  (with-temp-buffer
    (let ((process-environment
           (cons (format "WINEPREFIX=%s" prefix) process-environment)))
      (when (eq 0 (call-process b4x-winepath-binary nil t nil "-w" host))
        (string-trim (buffer-string))))))

(defun b4x-wine--host-to-wine-fallback (host prefix)
  "Deterministic host -> Windows mapping when `winepath' is unavailable."
  (let ((drive-c (expand-file-name "drive_c" prefix)))
    (if (or (string= host drive-c)
            (string-prefix-p (file-name-as-directory drive-c) host))
        (let ((rel (substring host (length drive-c))))
          (concat "C:"
                  (mapconcat #'identity (split-string rel "/" t) "\\")))
      (let* ((segs (split-string host "/" t))
             (posix (mapconcat #'identity segs "\\")))
        (concat "Z:" (if (string-prefix-p "\\" posix) posix (concat "\\" posix)))))))


;;; b4xV5.ini + install discovery

(defconst b4x-wine--appdata-platform-dirs
  '((b4a . ("B4A" "Basic4android"))
    (b4j . ("B4J"))
    (b4i . ("B4i"))
    (b4r . ("B4R")))
  "Platform subfolders under `Anywhere Software' to probe for `b4xV5.ini'.")

(defun b4x-wine-platform-dirs (platform)
  "Return the candidate AppData subfolders for PLATFORM."
  (or (cdr (assq platform b4x-wine--appdata-platform-dirs))
      (list (upcase (symbol-name platform)))))

(defun b4x-wine--users-root (prefix)
  "Return the `drive_c/users' path of PREFIX, or nil if absent."
  (let ((root (expand-file-name "drive_c/users" prefix)))
    (and (file-exists-p root) root)))

(defun b4x-find-wine-ini (platform &optional prefix)
  "Discover `b4xV5.ini' for PLATFORM under PREFIX (defaults to active prefix).

PLATFORM is a symbol like `b4j' or `b4a'.  Returns the first matching path."
  (let* ((prefix (or prefix (b4x-wine-resolve-prefix)))
         (users-root (b4x-wine--users-root prefix))
         (dirs (b4x-wine-platform-dirs platform)))
    (and users-root
         (cl-some
          (lambda (user)
            (cl-some
             (lambda (pdir)
               (let ((candidate
                      (expand-file-name
                       (mapconcat #'identity
                                  (list user "AppData" "Roaming"
                                         "Anywhere Software" pdir "b4xV5.ini")
                                  "/")
                       users-root)))
                 (and (file-exists-p candidate) candidate)))
             dirs))
          (directory-files users-root t "^[^.].*" t)))))

(defun b4x-find-wine-install-dir (platform &optional prefix)
  "Discover the install directory for PLATFORM under PREFIX."
  (let* ((prefix (or prefix (b4x-wine-resolve-prefix)))
         (root (expand-file-name "drive_c/Program Files/Anywhere Software" prefix))
         (dirs (b4x-wine-platform-dirs platform)))
    (and (file-exists-p root)
         (cl-some (lambda (d)
                    (let ((cand (expand-file-name d root)))
                      (and (file-exists-p cand) cand)))
                  dirs))))

(provide 'b4x-wine)
;;; b4x-wine.el ends here
