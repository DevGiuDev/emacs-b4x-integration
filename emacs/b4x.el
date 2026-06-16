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

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'project)
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
    (define-key map (kbd "C-c C-o") #'b4x-open-project)
    (define-key map (kbd "C-c C-i") #'b4x-project-info)
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

(defun b4x--maybe-wine-flags ()
  "Return a list of --wineprefix/--b4x-root flags from the active config."
  (let ((prefix (b4x-wine-resolve-prefix))
        (root (when (b4x-wine-active-p) (b4x-find-wine-install-dir 'b4j))))
    (delq nil
          (list (and (file-directory-p prefix)
                     (format "--wineprefix=%s" prefix))
                (and root (format "--b4x-root=%s" root))))))

(defun b4x--run-script (script args)
  "Run SCRIPT with ARGS (a list) via `compile'."
  (unless (file-executable-p script)
    (user-error "Script not executable: %s" script))
  (let ((cmd (mapconcat #'shell-quote-argument (cons script args) " ")))
    (compile cmd)))

;;;###autoload
(defun b4x-build ()
  "Build the current B4X project with the vendored `b4x-build.sh'.

Both vendored scripts take host paths (the platform folder holding the .b4j)
and convert to Wine paths internally."
  (interactive)
  (let* ((proj (b4x--current-project))
         (script (b4x--script-path "scripts/b4x-build.sh"))
         (dir (b4x-project-project-dir proj))
         (pf (b4x-project-project-file proj))
         (args (append (list dir (format "--project=%s" pf))
                       (b4x--maybe-wine-flags))))
    (b4x--run-script script args)))

;;;###autoload
(defun b4x-run-project ()
  "Run the current B4X project's jar with the vendored `b4x-run.sh'."
  (interactive)
  (let* ((proj (b4x--current-project))
         (script (b4x--script-path "scripts/b4x-run.sh"))
         (dir (b4x-project-project-dir proj))
         (extra (append (and b4x-build-port
                             (list (format "--port=%d" b4x-build-port)))
                        (and b4x-java-opts
                             (list (format "--java-opts=%s"
                                           (mapconcat #'identity
                                                      b4x-java-opts " ")))))))
    (b4x--run-script script (cons dir extra))))


;;; Compilation mode tweaks

(with-eval-after-load 'compile
  ;; B4JBuilder / javac error lines look like "file.bas:12: error: ..."
  (add-to-list 'compilation-error-regexp-alist
               (list 'b4x-line "\\(.+\\):\\([0-9]+\\):" 1 2)))

(provide 'b4x)
;;; b4x.el ends here
