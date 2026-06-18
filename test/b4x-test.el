;;; b4x-test.el --- ERT tests for the B4X project model -*- lexical-binding: t; -*-

;; Run from repo root:
;;   emacs -Q --batch -L emacs -l test/b4x-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'b4x-project)
(require 'b4x-wine)
(require 'b4x-nav)
(require 'b4x-flymake)
(require 'b4x)

(defconst b4x-test--proyprueba
  (expand-file-name "~/dev/B4XProj/ProyPrueba/B4J/ProyPrueba.b4j")
  "Real B4J project file used for integration tests on this machine.")

(defconst b4x-test--jetty
  (expand-file-name "~/dev/B4XProj/jetty12-Test/jetty12-Test.b4j")
  "Another real B4J project (flat layout, no platform subfolder).")

(defun b4x-test--project-exists-p (file)
  "Non-nil if FILE exists on disk (skips tests otherwise)."
  (and file (file-regular-p file)))

(defmacro b4x-test-skip-unless (file &rest body)
  "Run BODY unless FILE is missing."
  (declare (indent 1))
  `(if (b4x-test--project-exists-p ,file)
       (progn ,@body)
     (ert-skip (format "%s not present on this machine" ,file))))


;;; Path translation (deterministic, no subprocess)

(ert-deftest b4x-wine/windows-drive-detection ()
  (should (b4x-windows-path-p "C:\\Program Files"))
  (should (b4x-windows-path-p "Z:/home/foo"))
  (should (b4x-windows-path-p "D:"))
  (should-not (b4x-windows-path-p "/home/foo"))
  (should-not (b4x-windows-path-p "relative/path")))

(ert-deftest b4x-wine/z-drive-maps-to-host-root ()
  "Z:\\ paths resolve under the host root regardless of prefix contents."
  (should (equal (b4x-wine-path-to-host "Z:\\home\\devgiu\\dev\\B4XAdditionalLibs")
                 "/home/devgiu/dev/B4XAdditionalLibs")))

(ert-deftest b4x-wine/relative-with-base ()
  (should (equal (b4x-wine-path-to-host "..\\B4XMainPage" "/home/x/Proj/B4J")
                 "/home/x/Proj/B4XMainPage"))
  (should (equal (b4x-wine-path-to-host "foo/bar" "/root")
                 "/root/foo/bar")))

(ert-deftest b4x-wine/posix-absolute-passthrough ()
  (should (equal (b4x-wine-path-to-host "/usr/local/bin")
                 "/usr/local/bin")))

(ert-deftest b4x-wine/host-to-wine-fallback ()
  "Without relying on winepath availability, the fallback maps Z: correctly."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) 1)))          ; force fallback path
    (should (equal (b4x-host-to-wine-path "/home/devgiu/dev/B4XAdditionalLibs")
                   "Z:\\home\\devgiu\\dev\\B4XAdditionalLibs"))))


;;; Header parsing unit tests

(ert-deftest b4x-project/parse-header-basics ()
  (let ((parsed (b4x-project--parse-header
                 "AppType=JavaFX\nLibrary1=jcore\nLibrary2=jfx\nModule1=|relative|..\\B4XMainPage\n@EndOfDesignText@\nSub Process_Globals\nEnd Sub")))
    (let ((header (car parsed))
          (main (cdr parsed)))
      (should (equal (cdr (assoc "AppType" header)) "JavaFX"))
      (should (equal (b4x-project--collect-numbered "Library" header)
                     '("jcore" "jfx")))
      (should (string-prefix-p "Sub Process_Globals" (string-trim main))))))

(ert-deftest b4x-project/module-spec-kinds ()
  (should (equal (b4x-project--parse-module-spec "|relative|..\\B4XMainPage")
                 '(relative . "..\\B4XMainPage")))
  (should (equal (b4x-project--parse-module-spec "|absolute|C:\\mods\\Foo")
                 '(absolute . "C:\\mods\\Foo")))
  (should (equal (b4x-project--parse-module-spec "|shared|Util")
                 '(shared . "Util")))
  (should (equal (b4x-project--parse-module-spec "PlainMod")
                 '(plain . "PlainMod"))))


;;; Integration against real projects

(ert-deftest b4x-project/proyprueba-model ()
  (b4x-test-skip-unless b4x-test--proyprueba
    (let ((proj (b4x-load-project b4x-test--proyprueba)))
      (should (eq (b4x-project-platform proj) 'b4j))
      (should (equal (b4x-project-app-type proj) "JavaFX"))
      ;; Libraries from LibraryN.
      (should (equal (b4x-project-libraries proj) '("jcore" "jfx" "b4xpages")))
      ;; Root is the parent of the B4J/ folder.
      (should (equal (b4x-project-root-dir proj)
                     (expand-file-name "~/dev/B4XProj/ProyPrueba")))
      ;; Modules resolve to actual .bas files under the project root.
      (should (member (expand-file-name "~/dev/B4XProj/ProyPrueba/B4XMainPage.bas")
                      (b4x-project-modules proj)))
      (should (member (expand-file-name "~/dev/B4XProj/ProyPrueba/Test.bas")
                      (b4x-project-modules proj)))
      ;; Main code was extracted (non-empty).
      (should (> (length (b4x-project-main-code proj)) 0)))))

(ert-deftest b4x-project/proyprueba-ini-discovery ()
  (b4x-test-skip-unless b4x-test--proyprueba
    (let ((proj (b4x-load-project b4x-test--proyprueba)))
      (should (b4x-project-ini-path proj))
      (should (file-regular-p (b4x-project-ini-path proj)))
      ;; The additional libs folder from the INI should translate to a host path.
      (let ((folders (b4x-ini-folders (b4x-project-ini-path proj))))
        (should (equal (cdr (assq 'additional-libraries-folder folders))
                       "/home/devgiu/dev/B4XAdditionalLibs"))))))

(ert-deftest b4x-project/jetty-flat-layout ()
  (b4x-test-skip-unless b4x-test--jetty
    (let ((proj (b4x-load-project b4x-test--jetty)))
      (should (eq (b4x-project-platform proj) 'b4j))
      ;; Flat layout: root == dir of the project file (no trailing slash).
      (should (equal (b4x-project-root-dir proj)
                     (directory-file-name
                      (file-name-directory b4x-test--jetty)))))))

(provide 'b4x-test)
;;; b4x-test.el ends here


;;; Navigation: symbol parser + table

(ert-deftest b4x-nav/parse-source-subs-types-globals ()
  (let ((syms (b4x-nav--parse-source
               "Sub Process_Globals\n  Dim A As Int\n  Private B, C As String\nEnd Sub\n\nSub AppStart (Args() As String)\nEnd Sub\n\nPublic Sub Foo\nEnd Sub\n\nType MyType\n  X As Int\nEnd Type"
               "/fake/mod.bas")))
    (let ((names (mapcar #'b4x-sym-name syms))
          (kinds (mapcar #'b4x-sym-kind syms)))
      ;; Process_Globals is NOT indexed as a sub (it is a globals section).
      (should-not (member "Process_Globals" names))
      ;; AppStart and Foo are subs.
      (should (member "AppStart" names))
      (should (member "Foo" names))
      (should (member 'sub kinds))
      ;; MyType is a type.
      (should (member "MyType" names))
      (should (member 'type kinds))
      ;; Globals A, B, C indexed; X (inside Type) is NOT (only globals sections).
      (should (member "A" names))
      (should (member "B" names))
      (should (member "C" names))
      (should-not (member "X" names))))

  ;; Visibility detection.
  (let ((s (car (b4x-nav--parse-source "Private Sub Secret\nEnd Sub" "/f.bas"))))
    (should (eq (b4x-sym-visibility s) 'private))))

(ert-deftest b4x-nav/table-build-and-lookup ()
  (b4x-test-skip-unless b4x-test--proyprueba
    (let* ((proj (b4x-load-project b4x-test--proyprueba))
           (tab (b4x-nav-build-table proj)))
      ;; AppStart lives in the embedded Main code (the .b4j itself).
      (should (b4x-nav-lookup tab "AppStart"))
      ;; A symbol declared in a resolved module should be found.
      (should (> (length (b4x-symtab-files tab)) 0))
      ;; Lookup is case-insensitive.
      (should (equal (b4x-nav-lookup tab "appstart")
                     (b4x-nav-lookup tab "AppStart"))))))

(ert-deftest b4x-nav/imenu-current-buffer ()
  (with-temp-buffer
    (insert-file-contents b4x-test--proyprueba)
    (b4x-mode)
    (let ((idx (b4x-imenu-index)))
      (should (consp idx))
      ;; AppStart is a Sub in the project file's Main code.
      (should (member "Subs" (mapcar #'car idx))))))


;;; Flymake: duplicate-symbol + type-placement (pure logic)

(defun b4x-test--symtab (syms)
  "Build a `b4x-symtab' containing SYMS."
  (let ((tab (make-b4x-symtab)))
    (dolist (s syms) (b4x-nav--add-sym tab s))
    tab))

(ert-deftest b4x-flymake/duplicate-across-files ()
  ;; `Foo' exists in THIS file and in another module -> duplicate.
  (let* ((this "/proj/Main.bas")
         (live (list (make-b4x-sym :name "Foo" :kind 'sub :file this :line 5
                                   :visibility 'default)))
         (disk (b4x-test--symtab
                (list (make-b4x-sym :name "Foo" :kind 'sub
                                    :file "/proj/Other.bas" :line 9
                                    :visibility 'default)
                      (make-b4x-sym :name "Foo" :kind 'sub :file this :line 5
                                    :visibility 'default)))))
    (should (equal (list "/proj/Other.bas")
                   (mapcar #'b4x-sym-file
                           (b4x-flymake--foreign-dups (car live) this disk))))))

(ert-deftest b4x-flymake/private-sub-not-flagged ()
  ;; A Private Sub sharing a name with another file is intentionally ignored.
  ;; The skip happens at `b4x-flymake--dup-diagnostics' (the live symbol is
  ;; private); `foreign-dups' only filters OTHER private subs.
  (let* ((this "/proj/Main.bas")
         (live (list (make-b4x-sym :name "Helper" :kind 'sub :file this :line 3
                                   :visibility 'private)))
         (disk (b4x-test--symtab
                (list (make-b4x-sym :name "Helper" :kind 'sub
                                    :file "/proj/Other.bas" :line 1
                                    :visibility 'default)))))
    (should (b4x-flymake--private-sub-p (car live)))
    ;; No diagnostics are produced for a private live symbol.
    (should (null (b4x-flymake--dup-diagnostics live this disk)))))

(ert-deftest b4x-flymake/unique-symbol-not-flagged ()
  (let* ((this "/proj/Main.bas")
         (live (list (make-b4x-sym :name "Bar" :kind 'sub :file this :line 1
                                   :visibility 'default)))
         (disk (b4x-test--symtab
                (list (make-b4x-sym :name "Bar" :kind 'sub :file this :line 1
                                    :visibility 'default)))))
    (should-not (b4x-flymake--foreign-dups (car live) this disk))))

(ert-deftest b4x-flymake/type-inside-globals-ok ()
  (let ((lines (split-string
                "Sub Class_Globals\n  Type T\n    X As Int\n  End Type\nEnd Sub"
                "\n")))
    ;; `Type T' on line 2, Class_Globals header on line 1 -> inside.
    (should (b4x-flymake--inside-globals-p 2 lines))))

(ert-deftest b4x-flymake/type-outside-globals-flagged ()
  (let ((lines (split-string
                "Sub AppStart\nEnd Sub\n\nType T\n  X As Int\nEnd Type"
                "\n")))
    ;; `Type T' on line 4, no globals header within lookback -> outside.
    (should-not (b4x-flymake--inside-globals-p 4 lines))))


;;; Layouts & Files

(ert-deftest b4x-project/layout-ext-per-platform ()
  ;; Pure: construct a minimal project to test the extension mapping.
  (let ((b4j (make-b4x-project :platform 'b4j))
        (b4a (make-b4x-project :platform 'b4a))
        (b4i (make-b4x-project :platform 'b4i))
        (b4r (make-b4x-project :platform 'b4r)))
    (should (equal (b4x-project-layout-ext b4j) "bjl"))
    (should (equal (b4x-project-layout-ext b4a) "bal"))
    (should (equal (b4x-project-layout-ext b4i) "bil"))
    (should (equal (b4x-project-layout-ext b4r) nil))))

(ert-deftest b4x-project/proyprueba-layouts ()
  (b4x-test-skip-unless b4x-test--proyprueba
    (let* ((proj (b4x-load-project b4x-test--proyprueba))
           (layouts (b4x-project-layout-files proj)))
      ;; Header declares File1=MainPage.bjl -> MainPage resolved on disk.
      (should (assoc "MainPage" layouts))
      (should (file-regular-p (cdr (assoc "MainPage" layouts))))
      ;; Case-insensitive lookup.
      (should (b4x-project-find-layout proj "mainpage"))
      ;; A non-existent layout resolves to nil.
      (should-not (b4x-project-find-layout proj "DoesNotExist")))))

(ert-deftest b4x-project/proyectopages-multiple-layouts ()
  (let ((pf (expand-file-name "~/dev/B4XProj/ProyectoPages/B4J/ProyectoPages.b4j")))
    (b4x-test-skip-unless pf
      (let* ((proj (b4x-load-project pf))
             (names (mapcar #'car (b4x-project-layout-files proj))))
        (should (member "MainPage" names))
        (should (member "OtraPaginaMas" names))))))


;;; Layout name detection from source

(ert-deftest b4x-layout-name-from-loadlayout ()
  (cl-letf (((symbol-function 'b4x--known-layout-p)
             (lambda (n) (member n '("MainPage" "Other")))))
    (with-temp-buffer
      (b4x-mode)
      (insert "Sub B4XPage_Created (Root1 As B4XView)\n"
              "\tRoot1.LoadLayout(\"MainPage\")\n"
              "End Sub\n")
      (goto-char (point-min))
      (re-search-forward "LoadLayout")
      (should (equal (b4x--layout-name-at-point) "MainPage")))))

(ert-deftest b4x-compile/regexp-registration-shape ()
  (require 'compile)
  (should (memq 'b4x-line compilation-error-regexp-alist))
  (let ((entry (assoc 'b4x-line compilation-error-regexp-alist-alist)))
    (should entry)
    (should (stringp (nth 1 entry)))
    (should (equal (nth 2 entry) 1))
    (should (equal (nth 3 entry) 2))))
