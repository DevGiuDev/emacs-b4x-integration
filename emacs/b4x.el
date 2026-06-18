;;; b4x.el --- B4X (B4J/B4A) development for Emacs, Linux/Wine first -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; Author: emacs-b4x-integration
;; Keywords: languages, tools
;; Version: 0.1.0
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
;;   C-c C-m   switch module
;;   C-c C-l   jump to layout (from `LoadLayout("...")' or via completion)
;;   C-c C-c   build
;;   C-c C-r   run
;;   C-c C-e   open in the official B4X IDE under Wine

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'project)
(require 'transient)
(require 'b4x-wine)
(require 'b4x-project)
(require 'b4x-nav)
(require 'b4x-flymake)


;;; Customization

(defgroup b4x nil
  "B4X (B4J/B4A) development for Emacs."
  :group 'languages
  :link '(url-link "https://github.com/emacs-b4x-integration"))

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
    (define-key map (kbd "C-c C-l") #'b4x-goto-layout)
    (define-key map (kbd "C-c C-m") #'b4x-switch-module)
    (define-key map (kbd "C-c C-d") #'b4x-dispatch)
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
  (add-hook 'after-save-hook #'b4x-nav--clear-cache nil t))

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
  (let ((proj (b4x--current-project)))
    (with-current-buffer (get-buffer-create "*B4X Project*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Project:    %s\n" (b4x-project-project-file proj)))
        (insert (format "Platform:   %s\n" (b4x-project-platform proj)))
        (insert (format "AppType:    %s\n" (or (b4x-project-app-type proj) "-")))
        (insert (format "Version:    %s\n" (or (b4x-project-version proj) "-")))
        (insert (format "Root:       %s\n" (b4x-project-root-dir proj)))
        (insert (format "INI:        %s\n" (or (b4x-project-ini-path proj) "-")))
        (insert (format "Libraries:  %s\n" (b4x-project-libraries proj)))
        (insert "\nModules:\n")
        (dolist (m (b4x-project-modules proj))
          (insert (format "  - %s\n" m))))
      (goto-char (point-min))
      (view-mode 1)
      (display-buffer (current-buffer)))))


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

Both vendored scripts take host paths (the platform folder holding the .b4j)
and convert to Wine paths internally."
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
    (b4x--run-script script (b4x--run-command-args proj))))


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
file as a Windows path.  The process is detached so Emacs stays responsive
while the IDE GUI runs."
  (interactive)
  (unless (b4x-wine-active-p)
    (user-error "Opening the IDE requires Wine (set `b4x-wine-enabled'/`b4x-wine-prefix')"))
  (let* ((proj (b4x--current-project))
         (spec (b4x--open-in-ide-command-args proj))
         (exe (car spec))
         (pf-win (cdr spec))
         (exe-win (b4x-host-to-wine-path exe))
         (prefix (b4x-wine-resolve-prefix))
         (buffer (get-buffer-create "*B4X IDE*"))
         (process-environment
          (cons (format "WINEPREFIX=%s" prefix) process-environment)))
    (message "B4X: opening %s in the IDE (wine %s) ..."
             (file-name-nondirectory (b4x-project-project-file proj))
             (file-name-nondirectory exe))
    (start-file-process "b4x-ide" buffer b4x-wine-binary exe-win pf-win)))

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
    ("m" "Switch module"       b4x-switch-module)
    ("l" "Jump to layout"      b4x-goto-layout)]
   ["Build & Run"
    ("c" "Build"               b4x-build)
    ("r" "Run"                 b4x-run-project)
    ("e" "Open in B4X IDE"    b4x-open-in-ide)]])

;;; Compilation mode tweaks

(with-eval-after-load 'compile
  ;; B4JBuilder / javac error lines look like "file.bas:12: error: ..."
  (add-to-list 'compilation-error-regexp-alist
               (list 'b4x-line "\\(.+\\):\\([0-9]+\\):" 1 2)))

(provide 'b4x)
;;; b4x.el ends here
