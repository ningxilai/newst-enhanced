;;; newst-jsonrpc.el --- Plainview pager with feed_reader for Newsticker  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0") (emacs-stdio-jsonrpc "0.1.0"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Transparent plainview paging for Newsticker backed by C++ feed_reader.
;; Requires newst-sql for the SQLite cache that feed_reader reads from.
;; Simply (require 'newst-jsonrpc) — pager advice is installed automatically
;; if the feed_reader binary is found.
;;
;; feed_reader is started lazily on first pager use, so it is safe to
;; require this before newsticker is loaded.

;;; Code:

(require 'jsonrpc)
(require 'emacs-stdio-jsonrpc)
(require 'async nil t)

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
(declare-function newsticker--cache-replace-age "newst-backend.el")
(declare-function newsticker--cache-add "newst-backend.el")
(declare-function newsticker--cache-remove "newst-backend.el")
(declare-function newsticker--cache-mark-expired "newst-backend.el")
(declare-function newsticker--cache-get-feed "newst-backend.el")
(declare-function newsticker--cache-save-feed "newst-backend.el")
(declare-function newsticker--update-process-ids "newst-backend.el")
(declare-function newsticker--buffer-set-uptodate "newst-plainview.el")
(declare-function async-start "ext:async.el")
(declare-function dom-by-tag "dom.el")
(declare-function dom-tag "dom.el")
(declare-function dom-text "dom.el")
(declare-function dom-attr "dom.el")

;; ----------------------------------------------------------------------
;; User options
;; ----------------------------------------------------------------------

(defgroup newst-jsonrpc nil
  "Newsticker plainview pager via feed_reader."
  :group 'emacs-stdio-jsonrpc)

(defcustom newst-jsonrpc-page-size 20
  "Number of items per page in the paged plainview."
  :type 'integer
  :group 'newst-jsonrpc)

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

(defvar newst-jsonrpc--load-dir
  (when load-file-name (file-name-directory load-file-name))
  "Directory where newst-jsonrpc.el was loaded from.")

(defvar newst-jsonrpc-conn nil
  "JSON-RPC connection to feed_reader subprocess.
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
;; Async feed download queue (concurrency-limit + async subprocess parsing)
;; ----------------------------------------------------------------------

(defcustom newst-jsonrpc-max-concurrent 3
  "Maximum concurrent feed downloads."
  :type 'integer :group 'newst-jsonrpc)

(defvar newst-jsonrpc--active 0
  "Number of currently active feed downloads.")

(defvar newst-jsonrpc--queue nil
  "Queue of (FEED-NAME URL) pending download.")

;; --- Feed item extractor (runs in both async child and main thread) ---

(defun newst-jsonrpc--mime-strip ()
  "Remove MIME headers from current buffer."
  (goto-char (point-min))
  (when (search-forward "\n\n" nil t)
    (delete-region (point-min) (point))))

(defun newst-jsonrpc--extract-items (dom)
  "Extract feed items from DOM.
Returns (FEED-NAME FEED-TITLE (ITEM ...)) where each ITEM is
\(TITLE DESCRIPTION LINK TIME AGE POS PREFORMATTED-CONTENTS
 PREFORMATTED-TITLE EXTRA).

Time is (HIGH LOW MICRO PICO) as returned by `current-time'.
This function is designed to run in both the main thread and an
async child Emacs."
  (let* ((top (if (eq 'rss (dom-tag dom)) dom
                (or (car (dom-by-tag dom 'feed)) dom)))
         (is-atom (eq 'feed (dom-tag top)))
         (top-for-title (if (and (not is-atom)
                                 (eq 'rss (dom-tag top)))
                            (car (dom-by-tag top 'channel))
                          top))
         (feed-title (let ((t-el (dom-by-tag top-for-title 'title)))
                       (when t-el (dom-text (car t-el)))))
         (raw-items (if is-atom
                        (dom-by-tag top 'entry)
                      (dom-by-tag top 'item)))
         (time (current-time))
         (pos 0))
    (list feed-title
          (mapcar (lambda (item)
                    (setq pos (1+ pos))
                    (newst-jsonrpc--item-to-list item is-atom time pos))
                  raw-items))))

(defun newst-jsonrpc--item-to-list (item is-atom time pos)
  (let* ((title-el (car (dom-by-tag item 'title)))
         (title (if title-el (dom-text title-el) "[untitled]"))
         (desc (if is-atom
                   (or (let ((c (car (dom-by-tag item 'content))))
                         (and c (dom-text c)))
                       (let ((s (car (dom-by-tag item 'summary))))
                         (and s (dom-text s))))
                 (let ((d (car (dom-by-tag item 'description))))
                   (and d (dom-text d)))))
         (link (if is-atom
                   (let ((l (car (dom-by-tag item 'link))))
                     (if l (or (dom-attr l 'href) (dom-text l)) ""))
                 (let ((l (car (dom-by-tag item 'link))))
                   (if l (dom-text l) ""))))
         (guid (if is-atom
                   (let ((i (car (dom-by-tag item 'id))))
                     (and i (dom-text i)))
                 (let ((g (car (dom-by-tag item 'guid))))
                   (and g (dom-text g)))))
         (extra (when guid
                  `((guid nil ,guid)))))
    (list title (or desc "") link
          time 'new pos nil nil extra)))

;; --- Queue lifecycle ---

(defun newst-jsonrpc--dequeue ()
  "Start next queued download if under limit."
  (when (and newst-jsonrpc--queue
             (< newst-jsonrpc--active newst-jsonrpc-max-concurrent))
    (let ((item (pop newst-jsonrpc--queue)))
      (newst-jsonrpc--start-download (car item) (cadr item)))))

;; --- Result processing ---

(defun newst-jsonrpc--process-result (feed-name items)
  "Add parsed ITEMS to in-memory cache and persist to SQLite."
  (require 'newsticker)
  (let ((name-symbol (intern feed-name))
        (time (current-time)))
    (newsticker--cache-replace-age newsticker--cache
                                   name-symbol 'new 'obsolete-new)
    (newsticker--cache-replace-age newsticker--cache
                                   name-symbol 'old 'obsolete-old)
    (newsticker--cache-replace-age newsticker--cache
                                   name-symbol 'feed 'obsolete-old)
    (let* ((feed-entry (or (assoc feed-name newsticker-url-list)
                           (assoc feed-name newsticker-url-list-defaults)))
           (feed-url (and feed-entry (nth 1 feed-entry))))
      (setq newsticker--cache
            (newsticker--cache-add
             newsticker--cache name-symbol
             (or (car items) feed-name) "" (or feed-url "")
             time 'feed 0 nil)))
    (dolist (item (cdr items))
      (setq newsticker--cache
            (newsticker--cache-add newsticker--cache name-symbol
                                   (nth 0 item) (nth 1 item) (nth 2 item)
                                   (nth 3 item) (nth 4 item) (nth 5 item)
                                   (nth 8 item))))
    (newsticker--cache-replace-age newsticker--cache
                                   name-symbol 'obsolete-old 'deleteme)
    (newsticker--cache-remove newsticker--cache name-symbol 'deleteme)
    (if (not newsticker-keep-obsolete-items)
        (newsticker--cache-remove newsticker--cache
                                  name-symbol 'obsolete-new)
      (setq newsticker--cache
            (newsticker--cache-mark-expired
             newsticker--cache name-symbol
             'obsolete 'obsolete-expired
             newsticker-obsolete-item-max-age))
      (newsticker--cache-remove newsticker--cache
                                name-symbol 'obsolete-expired)
      (newsticker--cache-replace-age newsticker--cache
                                     name-symbol 'obsolete-new 'obsolete))
    (newsticker--update-process-ids)
    (setq newsticker--latest-update-time (current-time))
    (newsticker--cache-save-feed
     (newsticker--cache-get-feed name-symbol))
    (when (fboundp 'newsticker--buffer-set-uptodate)
      (newsticker--buffer-set-uptodate nil))))

;; --- Async download (via async-start) ---

(defun newst-jsonrpc--async-download (feed-name url)
  "Download and parse feed in async child process."
  (cl-incf newst-jsonrpc--active)
  (async-start
   `(lambda ()
      (require 'dom)
      (let* ((url ,url)
             (buf (url-retrieve-synchronously url)))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (goto-char (point-min))
            (when (search-forward "\n\n" nil t)
              (delete-region (point-min) (point)))
            (let ((dom (libxml-parse-xml-region (point-min) (point-max))))
              (kill-buffer buf)
              ;; Return (feed-title (item...)).  The caller wraps
              ;; it with feed-name on receipt.
              (cdr (newst-jsonrpc--extract-items dom)))))))
   (lambda (items)
     (when items
       (newst-jsonrpc--process-result feed-name
                                       (cons feed-name items)))
     (setq newst-jsonrpc--active (1- newst-jsonrpc--active))
     (newst-jsonrpc--dequeue))))

;; --- Direct download fallback (uses url-retrieve in main thread) ---

(defun newst-jsonrpc--direct-download (feed-name url)
  "Download and parse feed via url-retrieve (main thread fallback)."
  (let ((coding-system-for-read 'no-conversion))
    (url-retrieve url 'newst-jsonrpc--direct-callback
                  (list feed-name) t nil)))

(defun newst-jsonrpc--direct-callback (_status feed-name)
  "Callback for `newst-jsonrpc--direct-download'."
  (let ((buf (current-buffer)))
    (unwind-protect
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (newst-jsonrpc--mime-strip)
            (let* ((dom (ignore-errors
                          (libxml-parse-xml-region (point-min) (point-max))))
                   (result (and dom (newst-jsonrpc--extract-items dom))))
              (when result
                (newst-jsonrpc--process-result feed-name
                                                (cons feed-name result))))))
      (setq newst-jsonrpc--active (1- newst-jsonrpc--active))
      (newst-jsonrpc--dequeue))))

;; --- Dispatch ---

(defun newst-jsonrpc--start-download (feed-name url)
  "Start download+parse for FEED-NAME from URL.
Uses async-start if available, else url-retrieve."
  (if (featurep 'async)
      (newst-jsonrpc--async-download feed-name url)
    (newst-jsonrpc--direct-download feed-name url)))

;; --- Advice: intercept get-news-by-url to use queue ---

(defun newst-jsonrpc-advice-get-news-by-url (_orig-fn feed-name url)
  ":around advice for `newsticker--get-news-by-url'.
Routes through async download queue instead of direct url-retrieve."
  (if (< newst-jsonrpc--active newst-jsonrpc-max-concurrent)
      (newst-jsonrpc--start-download feed-name url)
    (push (list feed-name url) newst-jsonrpc--queue)
    (newst-jsonrpc-debug "queued %s (active=%d queue=%d)"
                          feed-name newst-jsonrpc--active
                          (length newst-jsonrpc--queue))))

;; ----------------------------------------------------------------------
;; feed_reader lifecycle (lazy start)
;; ----------------------------------------------------------------------

(defun newst-jsonrpc-start ()
  "Start feed_reader subprocess.  Return t on success."
  (let* ((dir (or newst-jsonrpc--load-dir default-directory))
          (bin (expand-file-name "build/feed_reader" dir))
          (db (if (and (boundp 'newsticker-dir) newsticker-dir)
                 (expand-file-name "cache.db" newsticker-dir)
               (expand-file-name "cache.db"
                                 (locate-user-emacs-file "newsticker")))))
    (condition-case err
        (progn
          (unless (file-exists-p bin)
            (error "feed_reader binary not found at %s" bin))
          (let ((conn (emacs-stdio-jsonrpc-start-app
                       "feed_reader" bin (list db)))
                (proc nil))
            (setq proc (ignore-errors (jsonrpc--process conn)))
            (unless (and proc (process-live-p proc))
              (emacs-stdio-jsonrpc-stop-app "feed_reader")
              (error "feed_reader process died immediately"))
            (setq newst-jsonrpc-conn conn)
            (newst-jsonrpc-debug
             "feed_reader started: %s DB=%s" (file-name-nondirectory bin) db)
            t))
      (error
       (newst-jsonrpc-debug "feed_reader start failed: %S" err)
       nil))))

(defun newst-jsonrpc-stop ()
  "Stop feed_reader subprocess."
  (when newst-jsonrpc-conn
    (emacs-stdio-jsonrpc-stop-app "feed_reader")
    (setq newst-jsonrpc-conn nil
          newst-jsonrpc-feed-name nil
          newst-jsonrpc-offset 0
          newst-jsonrpc-total 0
          newst-jsonrpc-page-content nil)))

(defun newst-jsonrpc--ensure-started ()
  "Start feed_reader if not already running.  Return t if running."
  (or newst-jsonrpc-conn
      (newst-jsonrpc-start)))

;; ----------------------------------------------------------------------
;; Core pager functions
;; ----------------------------------------------------------------------

(defun newst-jsonrpc--json-to-item (json)
  "Convert JSON plist from feed_reader to Elisp item list."
  (list (plist-get json :title)
        (plist-get json :description)
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
  (let ((new (+ newst-jsonrpc-offset
                newst-jsonrpc-page-size)))
    (if (>= new newst-jsonrpc-total)
        (condition-case nil
            (newst-jsonrpc--next-feed)
          (error nil))
      (newst-jsonrpc-goto
       newst-jsonrpc-feed-name new))))

(defun newst-jsonrpc-prev-page ()
  "Load previous page of current feed.  Wrap to prev feed at start."
  (let ((new (- newst-jsonrpc-offset
                newst-jsonrpc-page-size)))
    (if (< new 0)
        (condition-case nil
            (newst-jsonrpc--prev-feed)
          (error nil))
      (newst-jsonrpc-goto
       newst-jsonrpc-feed-name new))))

(defun newst-jsonrpc--next-feed ()
  "Load next feed's first page.  Cyclic through URL list."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (cur (assoc-string newst-jsonrpc-feed-name feeds))
         (next (cadr (member cur feeds))))
    (unless next
      (setq next (car feeds)))
    (when next
      (newst-jsonrpc-goto (car next) 0)
      (point))))

(defun newst-jsonrpc--prev-feed ()
  "Load previous feed's first page.  Cyclic through URL list."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (cur (assoc-string newst-jsonrpc-feed-name feeds))
         (prev (cadr (member cur (reverse feeds)))))
    (unless prev
      (setq prev (car (last feeds))))
    (when prev
      (newst-jsonrpc-goto (car prev) 0)
      (point))))

;; ----------------------------------------------------------------------
;; Pager advice
;; ----------------------------------------------------------------------

(defun newst-jsonrpc-advice-insert-all (orig-fn)
  "Around advice for `newsticker--buffer-insert-all-items'.
Start feed_reader lazily if needed, then load page from it.
Fall back to ORIG-FN on error or empty DB."
  (if (not (newst-jsonrpc--ensure-started))
      (funcall orig-fn)
    (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
           (first (car feeds)))
      (if (null first)
          (user-error "No feeds configured")
        (condition-case nil
            (progn
              (newst-jsonrpc-goto (car first) 0)
              (when (and (null newst-jsonrpc-page-content)
                         (eq 0 newst-jsonrpc-total))
                (funcall orig-fn)))
          (error (funcall orig-fn)))))))

(defun newst-jsonrpc-advice-next-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-next-item'.
When at last item, load next page from feed_reader."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn do-not-wrap)
    (if (save-excursion (newsticker--buffer-goto '(item)))
        (funcall orig-fn do-not-wrap)
      (newst-jsonrpc-next-page))))

(defun newst-jsonrpc-advice-prev-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-previous-item'.
When at first item, load previous page from feed_reader."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn do-not-wrap)
    (if (save-excursion (newsticker--buffer-goto '(item) nil t))
        (funcall orig-fn do-not-wrap)
      (newst-jsonrpc-prev-page))))

(defun newst-jsonrpc-advice-next-feed (orig-fn)
  "Around advice for `newsticker-next-feed'.
Load next feed's first page from feed_reader."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn)
    (newst-jsonrpc--next-feed)))

(defun newst-jsonrpc-advice-prev-feed (orig-fn)
  "Around advice for `newsticker-previous-feed'.
Load previous feed's first page from feed_reader."
  (if (not newst-jsonrpc-conn)
      (funcall orig-fn)
    (newst-jsonrpc--prev-feed)))

;; ----------------------------------------------------------------------
;; Auto-install pager advice on load
;; ----------------------------------------------------------------------

;; Install advice unconditionally.  feed_reader is started lazily on
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

;; Concurrent download queue + async parsing
(advice-add 'newsticker--get-news-by-url :around
            #'newst-jsonrpc-advice-get-news-by-url)

(provide 'newst-jsonrpc)
;;; newst-jsonrpc.el ends here
