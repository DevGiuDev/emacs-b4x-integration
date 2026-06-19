;;; b4x-test.el --- ERT tests for the B4X project model -*- lexical-binding: t; -*-

;; Run from repo root:
;;   emacs -Q --batch -L emacs -l test/b4x-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'b4x-project)
(require 'b4x-wine)
(require 'b4x-nav)
(require 'b4x-flymake)
(require 'b4x-layout)
(require 'b4x)

(defconst b4x-test--proyprueba
  (expand-file-name "~/dev/B4XProj/ProyPrueba/B4J/ProyPrueba.b4j")
  "Real B4J project file used for integration tests on this machine.")

(defconst b4x-test--jetty
  (expand-file-name "~/dev/B4XProj/jetty12-Test/jetty12-Test.b4j")
  "Another real B4J project (flat layout, no platform subfolder).")

(defconst b4x-test--emacs-testing
  (expand-file-name "~/dev/B4XProj/emacs-testing/B4J/emacs-testing.b4j")
  "Real multi-platform B4XPages project with shared root + B4J subfolder.")

(defconst b4x-test--emacs-testing-bjl
  (expand-file-name "~/dev/B4XProj/emacs-testing/B4J/Files/MainPage.bjl")
  "Real B4J layout used for layout-converter tests.")

(defconst b4x-test--emacs-testing-bal
  (expand-file-name "~/dev/B4XProj/emacs-testing/B4A/Files/mainpage.bal")
  "Real B4A layout used for layout-converter tests.")

(defconst b4x-test--emacs-testing-bil
  (expand-file-name "~/dev/B4XProj/emacs-testing/B4i/Files/mainpage.bil")
  "Real B4I layout used for layout-converter tests.")

(defconst b4x-test--birthday-reminder-b4a
  (expand-file-name "~/dev/B4XProj/B4X-Birthday-Reminder/B4A/BirthdayReminder.b4a")
  "Real B4A client project used for Android workflow smoke tests.")

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

(ert-deftest b4x-wine/winepath-output-noise-is-ignored ()
  "Ignore Wine noise and keep only the final Windows path from `winepath'."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _args)
               (insert "002c:fixme:winediag:loader_init noise\n")
               (insert "C:\\Program Files\\Anywhere Software\\B4J\\B4J.exe\n")
               0)))
    (should (equal (b4x-host-to-wine-path
                    (expand-file-name
                     "~/.wine_b4x/drive_c/Program Files/Anywhere Software/B4J/B4J.exe"))
                   "C:\\Program Files\\Anywhere Software\\B4J\\B4J.exe"))))


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

