;;; b4x.el --- B4X (B4J/B4A) development for Emacs, Linux/Wine first -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; Author: emacs-b4x-integration
;; Keywords: languages, tools
;; Version: 0.3.10
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Pure-Emacs-Lisp B4X (B4J / B4A) package for Linux, with first-class Wine
;; support.  See `docs/architecture.md' for the full design.
;;
;; Quick start:
;;
;;   (require 'b4x)
;;   (add-to-list 'auto-mode-alist '("\\.b4[aijr]\\'" . b4x-mode))
;;   (add-to-list 'auto-mode-alist '("\\.bas\\'" . b4x-mode))
;;
;; Then open a `.b4j'/`.bas' file.  You get a major mode with font-lock, imenu,
;; completion-at-point, xref goto-definition/references, and eldoc.  Use
;; `b4x-build' / `b4x-run-project' to compile and run (delegated to the
;; vendored Wine shell scripts).
;;
;; Key bindings in `b4x-mode':
;;
;;   C-c C-d   dispatch menu (transient)
;;   C-c C-o   open project
;;   C-c C-i   project info
;;   C-c C-n   create a new B4J module and register it in the project
;;   C-c C-s   add a library from core / Additional Libs
;;   C-c C-k   remove a library from the current project
;;   M-x b4x-list-available-libraries   list available libraries (clickable)
;;   C-c C-m   switch module
;;   C-c C-l   jump to layout (from `LoadLayout("...")' or via completion)
;;   C-c C-y   sync `Files/' layouts with `JsonLayouts/'
;;   M-x b4x-layout-open-json     open the JSON sidecar for a layout
;;   M-x b4x-layout-sync-project  sync `Files/' layouts with `JsonLayouts/'
;;   C-c C-c   build
;;   C-c C-r   run
;;   C-c C-e   open in the official B4X IDE under Wine
;;   C-c a s   select Android device
;;   C-c a i   install APK on device
;;   C-c a u   uninstall app from device
;;   C-c a l   launch app on device
;;   C-c a r   restart app on device
;;   C-c a g   stream filtered logcat

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'project)
(require 'button)
(require 'transient)
(require 'b4x-wine)
(require 'b4x-project)
(require 'b4x-nav)
(require 'b4x-flymake)
(require 'b4x-layout)


;;; Customization

(defgroup b4x nil
  "B4X (B4J/B4A) development for Emacs."
  :group 'languages
  :link '(url-link "https://github.com/emacs-b4x-integration"))

(defconst b4x-package-version "0.3.10"
  "Version string of the loaded B4X Emacs package.")

(defun b4x-version-string ()
  "Return a human-readable version string for the loaded B4X package."
  (let ((file (or (symbol-file 'b4x-mode 'defun)
                  (locate-library "b4x")
                  "<unknown>")))
    (format "B4X %s (%s)" b4x-package-version file)))

;;;###autoload
(defun b4x-version ()
  "Display the loaded B4X package version and source path."
  (interactive)
  (let ((s (b4x-version-string)))
    (when (called-interactively-p 'interactive)
      (message "%s" s))
    s))

(defcustom b4x-build-on-save nil
  "If non-nil, rebuild the project after saving a source file."
  :group 'b4x
  :type 'boolean)

(defcustom b4x-run-after-build nil
  "If non-nil, automatically run the jar after a successful build."
  :group 'b4x
  :type 'boolean)

(defcustom b4x-build-port nil
  "TCP port forwarded as PORT / JVM_SERVER_PORT when running jServer apps."
  :group 'b4x
  :type '(choice (const :tag "None" nil) integer))

(defcustom b4x-java-opts nil
  "Extra JVM options passed when running a B4J jar."
  :group 'b4x
  :type '(repeat string))

(defcustom b4x-enable-flymake t
  "If non-nil, enable `flymake-mode' in `b4x-mode' buffers.

The B4X diagnostic backend (`b4x-flymake') is registered regardless, so
if you manage flymake yourself you can set this to nil."
  :group 'b4x
  :type 'boolean)

(defcustom b4x-ide-log-file nil
  "File where Wine output from `b4x-open-in-ide' is appended (fire-and-forget).

Nil means a file named `b4x-ide.log' under `temporary-file-directory'.
Inspect it with `b4x-ide-log' if the IDE ever fails to open."
  :group 'b4x
  :type '(choice (const :tag "Default temp file" nil) file))

(defcustom b4x-adb-binary "adb"
  "ADB executable used by the B4A deployment helpers."
  :group 'b4x
  :type 'string)

(defcustom b4x-adb-serial nil
  "Optional device serial passed to ADB as `-s SERIAL'."
  :group 'b4x
  :type '(choice (const :tag "Default device" nil) string))

(defcustom b4x-b4a-logcat-buffer-name "*b4x-logcat*"
  "Buffer name used by `b4x-b4a-logcat'."
  :group 'b4x
  :type 'string)

(defcustom b4x-b4a-logcat-fallback-specs
  '("B4A:V" "B4X:V" "AndroidRuntime:E" "System.err:W" "*:S")
  "Logcat filter specs used when the app PID is not yet available.

When the target app is already running, `b4x-b4a-logcat' prefers
`adb logcat --pid=...'.  Otherwise it falls back to this quieter tag-based
filter instead of streaming the full device log.  Values use the same format as
plain `adb logcat TAG:PRIORITY' arguments."
  :group 'b4x
  :type '(repeat string))

(defcustom b4x-emulator-binary "emulator"
  "Android emulator executable used by the B4A hybrid helpers."
  :group 'b4x
  :type 'string)

(defcustom b4x-b4a-default-avd nil
  "Default AVD name used by `b4x-b4a-start-emulator' and hybrid debug helpers."
  :group 'b4x
  :type '(choice (const :tag "Prompt / none" nil) string))

(defcustom b4x-b4a-emulator-args nil
  "Extra command-line arguments passed to the Android emulator."
  :group 'b4x
  :type '(repeat string))

(defcustom b4x-b4a-emulator-log-file nil
  "File where detached emulator output is appended.

Nil means a file named `b4x-emulator.log' under `temporary-file-directory'."
  :group 'b4x
  :type '(choice (const :tag "Default temp file" nil) file))

(defcustom b4x-b4a-device-buffer-name "*b4x-android*"
  "Buffer name used by Android device wait / hybrid-debug helper commands."
  :group 'b4x
  :type 'string)

(defvar b4x--adb-last-serial nil
  "Last Android device serial selected for B4A helper commands.")


;;; Faces

(defface b4x-keyword-face
  '((t :inherit font-lock-keyword-face))
  "Face for B4X keywords."
  :group 'b4x)

(defface b4x-type-face
  '((t :inherit font-lock-type-face))
  "Face for B4X type names."
  :group 'b4x)

(defface b4x-sub-name-face
  '((t :inherit font-lock-function-name-face))
  "Face for B4X Sub names."
  :group 'b4x)


;;; Font lock

(defconst b4x--keywords
  '("Sub" "End" "If" "Then" "Else" "ElseIf" "For" "Next" "To" "Step"
    "Do" "Loop" "While" "Until" "Dim" "As" "Return" "Private" "Public"
    "Type" "Select" "Case" "Try" "Catch" "Finally" "Exit" "Continue"
    "True" "False" "Null" "Not" "And" "Or" "Mod" "Is" "CallSub"
    "Class_Globals" "Process_Globals" "Globals")
  "B4X language keywords.")

(defconst b4x--font-lock-keywords
  `((,(regexp-opt b4x--keywords 'symbols) . 'b4x-keyword-face)
    (,(rx line-start (* space)
          (optional (or "Public" "Private") (+ space))
          "Sub" (+ space)
          (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_")))))
     (1 'b4x-sub-name-face))
    (,(rx line-start (* space) "Type" (+ space)
          (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_")))))
     (1 'b4x-type-face)))
  "Font lock keywords for B4X source.")


;;; Syntax table

(defconst b4x--syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?' "<" st)          ; ' starts a comment
    (modify-syntax-entry ?\n ">" st)         ; newline ends comment
    (modify-syntax-entry ?_ "_" st)
    (dolist (c '(?. ?, ?: ?\; ?= ?< ?> ?+ ?- ?* ?/ ?\\ ?& ?| ?^ ?~))
      (modify-syntax-entry c "." st))
    st)
  "Syntax table for B4X source.")


;;; Keymap

(defvar b4x-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'b4x-build)
    (define-key map (kbd "C-c C-r") #'b4x-run-project)
    (define-key map (kbd "C-c C-e") #'b4x-open-in-ide)
    (define-key map (kbd "C-c C-o") #'b4x-open-project)
    (define-key map (kbd "C-c C-i") #'b4x-project-info)
    (define-key map (kbd "C-c C-v") #'b4x-version)
    (define-key map (kbd "C-c C-l") #'b4x-goto-layout)
    (define-key map (kbd "C-c C-y") #'b4x-layout-sync-project)
    (define-key map (kbd "C-c C-m") #'b4x-switch-module)
    (define-key map (kbd "C-c C-n") #'b4x-new-module)
    (define-key map (kbd "C-c C-s") #'b4x-add-library)
    (define-key map (kbd "C-c C-k") #'b4x-remove-library)
    (define-key map (kbd "C-c C-d") #'b4x-dispatch)
    (define-key map (kbd "C-c a s") #'b4x-b4a-select-device)
    (define-key map (kbd "C-c a i") #'b4x-b4a-install-apk)
    (define-key map (kbd "C-c a u") #'b4x-b4a-uninstall-app)
    (define-key map (kbd "C-c a l") #'b4x-b4a-launch-app)
    (define-key map (kbd "C-c a r") #'b4x-b4a-restart-app)
    (define-key map (kbd "C-c a g") #'b4x-b4a-logcat)
    (define-key map (kbd "C-c a k") #'b4x-b4a-stop-logcat)
    (define-key map (kbd "C-c a v") #'b4x-b4a-list-avds)
    (define-key map (kbd "C-c a e") #'b4x-b4a-start-emulator)
    (define-key map (kbd "C-c a w") #'b4x-b4a-wait-for-device)
    (define-key map (kbd "C-c a d") #'b4x-b4a-debug-in-ide)
    map)
  "Keymap for `b4x-mode'.")


;;; Major mode

;;;###autoload
(define-derived-mode b4x-mode prog-mode "B4X"
  "Major mode for editing B4X (B4J / B4A) source.

\\{b4x-mode-map}"
  :syntax-table b4x--syntax-table
  (setq-local font-lock-defaults '(b4x--font-lock-keywords nil t))
  (setq-local imenu-create-index-function #'b4x-imenu-index)
  (setq-local comment-start "'")
  (setq-local comment-start-skip "'+ *")
  (setq-local comment-end "")
  (setq-local outline-regexp "\\s-*\\(Sub\\|Type\\)\\_>")
  (setq-local add-log-current-defun-function #'b4x--current-sub)
  (add-hook 'completion-at-point-functions #'b4x-completion-at-point nil t)
  (add-hook 'eldoc-documentation-functions #'b4x-eldoc-function nil t)
  (add-hook 'xref-backend-functions #'b4x--xref-backend nil t)
  (add-hook 'flymake-diagnostic-functions #'b4x-flymake nil t)
  (when (and b4x-enable-flymake (not flymake-mode))
    (flymake-mode 1))
  (add-hook 'after-save-hook #'b4x-nav--clear-cache nil t)
  (b4x--remember-current-project))

(defun b4x--current-sub ()
  "Return the name of the Sub enclosing point, for `which-function' / add-log."
  (save-excursion
    (let ((limit (point)))
      (goto-char (point-min))
      (let (last)
        (while (re-search-forward
                (rx line-start (* space)
                    (optional (or "Public" "Private") (+ space))
                    "Sub" (+ space)
                    (group (+ (any "A-Za-z_") (* (any "A-Za-z0-9_"))))
                    (zero-or-one (* space) "("))
                limit t)
          (setq last (match-string 1)))
        last))))

(defun b4x--xref-backend ()
  "Return the B4X xref backend symbol when appropriate."
  (when (derived-mode-p 'b4x-mode)
    'b4x))

(defvar-local b4x--libraries-project-file nil
  "Project file associated with the current `b4x-libraries-mode' buffer.")

(defvar b4x-libraries-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'b4x-list-available-libraries)
    (define-key map (kbd "a") #'b4x-libraries-add-at-point)
    (define-key map (kbd "r") #'b4x-libraries-remove-at-point)
    (define-key map (kbd "k") #'b4x-libraries-remove-at-point)
    (define-key map (kbd "RET") #'b4x-libraries-activate)
    map)
  "Keymap for `b4x-libraries-mode'.")

(define-derived-mode b4x-libraries-mode special-mode "B4X-Libraries"
  "Mode used by `b4x-list-available-libraries'.")

(defun b4x--libraries-buffer-project ()
  "Return the project associated with the current libraries buffer."
  (unless (and b4x--libraries-project-file
               (file-regular-p b4x--libraries-project-file))
    (user-error "This libraries buffer is not attached to a live B4X project"))
  (b4x-load-project b4x--libraries-project-file))

(defun b4x--libraries-button-at-point ()
  "Return the library button at point, or nil."
  (button-at (point)))

(defun b4x--libraries-refresh-current-buffer ()
  "Refresh the current `b4x-libraries-mode' buffer."
  (let ((project-file b4x--libraries-project-file))
    (unless project-file
      (user-error "No project attached to this libraries buffer"))
    (b4x-list-available-libraries project-file)))

(defun b4x--libraries-handle-button (button action)
  "Apply ACTION to BUTTON's library and refresh the libraries buffer."
  (let* ((proj (b4x--libraries-buffer-project))
         (name (button-get button 'b4x-library-name))
         (present (button-get button 'b4x-library-present)))
    (pcase action
      ('add
       (if present
           (message "B4X: library already present: %s" name)
         (b4x--add-library-to-project proj name)
         (message "B4X: added library %s" name)))
      ('remove
       (if present
           (progn
             (b4x--remove-library-from-project proj name)
             (message "B4X: removed library %s" name))
         (message "B4X: library not present: %s" name)))
      ('toggle
       (if present
           (progn
             (b4x--remove-library-from-project proj name)
             (message "B4X: removed library %s" name))
         (b4x--add-library-to-project proj name)
         (message "B4X: added library %s" name)))))
  (b4x--libraries-refresh-current-buffer))

(defun b4x-libraries-activate ()
  "Toggle the library at point in a libraries buffer."
  (interactive)
  (if-let ((button (b4x--libraries-button-at-point)))
      (b4x--libraries-handle-button button 'toggle)
    (user-error "No library at point")))

(defun b4x-libraries-add-at-point ()
  "Add the library at point to the project."
  (interactive)
  (if-let ((button (b4x--libraries-button-at-point)))
      (b4x--libraries-handle-button button 'add)
    (user-error "No library at point")))

(defun b4x-libraries-remove-at-point ()
  "Remove the library at point from the project."
  (interactive)
  (if-let ((button (b4x--libraries-button-at-point)))
      (b4x--libraries-handle-button button 'remove)
    (user-error "No library at point")))


;;; auto-mode

;;;###autoload
(progn
  (add-to-list 'auto-mode-alist '("\\.b4[aijr]\\'" . b4x-mode))
  (add-to-list 'auto-mode-alist '("\\.bas\\'" . b4x-mode)))


;;; project.el integration

(defun b4x--project-finder (dir)
  "Return a B4X project object for DIR, or nil."
  (when-let ((pf (b4x-nav--locate-project-file (expand-file-name dir))))
    (cons 'b4x (b4x-project-root-from-file pf))))

(cl-defmethod project-root ((project (head b4x)))
  "Return the root directory of a B4X project."
  (cdr project))

(cl-defmethod project-files ((project (head b4x)) &optional _dirs)
  "Return source files for a B4X project (modules + project file)."
  (let* ((root (project-root project))
         (pf (b4x-nav--locate-project-file root))
         (files (when pf
                  (let ((proj (b4x-load-project pf)))
                    (cons pf (b4x-project-modules proj))))))
    (mapcar (lambda (f) (cons (file-relative-name f root) f))
            (or files (directory-files root t "\\`[^.]" t)))))

;;;###autoload
(add-hook 'project-find-functions #'b4x--project-finder)


;;; Interactive commands

(defun b4x--current-project ()
  "Return the `b4x-project' for the current buffer/project, or signal an error."
  (or (b4x-nav-current-project)
      (user-error "No B4X project found for %s"
                  (or (buffer-file-name) default-directory))))

(defun b4x--remember-project (proj)
  "Remember PROJ in `project.el' known projects."
  (when (and proj (fboundp 'project-remember-project))
    (project-remember-project (cons 'b4x (b4x-project-root-dir proj)))))

(defun b4x--remember-current-project ()
  "Best-effort helper to remember the current B4X project in `project.el'."
  (when-let ((proj (ignore-errors (b4x-nav-current-project))))
    (ignore-errors
      (b4x--remember-project proj))))

(defun b4x--library-source-label (source)
  "Return a human-readable label for library SOURCE." 
  (pcase source
    ('core "core")
    ('additional "additional")
    (_ "unknown")))

(defun b4x--project-library-lines (proj)
  "Return formatted lines describing the libraries currently added to PROJ."
  (let ((libs (b4x-project-libraries proj)))
    (if (null libs)
        '("  - (none)\n")
      (mapcar (lambda (name)
                (if-let ((lib (b4x-project-find-available-library proj name)))
                    (format "  - %s [%s]\n"
                            name
                            (b4x--library-source-label
                             (b4x-library-source lib)))
                  (format "  - %s [missing]\n" name)))
              libs))))

(defun b4x--project-library-present-p (proj name)
  "Return non-nil if PROJ already references library NAME."
  (member (downcase name)
          (mapcar #'downcase (b4x-project-libraries proj))))

(defun b4x--available-library-lines (proj)
  "Return formatted lines for all libraries available to PROJ."
  (let ((libs (b4x-project-available-libraries proj)))
    (if (null libs)
        '("  - (none)\n")
      (mapcar (lambda (lib)
                (format "%s %-24s [%-10s %-6s] %s\n"
                        (if (b4x--project-library-present-p proj
                                                           (b4x-library-name lib))
                            "*" " ")
                        (b4x-library-name lib)
                        (b4x--library-source-label (b4x-library-source lib))
                        (symbol-name (b4x-library-kind lib))
                        (b4x-library-path lib)))
              libs))))

(defun b4x--insert-available-library-entry (proj lib)
  "Insert one clickable available-library entry for PROJ and LIB."
  (let* ((present (b4x--project-library-present-p proj (b4x-library-name lib)))
         (line (format "%s %-24s [%-10s %-6s] %s"
                       (if present "*" " ")
                       (b4x-library-name lib)
                       (b4x--library-source-label (b4x-library-source lib))
                       (symbol-name (b4x-library-kind lib))
                       (b4x-library-path lib)))
         (button (insert-text-button
                  line
                  'follow-link t
                  'help-echo (if present
                                 "mouse-1/RET: remove library from project"
                               "mouse-1/RET: add library to project")
                  'action (lambda (btn)
                            (with-current-buffer (button-buffer btn)
                              (goto-char (button-start btn))
                              (b4x--libraries-handle-button btn 'toggle)))
                  'b4x-library-name (b4x-library-name lib)
                  'b4x-library-present present)))
    (button-put button 'face (if present 'success 'default))
    (insert "\n")))

;;;###autoload
(defun b4x-open-project (project-file)
  "Open the B4X project at PROJECT-FILE and visit its first module."
  (interactive
   (list (or (b4x-nav--locate-project-file
              (or (buffer-file-name) default-directory))
             (read-file-name "B4X project file (.b4j/.b4a): " nil nil t
                             nil #'b4x-project-file-p))))
  (let* ((proj (b4x-load-project project-file))
         (first-mod (car (b4x-project-modules proj))))
    (b4x--remember-project proj)
    (if first-mod
        (find-file first-mod)
      (find-file project-file))
    (message "B4X project loaded: %s (%s, %d module(s), %d lib(s))"
             (file-name-nondirectory project-file)
             (b4x-project-app-type proj)
             (length (b4x-project-modules proj))
             (length (b4x-project-libraries proj)))))

;;;###autoload
(defun b4x-project-info ()
  "Display the parsed model of the current B4X project in a buffer."
  (interactive)
  (let* ((proj (b4x--current-project))
         (library-dirs (b4x-project-library-dirs proj))
         (available (b4x-project-available-libraries proj))
         (pom-count (length (b4x-project-library-poms proj)))
         (core-count (cl-count-if (lambda (lib)
                                    (eq (b4x-library-source lib) 'core))
                                  available))
         (additional-count (cl-count-if (lambda (lib)
                                          (eq (b4x-library-source lib) 'additional))
                                        available)))
    (with-current-buffer (get-buffer-create "*B4X Project*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Package:    %s\n" (b4x-version-string)))
        (insert (format "Project:    %s\n" (b4x-project-project-file proj)))
        (insert (format "Platform:   %s\n" (b4x-project-platform proj)))
        (insert (format "AppType:    %s\n" (or (b4x-project-app-type proj) "-")))
        (insert (format "Version:    %s\n" (or (b4x-project-version proj) "-")))
        (insert (format "Root:       %s\n" (b4x-project-root-dir proj)))
        (insert (format "INI:        %s\n" (or (b4x-project-ini-path proj) "-")))
        (insert (format "CoreLibs:   %s\n"
                        (or (cdr (assq 'core library-dirs)) "-")))
        (insert (format "AddLibs:    %s\n"
                        (or (cdr (assq 'additional library-dirs)) "-")))
        (insert (format "Available:  %d core, %d additional\n"
                        core-count additional-count))
        (insert (format "POMs:       %d indexed\n" pom-count))
        (when (eq (b4x-project-platform proj) 'b4a)
          (insert (format "AndroidPkg: %s\n" (or (b4x--b4a-build-package proj) "-")))
          (insert (format "APK:        %s\n" (or (b4x--b4a-find-apk proj) "-"))))
        (insert "\nProject libraries:\n")
        (dolist (line (b4x--project-library-lines proj))
          (insert line))
        (insert "\nModules:\n")
        (dolist (m (b4x-project-modules proj))
          (insert (format "  - %s\n" m))))
      (goto-char (point-min))
      (view-mode 1)
      (display-buffer (current-buffer)))))

;;;###autoload
(defun b4x-list-available-libraries (&optional project-file)
  "Display all libraries available to PROJECT-FILE or the current project."
  (interactive)
  (let* ((proj (cond
                (project-file (b4x-load-project project-file))
                ((derived-mode-p 'b4x-libraries-mode)
                 (b4x--libraries-buffer-project))
                (t (b4x--current-project))))
         (library-dirs (b4x-project-library-dirs proj))
         (available (b4x-project-available-libraries proj)))
    (with-current-buffer (get-buffer-create "*B4X Libraries*")
      (let ((inhibit-read-only t))
        (b4x-libraries-mode)
        (setq-local b4x--libraries-project-file (b4x-project-project-file proj))
        (erase-buffer)
        (insert (format "Project:   %s\n" (b4x-project-project-file proj)))
        (insert (format "Platform:  %s\n" (b4x-project-platform proj)))
        (insert (format "CoreLibs:  %s\n"
                        (or (cdr (assq 'core library-dirs)) "-")))
        (insert (format "AddLibs:   %s\n"
                        (or (cdr (assq 'additional library-dirs)) "-")))
        (insert (format "Count:     %d\n" (length available)))
        (insert "\nLegend: * = already added to project\n")
        (insert "Actions: RET/mouse-1 toggle, a add, r/k remove, g refresh\n")
        (insert "Format: mark name [source kind] path\n\n")
        (if available
            (dolist (lib available)
              (b4x--insert-available-library-entry proj lib))
          (insert "  - (none)\n")))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

(defconst b4x--new-module-kinds
  '((static . (:label "Static Code"
               :platforms (b4j b4a)
               :module-type "StaticCode"
               :placement shared))
    (class . (:label "Class"
              :platforms (b4j b4a)
              :module-type "Class"
              :placement shared))
    (b4xpage . (:label "B4XPage"
                :platforms (b4j b4a)
                :module-type "Class"
                :placement shared
                :needs-library "b4xpages"))
    (service . (:label "Service"
                :platforms (b4a)
                :module-type "Service"
                :placement local)))
  "Kinds supported by `b4x-new-module'.")

(defun b4x--module-kind-prop (kind prop)
  "Return PROP from KIND's spec in `b4x--new-module-kinds'."
  (plist-get (cdr (assq kind b4x--new-module-kinds)) prop))

(defun b4x--module-kind-label (kind)
  "Return the human label for KIND."
  (or (b4x--module-kind-prop kind :label)
      (symbol-name kind)))

(defun b4x--module-kind-supported-p (kind platform)
  "Return non-nil when KIND is supported for PLATFORM."
  (memq platform (b4x--module-kind-prop kind :platforms)))

(defun b4x--module-kind-choices (proj)
  "Return `(LABEL . KIND)' choices valid for PROJ."
  (let ((platform (b4x-project-platform proj)))
    (delq nil
          (mapcar (lambda (it)
                    (let ((kind (car it)))
                      (when (b4x--module-kind-supported-p kind platform)
                        (cons (b4x--module-kind-label kind) kind))))
                  b4x--new-module-kinds))))

(defun b4x--module-name-p (name)
  "Return non-nil if NAME is a valid B4X module identifier." 
  (string-match-p (rx bos (or "_" alpha) (* (or "_" alnum)) eos) name))

(defun b4x--ensure-clean-visiting-buffer (file)
  "Signal an error if FILE is visited by a modified buffer." 
  (when-let ((buf (find-buffer-visiting file)))
    (when (buffer-modified-p buf)
      (user-error "Buffer has unsaved changes: %s" file))))

(defun b4x--write-file-preserving-buffers (file text)
  "Write TEXT to FILE, updating its visiting buffer if needed." 
  (b4x--ensure-clean-visiting-buffer file)
  (if-let ((buf (find-buffer-visiting file)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text)
          (save-buffer)))
    (with-temp-file file
      (insert text))))

(defun b4x--project-file-components (project-file)
  "Return plist describing PROJECT-FILE header/body formatting.

Keys: `:bom', `:newline', `:header', `:main'."
  (let* ((text (with-temp-buffer
                 (insert-file-contents project-file)
                 (buffer-string)))
         (bom (and (> (length text) 0) (eq (aref text 0) ?﻿)))
         (body (if bom (substring text 1) text))
         (newline (if (string-match-p "\r\n" body) "\r\n" "\n"))
         (parsed (b4x-project--parse-header body)))
    (list :bom bom :newline newline :header (car parsed) :main (cdr parsed))))

(defun b4x--header-max-index (prefix header)
  "Return the maximum numeric suffix for PREFIX in HEADER, or 0." 
  (let ((max 0))
    (dolist (entry header max)
      (when-let ((n (b4x-project--index-value prefix (car entry))))
        (setq max (max max n))))))

(defun b4x--header-set (key value header)
  "Set KEY to VALUE in HEADER, preserving its position when possible." 
  (if-let ((cell (assoc key header)))
      (progn (setcdr cell value) header)
    (append header (list (cons key value)))))

(defun b4x--header-insert-before (header before-key entry)
  "Insert ENTRY in HEADER before BEFORE-KEY, or append if absent." 
  (let (out done)
    (dolist (it header)
      (when (and (not done) (string= (car it) before-key))
        (push entry out)
        (setq done t))
      (push it out))
    (unless done
      (push entry out))
    (nreverse out)))

(defun b4x--header-add-numbered (prefix value header before-key)
  "Add a new `<PREFIX>N=VALUE' entry to HEADER before BEFORE-KEY." 
  (let ((entry (cons (format "%s%d" prefix (1+ (b4x--header-max-index prefix header)))
                     value)))
    (b4x--header-insert-before header before-key entry)))

(defun b4x--header-has-numbered-value (prefix value header)
  "Return non-nil if HEADER already has `<PREFIX>N=VALUE' (case-insensitive)." 
  (let ((needle (downcase value)))
    (seq-some (lambda (v) (string= (downcase v) needle))
              (b4x-project--collect-numbered prefix header))))

(defun b4x--header-remove-numbered (prefix header)
  "Return HEADER without any `<PREFIX>N=' entries."
  (seq-remove (lambda (entry)
                (b4x-project--index-value prefix (car entry)))
              header))

(defun b4x--header-replace-numbered (prefix values header before-key)
  "Replace HEADER's `<PREFIX>N=' entries with VALUES before BEFORE-KEY."
  (let ((out (b4x--header-remove-numbered prefix header)))
    (dolist (value values out)
      (setq out (b4x--header-add-numbered prefix value out before-key)))))

(defun b4x--header-string (header newline)
  "Render HEADER back to text using NEWLINE." 
  (mapconcat (lambda (entry)
               (format "%s=%s" (car entry) (cdr entry)))
             header newline))

(defun b4x--write-project-header (project-file header main newline bom)
  "Rewrite PROJECT-FILE from HEADER and MAIN, preserving NEWLINE/BOM." 
  (b4x--write-file-preserving-buffers
   project-file
   (concat (if bom "﻿" "")
           (b4x--header-string header newline)
           newline
           b4x-project--design-marker
           main)))

(defun b4x--module-header-defaults (proj)
  "Return plist of default header values inferred from PROJ's modules." 
  (let* ((sample (car (b4x-project-modules proj)))
         (sample-header
          (when (and sample (file-regular-p sample))
            (car (b4x-project--parse-header
                  (with-temp-buffer
                    (insert-file-contents sample)
                    (buffer-string))))))
         (platform-key
          (pcase (b4x-project-platform proj)
            ('b4j "B4J")
            ('b4a "B4A")
            ('b4i "B4i")
            ('b4r "B4R")
            (_ (upcase (symbol-name (b4x-project-platform proj)))))))
    (list :platform-key platform-key
          :group (or (b4x-project--first-value "Group" sample-header)
                     "Default Group")
          :modules-structure-version (or (b4x-project--first-value "ModulesStructureVersion" sample-header)
                                         "1")
          :version (or (b4x-project--first-value "Version" sample-header)
                       (b4x-project-version proj)
                       "10.5"))))

(defun b4x--module-target (proj name placement)
  "Return (FILE . MODULE-SPEC) for a new module NAME in PROJ at PLACEMENT.

PLACEMENT is either `shared' (project root when distinct from the platform
folder) or `local' (the platform folder itself)."
  (let* ((target-dir (pcase placement
                       ('local (b4x-project-project-dir proj))
                       (_ (if (equal (b4x-project-project-dir proj)
                                      (b4x-project-root-dir proj))
                              (b4x-project-project-dir proj)
                            (b4x-project-root-dir proj)))))
         (file (expand-file-name (concat name ".bas") target-dir)))
    (cons file
          (if (equal target-dir (b4x-project-project-dir proj))
              name
            (concat "|relative|"
                    (string-replace "/" "\\"
                                    (file-relative-name
                                     (file-name-sans-extension file)
                                     (b4x-project-project-dir proj))))))))

(defun b4x--module-template (proj kind name newline)
  "Return the source text for a new module of KIND/NAME in PROJ."
  (pcase-let* ((defaults (b4x--module-header-defaults proj))
               (platform-key (plist-get defaults :platform-key))
               (group (plist-get defaults :group))
               (msv (plist-get defaults :modules-structure-version))
               (version (plist-get defaults :version))
               (type (or (b4x--module-kind-prop kind :module-type) "Class"))
               (header (list (format "%s=true" platform-key)
                             (format "Group=%s" group)
                             (format "ModulesStructureVersion=%s" msv)
                             (format "Type=%s" type)
                             (format "Version=%s" version)
                             b4x-project--design-marker)))
    (concat
     (mapconcat #'identity header newline)
     newline
     (pcase kind
       ('static
        (mapconcat #'identity
                   '(""
                     "Sub Process_Globals"
                     "End Sub"
                     ""
                     "Public Sub Initialize"
                     "End Sub")
                   newline))
       ('class
        (mapconcat #'identity
                   '(""
                     "'Class module"
                     "Sub Class_Globals"
                     "End Sub"
                     ""
                     "Public Sub Initialize"
                     "End Sub")
                   newline))
       ('service
        (mapconcat #'identity
                   '(""
                     "#Region  Service Attributes"
                     "\t#StartAtBoot: False"
                     "\t#ExcludeFromLibrary: True"
                     "#End Region"
                     ""
                     "Sub Process_Globals"
                     "End Sub"
                     ""
                     "Sub Service_Create"
                     "End Sub"
                     ""
                     "Sub Service_Start (StartingIntent As Intent)"
                     "End Sub"
                     ""
                     "Sub Service_Destroy"
                     "End Sub")
                   newline))
       ('b4xpage
        (mapconcat #'identity
                   (list ""
                         "#Region  B4XPage Class"
                         "Sub Class_Globals"
                         "\tPrivate Root As B4XView"
                         "\tPrivate xui As XUI"
                         "End Sub"
                         ""
                         "Public Sub Initialize"
                         "'\tB4XPages.GetManager.LogEvents = True"
                         "End Sub"
                         ""
                         "Private Sub B4XPage_Created (Root1 As B4XView)"
                         "\tRoot = Root1"
                         (format "'\tRoot.LoadLayout(\"%s\")" name)
                         "End Sub"
                         "#End Region")
                   newline))))))

(defun b4x--create-module (proj kind name)
  "Create a new B4X module of KIND and NAME inside PROJ.

Supports B4J and B4A projects.  Returns the absolute path of the new `.bas'
file."
  (unless (memq (b4x-project-platform proj) '(b4j b4a))
    (user-error "`b4x-new-module' currently supports only B4J/B4A projects"))
  (unless (b4x--module-kind-supported-p kind (b4x-project-platform proj))
    (user-error "%s modules are not supported for %s"
                (b4x--module-kind-label kind)
                (b4x-project-platform proj)))
  (unless (b4x--module-name-p name)
    (user-error "Invalid B4X module name: %s" name))
  (when (and (eq kind 'b4xpage)
             (eq (b4x-project-platform proj) 'b4j)
             (not (string= (or (b4x-project-app-type proj) "") "JavaFX")))
    (user-error "B4XPage modules require a B4J JavaFX project"))
  (pcase-let* ((project-file (b4x-project-project-file proj))
               (`(:bom ,bom :newline ,newline :header ,header :main ,main)
                (b4x--project-file-components project-file))
               (`(,target-file . ,module-spec)
                (b4x--module-target proj name (b4x--module-kind-prop kind :placement)))
               (needed-lib (b4x--module-kind-prop kind :needs-library)))
    (b4x--ensure-clean-visiting-buffer project-file)
    (when (file-exists-p target-file)
      (user-error "Module already exists: %s" target-file))
    (setq header (b4x--header-add-numbered "Module" module-spec header "NumberOfModules"))
    (when (and needed-lib
               (not (b4x--header-has-numbered-value "Library" needed-lib header)))
      (setq header (b4x--header-add-numbered "Library" needed-lib header "NumberOfLibraries")))
    (setq header (b4x--header-set "NumberOfModules"
                                  (number-to-string
                                   (length (b4x-project--collect-numbered "Module" header)))
                                  header))
    (setq header (b4x--header-set "NumberOfLibraries"
                                  (number-to-string
                                   (length (b4x-project--collect-numbered "Library" header)))
                                  header))
    (b4x--write-file-preserving-buffers
     target-file (b4x--module-template proj kind name newline))
    (b4x--write-project-header project-file header main newline bom)
    (b4x-nav--clear-cache)
    target-file))

(defun b4x--read-module-kind (proj)
  "Prompt for a new-module kind valid for PROJ and return its symbol."
  (let* ((choices (b4x--module-kind-choices proj))
         (pick (completing-read "New module kind: " choices nil t)))
    (cdr (assoc pick choices))))

;;;###autoload
(defun b4x-new-module (kind name)
  "Create a new module NAME of KIND in the current B4J or B4A project."
  (interactive
   (let ((proj (b4x--current-project)))
     (list (b4x--read-module-kind proj)
           (read-string "New module name: "))))
  (let* ((proj (b4x--current-project))
         (path (b4x--create-module proj kind name)))
    (find-file path)
    (message "B4X: created %s (%s)%s"
             (file-name-nondirectory path)
             (b4x--module-kind-label kind)
             (if (eq kind 'b4xpage)
                 " — uncomment/create the layout when ready"
               ""))))

(defun b4x--available-library-choices (proj)
  "Return completion choices for libraries that can still be added to PROJ."
  (let ((present (mapcar #'downcase (b4x-project-libraries proj))))
    (mapcar (lambda (lib)
              (cons (format "%s [%s]"
                            (b4x-library-name lib)
                            (b4x--library-source-label
                             (b4x-library-source lib)))
                    (b4x-library-name lib)))
            (seq-remove (lambda (lib)
                          (member (b4x-library-canonical-name lib) present))
                        (b4x-project-available-libraries proj)))))

(defun b4x--read-library-name (proj)
  "Prompt for an available library name for PROJ."
  (let ((choices (b4x--available-library-choices proj)))
    (when (null choices)
      (user-error "No more libraries available to add"))
    (cdr (assoc (completing-read "Add library: " choices nil t) choices))))

(defun b4x--current-library-choices (proj)
  "Return completion choices for libraries currently referenced by PROJ."
  (mapcar (lambda (name)
            (if-let ((lib (b4x-project-find-available-library proj name)))
                (cons (format "%s [%s]"
                              name
                              (b4x--library-source-label
                               (b4x-library-source lib)))
                      name)
              (cons (format "%s [missing]" name) name)))
          (b4x-project-libraries proj)))

(defun b4x--read-current-library-name (proj)
  "Prompt for a currently added library name from PROJ."
  (let ((choices (b4x--current-library-choices proj)))
    (when (null choices)
      (user-error "Project has no libraries to remove"))
    (cdr (assoc (completing-read "Remove library: " choices nil t) choices))))

(defun b4x--add-library-to-project (proj library-name)
  "Add LIBRARY-NAME to PROJ's `LibraryN=' header entries.

Returns LIBRARY-NAME when it was added, nil when it was already present."
  (pcase-let* ((project-file (b4x-project-project-file proj))
               (`(:bom ,bom :newline ,newline :header ,header :main ,main)
                (b4x--project-file-components project-file)))
    (if (b4x--header-has-numbered-value "Library" library-name header)
        nil
      (setq header (b4x--header-add-numbered "Library" library-name header "NumberOfLibraries"))
      (setq header (b4x--header-set "NumberOfLibraries"
                                    (number-to-string
                                     (length (b4x-project--collect-numbered "Library" header)))
                                    header))
      (b4x--write-project-header project-file header main newline bom)
      (b4x-nav--clear-cache)
      library-name)))

(defun b4x--remove-library-from-project (proj library-name)
  "Remove LIBRARY-NAME from PROJ's `LibraryN=' header entries.

Returns LIBRARY-NAME when it was removed, nil when it was not present."
  (pcase-let* ((project-file (b4x-project-project-file proj))
               (`(:bom ,bom :newline ,newline :header ,header :main ,main)
                (b4x--project-file-components project-file))
               (libs (b4x-project--collect-numbered "Library" header))
               (needle (downcase library-name))
               (remaining (seq-remove (lambda (name)
                                        (string= (downcase name) needle))
                                      libs)))
    (if (= (length remaining) (length libs))
        nil
      (setq header (b4x--header-replace-numbered "Library" remaining header "NumberOfLibraries"))
      (setq header (b4x--header-set "NumberOfLibraries"
                                    (number-to-string (length remaining))
                                    header))
      (b4x--write-project-header project-file header main newline bom)
      (b4x-nav--clear-cache)
      library-name)))

;;;###autoload
(defun b4x-add-library (library-name)
  "Add LIBRARY-NAME from core / Additional Libs to the current project."
  (interactive
   (let ((proj (b4x--current-project)))
     (list (b4x--read-library-name proj))))
  (let* ((proj (b4x--current-project))
         (added (b4x--add-library-to-project proj library-name)))
    (if added
        (message "B4X: added library %s" added)
      (message "B4X: library already present: %s" library-name))))

;;;###autoload
(defun b4x-remove-library (library-name)
  "Remove LIBRARY-NAME from the current project."
  (interactive
   (let ((proj (b4x--current-project)))
     (list (b4x--read-current-library-name proj))))
  (let* ((proj (b4x--current-project))
         (removed (b4x--remove-library-from-project proj library-name)))
    (if removed
        (message "B4X: removed library %s" removed)
      (message "B4X: library not present: %s" library-name))))


;;; Build / Run (delegated to the vendored scripts)

(defun b4x--script-path (name)
  "Return the absolute path of vendored script NAME in the package."
  (expand-file-name name (file-name-directory (locate-library "b4x"))))

(defun b4x--maybe-wine-args ()
  "Return a flat list of --wineprefix flag+value for the vendored scripts.

We pass only the prefix; both scripts derive the B4X install root
(`Anywhere Software') from it by default.  The scripts use the two-argument
form (`--flag value'), not `--flag=value'."
  (let ((prefix (b4x-wine-resolve-prefix)))
    (if (file-directory-p prefix)
        (list "--wineprefix" prefix)
      nil)))

(defun b4x--run-script (script args)
  "Run SCRIPT with ARGS (a flat list) via `compile'."
  (unless (file-executable-p script)
    (user-error "Script not executable: %s" script))
  (let ((cmd (mapconcat #'shell-quote-argument (cons script args) " ")))
    (compile cmd)))

(defun b4x--build-command-args (proj)
  "Return the flat arg list (flags then positional) for `b4x-build.sh'."
  (let ((dir (b4x-project-project-dir proj))
        (pf (b4x-project-project-file proj)))
    ;; Flags first (--project <pf>, wine flags), then the positional project dir.
    (append (list "--project" pf)
            (b4x--maybe-wine-args)
            (list dir))))

(defun b4x--run-command-args (proj)
  "Return the flat arg list (flags then positional) for `b4x-run.sh'."
  (let ((dir (b4x-project-project-dir proj))
        args)
    (when b4x-build-port
      (setq args (append args (list "--port" (number-to-string b4x-build-port)))))
    (when b4x-java-opts
      (setq args (append args (list "--java-opts"
                                    (mapconcat #'identity b4x-java-opts " ")))))
    ;; Flags first, then the positional project dir.
    (append args (list dir))))

;;;###autoload
(defun b4x-build ()
  "Build the current B4X project with the vendored `b4x-build.sh'.

The vendored script takes host paths (the platform folder holding the
`.b4j'/`.b4a') and converts to Wine paths internally."
  (interactive)
  (let* ((proj (b4x--current-project))
         (script (b4x--script-path "scripts/b4x-build.sh")))
    (b4x--run-script script (b4x--build-command-args proj))))

;;;###autoload
(defun b4x-run-project ()
  "Run the current B4X project's jar with the vendored `b4x-run.sh'."
  (interactive)
  (let* ((proj (b4x--current-project))
         (script (b4x--script-path "scripts/b4x-run.sh")))
    (unless (eq (b4x-project-platform proj) 'b4j)
      (user-error "`b4x-run-project' currently supports only B4J jars; use `b4x-build' / `b4x-open-in-ide' for B4A"))
    (b4x--run-script script (b4x--run-command-args proj))))

(defun b4x--ensure-b4a-project (proj)
  "Signal an error unless PROJ is a B4A project."
  (unless (eq (b4x-project-platform proj) 'b4a)
    (user-error "This command currently supports only B4A projects"))
  proj)

(defun b4x--adb-base-args (&optional serial)
  "Return the base ADB argv, including an optional `-s SERIAL' selector."
  (let ((target (or serial b4x-adb-serial)))
    (append (when target (list "-s" target)))))

(defun b4x--adb-command-with-serial (serial &rest args)
  "Return a shell-safe ADB command line from ARGS targeting SERIAL.

When SERIAL is nil, the command uses the current default device selection."
  (mapconcat #'shell-quote-argument
             (cons b4x-adb-binary (append (b4x--adb-base-args serial) args))
             " "))

(defun b4x--adb-command (&rest args)
  "Return a shell-safe ADB command line from ARGS."
  (apply #'b4x--adb-command-with-serial nil args))

(defun b4x--adb-parse-devices (text)
  "Parse `adb devices -l' TEXT into a list of device plists.

Each plist includes at least `:serial', `:state', and `:label'."
  (let (out)
    (dolist (line (split-string text "\r?\n" t))
      (let ((trimmed (string-trim line)))
        (unless (or (string-empty-p trimmed)
                    (string-match-p (rx bos "List of devices attached" eos) trimmed)
                    (string-prefix-p "*" trimmed))
          (when (string-match
                 (rx bos
                     (group (+ (not (any blank))))
                     (+ blank)
                     (group (+ (not (any blank))))
                     (? (+ blank) (group (* nonl)))
                     eos)
                 trimmed)
            (let* ((serial (match-string 1 trimmed))
                   (state (match-string 2 trimmed))
                   (tail (or (match-string 3 trimmed) ""))
                   (model (when (string-match (rx "model:" (group (+ (not (any blank))))) tail)
                            (match-string 1 tail)))
                   (label (string-trim
                           (format "%s [%s]%s"
                                   serial state
                                   (if model (format " %s" model) "")))))
              (push (list :serial serial
                          :state state
                          :model model
                          :tail tail
                          :label label)
                    out))))))
    (nreverse out)))

(defun b4x--adb-list-devices ()
  "Return the current Android devices reported by `adb devices -l'."
  (b4x--adb-parse-devices
   (shell-command-to-string
    (mapconcat #'shell-quote-argument (list b4x-adb-binary "devices" "-l") " "))))

(defun b4x--adb-device-summary (devices)
  "Return a short human-readable summary string for DEVICES."
  (string-join
   (mapcar (lambda (dev)
             (format "%s=%s"
                     (plist-get dev :serial)
                     (plist-get dev :state)))
           devices)
   ", "))

(defun b4x--adb-resolve-serial (&optional require-ready prompt)
  "Return the Android device serial to use for helper commands.

If `b4x-adb-serial' is set, it wins.  Otherwise the function auto-selects the
sole connected device, reuses the last chosen device when still present, or
prompts when multiple candidates exist.  When REQUIRE-READY is non-nil, only
fully ready `device' entries are considered.  With PROMPT non-nil, always
prompt when candidates exist."
  (cond
   ((and b4x-adb-serial (not (string-empty-p b4x-adb-serial)))
    b4x-adb-serial)
   (t
    (let* ((devices (b4x--adb-list-devices))
           (pool (seq-filter (lambda (dev)
                               (if require-ready
                                   (string= (plist-get dev :state) "device")
                                 t))
                             devices))
           (last (and b4x--adb-last-serial
                      (seq-find (lambda (dev)
                                  (string= (plist-get dev :serial) b4x--adb-last-serial))
                                pool))))
      (cond
       ((and last (not prompt))
        (plist-get last :serial))
       ((null pool)
        (if require-ready
            (if devices
                (user-error "No ready Android devices (%s)" (b4x--adb-device-summary devices))
              (user-error "No Android devices found via `%s devices -l'" b4x-adb-binary))
          nil))
       ((and (= (length pool) 1) (not prompt))
        (setq b4x--adb-last-serial (plist-get (car pool) :serial)))
       (t
        (let* ((choices (mapcar (lambda (dev)
                                  (cons (plist-get dev :label) (plist-get dev :serial)))
                                pool))
               (choice (completing-read "Android device: " choices nil t)))
          (setq b4x--adb-last-serial (cdr (assoc choice choices))))))))))

(defun b4x--b4a-build-package (proj)
  "Return the Android package id declared by PROJ, or nil."
  (when-let ((build (car (b4x-project--collect-numbered "Build" (b4x-project-header proj)))))
    (let ((parts (split-string build "," t "[[:space:]]+")))
      (when (> (length parts) 1)
        (nth 1 parts)))))

(defun b4x--b4a-package-or-error (proj)
  "Return PROJ's Android package id, or signal a user error."
  (or (b4x--b4a-build-package proj)
      (user-error "Could not determine Android package id from BuildN=")))

(defun b4x--b4a-find-apk (proj)
  "Return the best APK candidate generated for the B4A project PROJ.

Prefers regular `.apk' files under `Objects/' and avoids common intermediate
names such as `unaligned' or split package archives when possible."
  (let* ((objects (expand-file-name "Objects" (b4x-project-project-dir proj)))
         (files (and (file-directory-p objects)
                     (directory-files-recursively objects "\\.apk\\'" t)))
         (ranked
          (sort (mapcar (lambda (f)
                          (list f
                                (if (string-match-p "unaligned\\|unsigned\\|split_" (downcase f)) 1 0)
                                (float-time (file-attribute-modification-time
                                             (file-attributes f)))))
                        files)
                (lambda (a b)
                  (if (= (nth 1 a) (nth 1 b))
                      (> (nth 2 a) (nth 2 b))
                    (< (nth 1 a) (nth 1 b)))))))
    (caar ranked)))

(defun b4x--b4a-launch-command (package &optional serial)
  "Return the ADB shell command that launches PACKAGE on SERIAL."
  (b4x--adb-command-with-serial serial
                                "shell" "monkey" "-p" package
                                "-c" "android.intent.category.LAUNCHER" "1"))

(defun b4x--b4a-force-stop-command (package &optional serial)
  "Return the ADB shell command that force-stops PACKAGE on SERIAL."
  (b4x--adb-command-with-serial serial
                                "shell" "am" "force-stop" package))

(defun b4x--b4a-uninstall-command (package &optional serial)
  "Return the ADB command that uninstalls PACKAGE from SERIAL."
  (b4x--adb-command-with-serial serial "uninstall" package))

(defun b4x--b4a-restart-command (package &optional serial)
  "Return the shell command that force-stops and relaunches PACKAGE on SERIAL."
  (format "%s && %s"
          (b4x--b4a-force-stop-command package serial)
          (b4x--b4a-launch-command package serial)))

(defun b4x--b4a-pidof (package &optional serial)
  "Return the device PID string for PACKAGE on SERIAL, or nil if unavailable."
  (let* ((cmd (b4x--adb-command-with-serial serial "shell" "pidof" "-s" package))
         (out (shell-command-to-string cmd))
         (pid (string-trim out)))
    (when (string-match-p (rx bos (+ digit) eos) pid)
      pid)))

(defun b4x--b4a-logcat-args (proj &optional serial)
  "Return the `adb logcat' argv list for PROJ on SERIAL.

Prefers PID filtering when the app is already running.  Otherwise falls back
to the quieter tag-based filter configured in `b4x-b4a-logcat-fallback-specs'."
  (let* ((pkg (b4x--b4a-build-package proj))
         (pid (and pkg (b4x--b4a-pidof pkg serial))))
    (append (b4x--adb-base-args serial)
            (if pid
                (list "logcat" (format "--pid=%s" pid))
              (append (list "logcat") b4x-b4a-logcat-fallback-specs)))))

(defun b4x--b4a-logcat-buffer ()
  "Return the dedicated B4A logcat buffer."
  (get-buffer-create b4x-b4a-logcat-buffer-name))

;;;###autoload
(defun b4x-b4a-select-device ()
  "Select the Android device to use for subsequent B4A helper commands.

The choice is cached in `b4x--adb-last-serial' for the current Emacs session.
Set `b4x-adb-serial' if you want a persistent explicit device override."
  (interactive)
  (let ((serial (b4x--adb-resolve-serial t t)))
    (message "B4X: selected Android device %s" serial)))

;;;###autoload
(defun b4x-b4a-install-apk ()
  "Install the current B4A project's APK on the selected Android device."
  (interactive)
  (let* ((proj (b4x--ensure-b4a-project (b4x--current-project)))
         (serial (b4x--adb-resolve-serial t))
         (apk (or (b4x--b4a-find-apk proj)
                  (user-error "No APK found under %s/Objects; build first"
                              (b4x-project-project-dir proj)))))
    (compile (b4x--adb-command-with-serial serial "install" "-r" apk))))

;;;###autoload
(defun b4x-b4a-uninstall-app ()
  "Uninstall the current B4A project's app from the selected Android device."
  (interactive)
  (let* ((proj (b4x--ensure-b4a-project (b4x--current-project)))
         (serial (b4x--adb-resolve-serial t))
         (pkg (b4x--b4a-package-or-error proj)))
    (compile (b4x--b4a-uninstall-command pkg serial))))

;;;###autoload
(defun b4x-b4a-launch-app ()
  "Launch the current B4A project on the selected Android device."
  (interactive)
  (let* ((proj (b4x--ensure-b4a-project (b4x--current-project)))
         (serial (b4x--adb-resolve-serial t))
         (pkg (b4x--b4a-package-or-error proj)))
    (compile (b4x--b4a-launch-command pkg serial))))

;;;###autoload
(defun b4x-b4a-restart-app ()
  "Force-stop and relaunch the current B4A project on the selected device."
  (interactive)
  (let* ((proj (b4x--ensure-b4a-project (b4x--current-project)))
         (serial (b4x--adb-resolve-serial t))
         (pkg (b4x--b4a-package-or-error proj)))
    (compile (b4x--b4a-restart-command pkg serial))))

;;;###autoload
(defun b4x-b4a-stop-logcat ()
  "Stop the running `b4x-b4a-logcat' process, if any."
  (interactive)
  (when-let* ((buf (get-buffer b4x-b4a-logcat-buffer-name))
              (proc (get-buffer-process buf)))
    (delete-process proc)
    (message "B4X: stopped logcat")))

;;;###autoload
(defun b4x-b4a-logcat (&optional clear)
  "Stream Android logcat for the current B4A project into `b4x-b4a-logcat-buffer-name'.

With prefix argument CLEAR, clear the selected device log first.  When the app
is already running and its PID can be resolved, filter logcat to that process.
Otherwise fall back to the quieter tag filter configured by
`b4x-b4a-logcat-fallback-specs'."
  (interactive "P")
  (let* ((proj (b4x--ensure-b4a-project (b4x--current-project)))
         (serial (b4x--adb-resolve-serial t))
         (pkg (b4x--b4a-build-package proj))
         (pid (and pkg (b4x--b4a-pidof pkg serial)))
         (buf (b4x--b4a-logcat-buffer)))
    (when clear
      (apply #'call-process b4x-adb-binary nil nil nil
             (append (b4x--adb-base-args serial) (list "logcat" "-c"))))
    (b4x-b4a-stop-logcat)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local default-directory (b4x-project-project-dir proj))))
    (let ((proc (make-process
                 :name "b4x-logcat"
                 :buffer buf
                 :command (cons b4x-adb-binary (b4x--b4a-logcat-args proj serial))
                 :noquery t
                 :filter (lambda (_proc chunk)
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (let ((inhibit-read-only t))
                                 (goto-char (point-max))
                                 (insert chunk))))))))
      (set-process-query-on-exit-flag proc nil)
      (display-buffer buf)
      (message "B4X: logcat %s%s"
               (if clear "(cleared) " "")
               (cond
                (pid (format "for %s (pid %s)" pkg pid))
                (pkg (format "for %s (filtered tags)" pkg))
                (t "(filtered tags)"))))))

(defun b4x--b4a-emulator-log-file ()
  "Return the log file used for detached Android emulator launches."
  (or b4x-b4a-emulator-log-file
      (expand-file-name "b4x-emulator.log" temporary-file-directory)))

(defun b4x--b4a-parse-avd-list (text)
  "Parse emulator `-list-avds' TEXT into a list of AVD names."
  (seq-filter (lambda (s) (not (string-empty-p s)))
              (mapcar #'string-trim (split-string text "\r?\n" t))))

(defun b4x--b4a-list-avds ()
  "Return the list of available Android AVD names."
  (b4x--b4a-parse-avd-list
   (shell-command-to-string
    (mapconcat #'shell-quote-argument (list b4x-emulator-binary "-list-avds") " "))))

(defun b4x--b4a-read-avd ()
  "Prompt for an AVD name, using `b4x-b4a-default-avd' when reasonable."
  (let* ((avds (b4x--b4a-list-avds))
         (default (and b4x-b4a-default-avd
                       (member b4x-b4a-default-avd avds)
                       b4x-b4a-default-avd)))
    (cond
     ((null avds)
      (user-error "No Android AVDs found via `%s -list-avds'" b4x-emulator-binary))
     ((and default (= (length avds) 1)) default)
     (t (completing-read "AVD: " avds nil t nil nil default)))))

(defun b4x--b4a-emulator-shell-command (avd)
  "Return a detached shell command that launches AVD with the Linux emulator."
  (let ((logfile (b4x--b4a-emulator-log-file)))
    (format "setsid nohup %s -avd %s %s </dev/null >>%s 2>&1 &"
            (shell-quote-argument b4x-emulator-binary)
            (shell-quote-argument avd)
            (mapconcat #'shell-quote-argument b4x-b4a-emulator-args " ")
            (shell-quote-argument logfile))))

(defun b4x--b4a-wait-script (&optional serial)
  "Return the shell script body that waits for Android boot completion via ADB.

When SERIAL is non-nil, target that specific Android device."
  (let ((adb (b4x--adb-command-with-serial serial)))
    (format "%s wait-for-device && until [ \"$(%s shell getprop sys.boot_completed 2>/dev/null | tr -d '\\r')\" = 1 ]; do sleep 2; done && echo Device ready"
            adb adb)))

(defun b4x--b4a-wait-shell-command (&optional serial)
  "Return a shell command that waits for Android boot completion via ADB.

When SERIAL is non-nil, target that specific Android device."
  (format "bash -lc %s"
          (shell-quote-argument (b4x--b4a-wait-script serial))))

(defun b4x--open-project-in-ide (proj)
  "Open PROJ in the official B4X IDE under Wine."
  (unless (b4x-wine-active-p)
    (user-error "Opening the IDE requires Wine (set `b4x-wine-enabled'/`b4x-wine-prefix')"))
  (let* ((spec (b4x--open-in-ide-command-args proj))
         (exe (car spec))
         (pf-win (cdr spec))
         (exe-win (b4x-host-to-wine-path exe))
         (prefix (b4x-wine-resolve-prefix))
         (logfile (b4x--ide-log-file))
         (default-directory (b4x-project-project-dir proj))
         (process-environment
          (cons (format "WINEPREFIX=%s" prefix) process-environment))
         (shell-cmd (format "setsid nohup %s %s %s </dev/null >>%s 2>&1 &"
                            (shell-quote-argument b4x-wine-binary)
                            (shell-quote-argument exe-win)
                            (shell-quote-argument pf-win)
                            (shell-quote-argument logfile))))
    (message "B4X: opening %s in the IDE (wine %s) — log: %s"
             (file-name-nondirectory (b4x-project-project-file proj))
             (file-name-nondirectory exe)
             logfile)
    (call-process-shell-command shell-cmd)))

;;;###autoload
(defun b4x-b4a-list-avds ()
  "Display the available Android AVD names discovered by the Linux emulator."
  (interactive)
  (let ((avds (b4x--b4a-list-avds)))
    (if avds
        (message "B4X: AVDs: %s" (string-join avds ", "))
      (message "B4X: no AVDs found"))))

;;;###autoload
(defun b4x-b4a-start-emulator (avd)
  "Start Android emulator AVD natively on Linux, detached from Emacs."
  (interactive (list (b4x--b4a-read-avd)))
  (call-process-shell-command (b4x--b4a-emulator-shell-command avd))
  (message "B4X: starting Android emulator `%s' — log: %s"
           avd (b4x--b4a-emulator-log-file)))

;;;###autoload
(defun b4x-b4a-wait-for-device ()
  "Wait for an Android device/emulator to become fully booted.

If multiple devices are currently visible and no explicit `b4x-adb-serial' is
configured, auto-select one target device for this wait command."
  (interactive)
  (compile (b4x--b4a-wait-shell-command (b4x--adb-resolve-serial nil))))

;;;###autoload
(defun b4x-b4a-debug-in-ide (&optional avd)
  "Prepare native Android tooling, then open the current B4A project in B4A IDE.

With prefix argument, prompt for an AVD and launch it natively first.  Then
wait for ADB/device boot completion asynchronously and finally open `B4A.exe'
under Wine so the official debugger can be used from the IDE.  If multiple
Android devices are already visible and no explicit `b4x-adb-serial' is set,
auto-select one target device for the wait step."
  (interactive (list (and current-prefix-arg (b4x--b4a-read-avd))))
  (let* ((proj (b4x--ensure-b4a-project (b4x--current-project)))
         (project-file (b4x-project-project-file proj))
         (serial (b4x--adb-resolve-serial nil))
         (buf (get-buffer-create b4x-b4a-device-buffer-name)))
    (when avd
      (call-process-shell-command (b4x--b4a-emulator-shell-command avd))
      (message "B4X: starting Android emulator `%s' — waiting for boot..." avd))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (compilation-mode)))
    (let ((proc (make-process :name "b4x-android-wait"
                              :buffer buf
                              :command (list "bash" "-lc" (b4x--b4a-wait-script serial))
                              :noquery t
                              :sentinel
                              (lambda (p _event)
                                (when (and (memq (process-status p) '(exit signal))
                                           (= (process-exit-status p) 0))
                                  (b4x--open-project-in-ide (b4x-load-project project-file))
                                  (message "B4X: device ready; project opened in B4A IDE. Use Run/Debug there."))))))
      (set-process-query-on-exit-flag proc nil)
      (display-buffer buf)
      (message "B4X: waiting for Android device/emulator%s..."
               (if serial (format " %s" serial) "")))))


;;; Open the B4X IDE under Wine

(defconst b4x--ide-exe
  '((b4j . "B4J.exe")
    (b4a . "B4A.exe")
    (b4i . "B4i.exe")
    (b4r . "B4R.exe"))
  "IDE executable name per B4X platform.")

(defun b4x--ide-exe-path (platform)
  "Return the host path of the IDE executable for PLATFORM, or nil.

Only `b4j'/`b4a' are typically available under a Linux Wine prefix."
  (when-let ((exe (cdr (assq platform b4x--ide-exe))))
    (when-let ((dir (b4x-find-wine-install-dir platform)))
      (let ((path (expand-file-name exe dir)))
        (and (file-executable-p path) path)))))

(defun b4x--open-in-ide-command-args (proj)
  "Return (EXE . PROJECT-WIN-PATH) for launching the IDE of PROJ."
  (let* ((platform (b4x-project-platform proj))
         (exe (or (b4x--ide-exe-path platform)
                  (user-error "No IDE executable found for %s under %s"
                              platform (b4x-wine-resolve-prefix))))
         (pf-win (b4x-host-to-wine-path (b4x-project-project-file proj))))
    (cons exe pf-win)))

;;;###autoload
(defun b4x-open-in-ide ()
  "Open the current B4X project in the official B4X IDE under Wine.

Launches `B4J.exe'/`B4A.exe' (from the Wine install dir) with the project
file as a Windows path.  The process is fully detached from Emacs
(`nohup ... </dev/null >>log 2>&1 &') so the GUI runs independently even
after Emacs is closed; Wine output is appended to `b4x-ide-log-file'."
  (interactive)
  (b4x--open-project-in-ide (b4x--current-project)))

(defun b4x--ide-log-file ()
  "Return the Wine log path used by `b4x-open-in-ide'."
  (or b4x-ide-log-file
      (expand-file-name "b4x-ide.log" temporary-file-directory)))

;;;###autoload
(defun b4x-ide-log ()
  "Display the Wine log produced by the last `b4x-open-in-ide'."
  (interactive)
  (let ((file (b4x--ide-log-file)))
    (if (file-readable-p file)
        (display-buffer (find-file-noselect file))
      (message "B4X: no IDE log yet at %s" file))))

;;; Layout & module navigation

;;;###autoload
(defun b4x-goto-layout (name)
  "Jump to the layout file referenced by NAME (or at point).

Recognizes `LoadLayout(\"NAME\")' on the current line; if point is on a
string or symbol matching a layout, uses it.  Otherwise prompts with
the project's known layouts for completion."
  (interactive
   (list (or (b4x--layout-name-at-point)
             (let ((proj (b4x--current-project)))
               (b4x--read-layout proj)))))
  (let* ((proj (b4x--current-project))
         (path (b4x-project-find-layout proj name)))
    (if path
        (find-file path)
      (user-error "Layout '%s' not found in %s" name
                  (b4x-project-project-file proj)))))

(defun b4x--layout-name-at-point ()
  "Return a layout name referenced on the current line, or nil.

Handles `LoadLayout(\"X\")', `XUI.LoadLayout(...)', and a bare string/symbol
at point that matches a declared layout."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (cond
     ;; LoadLayout("Name") anywhere on the line.
     ((string-match (rx "LoadLayout" (* space) "("
                        (* space) "\"" (group (+ (not (any "\"")))) "\"")
                    line)
      (match-string 1 line))
     ;; Point inside a quoted string matching a layout.
     ((and (nth 3 (syntax-ppss))
           (bounds-of-thing-at-point 'word))
      (let ((w (thing-at-point 'word t)))
        (when (b4x--known-layout-p w) w))))))

(defun b4x--known-layout-p (name)
  "Non-nil if NAME matches a layout in the current project."
  (and name
       (let ((proj (b4x-nav-current-project)))
         (and proj (b4x-project-find-layout proj name)))))

(defun b4x--read-layout (project)
  "Read a layout name from PROJECT's layouts, with completion."
  (let* ((layouts (b4x-project-layout-files project))
         (names (mapcar #'car layouts)))
    (if (null names)
        (user-error "No layout files found for %s"
                    (b4x-project-project-file project))
      (completing-read "Layout: " names nil t))))

;;;###autoload
(defun b4x-switch-module ()
  "Switch to another module of the current B4X project."
  (interactive)
  (let* ((proj (b4x--current-project))
         (current (buffer-file-name))
         ;; Include the project file itself alongside its modules.
         (candidates (cons (cons (format "%s (project file)"
                                         (file-name-nondirectory
                                          (b4x-project-project-file proj)))
                                 (b4x-project-project-file proj))
                           (mapcar (lambda (m)
                                     (cons (file-name-nondirectory m) m))
                                   (b4x-project-modules proj))))
         (choice (completing-read
                  "Module: "
                  (lambda (string pred action)
                    (complete-with-action action candidates string pred))
                  nil t nil nil
                  (and current
                       (or (car (rassoc current candidates))
                           (file-name-nondirectory current))))))
    (find-file (cdr (assoc choice candidates)))))

;;; Dispatch menu (transient)

;;;###autoload
(transient-define-prefix b4x-dispatch ()
  "B4X dispatch menu."
  [["Project"
    ("o" "Open project"       b4x-open-project)
    ("i" "Project info"        b4x-project-info)
    ("S" "List libraries"      b4x-list-available-libraries)
    ("v" "Version"             b4x-version)
    ("n" "New module"          b4x-new-module)
    ("s" "Add library"         b4x-add-library)
    ("k" "Remove library"      b4x-remove-library)
    ("m" "Switch module"       b4x-switch-module)
    ("l" "Jump to layout"      b4x-goto-layout)]
   ["Layouts"
    ("j" "Open JSON sidecar"   b4x-layout-open-json)
    ("x" "Export -> JSON"      b4x-layout-export)
    ("I" "Import <- JSON"      b4x-layout-import)
    ("y" "Sync project"        b4x-layout-sync-project)]
   ["Build & Run"
    ("c" "Build"               b4x-build)
    ("r" "Run"                 b4x-run-project)
    ("e" "Open in B4X IDE"    b4x-open-in-ide)
    ("L" "Show IDE log"        b4x-ide-log)]
   ["B4A / Android"
    ("a s" "Select device"     b4x-b4a-select-device)
    ("a v" "List AVDs"         b4x-b4a-list-avds)
    ("a e" "Start emulator"    b4x-b4a-start-emulator)
    ("a w" "Wait for device"   b4x-b4a-wait-for-device)
    ("a d" "Debug in B4A IDE"  b4x-b4a-debug-in-ide)
    ("a i" "Install APK"       b4x-b4a-install-apk)
    ("a u" "Uninstall app"     b4x-b4a-uninstall-app)
    ("a l" "Launch app"        b4x-b4a-launch-app)
    ("a r" "Restart app"       b4x-b4a-restart-app)
    ("a g" "Logcat"            b4x-b4a-logcat)
    ("a k" "Stop logcat"       b4x-b4a-stop-logcat)]])

;;; Compilation mode tweaks

(with-eval-after-load 'compile
  ;; B4JBuilder / javac error lines look like "file.bas:12: error: ..."
  (add-to-list 'compilation-error-regexp-alist-alist
               '(b4x-line "\\(.+\\):\\([0-9]+\\):" 1 2))
  (add-to-list 'compilation-error-regexp-alist 'b4x-line))

(provide 'b4x)
;;; b4x.el ends here
