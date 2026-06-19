;;; b4x-layout.el --- B4X layout (.bjl/.bal/.bil) converter and sync -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-b4x-integration contributors

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Binary reader / writer for B4X layout files plus JSON import/export and
;; project-level sync helpers.  The object shape matches the JSON emitted by the
;; external JsonLayouts project, but this implementation is pure Emacs Lisp and
;; does not require SQLite.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'b4x-project)
(require 'b4x-nav)

(defconst b4x-layout-cint 1)
(defconst b4x-layout-cstring 2)
(defconst b4x-layout-cmap 3)
(defconst b4x-layout-endofmap 4)
(defconst b4x-layout-bool 5)
(defconst b4x-layout-ccolor 6)
(defconst b4x-layout-cfloat 7)
(defconst b4x-layout-cached-string 9)
(defconst b4x-layout-rect32 11)
(defconst b4x-layout-cnull 12)

(defconst b4x-layout--json-null :b4x-layout-null
  "Internal sentinel used for a JSON null value.")

(defconst b4x-layout--sync-version 1
  "Schema version for the optional layout sync sidecar.")

(cl-defstruct b4x-layout-object
  "Ordered JSON-like object used by the layout converter."
  entries)

(cl-defstruct b4x-layout-reader
  "Binary reader state for a layout file."
  data
  (pos 0))

(cl-defstruct b4x-layout-cache
  "Ordered string cache used while writing layout files."
  (table (make-hash-table :test 'equal))
  order
  tail
  (size 0))

(defun b4x-layout-object-get (object key &optional default)
  "Return OBJECT's value for KEY, or DEFAULT."
  (if-let ((cell (assoc key (b4x-layout-object-entries object))))
      (cdr cell)
    default))

(defun b4x-layout-object-put (object key value)
  "Store VALUE under KEY in OBJECT, preserving entry order."
  (if-let ((cell (assoc key (b4x-layout-object-entries object))))
      (setcdr cell value)
    (setf (b4x-layout-object-entries object)
          (append (b4x-layout-object-entries object)
                  (list (cons key value)))))
  object)

(defun b4x-layout-object-keys (object)
  "Return OBJECT's keys in order."
  (mapcar #'car (b4x-layout-object-entries object)))

(defun b4x-layout--make-object (&optional entries)
  "Return a `b4x-layout-object' with ENTRIES."
  (make-b4x-layout-object :entries entries))

(defun b4x-layout--ensure-object (value context)
  "Return VALUE as a layout object or signal an error mentioning CONTEXT."
  (unless (b4x-layout-object-p value)
    (error "Expected object for %s, got: %S" context value))
  value)

(defun b4x-layout--typed-wrapper-tag (value)
  "Return VALUE's `ValueType' when VALUE is a typed wrapper, else nil."
  (when (b4x-layout-object-p value)
    (let ((tag (b4x-layout-object-get value "ValueType" :missing)))
      (unless (eq tag :missing) tag))))

(defun b4x-layout--sequence-to-list (seq)
  "Return SEQ as a Lisp list."
  (cond
   ((null seq) nil)
   ((vectorp seq) (append seq nil))
   ((listp seq) seq)
   (t (error "Expected list/vector sequence, got: %S" seq))))

(defun b4x-layout--float32-from-bits (bits)
  "Decode IEEE754 single-precision BITS into an Emacs float."
  (let* ((sign (if (zerop (logand bits #x80000000)) 1.0 -1.0))
         (exp (logand #xff (ash bits -23)))
         (frac (logand bits #x7fffff)))
    (cond
     ((= exp #xff)
      (error "Unsupported non-finite float32 bits: %#x" bits))
     ((zerop exp)
      (if (zerop frac)
          (* sign 0.0)
        (* sign (expt 2.0 -126) (/ frac (float (ash 1 23))))))
     (t
      (* sign (expt 2.0 (- exp 127))
         (+ 1.0 (/ frac (float (ash 1 23)))))))))

(defun b4x-layout--float32-to-bits (value)
  "Encode VALUE as IEEE754 single-precision bits."
  (when (or (not (numberp value)) (isnan value))
    (error "Cannot encode non-finite float: %S" value))
  (let* ((value (float value))
         (sign (if (< value 0.0) #x80000000 0))
         (absval (abs value)))
    (cond
     ((zerop absval) sign)
     ((>= absval (expt 2.0 128))
      (error "Float out of single-precision range: %S" value))
     ((< absval (expt 2.0 -126))
      (let ((frac (round (* absval (expt 2.0 149)))))
        (when (>= frac (ash 1 23))
          ;; Rounded up to the smallest normalized float.
          (setq frac 0)
          (setq sign (logior sign (ash 1 23))))
        (logior sign frac)))
     (t
      (pcase-let* ((`(,sig . ,exp0) (frexp absval))
                   (mant (* sig 2.0))
                   (exp (1- exp0))
                   (exp-bits (+ exp 127))
                   (frac (round (* (- mant 1.0) (ash 1 23)))))
        (when (= frac (ash 1 23))
          (setq frac 0)
          (setq exp-bits (1+ exp-bits)))
        (when (>= exp-bits #xff)
          (error "Float out of single-precision range: %S" value))
        (logior sign (ash exp-bits 23) frac))))))

(defun b4x-layout--u8-string (&rest bytes)
  "Return a unibyte string made from BYTES."
  (apply #'unibyte-string bytes))

(defun b4x-layout--pack-u16le (value)
  "Pack VALUE as little-endian uint16."
  (setq value (logand value #xffff))
  (b4x-layout--u8-string (logand value #xff)
                         (logand (ash value -8) #xff)))

(defun b4x-layout--pack-u32le (value)
  "Pack VALUE as little-endian uint32."
  (setq value (logand value #xffffffff))
  (b4x-layout--u8-string (logand value #xff)
                         (logand (ash value -8) #xff)
                         (logand (ash value -16) #xff)
                         (logand (ash value -24) #xff)))

(defun b4x-layout--pack-s32le (value)
  "Pack VALUE as little-endian int32."
  (b4x-layout--pack-u32le value))

(defun b4x-layout--pack-f32le (value)
  "Pack VALUE as little-endian float32."
  (b4x-layout--pack-u32le (b4x-layout--float32-to-bits value)))

(defun b4x-layout--write-u8 (value)
  "Insert VALUE as one byte at point in the current unibyte buffer."
  (insert (b4x-layout--u8-string (logand value #xff))))

(defun b4x-layout--write-s32 (value)
  "Insert VALUE as little-endian int32 in the current unibyte buffer."
  (insert (b4x-layout--pack-s32le value)))

(defun b4x-layout--write-f32 (value)
  "Insert VALUE as little-endian float32 in the current unibyte buffer."
  (insert (b4x-layout--pack-f32le (float value))))

(defun b4x-layout--write-u16 (value)
  "Insert VALUE as little-endian uint16 in the current unibyte buffer."
  (insert (b4x-layout--pack-u16le value)))

(defun b4x-layout--read-u8 (reader)
  "Read one unsigned byte from READER."
  (let* ((data (b4x-layout-reader-data reader))
         (pos (b4x-layout-reader-pos reader))
         (len (length data)))
    (when (>= pos len)
      (error "Unexpected end of layout data"))
    (prog1 (aref data pos)
      (setf (b4x-layout-reader-pos reader) (1+ pos)))))

(defun b4x-layout--read-s8 (reader)
  "Read one signed byte from READER."
  (let ((v (b4x-layout--read-u8 reader)))
    (if (> v 127) (- v 256) v)))

(defun b4x-layout--read-u16le (reader)
  "Read one little-endian uint16 from READER."
  (let ((b0 (b4x-layout--read-u8 reader))
        (b1 (b4x-layout--read-u8 reader)))
    (logior b0 (ash b1 8))))

(defun b4x-layout--read-s16le (reader)
  "Read one little-endian int16 from READER."
  (let ((v (b4x-layout--read-u16le reader)))
    (if (> v #x7fff) (- v #x10000) v)))

(defun b4x-layout--read-u32le (reader)
  "Read one little-endian uint32 from READER."
  (let ((b0 (b4x-layout--read-u8 reader))
        (b1 (b4x-layout--read-u8 reader))
        (b2 (b4x-layout--read-u8 reader))
        (b3 (b4x-layout--read-u8 reader)))
    (logior b0 (ash b1 8) (ash b2 16) (ash b3 24))))

(defun b4x-layout--read-s32le (reader)
  "Read one little-endian int32 from READER."
  (let ((v (b4x-layout--read-u32le reader)))
    (if (> v #x7fffffff) (- v #x100000000) v)))

(defun b4x-layout--read-f32le (reader)
  "Read one little-endian float32 from READER."
  (b4x-layout--float32-from-bits (b4x-layout--read-u32le reader)))

(defun b4x-layout--read-bytes (reader count)
  "Read COUNT raw bytes from READER as a unibyte string."
  (let* ((data (b4x-layout-reader-data reader))
         (pos (b4x-layout-reader-pos reader))
         (end (+ pos count))
         (len (length data)))
    (when (> end len)
      (error "Unexpected end of layout data"))
    (prog1 (substring data pos end)
      (setf (b4x-layout-reader-pos reader) end))))

(defun b4x-layout--read-string (reader)
  "Read one UTF-8 string from READER."
  (decode-coding-string
   (b4x-layout--read-bytes reader (b4x-layout--read-s32le reader))
   'utf-8 t))

(defun b4x-layout--write-string (string)
  "Insert STRING as B4X binary UTF-8 string in the current buffer."
  (let ((bytes (encode-coding-string string 'utf-8 t)))
    (b4x-layout--write-s32 (length bytes))
    (insert bytes)))

(defun b4x-layout--load-strings-cache (reader)
  "Read one strings cache array from READER."
  (let ((count (b4x-layout--read-s32le reader))
        strings)
    (dotimes (_ count)
      (push (b4x-layout--read-string reader) strings))
    (nreverse strings)))

(defun b4x-layout--read-cached-string (reader cache)
  "Read one cached string from READER using CACHE."
  (if cache
      (let ((idx (b4x-layout--read-s32le reader)))
        (or (nth idx cache)
            (error "Cached string index out of range: %s" idx)))
    (b4x-layout--read-string reader)))

(defun b4x-layout--cache-intern (cache string)
  "Return CACHE index for STRING, adding it when missing."
  (or (gethash string (b4x-layout-cache-table cache))
      (let ((idx (b4x-layout-cache-size cache))
            (cell (list string)))
        (puthash string idx (b4x-layout-cache-table cache))
        (if (b4x-layout-cache-tail cache)
            (setcdr (b4x-layout-cache-tail cache) cell)
          (setf (b4x-layout-cache-order cache) cell))
        (setf (b4x-layout-cache-tail cache) cell
              (b4x-layout-cache-size cache) (1+ idx))
        idx)))

(defun b4x-layout--write-cached-string (cache string)
  "Insert CACHE index for STRING in the current binary buffer."
  (b4x-layout--write-s32 (b4x-layout--cache-intern cache string)))

(defun b4x-layout--write-strings-cache (cache)
  "Insert CACHE contents in the current binary buffer."
  (b4x-layout--write-s32 (b4x-layout-cache-size cache))
  (dolist (string (b4x-layout-cache-order cache))
    (b4x-layout--write-string string)))

(defun b4x-layout--gunzip-string (string)
  "Return STRING gunzipped as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert string)
    (zlib-decompress-region (point-min) (point-max))
    (buffer-string)))

(defun b4x-layout--gzip-string (string)
  "Return STRING gzipped as a unibyte string."
  (let ((output (generate-new-buffer " *b4x-layout-gzip*")))
    (unwind-protect
        (progn
          (with-current-buffer output
            (set-buffer-multibyte nil))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert string)
            (let ((status (call-process-region (point-min) (point-max)
                                               "gzip" nil output nil "-nc")))
              (unless (eq status 0)
                (error "gzip failed while writing designer scripts"))))
          (with-current-buffer output
            (buffer-string)))
      (kill-buffer output))))

(defun b4x-layout--read-binary-string (reader)
  "Read one varint-length UTF-8 string from READER."
  (let ((length 0)
        (shift 0)
        (done nil))
    (while (not done)
      (let* ((byte (b4x-layout--read-u8 reader))
             (value (logand #x7f byte)))
        (setq length (+ length (ash value shift)))
        (if (= byte value)
            (setq done t)
          (setq shift (+ shift 7)))))
    (decode-coding-string (b4x-layout--read-bytes reader length) 'utf-8 t)))

(defun b4x-layout--write-binary-string (string)
  "Insert STRING using the B4X varint-length UTF-8 encoding."
  (let ((n (length string)))
    (while (>= n 128)
      (b4x-layout--write-u8 (logior #x80 (logand n #x7f)))
      (setq n (ash n -7)))
    (b4x-layout--write-u8 n)
    (insert (encode-coding-string string 'utf-8 t))))

(defun b4x-layout--read-variant (reader)
  "Read one layout variant object from READER."
  (b4x-layout--make-object
   (list (cons "Scale" (b4x-layout--read-f32le reader))
         (cons "Width" (b4x-layout--read-s32le reader))
         (cons "Height" (b4x-layout--read-s32le reader)))))

(defun b4x-layout--write-variant (variant)
  "Insert VARIANT in the current binary buffer."
  (setq variant (b4x-layout--ensure-object variant "variant"))
  (b4x-layout--write-f32 (or (b4x-layout-object-get variant "Scale") 1.0))
  (b4x-layout--write-s32 (or (b4x-layout-object-get variant "Width") 0))
  (b4x-layout--write-s32 (or (b4x-layout-object-get variant "Height") 0)))

(defun b4x-layout--read-scripts (reader)
  "Read the compressed designer scripts blob from READER."
  (let* ((raw (b4x-layout--read-bytes reader (b4x-layout--read-s32le reader)))
         (scripts-reader (make-b4x-layout-reader :data (b4x-layout--gunzip-string raw)))
         (out (list (b4x-layout--read-binary-string scripts-reader)))
         (variants (b4x-layout--read-s32le scripts-reader)))
    (dotimes (_ variants)
      (b4x-layout--read-variant scripts-reader)
      (setq out (append out (list (b4x-layout--read-binary-string scripts-reader)))))
    (vconcat out)))

(defun b4x-layout--write-scripts (scripts variants)
  "Return gzipped binary designer scripts for SCRIPTS and VARIANTS."
  (let ((scripts (copy-sequence (b4x-layout--sequence-to-list scripts)))
        raw)
    (unless scripts
      (setq scripts '("")))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (b4x-layout--write-binary-string (or (car scripts) ""))
      (setq scripts (cdr scripts))
      (b4x-layout--write-s32 (length (b4x-layout--sequence-to-list variants)))
      (dolist (variant (b4x-layout--sequence-to-list variants))
        (b4x-layout--write-variant variant)
        (b4x-layout--write-binary-string (or (car scripts) ""))
        (setq scripts (cdr scripts)))
      (setq raw (buffer-string)))
    (b4x-layout--gzip-string raw)))

(defun b4x-layout--typed-value (tag &optional value)
  "Return a typed wrapper object for TAG and VALUE."
  (b4x-layout--make-object
   (if (eq value :missing)
       (list (cons "ValueType" tag))
     (list (cons "ValueType" tag)
           (cons "Value" value)))))

(defun b4x-layout--read-map (reader cache)
  "Read one recursive property map from READER using CACHE."
  (let (entries stop)
    (while (not stop)
      (let* ((key (b4x-layout--read-cached-string reader cache))
             (tag (b4x-layout--read-s8 reader))
             value)
        (pcase tag
          (1 (setq value (b4x-layout--read-s32le reader)))
          (2 (setq value (b4x-layout--typed-value tag
                                                  (b4x-layout--read-string reader))))
          (3 (setq value (b4x-layout--read-map reader cache)))
          (4 (setq stop t))
          (5 (setq value (if (= (b4x-layout--read-s8 reader) 1) t :json-false)))
          (6 (setq value
                   (b4x-layout--typed-value
                    tag
                    (concat "0x"
                            (upcase
                             (mapconcat (lambda (b) (format "%02x" b))
                                        (string-to-list
                                         (b4x-layout--read-bytes reader 4))
                                        ""))))))
          (7 (setq value (b4x-layout--typed-value tag
                                                  (b4x-layout--read-f32le reader))))
          (9 (setq value (b4x-layout--read-cached-string reader cache)))
          (11 (setq value (b4x-layout--typed-value
                           tag
                           (vector (b4x-layout--read-s16le reader)
                                   (b4x-layout--read-s16le reader)
                                   (b4x-layout--read-s16le reader)
                                   (b4x-layout--read-s16le reader)))))
          (12 (setq value (b4x-layout--typed-value tag :missing)))
          (_ (error "Unsupported layout value tag %s for key %S" tag key)))
        (unless stop
          (push (cons key value) entries))))
    (b4x-layout--make-object (nreverse entries))))

(defun b4x-layout-read-file (file)
  "Read B4X layout FILE (`.bjl', `.bal', or `.bil') into a Lisp object."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (let* ((reader (make-b4x-layout-reader :data (buffer-string)))
           (header (b4x-layout--make-object))
           (version (b4x-layout--read-s32le reader)))
      (when (< version 3)
        (error "Unsupported layout version %s in %s" version file))
      (b4x-layout--read-s32le reader) ; header-size stub
      (b4x-layout-object-put header "Version" version)
      (b4x-layout-object-put header "GridSize"
                             (if (>= version 4)
                                 (b4x-layout--read-s32le reader)
                               10))
      (let* ((cache (b4x-layout--load-strings-cache reader))
             (controls nil)
             (ncontrols (b4x-layout--read-s32le reader)))
        (dotimes (_ ncontrols)
          (push (b4x-layout--make-object
                 (list (cons "Name" (b4x-layout--read-cached-string reader cache))
                       (cons "JavaType" (b4x-layout--read-cached-string reader cache))
                       (cons "DesignerType" (b4x-layout--read-cached-string reader cache))))
                controls))
        (b4x-layout-object-put header "ControlsHeaders" (vconcat (nreverse controls)))
        (let ((files nil)
              (nfiles (b4x-layout--read-s32le reader)))
          (dotimes (_ nfiles)
            (push (b4x-layout--read-string reader) files))
          (b4x-layout-object-put header "Files" (vconcat (nreverse files)))))
      (b4x-layout-object-put header "DesignerScript" (b4x-layout--read-scripts reader))
      (let* ((map-cache (b4x-layout--load-strings-cache reader))
             (variants nil)
             (nvariants (b4x-layout--read-s32le reader))
             data)
        (dotimes (_ nvariants)
          (push (b4x-layout--read-variant reader) variants))
        (setq data (b4x-layout--read-map reader map-cache))
        (b4x-layout--read-s32le reader) ; trailing 0 sentinel
        (b4x-layout--make-object
         (list (cons "LayoutHeader" header)
               (cons "Variants" (vconcat (nreverse variants)))
               (cons "Data" data)
               (cons "FontAwesome"
                           (if (= (b4x-layout--read-s8 reader) 1) t :json-false))
               (cons "MaterialIcons"
                           (if (= (b4x-layout--read-s8 reader) 1) t :json-false))))))))

(defun b4x-layout--write-map (map cache to-bil)
  "Insert MAP in the current binary buffer using CACHE.
When TO-BIL is non-nil, skip `CNULL' and `RECT32' typed wrappers." 
  (setq map (b4x-layout--ensure-object map "layout map"))
  (dolist (entry (b4x-layout-object-entries map))
    (let* ((key (car entry))
           (val (cdr entry))
           (typed-tag (b4x-layout--typed-wrapper-tag val)))
      (when (and to-bil typed-tag
                 (memq typed-tag (list b4x-layout-cnull b4x-layout-rect32)))
        (setq key nil))
      (when key
        (b4x-layout--write-cached-string cache key)
        (cond
         (typed-tag
          (b4x-layout--write-u8 typed-tag)
          (pcase typed-tag
            (2 (b4x-layout--write-string (or (b4x-layout-object-get val "Value") "")))
            (6 (let ((hex (or (b4x-layout-object-get val "Value") "0x00000000")))
                 (insert (apply #'b4x-layout--u8-string
                                (mapcar (lambda (pair)
                                          (string-to-number pair 16))
                                        (seq-partition (substring hex 2) 2))))))
            (7 (b4x-layout--write-f32 (or (b4x-layout-object-get val "Value") 0.0)))
            (11 (let ((rect (b4x-layout--sequence-to-list
                             (or (b4x-layout-object-get val "Value") []))))
                  (unless (= (length rect) 4)
                    (error "RECT32 expects 4 shorts, got %S" rect))
                  (dolist (n rect)
                    (b4x-layout--write-u16 n))))
            (12 nil)
            (_ (error "Unsupported typed wrapper tag %S" typed-tag))))
         ((b4x-layout-object-p val)
          (b4x-layout--write-u8 b4x-layout-cmap)
          (b4x-layout--write-map val cache to-bil)
          (b4x-layout--write-string "")
          (b4x-layout--write-u8 b4x-layout-endofmap))
         ((and (integerp val) (not (eq val t)))
          (b4x-layout--write-u8 b4x-layout-cint)
          (b4x-layout--write-s32 val))
         ((stringp val)
          (b4x-layout--write-u8 b4x-layout-cached-string)
          (b4x-layout--write-cached-string cache val))
         ((memq val '(t :json-false))
          (b4x-layout--write-u8 b4x-layout-bool)
          (b4x-layout--write-u8 (if (eq val t) 1 0)))
         ((or (null val) (eq val b4x-layout--json-null))
          (b4x-layout--write-u8 b4x-layout-cnull))
         (t
          (error "Unsupported layout map value for %S: %S" key val)))))))

(defun b4x-layout-write-file (layout file)
  "Write LAYOUT to binary FILE (`.bjl', `.bal', or `.bil')."
  (make-directory (file-name-directory file) t)
  (let* ((layout (b4x-layout--ensure-object layout "layout"))
         (header (b4x-layout--ensure-object
                  (b4x-layout-object-get layout "LayoutHeader") "LayoutHeader"))
         (variants (b4x-layout--sequence-to-list
                    (or (b4x-layout-object-get layout "Variants") nil)))
         (data (b4x-layout--ensure-object
                (b4x-layout-object-get layout "Data") "Data"))
         (to-bil (string-match-p "\\.bil\\'" file))
         (version (or (b4x-layout-object-get header "Version") 5))
         header-body
         layout-body
         scripts)
    ;; Header cached section.
    (let ((cache (make-b4x-layout-cache)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (let ((controls (b4x-layout--sequence-to-list
                         (or (b4x-layout-object-get header "ControlsHeaders") nil))))
          (b4x-layout--write-s32 (length controls))
          (dolist (control controls)
            (setq control (b4x-layout--ensure-object control "control header"))
            (b4x-layout--write-cached-string cache (or (b4x-layout-object-get control "Name") ""))
            (b4x-layout--write-cached-string cache (or (b4x-layout-object-get control "JavaType") ""))
            (b4x-layout--write-cached-string cache (or (b4x-layout-object-get control "DesignerType") ""))))
        (setq header-body (buffer-string)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (b4x-layout--write-strings-cache cache)
        (insert header-body)
        (setq header-body (buffer-string))))
    ;; Layout cached section.
    (let ((cache (make-b4x-layout-cache)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (b4x-layout--write-s32 (length variants))
        (dolist (variant variants)
          (b4x-layout--write-variant variant))
        (b4x-layout--write-map data cache to-bil)
        (b4x-layout--write-string "")
        (b4x-layout--write-u8 b4x-layout-endofmap)
        (setq layout-body (buffer-string)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (b4x-layout--write-strings-cache cache)
        (insert layout-body)
        (setq layout-body (buffer-string))))
    (setq scripts (b4x-layout--write-scripts
                   (or (b4x-layout-object-get header "DesignerScript") '(""))
                   variants))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (let ((stub-pos nil)
            (files (b4x-layout--sequence-to-list
                    (or (b4x-layout-object-get header "Files") nil))))
        (b4x-layout--write-s32 version)
        (setq stub-pos (point))
        (b4x-layout--write-s32 0)
        (when (>= version 4)
          (b4x-layout--write-s32 (or (b4x-layout-object-get header "GridSize") 10)))
        (insert header-body)
        (b4x-layout--write-s32 (length files))
        (dolist (f files)
          (b4x-layout--write-string f))
        (b4x-layout--write-s32 (length scripts))
        (insert scripts)
        (let ((end (point)))
          (save-excursion
            (goto-char stub-pos)
            (delete-region stub-pos (+ stub-pos 4))
            (insert (b4x-layout--pack-s32le (- end stub-pos 4))))
          (goto-char end))
        (insert layout-body)
        (b4x-layout--write-s32 0)
        (b4x-layout--write-u8 (if (eq (b4x-layout-object-get layout "FontAwesome") t) 1 0))
        (b4x-layout--write-u8 (if (eq (b4x-layout-object-get layout "MaterialIcons") t) 1 0))))))

(defun b4x-layout--from-json-data (value)
  "Convert parsed JSON VALUE into layout objects."
  (cond
   ((eq value b4x-layout--json-null) b4x-layout--json-null)
   ((eq value :json-false) :json-false)
   ((hash-table-p value)
    (let (entries)
      (maphash (lambda (k v)
                 (push (cons k (b4x-layout--from-json-data v)) entries))
               value)
      (b4x-layout--make-object (nreverse entries))))
   ((and (listp value)
         (or (null value) (consp (car value))))
    (b4x-layout--make-object
     (mapcar (lambda (entry)
               (cons (car entry) (b4x-layout--from-json-data (cdr entry))))
             value)))
   ((vectorp value)
    (apply #'vector (mapcar #'b4x-layout--from-json-data value)))
   ((listp value)
    (mapcar #'b4x-layout--from-json-data value))
   (t value)))

(defun b4x-layout--to-json-data (value)
  "Convert internal layout VALUE into something `json-encode' accepts."
  (cond
   ((b4x-layout-object-p value)
    (if (null (b4x-layout-object-entries value))
        (make-hash-table :test 'equal)
      (mapcar (lambda (entry)
                (cons (car entry) (b4x-layout--to-json-data (cdr entry))))
              (b4x-layout-object-entries value))))
   ((vectorp value)
    (apply #'vector (mapcar #'b4x-layout--to-json-data (append value nil))))
   ((listp value)
    (mapcar #'b4x-layout--to-json-data value))
   ((eq value :json-false) json-false)
   ((eq value b4x-layout--json-null) nil)
   (t value)))

(defun b4x-layout-read-json-file (file)
  "Read JSON FILE into the internal layout object shape."
  (let ((json-object-type 'alist)
        (json-array-type 'vector)
        (json-key-type 'string)
        (json-false :json-false)
        (json-null b4x-layout--json-null))
    (with-temp-buffer
      (insert-file-contents file)
      (b4x-layout--from-json-data (json-read)))))

(defun b4x-layout-write-json-file (layout file)
  "Write LAYOUT to pretty-printed JSON FILE."
  (make-directory (file-name-directory file) t)
  (let ((json-encoding-pretty-print nil))
    (with-temp-file file
      (insert (json-encode (b4x-layout--to-json-data layout)))
      (json-pretty-print-buffer))))

(defun b4x-layout--canonical (value)
  "Return a canonical structure for comparing layout VALUEs semantically."
  (cond
   ((b4x-layout-object-p value)
    (cons :object
          (mapcar (lambda (entry)
                    (cons (car entry) (b4x-layout--canonical (cdr entry))))
                  (b4x-layout-object-entries value))))
   ((vectorp value)
    (apply #'vector (mapcar #'b4x-layout--canonical (append value nil))))
   ((listp value)
    (mapcar #'b4x-layout--canonical value))
   (t value)))

(defun b4x-layout-equal-p (a b)
  "Non-nil when layouts A and B are semantically equal."
  (equal (b4x-layout--canonical a)
         (b4x-layout--canonical b)))

(defun b4x-layout-project-json-dir (project)
  "Return PROJECT's `JsonLayouts/' directory path."
  (expand-file-name "JsonLayouts" (b4x-project-project-dir project)))

(defun b4x-layout-json-file (project name)
  "Return the JSON sidecar path for layout NAME in PROJECT."
  (expand-file-name (concat name ".json") (b4x-layout-project-json-dir project)))

(defun b4x-layout-sync-state-file (project)
  "Return PROJECT's optional sync sidecar path."
  (expand-file-name ".b4x-layout-sync.json" (b4x-layout-project-json-dir project)))

(defun b4x-layout--json-layout-files (project)
  "Return a list of (NAME . PATH) for JSON layouts in PROJECT."
  (let ((dir (b4x-layout-project-json-dir project))
        out)
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.json\\'" t))
        (unless (string= (file-name-nondirectory file) ".b4x-layout-sync.json")
          (push (cons (file-name-base file) file) out))))
    (sort out (lambda (a b) (string< (car a) (car b))))))

(defun b4x-layout--file-mtime (file)
  "Return FILE's modification time as a float, or nil when missing."
  (when (and file (file-exists-p file))
    (float-time (file-attribute-modification-time (file-attributes file)))))

(defun b4x-layout--sidecar-read (project)
  "Read PROJECT's sync sidecar into an alist keyed by lowercased layout name."
  (let ((file (b4x-layout-sync-state-file project))
        (json-object-type 'alist)
        (json-array-type 'vector)
        (json-key-type 'string)
        (json-false :json-false)
        (json-null b4x-layout--json-null))
    (if (file-regular-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (let* ((obj (json-read))
                 (layouts (cdr (assoc "layouts" obj))))
            (or layouts nil)))
      nil)))

(defun b4x-layout--sidecar-write (project state)
  "Write PROJECT sync STATE alist to the sidecar JSON file."
  (let ((dir (b4x-layout-project-json-dir project))
        (file (b4x-layout-sync-state-file project)))
    (make-directory dir t)
    (with-temp-file file
      (insert (json-encode `(("version" . ,b4x-layout--sync-version)
                             ("layouts" . ,state))))
      (json-pretty-print-buffer))))

(defun b4x-layout--state-entry (state lower-name)
  "Return STATE entry for LOWER-NAME."
  (cdr (assoc lower-name state)))

(defun b4x-layout--state-set (state lower-name entry)
  "Return STATE with LOWER-NAME updated to ENTRY."
  (let ((cell (assoc lower-name state)))
    (if cell
        (progn (setcdr cell entry) state)
      (append state (list (cons lower-name entry))))))

(defun b4x-layout--state-del (state lower-name)
  "Return STATE without LOWER-NAME."
  (seq-remove (lambda (entry) (string= (car entry) lower-name)) state))

(defun b4x-layout--make-state-entry (name owner bal-file json-file)
  "Build a sidecar entry for NAME and the two files."
  `(("name" . ,name)
    ("owner" . ,owner)
    ("bal_mtime" . ,(b4x-layout--file-mtime bal-file))
    ("json_mtime" . ,(b4x-layout--file-mtime json-file))))

(defun b4x-layout--current-project ()
  "Return the current B4X project or signal an error."
  (or (b4x-nav-current-project)
      (error "Not inside a B4X project")))

(defun b4x-layout--current-layout-name (project)
  "Return the current layout/JSON base name in PROJECT, or nil."
  (when-let ((file (buffer-file-name)))
    (let ((ext (downcase (or (file-name-extension file) "")))
          (layout-ext (b4x-project-layout-ext project)))
      (cond
       ((and layout-ext (string= ext layout-ext))
        (file-name-base file))
       ((string= ext "json")
        (let ((json-dir (file-name-as-directory (b4x-layout-project-json-dir project))))
          (when (string-prefix-p json-dir (expand-file-name file))
            (file-name-base file))))))))

(defun b4x-layout--read-layout-name (project prompt &optional allow-json-only)
  "Prompt for a layout name in PROJECT using PROMPT.
When ALLOW-JSON-ONLY is non-nil, include names that only exist as JSON files." 
  (let* ((layouts (mapcar #'car (b4x-project-layout-files project)))
         (jsons (mapcar #'car (b4x-layout--json-layout-files project)))
         (names (sort (delete-dups (append layouts (and allow-json-only jsons))) #'string<))
         (default (b4x-layout--current-layout-name project)))
    (if names
        (completing-read prompt names nil t nil nil default)
      (error "No layout files known for %s" (b4x-project-project-file project)))))

(defun b4x-layout-export (name)
  "Export layout NAME from binary form to `JsonLayouts/NAME.json'."
  (interactive
   (let ((proj (b4x-layout--current-project)))
     (list (b4x-layout--read-layout-name proj "Export layout: "))))
  (let* ((project (b4x-layout--current-project))
         (bal-file (or (b4x-project-find-layout project name)
                       (error "Layout %S not found in %s" name
                              (b4x-project-project-file project))))
         (json-file (b4x-layout-json-file project name))
         (layout (b4x-layout-read-file bal-file))
         (state (b4x-layout--sidecar-read project)))
    (make-directory (file-name-directory json-file) t)
    (b4x-layout-write-json-file layout json-file)
    (setq state (b4x-layout--state-set
                 state (downcase name)
                 (b4x-layout--make-state-entry name "bal" bal-file json-file)))
    (b4x-layout--sidecar-write project state)
    (message "B4X: exported layout %s -> %s" name json-file)))

(defun b4x-layout-import (name)
  "Import `JsonLayouts/NAME.json' to the binary layout file."
  (interactive
   (let ((proj (b4x-layout--current-project)))
     (list (b4x-layout--read-layout-name proj "Import layout JSON: " t))))
  (let* ((project (b4x-layout--current-project))
         (json-file (b4x-layout-json-file project name))
         (layout-ext (or (b4x-project-layout-ext project)
                         (error "Current B4X platform has no layouts")))
         (files-dir (or (b4x-project-files-dir project)
                        (error "Project has no Files/ directory: %s"
                               (b4x-project-project-file project))))
         (bal-file (or (b4x-project-find-layout project name)
                       (expand-file-name (concat name "." layout-ext) files-dir)))
         (layout (b4x-layout-read-json-file json-file))
         (state (b4x-layout--sidecar-read project)))
    (unless (file-regular-p json-file)
      (error "JSON layout not found: %s" json-file))
    (make-directory (file-name-directory bal-file) t)
    (b4x-layout-write-file layout bal-file)
    (setq state (b4x-layout--state-set
                 state (downcase name)
                 (b4x-layout--make-state-entry name "json" bal-file json-file)))
    (b4x-layout--sidecar-write project state)
    (message "B4X: imported layout %s <- %s" name json-file)))

(defun b4x-layout-open-json (name)
  "Open the JSON sidecar for layout NAME, offering to export it if needed."
  (interactive
   (let ((proj (b4x-layout--current-project)))
     (list (b4x-layout--read-layout-name proj "Layout JSON: " t))))
  (let* ((project (b4x-layout--current-project))
         (json-file (b4x-layout-json-file project name)))
    (unless (file-exists-p json-file)
      (if (and (b4x-project-find-layout project name)
               (y-or-n-p (format "JSON sidecar missing for %s. Export it now? " name)))
          (b4x-layout-export name)
        (error "JSON sidecar not found: %s" json-file)))
    (find-file json-file)))

(defun b4x-layout--sync-delete-file (file)
  "Move FILE to trash when possible, else delete it permanently."
  (when (file-exists-p file)
    (if (fboundp 'move-file-to-trash)
        (move-file-to-trash file)
      (delete-file file))))

(defun b4x-layout--sync-both-no-state (_name bal-file json-file)
  "Handle the case where a layout has both files but no sync state.
Return one of the symbols `noop' or `conflict'."
  (if (b4x-layout-equal-p (b4x-layout-read-file bal-file)
                          (b4x-layout-read-json-file json-file))
      'noop
    'conflict))

(defun b4x-layout-sync-project ()
  "Synchronize `Files/*.b?l' and `JsonLayouts/*.json' for the current project.

Uses an optional JSON sidecar to track previous sync state.  Without prior
state, only clear cases are acted on automatically; divergent existing pairs are
reported as conflicts instead of guessed."
  (interactive)
  (let* ((project (b4x-layout--current-project))
         (layout-files (b4x-project-layout-files project))
         (json-files (b4x-layout--json-layout-files project))
         (state (b4x-layout--sidecar-read project))
         (all (make-hash-table :test 'equal))
         (exported 0)
         (imported 0)
         (deleted 0)
         (unchanged 0)
         conflicts)
    (dolist (entry layout-files)
      (puthash (downcase (car entry))
               (list :name (car entry) :bal (cdr entry))
               all))
    (dolist (entry json-files)
      (let* ((lower (downcase (car entry)))
             (slot (gethash lower all)))
        (puthash lower
                 (plist-put (or slot (list :name (car entry))) :json (cdr entry))
                 all)))
    (let (slots)
      (maphash (lambda (lower slot)
                 (push (cons lower slot) slots))
               all)
      (dolist (pair slots)
        (let* ((lower (car pair))
               (slot (cdr pair))
               (name (plist-get slot :name))
               (bal-file (plist-get slot :bal))
               (json-file (plist-get slot :json))
               (entry (b4x-layout--state-entry state lower))
               (owner (cdr (assoc "owner" entry)))
               (bal-mtime (b4x-layout--file-mtime bal-file))
               (json-mtime (b4x-layout--file-mtime json-file))
               (state-bal (cdr (assoc "bal_mtime" entry)))
               (state-json (cdr (assoc "json_mtime" entry))))
          (cond
           ((and bal-file (not json-file))
            (if (and entry (string= owner "json"))
                (progn
                  (b4x-layout--sync-delete-file bal-file)
                  (setq state (b4x-layout--state-del state lower))
                  (cl-incf deleted))
              (let ((target (b4x-layout-json-file project name)))
                (b4x-layout-write-json-file (b4x-layout-read-file bal-file) target)
                (setq state (b4x-layout--state-set
                             state lower
                             (b4x-layout--make-state-entry name "bal" bal-file target)))
                (cl-incf exported))))
           ((and json-file (not bal-file))
            (if (and entry (string= owner "bal"))
                (progn
                  (b4x-layout--sync-delete-file json-file)
                  (setq state (b4x-layout--state-del state lower))
                  (cl-incf deleted))
              (let* ((layout-ext (b4x-project-layout-ext project))
                     (target (expand-file-name (concat name "." layout-ext)
                                               (b4x-project-files-dir project))))
                (b4x-layout-write-file (b4x-layout-read-json-file json-file) target)
                (setq state (b4x-layout--state-set
                             state lower
                             (b4x-layout--make-state-entry name "json" target json-file)))
                (cl-incf imported))))
           ((and bal-file json-file)
            (cond
             ((null entry)
              (pcase (b4x-layout--sync-both-no-state name bal-file json-file)
                ('noop
                 (setq state (b4x-layout--state-set
                              state lower
                              (b4x-layout--make-state-entry
                               name
                               (if (and bal-mtime json-mtime (> bal-mtime json-mtime))
                                   "bal"
                                 "json")
                               bal-file json-file)))
                 (cl-incf unchanged))
                ('conflict
                 (push name conflicts))))
             ((and (equal bal-mtime state-bal)
                   (equal json-mtime state-json))
              (cl-incf unchanged))
             ((and (equal json-mtime state-json)
                   (not (equal bal-mtime state-bal)))
              (b4x-layout-write-json-file (b4x-layout-read-file bal-file) json-file)
              (setq state (b4x-layout--state-set
                           state lower
                           (b4x-layout--make-state-entry name "bal" bal-file json-file)))
              (cl-incf exported))
             ((and (equal bal-mtime state-bal)
                   (not (equal json-mtime state-json)))
              (b4x-layout-write-file (b4x-layout-read-json-file json-file) bal-file)
              (setq state (b4x-layout--state-set
                           state lower
                           (b4x-layout--make-state-entry name "json" bal-file json-file)))
              (cl-incf imported))
             ((b4x-layout-equal-p (b4x-layout-read-file bal-file)
                                  (b4x-layout-read-json-file json-file))
              (setq state (b4x-layout--state-set
                           state lower
                           (b4x-layout--make-state-entry name owner bal-file json-file)))
              (cl-incf unchanged))
             (t
              (push name conflicts)))))))
    (b4x-layout--sidecar-write project state)
    (if conflicts
        (message "B4X: layout sync done — exported %d, imported %d, deleted %d, unchanged %d, conflicts: %s"
                 exported imported deleted unchanged
                 (string-join (sort conflicts #'string<) ", "))
      (message "B4X: layout sync done — exported %d, imported %d, deleted %d, unchanged %d"
               exported imported deleted unchanged)))))

(provide 'b4x-layout)
;;; b4x-layout.el ends here