(ert-deftest b4x-project/emacs-testing-b4xpages-layout ()
  (b4x-test-skip-unless b4x-test--emacs-testing
    (let* ((proj (b4x-load-project b4x-test--emacs-testing))
           (root (expand-file-name "~/dev/B4XProj/emacs-testing"))
           (layouts (b4x-project-layout-files proj)))
      (should (eq (b4x-project-platform proj) 'b4j))
      (should (equal (b4x-project-root-dir proj) root))
      (should (equal (b4x-project-app-type proj) "JavaFX"))
      (should (member (expand-file-name "~/dev/B4XProj/emacs-testing/B4XMainPage.bas")
                      (b4x-project-modules proj)))
      (should (assoc "MainPage" layouts))
      (should (equal (cdr (assoc "MainPage" layouts))
                     (expand-file-name "~/dev/B4XProj/emacs-testing/B4J/Files/MainPage.bjl"))))))

(ert-deftest b4x-project/emacs-testing-project-current-from-shared-and-layout ()
  (b4x-test-skip-unless b4x-test--emacs-testing
    (dolist (dir (list (file-name-directory "~/dev/B4XProj/emacs-testing/B4XMainPage.bas")
                       (file-name-directory "~/dev/B4XProj/emacs-testing/B4J/Files/MainPage.bjl")
                       (file-name-directory b4x-test--emacs-testing)))
      (should (equal (project-current nil (expand-file-name dir))
                     '(b4x . "/home/devgiu/dev/B4XProj/emacs-testing"))))))

(ert-deftest b4x-layout/read-real-b4j-layout ()
  (b4x-test-skip-unless b4x-test--emacs-testing-bjl
    (let* ((layout (b4x-layout-read-file b4x-test--emacs-testing-bjl))
           (header (b4x-layout-object-get layout "LayoutHeader"))
           (variants (b4x-layout-object-get layout "Variants"))
           (data (b4x-layout-object-get layout "Data")))
      (should (b4x-layout-object-p layout))
      (should (b4x-layout-object-p header))
      (should (= (b4x-layout-object-get header "Version") 5))
      (should (= (length variants) 1))
      (should (equal (b4x-layout-object-get data "name") "Main")))))

(ert-deftest b4x-layout/binary-roundtrip-real-layouts ()
  (dolist (file (list b4x-test--emacs-testing-bjl
                      b4x-test--emacs-testing-bal
                      b4x-test--emacs-testing-bil))
    (b4x-test-skip-unless file
      (let* ((layout (b4x-layout-read-file file))
             (tmp (make-temp-file "b4x-layout-" nil
                                  (concat "." (file-name-extension file)))))
        (unwind-protect
            (progn
              (b4x-layout-write-file layout tmp)
              (should (b4x-layout-equal-p layout (b4x-layout-read-file tmp))))
          (when (file-exists-p tmp)
            (delete-file tmp)))))))

(ert-deftest b4x-layout/json-roundtrip-real-layout ()
  (b4x-test-skip-unless b4x-test--emacs-testing-bjl
    (let* ((layout (b4x-layout-read-file b4x-test--emacs-testing-bjl))
           (json (make-temp-file "b4x-layout-" nil ".json"))
           (tmp (make-temp-file "b4x-layout-" nil ".bjl")))
      (unwind-protect
          (progn
            (b4x-layout-write-json-file layout json)
            (b4x-layout-write-file (b4x-layout-read-json-file json) tmp)
            (should (b4x-layout-equal-p layout (b4x-layout-read-file tmp))))
        (when (file-exists-p json) (delete-file json))
        (when (file-exists-p tmp) (delete-file tmp))))))

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

(ert-deftest b4x-nav/table-cache-uses-string-equality ()
  (let ((build-count 0)
        (b4x-nav--table-cache nil))
    (cl-letf (((symbol-function 'b4x-nav-current-project)
               (lambda ()
                 ;; Fresh string object each call: `eq' would miss this cache.
                 (make-b4x-project :project-file (copy-sequence "/tmp/Demo.b4j"))))
              ((symbol-function 'b4x-nav-build-table)
               (lambda (proj)
                 (cl-incf build-count)
                 (make-b4x-symtab :project proj))))
      (should (b4x-nav-table))
      (should (b4x-nav-table))
      (should (= build-count 1)))))

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

(ert-deftest b4x-version/runtime-version-is-queryable ()
  (should (stringp b4x-package-version))
  (should (string-match-p "^B4X " (b4x-version-string)))
  (should (string-match-p (regexp-quote b4x-package-version)
                          (b4x-version-string)))
  (should (equal (b4x-version) (b4x-version-string))))

(ert-deftest b4x-project/remember-project-integrates-with-project-el ()
  (let* ((proj (make-b4x-project :root-dir "/tmp/demo-b4x-root"))
         remembered)
    (cl-letf (((symbol-function 'project-remember-project)
               (lambda (pr &optional _no-write)
                 (setq remembered pr))))
      (b4x--remember-project proj)
      (should (equal remembered '(b4x . "/tmp/demo-b4x-root"))))))

(defun b4x-test--write (file content)
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert content)))

(defun b4x-test--write-b4xlib (archive files)
  "Create ARCHIVE as a `.b4xlib' zip from FILES alist of (NAME . CONTENT)."
  (unless (executable-find "python3")
    (error "python3 is required to build test .b4xlib archives"))
  (let ((srcdir (make-temp-file "b4xlib-src-" t)))
    (unwind-protect
        (progn
          (dolist (entry files)
            (b4x-test--write (expand-file-name (car entry) srcdir) (cdr entry)))
          (with-temp-buffer
            (unless (eq 0 (call-process "python3" nil t nil "-c"
                                        (concat
                                         "import os, sys, zipfile\n"
                                         "archive, src = sys.argv[1], sys.argv[2]\n"
                                         "with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:\n"
                                         "    for root, _, files in os.walk(src):\n"
                                         "        for f in files:\n"
                                         "            p = os.path.join(root, f)\n"
                                         "            z.write(p, os.path.relpath(p, src))\n")
                                        archive srcdir))
              (error "Failed to create %s: %s" archive (buffer-string)))))
      (delete-directory srcdir t))))

(ert-deftest b4x-project/library-xml-api-parsing-and-candidates ()
  (let* ((root (make-temp-file "b4x-libxml-" t))
         (platform-dir (expand-file-name "B4J" root))
         (core-dir (expand-file-name "core-libs" root))
         (ini-file (expand-file-name "b4xV5.ini" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir))
         (xml-file (expand-file-name "Foo.xml" core-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (make-directory core-dir t)
          (b4x-test--write
           xml-file
           (mapconcat #'identity
                      '("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                        "<root>"
                        "  <class>"
                        "    <name>demo.wrapper.FooWrapper</name>"
                        "    <shortname>Foo</shortname>"
                        "    <event>Ready (Success As Boolean)</event>"
                        "    <method><name>Bar</name></method>"
                        "    <property><name>Baz</name></property>"
                        "  </class>"
                        "</root>")
                      "\n"))
          (b4x-test--write ini-file (format "LibrariesFolder=%s\n" core-dir))
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Library1=Foo"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@")
                      "\n"))
          (let* ((proj (b4x-load-project project-file ini-file))
                 (apis (b4x-project-library-apis proj))
                 (api (car apis))
                 (class (car (b4x-library-api-classes api)))
                 (cands (b4x-project-library-completion-candidates proj))
                 (bar-info (b4x-project-library-symbol-info proj "Bar")))
            (should (= (length apis) 1))
            (should (equal (b4x-library-api-xml-path api) xml-file))
            (should (equal (b4x-library-class-shortname class) "Foo"))
            (should (equal (b4x-library-class-methods class) '("Bar")))
            (should (equal (b4x-library-class-properties class) '("Baz")))
            (should (equal (b4x-library-class-events class) '("Ready")))
            (should (equal (b4x-project-format-library-member-signature
                            (car (b4x-library-class-method-details class)))
                           "Bar()"))
            (should (equal (plist-get bar-info :kind) 'method))
            (should (equal (b4x-project-library-symbol-annotation proj "Bar")
                           " [method:Foo]"))
            (should (member "Foo" cands))
            (should (member "Bar" cands))
            (should (member "Baz" cands))
            (should (member "Ready" cands))))
      (delete-directory root t))))

(ert-deftest b4x-project/library-xml-api-disk-cache ()
  (let* ((root (make-temp-file "b4x-libxml-cache-" t))
         (cache-dir (expand-file-name "cache" root))
         (platform-dir (expand-file-name "B4J" root))
         (core-dir (expand-file-name "core-libs" root))
         (ini-file (expand-file-name "b4xV5.ini" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir))
         (xml-file (expand-file-name "Foo.xml" core-dir))
         (b4x-cache-directory cache-dir))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (make-directory core-dir t)
          (b4x-test--write xml-file "<root><class><shortname>Foo</shortname></class></root>")
          (b4x-test--write ini-file (format "LibrariesFolder=%s\n" core-dir))
          (b4x-test--write project-file
                           (mapconcat #'identity
                                      '("AppType=JavaFX"
                                        "Library1=Foo"
                                        "NumberOfLibraries=1"
                                        "NumberOfModules=0"
                                        "Version=10.5"
                                        "@EndOfDesignText@")
                                      "\n"))
          (let* ((proj (b4x-load-project project-file ini-file))
                 (lib (b4x-project-find-available-library proj "Foo"))
                 (api1 (b4x-project-parse-library-api lib)))
            (should (equal (b4x-library-api-xml-path api1) xml-file))
            (b4x-project-clear-caches)
            (cl-letf (((symbol-function 'b4x-project--parse-xml-root)
                       (lambda (&rest _)
                         (error "disk cache miss"))))
              (let ((api2 (b4x-project-parse-library-api lib)))
                (should (equal (b4x-library-api-xml-path api2) xml-file))))))
      (delete-directory root t))))

(ert-deftest b4x-nav/completion-includes-library-xml-candidates ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) '("Foo" "Bar" "Ready")))
              ((symbol-function 'b4x-project-library-symbol-annotation)
               (lambda (_proj cand) (and (string= cand "Foo") " [class]")))
              ((symbol-function 'b4x-project-library-symbol-doc)
               (lambda (_proj cand &optional multiline)
                 (and (string= cand "Foo")
                      (if multiline "Foo\nLibrary: Test" "Foo")))))
      (with-temp-buffer
        (b4x-mode)
        (insert "Fo")
        (let* ((capf (b4x-completion-at-point))
               (collection (nth 2 capf))
               (cands (all-completions "F" collection))
               (annotation-fn (plist-get (nthcdr 3 capf) :annotation-function))
               (doc-fn (plist-get (nthcdr 3 capf) :company-doc-buffer)))
          (should (member "Foo" cands))
          (should (eq (plist-get (nthcdr 3 capf) :category) 'b4x))
          (should (equal (funcall annotation-fn "Foo") " [class]"))
          (should (string-match-p "Library: Test"
                                  (with-current-buffer (funcall doc-fn "Foo")
                                    (buffer-string)))))))))

(ert-deftest b4x-nav/completion-includes-local-vars-from-current-sub ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-candidates)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "Private Sub Base64Encode(Value As String) As String\n"
                "    Dim Base64JO As JavaObject\n"
                "    Base64J\n"
                "End Sub\n")
        (goto-char (point-min))
        (search-forward "Base64J")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "Base64J" (nth 2 capf))))
          (should (member "Base64JO" cands)))))))

(ert-deftest b4x-nav/company-doc-buffer-falls-back-to-project-symbol-doc ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj))
         (file "/tmp/Demo.bas"))
    (dolist (sym (list (make-b4x-sym :name "Foo" :kind 'sub :file file :line 1)
                       (make-b4x-sym :name "GlobalCounter" :kind 'variable :file file :line 4)
                       (make-b4x-sym :name "MyType" :kind 'type :file file :line 6)))
      (b4x-nav--add-sym tab sym))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-candidates)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-symbol-doc)
               (lambda (&rest _) nil))
              ((symbol-function 'b4x-nav--b4xlib-symbol-doc)
               (lambda (&rest _) nil)))
      (with-temp-buffer
        (b4x-mode)
        (setq-local buffer-file-name file)
        (insert "Public Sub Foo(Name As String)\n"
                "End Sub\n"
                "Sub Process_Globals\n"
                "  Dim GlobalCounter As Int\n"
                "End Sub\n"
                "Type MyType\n"
                "End Type\n"
                "Fo")
        (let* ((capf (b4x-completion-at-point))
               (doc-fn (plist-get (nthcdr 3 capf) :company-doc-buffer)))
          (should (string-match-p
                   "Public Sub Foo(Name As String)"
                   (with-current-buffer (funcall doc-fn "Foo")
                     (buffer-string))))
          (should (string-match-p
                   "Dim GlobalCounter As Int"
                   (with-current-buffer (funcall doc-fn "GlobalCounter")
                     (buffer-string))))
          (should (string-match-p
                   "Type MyType"
                   (with-current-buffer (funcall doc-fn "MyType")
                     (buffer-string)))))))))

(ert-deftest b4x-nav/completion-after-as-only-offers-types ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--project-type-names)
               (lambda (_proj _tab) '("Map" "List" "JavaObject" "String")))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) '("CreateMap" "ConfigAsMap"))))
      (with-temp-buffer
        (b4x-mode)
        (insert "Dim n As Ma")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "Ma" (nth 2 capf))))
          (should (member "Map" cands))
          (should-not (member "CreateMap" cands))
          (should-not (member "ConfigAsMap" cands))))
      (with-temp-buffer
        (b4x-mode)
        (insert "Dim s As St")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "St" (nth 2 capf))))
          (should (member "String" cands)))))))

