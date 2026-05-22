;;; newst-jsonrpc.el --- Plainview pager with pager for Newsticker  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0") (emacs-stdio-jsonrpc "0.1.0"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Transparent plainview paging for Newsticker backed by C++ pager.
;; Requires newst-sql for the SQLite cache that pager reads from.
;; Requires newst-async-net for the async feed download queue.
;; Simply (require 'newst-jsonrpc) — pager advice is installed automatically
;; if the pager binary is found.

;;; Code:

(require 'jsonrpc)
(require 'emacs-stdio-jsonrpc nil t)
(require 'newst-async-net)

(eval-when-compile
  (require 'newsticker nil t))

(declare-function newsticker--buffer-insert-item "newst-plainview.el")
(declare-function newsticker--buffer-set-faces "newst-plainview.el")
(declare-function newsticker--buffer-set-invisibility "newst-plainview.el")
(declare-function newsticker--buffer-goto "newst-plainview.el")
(declare-function newsticker-hide-all-desc "newst-plainview.el")
(declare-function newsticker-hide-old-items "newst-plainview.el")
(declare-function newsticker-hide-old-feed-header "newst-plainview.el")
(declare-function newsticker-show-new-item-desc "newst-plainview.el")
(declare-function emacs-stdio-jsonrpc-start-app "ext:emacs-stdio-jsonrpc.el")
(declare-function emacs-stdio-jsonrpc-stop-app "ext:emacs-stdio-jsonrpc.el")

;; ----------------------------------------------------------------------
;; User options
;; ----------------------------------------------------------------------

(defgroup newst-jsonrpc nil
  "Newsticker plainview pager via pager."
  :group 'emacs-stdio-jsonrpc)

(defcustom newst-jsonrpc-page-size 20
  "Number of items per page in the paged plainview."
  :type 'integer
  :group 'newst-jsonrpc)

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

(defvar newst-jsonrpc-pager-path nil
  "Explicit path to the pager binary.
If nil, auto-detect relative to WHERE-THIS-FILE-WAS-LOADED-FROM
\(handles both `load-file' and `eval-buffer').")

(defun newst-jsonrpc--find-pager ()
  "Locate the pager binary.
Checks, in order:
1. `newst-jsonrpc-pager-path' (if set)
2. relative to `newst-jsonrpc--load-dir' (captured at load/eval time)
3. `default-directory' (fallback)"
  (or newst-jsonrpc-pager-path
      (let ((dir (or newst-jsonrpc--load-dir default-directory)))
        (expand-file-name "build/pager" dir))))

(defvar newst-jsonrpc--load-dir
  ;; Captured at load/eval time so it works with both `load-file' and
  ;; `eval-buffer'.
  (or (when load-file-name (file-name-directory load-file-name))
      (when buffer-file-name (file-name-directory buffer-file-name))
      default-directory)
  "Directory where newst-jsonrpc.el was loaded from.")


(defvar newst-jsonrpc-conn nil
  "JSON-RPC connection to pager subprocess.
Non-nil means the pager is active.")

(defvar newst-jsonrpc-feed-name nil
  "String name of the current feed.")

(defvar newst-jsonrpc-offset 0
  "Item offset of the current page.")

(defvar newst-jsonrpc-total 0
  "Total items in the current feed.")

(defvar newst-jsonrpc-page-content nil
  "Items in the current page (Elisp item list format).")

(defvar newst-jsonrpc-debug nil
  "When non-nil, print diagnostic messages for pager.")

(defun newst-jsonrpc-debug (fmt &rest args)
  (when newst-jsonrpc-debug
    (apply #'message (concat "[jrpc-nw] " fmt) args)))

;; ----------------------------------------------------------------------
;; pager lifecycle (lazy start)
;; ----------------------------------------------------------------------

(defun newst-jsonrpc-start ()
  "Start pager subprocess.  Return t on success."
  (let* ((bin (newst-jsonrpc--find-pager))
          (db (if (and (boundp 'newsticker-dir) newsticker-dir)
                  (expand-file-name "cache.db" newsticker-dir)
                (expand-file-name "cache.db"
                                  (locate-user-emacs-file "newsticker")))))
    (condition-case err
        (progn
          (unless (file-exists-p bin)
            (error "pager binary not found at %s" bin))
          (let ((conn (emacs-stdio-jsonrpc-start-app
                       "pager" bin (list db)))
                (proc nil))
            (setq proc (ignore-errors (jsonrpc--process conn)))
            (unless (and proc (process-live-p proc))
              (emacs-stdio-jsonrpc-stop-app "pager")
              (error "pager process died immediately"))
            (setq newst-jsonrpc-conn conn)
            (newst-jsonrpc-debug
             "pager started: %s DB=%s" (file-name-nondirectory bin) db)
            t))
      (error
       (newst-jsonrpc-debug "pager start failed: %S" err)
       nil))))

(defun newst-jsonrpc-stop ()
  "Stop pager subprocess."
  (when newst-jsonrpc-conn
    (emacs-stdio-jsonrpc-stop-app "pager")
    (setq newst-jsonrpc-conn nil
          newst-jsonrpc-feed-name nil
          newst-jsonrpc-offset 0
          newst-jsonrpc-total 0
          newst-jsonrpc-page-content nil)))

(defun newst-jsonrpc--ensure-started ()
  "Start pager if not already running.  Return t if running."
  (or newst-jsonrpc-conn
      (newst-jsonrpc-start)))

;; ----------------------------------------------------------------------
;; Core pager functions
;; ----------------------------------------------------------------------

(defvar newst-jsonrpc-max-desc-length 2000
  "Truncate item descriptions to this many characters.
Set to nil for no truncation.")

(defun newst-jsonrpc--json-to-item (json)
  "Convert JSON plist from pager to Elisp item list."
  (list (plist-get json :title)
        (let ((desc (plist-get json :description)))
          (when desc
            (if (and newst-jsonrpc-max-desc-length
                     (> (length desc) newst-jsonrpc-max-desc-length))
                (truncate-string-to-width desc newst-jsonrpc-max-desc-length)
              desc)))
        (plist-get json :link)
        (append (plist-get json :time) nil)
        (intern (plist-get json :age))
        (plist-get json :pos)
        (plist-get json :preformatted-contents)
        (plist-get json :preformatted-title)
        (let ((extra (plist-get json :extra)))
          (if (and extra (not (string= extra ""))) (read extra) nil))))

(defun newst-jsonrpc--fetch-page (feed-name offset limit)
  "Return (ITEMS . TOTAL) for FEED-NAME at OFFSET with LIMIT."
  (let* ((result (jsonrpc-request
                  newst-jsonrpc-conn
                  "get_page"
                  (list :feed feed-name :offset offset :limit limit)
                  :timeout 10))
         (items (mapcar #'newst-jsonrpc--json-to-item
                        (plist-get result :items)))
         (total (plist-get result :total)))
    (cons items total)))

(defun newst-jsonrpc--feed-descriptor (feed-sym)
  "Return feed-descriptor item for FEED-SYM from in-memory cache."
  (let ((feed (assoc feed-sym newsticker--cache)))
    (when feed
      (catch 'found
        (dolist (item (cdr feed))
          (when (eq (newsticker--age item) 'feed)
            (throw 'found item)))))))

(defun newst-jsonrpc--build-buffer ()
  "Clear *newsticker* and insert current page."
  (let ((buf (get-buffer "*newsticker*")))
    (unless buf (user-error "No *newsticker* buffer"))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (sym (intern newst-jsonrpc-feed-name)))
        (erase-buffer)
        (set-buffer-modified-p nil)
        (let ((fd (newst-jsonrpc--feed-descriptor sym)))
          (when fd
            (newsticker--buffer-insert-item fd sym)))
        (dolist (item newst-jsonrpc-page-content)
          (newsticker--buffer-insert-item item sym))
        (let ((p (point)))
          (insert "\n")
          (put-text-property p (point) 'hard t))
        (newsticker--buffer-set-faces (point-min) (point-max))
        (newsticker--buffer-set-invisibility (point-min) (point-max))
        (newsticker-hide-all-desc)
        (when newsticker-hide-old-items-in-newsticker-buffer
          (newsticker-hide-old-items))
        (when newsticker-hide-old-feed-header
          (newsticker-hide-old-feed-header))
        (when newsticker-show-descriptions-of-new-items
          (newsticker-show-new-item-desc)))
      (goto-char (point-min)))))

(defun newst-jsonrpc-goto (feed-name offset)
  "Switch to FEED-NAME at OFFSET."
  (setq newst-jsonrpc-feed-name feed-name
        newst-jsonrpc-offset offset)
  (let* ((result (newst-jsonrpc--fetch-page
                  feed-name offset
                  newst-jsonrpc-page-size))
         (items (car result))
         (total (cdr result)))
    (setq newst-jsonrpc-total total
          newst-jsonrpc-page-content items)
    (newst-jsonrpc--build-buffer)))

(defun newst-jsonrpc-next-page ()
  "Load next page of current feed.  Wrap to next feed at end."
  (let ((new (+ newst-jsonrpc-offset newst-jsonrpc-page-size)))
    (if (>= new newst-jsonrpc-total)
        (ignore-errors (newst-jsonrpc--next-feed))
      (newst-jsonrpc-goto newst-jsonrpc-feed-name new))))

(defun newst-jsonrpc-prev-page ()
  "Load previous page of current feed.  Wrap to prev feed at start."
  (let ((new (- newst-jsonrpc-offset newst-jsonrpc-page-size)))
    (if (< new 0)
        (ignore-errors (newst-jsonrpc--prev-feed))
      (newst-jsonrpc-goto newst-jsonrpc-feed-name new))))

(defun newst-jsonrpc--adjacent-feed (feeds cur &optional prev)
  "Return feed adjacent to CUR in FEEDS.
When PREV is non-nil, return the preceding feed (reverse navigation)."
  (let* ((seq (if prev (reverse feeds) feeds))
         (tail (member cur seq))
         (next (if (cdr tail) (cadr tail) (car seq))))
    (when next
      (newst-jsonrpc-goto (car next) 0)
      (point))))

(defun newst-jsonrpc--next-feed ()
  "Load next feed's first page.  Cyclic through URL list."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (cur (assoc-string newst-jsonrpc-feed-name feeds)))
    (when cur
      (newst-jsonrpc--adjacent-feed feeds cur))))

(defun newst-jsonrpc--prev-feed ()
  "Load previous feed's first page.  Cyclic through URL list."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (cur (assoc-string newst-jsonrpc-feed-name feeds)))
    (when cur
      (newst-jsonrpc--adjacent-feed feeds cur 'prev))))

;; ----------------------------------------------------------------------
;; Pager advice
;; ----------------------------------------------------------------------

(defun newst-jsonrpc-advice-insert-all (_orig-fn)
  "Around advice for `newsticker--buffer-insert-all-items'.
Start pager lazily if needed, then load page from it.
Show a placeholder buffer when pager is unavailable, instead
of falling through to ORIG-FN which inserts the entire cache."
  (if (not (newst-jsonrpc--ensure-started))
      (let ((buf (get-buffer-create "*newsticker*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert ";; pager not started\n")
            (insert ";; M-x newst-jsonrpc-start RET to retry\n")
            (insert ";; or set newst-jsonrpc-pager-path to the pager binary\n"))
          (newsticker-mode)
          (display-buffer buf)))
    (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
           (first (car feeds)))
      (if (null first)
          (user-error "No feeds configured")
        (condition-case err
            (progn
              (newst-jsonrpc-goto (car first) 0)
              (when (and (null newst-jsonrpc-page-content)
                         (eq 0 newst-jsonrpc-total))
                ;; feed exists but has 0 items — show empty page
                (newst-jsonrpc--build-buffer)))
          (error
           (newst-jsonrpc-debug "page load failed: %S" err)
           (let ((buf (get-buffer-create "*newsticker*")))
             (with-current-buffer buf
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (format ";; pager error: %s\n" err))
                 (insert ";; check *pager* process buffer for details\n"))
               (newsticker-mode)
               (display-buffer buf)))))))))

(defun newst-jsonrpc-advice-next-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-next-item'.
When at last item, load next page from pager."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn do-not-wrap)
    (if (save-excursion (newsticker--buffer-goto '(item)))
        (funcall orig-fn do-not-wrap)
      (newst-jsonrpc-next-page))))

(defun newst-jsonrpc-advice-prev-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-previous-item'.
When at first item, load previous page from pager."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn do-not-wrap)
    (if (save-excursion (newsticker--buffer-goto '(item) nil t))
        (funcall orig-fn do-not-wrap)
      (newst-jsonrpc-prev-page))))

(defun newst-jsonrpc-advice-next-feed (orig-fn)
  "Around advice for `newsticker-next-feed'.
Load next feed's first page from pager."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn)
    (newst-jsonrpc--next-feed)))

(defun newst-jsonrpc-advice-prev-feed (orig-fn)
  "Around advice for `newsticker-previous-feed'.
Load previous feed's first page from pager."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn)
    (newst-jsonrpc--prev-feed)))

;; ----------------------------------------------------------------------
;; Auto-install pager advice on load
;; ----------------------------------------------------------------------

;; Install advice unconditionally.  pager is started lazily on
;; first page load (see `newst-jsonrpc-advice-insert-all').
;; Safe even if newsticker is not yet loaded.
(advice-add 'newsticker--buffer-insert-all-items :around
            #'newst-jsonrpc-advice-insert-all)
(advice-add 'newsticker-next-item :around
            #'newst-jsonrpc-advice-next-item)
(advice-add 'newsticker-previous-item :around
            #'newst-jsonrpc-advice-prev-item)
(advice-add 'newsticker-next-feed :around
            #'newst-jsonrpc-advice-next-feed)
(advice-add 'newsticker-previous-feed :around
            #'newst-jsonrpc-advice-prev-feed)

(provide 'newst-jsonrpc)
;;; newst-jsonrpc.el ends here
