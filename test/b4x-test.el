;;; b4x-test.el --- ERT tests for the B4X project model -*- lexical-binding: t; -*-

;; Run from repo root:
;;   emacs -Q --batch -L emacs -l test/b4x-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'b4x-project)
(require 'b4x-wine)

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