(ert-deftest b4x-nav/contextual-map-members-from-implicit-core-api ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (tab (make-b4x-symtab :project proj))
         (map-class (make-b4x-library-class :shortname "Map"
                                            :methods '("ContainsKey" "Put")
                                            :properties '("Size")))
         (api (make-b4x-library-api :classes (list map-class))))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-apis)
               (lambda (_proj) (list api)))
              ((symbol-function 'b4x-project-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-indices)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "Private Sub Test\n"
                "    Dim Entry As Map\n"
                "    Entry.\n"
                "End Sub\n")
        (goto-char (point-min))
        (search-forward "Entry.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "ContainsKey" cands))
          (should (member "Put" cands))
          (should (member "Size" cands)))))))

(ert-deftest b4x-nav/contextual-core-members-from-builtins-with-initializer ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-indices)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "Private Sub Test\n"
                "    Dim Items As List = Array(1, 2, 3)\n"
                "    Dim Entry As Map = CreateMap()\n"
                "    Items.\n"
                "    Entry.\n"
                "End Sub\n")
        (goto-char (point-min))
        (search-forward "Items.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "Add" cands))
          (should (member "Size" cands)))
        (search-forward "Entry.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "ContainsKey" cands))
          (should (member "Put" cands)))))))

(ert-deftest b4x-nav/contextual-chained-core-members-from-return-types ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-indices)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "Private Sub Test\n"
                "    Dim Entry As Map = CreateMap()\n"
                "    Entry.Keys.\n"
                "End Sub\n")
        (goto-char (point-min))
        (search-forward "Entry.Keys.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "Add" cands))
          (should (member "Get" cands))
          (should (member "Size" cands)))))))

(ert-deftest b4x-nav/completion-includes-builtin-global-constructors ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-completion-candidates)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-candidates)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "CreateM")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "CreateM" (nth 2 capf)))
               (annotation-fn (plist-get (nthcdr 3 capf) :annotation-function))
               (doc-fn (plist-get (nthcdr 3 capf) :company-doc-buffer)))
          (should (member "CreateMap" cands))
          (should (equal (funcall annotation-fn "CreateMap") " [builtin]"))
          (should (string-match-p "CreateMap"
                                  (with-current-buffer (funcall doc-fn "CreateMap")
                                    (buffer-string)))))))))

(ert-deftest b4x-nav/contextual-project-member-returntype-inference ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (file "/tmp/MyType.bas")
         (tab (make-b4x-symtab :project proj)))
    (dolist (sym (list (make-b4x-sym :name "FetchItems" :kind 'sub :file file :line 2)
                       (make-b4x-sym :name "Init" :kind 'sub :file file :line 5)))
      (b4x-nav--add-sym tab sym))
    (setf (b4x-symtab-files tab) (list file))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-indices)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (setq-local buffer-file-name file)
        (insert "Type MyType\nEnd Type\n"
                "Public Sub FetchItems As List\nEnd Sub\n"
                "Public Sub Init\n  Dim T As MyType\n  T.FetchItems.\nEnd Sub\n")
        (goto-char (point-min))
        (search-forward "T.FetchItems.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "Add" cands))
          (should (member "Get" cands)))))))

(ert-deftest b4x-nav/contextual-assignment-inference-from-project-return ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (file "/tmp/MyType.bas")
         (tab (make-b4x-symtab :project proj)))
    (dolist (sym (list (make-b4x-sym :name "FetchItems" :kind 'sub :file file :line 2)
                       (make-b4x-sym :name "Init" :kind 'sub :file file :line 5)))
      (b4x-nav--add-sym tab sym))
    (setf (b4x-symtab-files tab) (list file))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-indices)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (setq-local buffer-file-name file)
        (insert "Type MyType\nEnd Type\n"
                "Public Sub FetchItems As List\nEnd Sub\n"
                "Public Sub Init\n"
                "  Dim T As MyType\n"
                "  Dim Items\n"
                "  Items = T.FetchItems\n"
                "  Items.\n"
                "End Sub\n")
        (goto-char (point-min))
        (search-forward "Items.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "Add" cands))
          (should (member "Get" cands)))))))

(ert-deftest b4x-nav/contextual-assignment-inference-through-variable-alias ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--implicit-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-project-library-apis)
               (lambda (_proj) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-indices)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "Private Sub Test\n"
                "  Dim Entry\n"
                "  Dim Keys\n"
                "  Entry = CreateMap()\n"
                "  Keys = Entry.Keys\n"
                "  Keys.\n"
                "End Sub\n")
        (goto-char (point-min))
        (search-forward "Keys.")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (member "Add" cands))
          (should (member "Get" cands))
          (should (member "Size" cands)))))))

(ert-deftest b4x-nav/global-completion-ranks-project-before-libs ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j" :platform 'b4j))
         (tab (make-b4x-symtab :project proj)))
    (dolist (sym (list (make-b4x-sym :name "ProjectFoo" :kind 'sub :file "/tmp/a.bas" :line 1)))
      (b4x-nav--add-sym tab sym))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--current-buffer-symbol-candidates)
               (lambda () '("LocalFoo")))
              ((symbol-function 'b4x-nav--implicit-library-completion-candidates)
               (lambda (_proj) '("CoreFoo")))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) '("LibFoo")))
              ((symbol-function 'b4x-nav--project-b4xlib-candidates)
               (lambda (_proj) '("B4XFoo"))))
      (with-temp-buffer
        (b4x-mode)
        (insert "F")
        (let* ((capf (b4x-completion-at-point))
               (cands (all-completions "" (nth 2 capf))))
          (should (< (seq-position cands "LocalFoo" #'equal)
                     (seq-position cands "ProjectFoo" #'equal)
                     (seq-position cands "CoreFoo" #'equal)
                     (seq-position cands "LibFoo" #'equal)
                     (seq-position cands "B4XFoo" #'equal))))))))

(ert-deftest b4x-project/pom-indexing-and-association ()
  (let* ((root (make-temp-file "b4x-pom-" t))
         (platform-dir (expand-file-name "B4J" root))
         (core-dir (expand-file-name "core-libs" root))
         (ini-file (expand-file-name "b4xV5.ini" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir))
         (jar-file (expand-file-name "Foo.jar" core-dir))
         (pom-file (expand-file-name "maven/demo/foo/pom.xml" core-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (make-directory (file-name-directory pom-file) t)
          (make-directory core-dir t)
          (b4x-test--write jar-file "")
          (b4x-test--write
           pom-file
           (mapconcat #'identity
                      '("<project xmlns=\"http://maven.apache.org/POM/4.0.0\""
                        "         xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
                        "         xsi:schemaLocation=\"http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd\">"
                        "  <modelVersion>4.0.0</modelVersion>"
                        "  <groupId>demo.group</groupId>"
                        "  <artifactId>Foo</artifactId>"
                        "  <version>1.2.3</version>"
                        "  <packaging>jar</packaging>"
                        "  <name>Foo Library</name>"
                        "  <description>Demo Foo artifact</description>"
                        "</project>")
                      "\n"))
          (b4x-test--write ini-file (format "LibrariesFolder=%s\n" core-dir))
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Library1=Foo"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@")
                      "\n"))
          (let* ((proj (b4x-load-project project-file ini-file))
                 (poms (b4x-project-library-poms proj))
                 (pom (seq-find (lambda (it)
                                  (equal (b4x-library-pom-path it) pom-file))
                                poms))
                 (assoc-pom (b4x-project-find-library-pom proj "Foo")))
            (should pom)
            (should (>= (length poms) 1))
            (should (equal (b4x-library-pom-artifact-id pom) "Foo"))
            (should (equal (b4x-library-pom-group-id pom) "demo.group"))
            (should (equal (b4x-library-pom-version pom) "1.2.3"))
            (should (equal (b4x-library-pom-description pom) "Demo Foo artifact"))
            (should (equal (b4x-library-pom-path assoc-pom) pom-file))))
      (delete-directory root t))))

(ert-deftest b4x-nav/eldoc-falls-back-to-library-xml-doc ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-project-library-symbol-doc)
               (lambda (_proj cand &optional _multiline)
                 (and (string= cand "Bar") "Bar() — library doc"))))
      (with-temp-buffer
        (b4x-mode)
        (insert "Bar")
        (should (equal (b4x-eldoc-function) "Bar() — library doc"))))))

(ert-deftest b4x-nav/company-doc-buffer-renders-html-docs ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-project-library-completion-candidates)
               (lambda (_proj) '("Foo")))
              ((symbol-function 'b4x-project-library-symbol-doc)
               (lambda (_proj cand &optional multiline)
                 (and (string= cand "Foo")
                      (if multiline
                          "Foo()\n<b>Bold</b> &amp; text"
                        "Foo()"))))
              ((symbol-function 'b4x-project-library-symbol-annotation)
               (lambda (&rest _) nil))
              ((symbol-function 'b4x-nav--project-b4xlib-candidates)
               (lambda (_proj) nil)))
      (with-temp-buffer
        (b4x-mode)
        (insert "Fo")
        (let* ((capf (b4x-completion-at-point))
               (doc-fn (plist-get (nthcdr 3 capf) :company-doc-buffer))
               (text (with-current-buffer (funcall doc-fn "Foo")
                       (buffer-string))))
          (should (string-match-p "Foo()" text))
          (should (string-match-p "Bold & text" text))
          (should-not (string-match-p "<b>" text))
          (should-not (string-match-p "&amp;" text)))))))

(ert-deftest b4x-project/b4xlib-indexing-and-docs ()
  (unless (executable-find "unzip")
    (ert-skip "unzip not available"))
  (let* ((root (make-temp-file "b4x-b4xlib-" t))
         (platform-dir (expand-file-name "B4J" root))
         (core-dir (expand-file-name "core-libs" root))
         (ini-file (expand-file-name "b4xV5.ini" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir))
         (lib-file (expand-file-name "DemoLib.b4xlib" core-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (make-directory core-dir t)
          (b4x-test--write-b4xlib
           lib-file
           '(("manifest.txt" . "Module=DemoLib")
             ("Utility.bas" . "Sub Process_Globals\n  Public GlobalCounter As Int\nEnd Sub\n\nPublic Sub DoWork(Name As String)\nEnd Sub\n\nType DemoType\n  Value As String\nEnd Type\n")
             ("Worker.bas" . "Sub Class_Globals\n  Private LocalValue As Int\nEnd Sub\n\nPublic Sub Initialize\nEnd Sub\n")))
          (b4x-test--write ini-file (format "LibrariesFolder=%s\n" core-dir))
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Library1=DemoLib"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@")
                      "\n"))
          (let* ((proj (b4x-load-project project-file ini-file))
                 (cands (b4x-nav--project-b4xlib-candidates proj)))
            (should (member "Utility" cands))
            (should (member "Worker" cands))
            (should (member "DoWork" cands))
            (should (member "DemoType" cands))
            (should (member "GlobalCounter" cands))
            (should (equal (b4x-nav--b4xlib-symbol-annotation proj "Utility")
                           " [b4xlib:module]"))
            (should (string-match-p "DoWork(Name As String)"
                                    (b4x-nav--b4xlib-symbol-doc proj "DoWork")))
            (should (string-match-p "Utility (b4xlib module)"
                                    (b4x-nav--b4xlib-symbol-doc proj "Utility")))) )
      (delete-directory root t))))

(ert-deftest b4x-nav/b4xlib-index-disk-cache ()
  (unless (executable-find "unzip")
    (ert-skip "unzip not available"))
  (let* ((root (make-temp-file "b4x-b4xlib-cache-" t))
         (cache-dir (expand-file-name "cache" root))
         (lib-file (expand-file-name "DemoLib.b4xlib" root))
         (b4x-cache-directory cache-dir)
         (lib (make-b4x-library :name "DemoLib"
                                :canonical-name "demolib"
                                :source 'core
                                :kind 'b4xlib
                                :path lib-file)))
    (unwind-protect
        (progn
          (b4x-test--write-b4xlib
           lib-file
           '(("Utility.bas" . "Public Sub DoWork(Name As String)\nEnd Sub\n")))
          (let ((index1 (b4x-nav--index-b4xlib lib)))
            (should (member "DoWork"
                            (b4x-nav-all-names (b4x-nav-b4xlib-index-symtab index1))))
            (setq b4x-nav--b4xlib-cache (make-hash-table :test 'equal))
            (cl-letf (((symbol-function 'b4x-nav--ensure-b4xlib-extracted)
                       (lambda (&rest _)
                         (error "disk cache miss"))))
              (let ((index2 (b4x-nav--index-b4xlib lib)))
                (should (member "DoWork"
                                (b4x-nav-all-names
                                 (b4x-nav-b4xlib-index-symtab index2))))))))
      (delete-directory root t))))

(ert-deftest b4x-nav/eldoc-falls-back-to-b4xlib-doc ()
  (let* ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"))
         (tab (make-b4x-symtab :project proj)))
    (cl-letf (((symbol-function 'b4x-nav-table) (lambda (&optional _no-cache) tab))
              ((symbol-function 'b4x-nav--b4xlib-symbol-doc)
               (lambda (_proj cand &optional _multiline)
                 (and (string= cand "DoWork") "DoWork(Name As String) — b4xlib"))))
      (with-temp-buffer
        (b4x-mode)
        (insert "DoWork")
        (should (equal (b4x-eldoc-function) "DoWork(Name As String) — b4xlib"))))))

(ert-deftest b4x-project/available-libraries-merge-core-and-additional ()
  (let* ((root (make-temp-file "b4x-libs-" t))
         (platform-dir (expand-file-name "B4J" root))
         (core-dir (expand-file-name "core-libs" root))
         (additional-dir (expand-file-name "Additional Libs" root))
         (ini-file (expand-file-name "b4xV5.ini" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (make-directory core-dir t)
          (make-directory additional-dir t)
          (make-directory (expand-file-name "nested" core-dir) t)
          (b4x-test--write (expand-file-name "jCore.jar" core-dir) "")
          (b4x-test--write (expand-file-name "Json.jar" core-dir) "")
          (b4x-test--write (expand-file-name "HikariCP.jar" core-dir) "")
          (b4x-test--write (expand-file-name "HikariCP.xml" core-dir) "")
          (b4x-test--write (expand-file-name "B4XPages.b4xlib" core-dir) "")
          (b4x-test--write (expand-file-name "ignored.jar" (expand-file-name "nested" core-dir)) "")
          (b4x-test--write (expand-file-name "CustomLib.b4xlib" additional-dir) "")
          (b4x-test--write (expand-file-name "B4XPages.b4xlib" additional-dir) "")
          (b4x-test--write
           ini-file
           (format "LibrariesFolder=%s\nAdditionalLibrariesFolder=%s\n"
                   core-dir additional-dir))
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Library1=jcore"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@")
                      "\n"))
          (let* ((proj (b4x-load-project project-file ini-file))
                 (libs (b4x-project-available-libraries proj))
                 (names (mapcar #'b4x-library-canonical-name libs))
                 (b4xpages (b4x-project-find-available-library proj "b4xpages"))
                 (hikari (b4x-project-find-available-library proj "HikariCP")))
            (should (equal names '("b4xpages" "customlib" "hikaricp" "jcore" "json")))
            (should (eq (b4x-library-source b4xpages) 'additional))
            (should (eq (b4x-library-kind hikari) 'xml))))
      (delete-directory root t))))

(ert-deftest b4x-project/available-library-lines-mark-present ()
  (let ((proj (make-b4x-project :libraries '("Json"))))
    (cl-letf (((symbol-function 'b4x-project-available-libraries)
               (lambda (_proj)
                 (list (make-b4x-library :name "Json"
                                         :canonical-name "json"
                                         :source 'core
                                         :kind 'jar
                                         :path "/tmp/Json.jar")
                       (make-b4x-library :name "XLUtils"
                                         :canonical-name "xlutils"
                                         :source 'additional
                                         :kind 'b4xlib
                                         :path "/tmp/XLUtils.b4xlib")))))
      (let ((lines (b4x--available-library-lines proj)))
        (should (string-prefix-p "* Json" (car lines)))
        (should (string-match-p (regexp-quote "[core       jar   ] /tmp/Json.jar")
                                (car lines)))
        (should (string-prefix-p "  XLUtils" (cadr lines)))))))

(ert-deftest b4x-project/insert-available-library-entry-makes-button ()
  (let ((proj (make-b4x-project :libraries '("Json")))
        (lib (make-b4x-library :name "Json"
                               :canonical-name "json"
                               :source 'core
                               :kind 'jar
                               :path "/tmp/Json.jar")))
    (with-temp-buffer
      (b4x-libraries-mode)
      (let ((inhibit-read-only t))
        (b4x--insert-available-library-entry proj lib))
      (goto-char (point-min))
      (let ((button (button-at (point))))
        (should button)
        (should (equal (button-get button 'b4x-library-name) "Json"))
        (should (button-get button 'b4x-library-present))))))

(ert-deftest b4x-project/list-available-libraries-buffer-mode ()
  (let ((proj (make-b4x-project :project-file "/tmp/Demo.b4j"
                                :platform 'b4j
                                :libraries '("Json"))))
    (cl-letf (((symbol-function 'b4x--current-project) (lambda () proj))
              ((symbol-function 'b4x-project-library-dirs)
               (lambda (_proj) '((core . "/tmp/core") (additional . "/tmp/additional"))))
              ((symbol-function 'b4x-project-available-libraries)
               (lambda (_proj)
                 (list (make-b4x-library :name "Json"
                                         :canonical-name "json"
                                         :source 'core
                                         :kind 'jar
                                         :path "/tmp/core/Json.jar")))))
      (b4x-list-available-libraries)
      (with-current-buffer "*B4X Libraries*"
        (should (eq major-mode 'b4x-libraries-mode))
        (should (equal b4x--libraries-project-file "/tmp/Demo.b4j"))
        (goto-char (point-min))
        (search-forward "Actions: RET/mouse-1 toggle")
        (goto-char (point-min))
        (search-forward "Json")
        (should (button-at (match-beginning 0)))))))

(ert-deftest b4x-project/add-library-updates-header ()
  (let* ((root (make-temp-file "b4x-addlib-" t))
         (platform-dir (expand-file-name "B4J" root))
         (core-dir (expand-file-name "core-libs" root))
         (ini-file (expand-file-name "b4xV5.ini" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (make-directory core-dir t)
          (b4x-test--write (expand-file-name "Json.jar" core-dir) "")
          (b4x-test--write
           ini-file
           (format "LibrariesFolder=%s\n" core-dir))
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Library1=jcore"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@")
                      "\n"))
          (let* ((proj (b4x-load-project project-file ini-file))
                 (added (b4x--add-library-to-project proj "Json"))
                 (project-text (with-temp-buffer
                                 (insert-file-contents project-file)
                                 (buffer-string))))
            (should (equal added "Json"))
            (should (string-match-p "Library2=Json" project-text))
            (should (string-match-p "NumberOfLibraries=2" project-text))
            (should-not (b4x--add-library-to-project (b4x-load-project project-file ini-file)
                                                     "Json"))))
      (delete-directory root t))))

(ert-deftest b4x-project/remove-library-updates-header ()
  (let* ((root (make-temp-file "b4x-rmlib-" t))
         (platform-dir (expand-file-name "B4J" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Library1=jcore"
                        "Library2=jfx"
                        "Library3=Json"
                        "NumberOfLibraries=3"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@")
                      "\n"))
          (let* ((proj (b4x-load-project project-file))
                 (removed (b4x--remove-library-from-project proj "jfx"))
                 (project-text (with-temp-buffer
                                 (insert-file-contents project-file)
                                 (buffer-string))))
            (should (equal removed "jfx"))
            (should (string-match-p "Library1=jcore" project-text))
            (should (string-match-p "Library2=Json" project-text))
            (should-not (string-match-p "Library3=" project-text))
            (should (string-match-p "NumberOfLibraries=2" project-text))
            (should-not (b4x--remove-library-from-project (b4x-load-project project-file)
                                                          "does-not-exist"))))
      (delete-directory root t))))

(ert-deftest b4x-new-module/class-in-platform-project-root ()
  (let* ((root (make-temp-file "b4x-newmod-root-" t))
         (platform-dir (expand-file-name "B4J" root))
         (project-file (expand-file-name "Demo.b4j" platform-dir))
         (module-file (expand-file-name "Foo.bas" root)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Build1=Default,demo.app"
                        "Group=Default Group"
                        "Library1=jcore"
                        "Library2=jfx"
                        "NumberOfFiles=0"
                        "NumberOfLibraries=2"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@"
                        "Sub Process_Globals"
                        "End Sub")
                      "\n"))
          (let* ((proj (b4x-load-project project-file))
                 (created (b4x--create-module proj 'class "Foo"))
                 (project-text (with-temp-buffer
                                 (insert-file-contents project-file)
                                 (buffer-string)))
                 (module-text (with-temp-buffer
                                (insert-file-contents module-file)
                                (buffer-string))))
            (should (equal created module-file))
            (should (file-regular-p module-file))
            (should (string-match-p (regexp-quote "Module1=|relative|..\\Foo")
                                    project-text))
            (should (string-match-p "NumberOfModules=1" project-text))
            (should (string-match-p "Type=Class" module-text))
            (should (string-match-p "Sub Class_Globals" module-text))))
      (delete-directory root t))))

(ert-deftest b4x-new-module/b4xpage-adds-library-in-flat-project ()
  (let* ((root (make-temp-file "b4x-newmod-flat-" t))
         (project-file (expand-file-name "FlatDemo.b4j" root))
         (module-file (expand-file-name "SettingsPage.bas" root)))
    (unwind-protect
        (progn
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("AppType=JavaFX"
                        "Build1=Default,flat.demo"
                        "Group=Default Group"
                        "Library1=jcore"
                        "Library2=jfx"
                        "NumberOfFiles=0"
                        "NumberOfLibraries=2"
                        "NumberOfModules=0"
                        "Version=10.5"
                        "@EndOfDesignText@"
                        "Sub Process_Globals"
                        "End Sub")
                      "\n"))
          (let* ((proj (b4x-load-project project-file))
                 (created (b4x--create-module proj 'b4xpage "SettingsPage"))
                 (project-text (with-temp-buffer
                                 (insert-file-contents project-file)
                                 (buffer-string)))
                 (module-text (with-temp-buffer
                                (insert-file-contents module-file)
                                (buffer-string))))
            (should (equal created module-file))
            (should (file-regular-p module-file))
            (should (string-match-p "Module1=SettingsPage" project-text))
            (should (string-match-p "Library3=b4xpages" project-text))
            (should (string-match-p "NumberOfLibraries=3" project-text))
            (should (string-match-p "B4XPage_Created" module-text))
            (should (string-match-p "Root.LoadLayout(\\\"SettingsPage\\\")" module-text))))
      (delete-directory root t))))

(ert-deftest b4x-new-module/b4a-b4xpage-in-shared-root ()
  (let* ((root (make-temp-file "b4x-newmod-b4a-root-" t))
         (platform-dir (expand-file-name "B4A" root))
         (project-file (expand-file-name "Demo.b4a" platform-dir))
         (module-file (expand-file-name "SharedPage.bas" root)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("Build1=Default,demo.app"
                        "Group=Default Group"
                        "Library1=core"
                        "NumberOfFiles=0"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=9.9"
                        "@EndOfDesignText@"
                        "Sub Process_Globals"
                        "End Sub")
                      "\n"))
          (let* ((proj (b4x-load-project project-file))
                 (created (b4x--create-module proj 'b4xpage "SharedPage"))
                 (project-text (with-temp-buffer
                                 (insert-file-contents project-file)
                                 (buffer-string)))
                 (module-text (with-temp-buffer
                                (insert-file-contents module-file)
                                (buffer-string))))
            (should (equal created module-file))
            (should (string-match-p (regexp-quote "Module1=|relative|..\\SharedPage")
                                    project-text))
            (should (string-match-p "Library2=b4xpages" project-text))
            (should (string-match-p "NumberOfLibraries=2" project-text))
            (should (string-match-p "B4A=true" module-text))
            (should (string-match-p "B4XPage_Created" module-text))))
      (delete-directory root t))))

(ert-deftest b4x-new-module/b4a-service-in-platform-dir ()
  (let* ((root (make-temp-file "b4x-newmod-b4a-service-" t))
         (platform-dir (expand-file-name "B4A" root))
         (project-file (expand-file-name "Demo.b4a" platform-dir))
         (module-file (expand-file-name "SyncService.bas" platform-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("Build1=Default,demo.app"
                        "Group=Default Group"
                        "Library1=core"
                        "NumberOfFiles=0"
                        "NumberOfLibraries=1"
                        "NumberOfModules=0"
                        "Version=9.9"
                        "@EndOfDesignText@"
                        "Sub Process_Globals"
                        "End Sub")
                      "\n"))
          (let* ((proj (b4x-load-project project-file))
                 (created (b4x--create-module proj 'service "SyncService"))
                 (project-text (with-temp-buffer
                                 (insert-file-contents project-file)
                                 (buffer-string)))
                 (module-text (with-temp-buffer
                                (insert-file-contents module-file)
                                (buffer-string))))
            (should (equal created module-file))
            (should (string-match-p "Module1=SyncService" project-text))
            (should (string-match-p "Type=Service" module-text))
            (should (string-match-p "Sub Service_Start (StartingIntent As Intent)"
                                    module-text))))
      (delete-directory root t))))

(ert-deftest b4x-b4a/build-package-from-header ()
  (let* ((root (make-temp-file "b4x-b4a-pkg-" t))
         (platform-dir (expand-file-name "B4A" root))
         (project-file (expand-file-name "Demo.b4a" platform-dir)))
    (unwind-protect
        (progn
          (make-directory platform-dir t)
          (b4x-test--write
           project-file
           (mapconcat #'identity
                      '("Build1=Default,com.example.demo"
                        "Group=Default Group"
                        "NumberOfLibraries=0"
                        "NumberOfModules=0"
                        "Version=9.9"
                        "@EndOfDesignText@")
                      "\n"))
          (let ((proj (b4x-load-project project-file)))
            (should (equal (b4x--b4a-build-package proj) "com.example.demo"))))
      (delete-directory root t))))

(ert-deftest b4x-b4a/find-apk-prefers-final-apk ()
  (let* ((root (make-temp-file "b4x-b4a-apk-" t))
         (platform-dir (expand-file-name "B4A" root))
         (objects-dir (expand-file-name "Objects" platform-dir))
         (project-file (expand-file-name "Demo.b4a" platform-dir))
         (final-apk (expand-file-name "bin/Demo.apk" objects-dir))
         (bad-apk (expand-file-name "bin/Demo-unaligned.apk" objects-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory final-apk) t)
          (b4x-test--write project-file "Build1=Default,demo.app\n@EndOfDesignText@")
          (b4x-test--write bad-apk "x")
          (b4x-test--write final-apk "y")
          (set-file-times bad-apk (time-subtract (current-time) (seconds-to-time 60)))
          (set-file-times final-apk (current-time))
          (let ((proj (b4x-load-project project-file)))
            (should (equal (b4x--b4a-find-apk proj) final-apk))))
      (delete-directory root t))))

(ert-deftest b4x-b4a/adb-command-includes-serial-when-set ()
  (let ((b4x-adb-binary "adb")
        (b4x-adb-serial "emulator-5554"))
    (should (equal (b4x--adb-command "install" "-r" "/tmp/app.apk")
                   "adb -s emulator-5554 install -r /tmp/app.apk"))))

(ert-deftest b4x-b4a/parse-avd-list ()
  (should (equal (b4x--b4a-parse-avd-list "Pixel_8\nTablet_API_34\n")
                 '("Pixel_8" "Tablet_API_34"))))

(ert-deftest b4x-b4a/emulator-shell-command-includes-avd-and-extra-args ()
  (let ((b4x-emulator-binary "emulator")
        (b4x-b4a-emulator-args '("-no-snapshot" "-gpu" "host"))
        (b4x-b4a-emulator-log-file "/tmp/emulator.log"))
    (should (string-match-p (regexp-quote "emulator -avd Pixel_8 -no-snapshot -gpu host")
                            (b4x--b4a-emulator-shell-command "Pixel_8")))
    (should (string-match-p (regexp-quote "/tmp/emulator.log")
                            (b4x--b4a-emulator-shell-command "Pixel_8")))))

(ert-deftest b4x-b4a/wait-script-uses-adb-and-boot-completion ()
  (let ((b4x-adb-binary "adb")
        (b4x-adb-serial "emulator-5554"))
    (let ((script (b4x--b4a-wait-script)))
      (should (string-match-p (regexp-quote "adb -s emulator-5554 wait-for-device") script))
      (should (string-match-p (regexp-quote "shell getprop sys.boot_completed") script)))))

(ert-deftest b4x-b4a/parse-adb-devices-output ()
  (let* ((devices (b4x--adb-parse-devices
                   (mapconcat #'identity
                              '("List of devices attached"
                                "emulator-5554 device product:sdk_gphone64_x86_64 model:Pixel_8 device:emu64xa transport_id:1"
                                "R58M123456A unauthorized usb:1-1 transport_id:2")
                              "\n")))
         (first (car devices))
         (second (cadr devices)))
    (should (= (length devices) 2))
    (should (equal (plist-get first :serial) "emulator-5554"))
    (should (equal (plist-get first :state) "device"))
    (should (equal (plist-get first :model) "Pixel_8"))
    (should (string-match-p "Pixel_8" (plist-get first :label)))
    (should (equal (plist-get second :state) "unauthorized"))))

(ert-deftest b4x-b4a/resolve-serial-auto-selects-sole-ready-device ()
  (let ((b4x-adb-serial nil)
        (b4x--adb-last-serial nil))
    (cl-letf (((symbol-function 'b4x--adb-list-devices)
               (lambda () (list (list :serial "emulator-5554"
                                      :state "device"
                                      :label "emulator-5554 [device]")))))
      (should (equal (b4x--adb-resolve-serial t) "emulator-5554"))
      (should (equal b4x--adb-last-serial "emulator-5554")))))

(ert-deftest b4x-b4a/resolve-serial-prompts-when-multiple-ready-devices ()
  (let ((b4x-adb-serial nil)
        (b4x--adb-last-serial nil))
    (cl-letf (((symbol-function 'b4x--adb-list-devices)
               (lambda () (list (list :serial "emulator-5554" :state "device"
                                      :label "emulator-5554 [device] Pixel_8")
                                (list :serial "R58M123456A" :state "device"
                                      :label "R58M123456A [device] Galaxy"))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (caar (last collection)))))
      (should (equal (b4x--adb-resolve-serial t) "R58M123456A"))
      (should (equal b4x--adb-last-serial "R58M123456A")))))

(ert-deftest b4x-b4a/logcat-args-use-pid-when-available ()
  (let ((b4x-b4a-logcat-fallback-specs '("B4A:V" "*:S")))
    (cl-letf (((symbol-function 'b4x--b4a-build-package)
               (lambda (_proj) "com.example.demo"))
              ((symbol-function 'b4x--b4a-pidof)
               (lambda (_pkg &optional _serial) "4242")))
      (should (equal (b4x--b4a-logcat-args (make-b4x-project) "emulator-5554")
                     '("-s" "emulator-5554" "logcat" "--pid=4242"))))))

(ert-deftest b4x-b4a/logcat-args-fallback-to-tag-filter-when-pid-missing ()
  (let ((b4x-b4a-logcat-fallback-specs '("B4A:V" "AndroidRuntime:E" "*:S")))
    (cl-letf (((symbol-function 'b4x--b4a-build-package)
               (lambda (_proj) "com.example.demo"))
              ((symbol-function 'b4x--b4a-pidof)
               (lambda (_pkg &optional _serial) nil)))
      (should (equal (b4x--b4a-logcat-args (make-b4x-project) "emulator-5554")
                     '("-s" "emulator-5554" "logcat" "B4A:V" "AndroidRuntime:E" "*:S"))))))

(ert-deftest b4x-b4a/restart-command-chains-force-stop-and-launch ()
  (let ((cmd (b4x--b4a-restart-command "com.example.demo" "emulator-5554")))
    (should (string-match-p (regexp-quote "adb -s emulator-5554 shell am force-stop com.example.demo") cmd))
    (should (string-match-p (regexp-quote "&& adb -s emulator-5554 shell monkey -p com.example.demo") cmd))))

(ert-deftest b4x-b4a/uninstall-command-targets-package ()
  (should (equal (b4x--b4a-uninstall-command "com.example.demo" "emulator-5554")
                 "adb -s emulator-5554 uninstall com.example.demo")))

(ert-deftest b4x-project/birthday-reminder-b4a-model ()
  (b4x-test-skip-unless b4x-test--birthday-reminder-b4a
    (let* ((proj (b4x-load-project b4x-test--birthday-reminder-b4a))
           (layouts (b4x-project-layout-files proj))
           (modules (b4x-project-modules proj)))
      (should (eq (b4x-project-platform proj) 'b4a))
      (should (equal (b4x--b4a-build-package proj) "com.leafecodes.birthdayreminder"))
      (should (= (length (b4x-project-libraries proj)) 7))
      (should (= (length layouts) 5))
      (should (assoc "mainpage" layouts))
      (should (member (expand-file-name "~/dev/B4XProj/B4X-Birthday-Reminder/B4A/Starter.bas") modules))
      (should (member (expand-file-name "~/dev/B4XProj/B4X-Birthday-Reminder/B4XMainPage.bas") modules))
      (should (member (expand-file-name "~/dev/B4XProj/B4X-Birthday-Reminder/moAdd.bas") modules))
      (should (member (expand-file-name "~/dev/B4XProj/B4X-Birthday-Reminder/moSingle.bas") modules)))))
