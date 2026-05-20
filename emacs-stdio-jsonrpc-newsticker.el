;;; emacs-stdio-jsonrpc-newsticker.el --- Newsticker integration for feed_processor  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0") (emacs-stdio-jsonrpc "0.1.0"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; This package provides a Newsticker integration for the C++ feed_processor
;; and feed_reader subprocesses.  When
;; `emacs-stdio-jsonrpc-newsticker-mode' is enabled:
;;
;; 1. **Feed parsing** is redirected to feed_processor (C++ via JSON-RPC),
;;    offloading XML processing from Emacs main thread.
;;
;; 2. **Plainview paging** is enabled: the *newsticker* buffer shows only
;;    one page of items at a time.  Pressing `n` at the last item loads
;;    the next page from feed_reader (C++ SQLite reader).  Pressing `p` at
;;    the first item loads the previous page.  All existing keys work
;;    unchanged — the paging is transparent.
;;
;; Usage:
;;
;;   (require 'emacs-stdio-jsonrpc-newsticker)
;;   (emacs-stdio-jsonrpc-newsticker-mode 1)
;;   M-x newsticker-show-news
;;
;; If feed_reader fails to start (binary or SQLite DB not found), the
;; pager is not activated; standard Plainview behavior is preserved.
;; If feed_processor fails, the mode still works but falls back to
;; Emacs native feed parsing.

;;; Code:

(require 'jsonrpc)
(require 'sqlite)
(require 'emacs-stdio-jsonrpc)

(eval-when-compile
  (require 'newsticker nil t))

;; declare-function for all newsticker symbols used here
(declare-function newsticker--cache-replace-age "newst-backend.el")
(declare-function newsticker--cache-add "newst-backend.el")
(declare-function newsticker--cache-remove "newst-backend.el")
(declare-function newsticker--cache-mark-expired "newst-backend.el")
(declare-function newsticker--cache-get-feed "newst-backend.el")
(declare-function newsticker--cache-save-feed "newst-backend.el")
(declare-function newsticker--update-process-ids "newst-backend.el")
(declare-function newsticker--age "newst-backend.el")
(declare-function newsticker--buffer-insert-item "newst-plainview.el")
(declare-function newsticker--buffer-set-faces "newst-plainview.el")
(declare-function newsticker--buffer-set-invisibility "newst-plainview.el")
(declare-function newsticker--buffer-goto "newst-plainview.el")
(declare-function newsticker-hide-all-desc "newst-plainview.el")
(declare-function newsticker-hide-old-items "newst-plainview.el")
(declare-function newsticker-hide-old-feed-header "newst-plainview.el")
(declare-function newsticker-show-new-item-desc "newst-plainview.el")
(declare-function jsonrpc--process "jsonrpc")

(defgroup emacs-stdio-jsonrpc-newsticker nil
  "Newsticker integration for feed_processor subprocess."
  :group 'emacs-stdio-jsonrpc)

(defvar emacs-stdio-jsonrpc--newsticker-debug nil
  "When non-nil, print diagnostic messages for newsticker integration.")

(defun emacs-stdio-jsonrpc--newsticker-debug (fmt &rest args)
  "Print debug message if `emacs-stdio-jsonrpc--newsticker-debug' is non-nil."
  (when emacs-stdio-jsonrpc--newsticker-debug
    (apply #'message (concat "[jrpc-nw] " fmt) args)))

;; ======================================================================
;; Feed processing (sentinel advice — existing)
;; ======================================================================

(defvar emacs-stdio-jsonrpc--newsticker-busy nil
  "Non-nil while a feed is being processed via C++.
Prevents re-entrant calls from corrupting JSON-RPC state.")

(defvar emacs-stdio-jsonrpc--newsticker-queue nil
  "Queue of (FEED-NAME COMMAND XML) pending C++ processing.")

(defun emacs-stdio-jsonrpc--newsticker-process-queued ()
  "Process the next feed from the pending queue."
  (when emacs-stdio-jsonrpc--newsticker-queue
    (let ((item (pop emacs-stdio-jsonrpc--newsticker-queue)))
      (emacs-stdio-jsonrpc--newsticker-debug
       "processing queued feed %s" (car item))
      (apply #'emacs-stdio-jsonrpc--newsticker-do-parse item)
      (when emacs-stdio-jsonrpc--newsticker-queue
        (run-with-timer 0.01 nil
          #'emacs-stdio-jsonrpc--newsticker-process-queued)))))

(defun emacs-stdio-jsonrpc--newsticker-sentinel-advice
    (orig-fun event status-ok feed-name command buffer)
  "Advice around `newsticker--sentinel-work' to use C++ feed processor."
  (condition-case err
      (if (or (not status-ok) (not feed-name)
              (not (buffer-live-p buffer)))
          (progn
            (emacs-stdio-jsonrpc--newsticker-debug
             "fallback to original: status-ok=%S feed=%S buffer=%S"
             status-ok feed-name buffer)
            (funcall orig-fun event status-ok feed-name command buffer))
        (emacs-stdio-jsonrpc--newsticker-debug
         "intercepted feed=%S command=%S buffer=%S"
         feed-name command buffer)
        (unless (emacs-stdio-jsonrpc-running-p)
          (emacs-stdio-jsonrpc-start))
        (if (not (emacs-stdio-jsonrpc-running-p))
            (progn
              (emacs-stdio-jsonrpc--newsticker-debug
               "subprocess not running, fallback to original for %s" feed-name)
              (funcall orig-fun event status-ok feed-name command buffer))
          (if emacs-stdio-jsonrpc--newsticker-busy
              (let ((xml (with-current-buffer buffer
                           (buffer-string))))
                (push (list feed-name command xml)
                      emacs-stdio-jsonrpc--newsticker-queue)
                (emacs-stdio-jsonrpc--newsticker-debug
                 "queued feed %s (busy, %d pending)"
                 feed-name (length emacs-stdio-jsonrpc--newsticker-queue)))
            (let ((emacs-stdio-jsonrpc--newsticker-busy t))
              (emacs-stdio-jsonrpc--newsticker-do-parse feed-name command buffer)
              (when emacs-stdio-jsonrpc--newsticker-queue
                (run-with-timer 0.01 nil
                  #'emacs-stdio-jsonrpc--newsticker-process-queued))))))
    (error
     (emacs-stdio-jsonrpc--newsticker-debug
      "error in advice, falling back: %S" err)
     (message "jrpc-nw: error processing %s: %S" feed-name err)
     (funcall orig-fun event status-ok feed-name command buffer))))

(defun emacs-stdio-jsonrpc--newsticker-do-parse (feed-name command &optional buffer-or-xml)
  "Parse feed through C++ feed_processor and update cache."
  (let* ((name-symbol (intern feed-name))
         (time (current-time))
         (something-was-added nil)
         (ct (current-time))
         (xml (if (and (bufferp buffer-or-xml) (buffer-live-p buffer-or-xml))
                  (with-current-buffer buffer-or-xml
                    (buffer-string))
                buffer-or-xml)))
    (catch 'oops
      (newsticker--cache-replace-age newsticker--cache name-symbol
                                     'new 'obsolete-new)
      (newsticker--cache-replace-age newsticker--cache name-symbol
                                     'old 'obsolete-old)
      (newsticker--cache-replace-age newsticker--cache name-symbol
                                     'feed 'obsolete-old)
      (condition-case err
          (let* ((result (emacs-stdio-jsonrpc-process-feed xml
                                                           :chunk-size 1000))
                 (feed-title (plist-get result :feed-title))
                 (chunks (plist-get result :chunks))
                 (feed-entry (or (assoc feed-name newsticker-url-list)
                                 (assoc feed-name newsticker-url-list-defaults)))
                 (feed-url (and feed-entry (nth 1 feed-entry)))
                 (index 0))
            (setq newsticker--cache
                  (newsticker--cache-add
                   newsticker--cache name-symbol
                   (or feed-title feed-name) ""
                   (or feed-url "") time 'feed 0 nil))
            (setq something-was-added t)
            (dolist (chunk (append chunks nil))
              (dolist (item (append (plist-get chunk :items) nil))
                (let ((title (plist-get item :title))
                      (desc (plist-get item :description))
                      (link (plist-get item :link))
                      (guid (plist-get item :guid)))
                  (setq newsticker--cache
                        (newsticker--cache-add
                         newsticker--cache name-symbol
                         (or title "[untitled]")
                         (or desc "") (or link "")
                         time 'new index
                         (when guid `((guid nil ,guid)))))
                  (setq index (1+ index)))))
            (setq something-was-added t)
            (newsticker--cache-replace-age newsticker--cache name-symbol
                                           'obsolete-old 'deleteme)
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
              (newsticker--cache-replace-age newsticker--cache name-symbol
                                             'obsolete-new 'obsolete))
            (newsticker--update-process-ids)
            (when (= 0 (length newsticker--process-ids))
              (when (fboundp 'newsticker--ticker-text-setup)
                (newsticker--ticker-text-setup)))
            (setq newsticker--latest-update-time (current-time))
            (when something-was-added
              (newsticker--cache-save-feed
               (newsticker--cache-get-feed name-symbol))
              (when (fboundp 'newsticker--buffer-set-uptodate)
                (newsticker--buffer-set-uptodate nil))))
        (error
         (setq newsticker--cache
               (newsticker--cache-add
                newsticker--cache name-symbol
                newsticker--error-headline
                (format-message
                 (concat "%s: feed_processor error for %s.\n"
                         "Return status was `%s'\n"
                         "Command was `%s'")
                 (format-time-string "%A, %H:%M")
                 feed-name (error-message-string err) command)
                "" ct 'new 0
                '((guid nil "newsticker--download-error"))
                ct))
         (message "feed_processor: Error parsing %s: %s"
                  feed-name (error-message-string err)))))))

;; ======================================================================
;; Plainview pager (implicit — feed_reader backed)
;; ======================================================================

(defvar emacs-stdio-jsonrpc--newsticker-pager-conn nil
  "JSON-RPC connection to feed_reader subprocess.
Non-nil means the pager is active.")

(defvar emacs-stdio-jsonrpc--newsticker-pager-page-size 20
  "Number of items per page.")

(defvar emacs-stdio-jsonrpc--newsticker-pager-feed-name nil
  "String name of the current feed.")

(defvar emacs-stdio-jsonrpc--newsticker-pager-offset 0
  "Item offset of the current page.")

(defvar emacs-stdio-jsonrpc--newsticker-pager-total 0
  "Total items in the current feed.")

(defvar emacs-stdio-jsonrpc--newsticker-pager-page-content nil
  "Items in the current page (Elisp item list format).")

;; Saved original functions for restoring on mode disable
(defvar emacs-stdio-jsonrpc--newsticker-pager-saved-insert-all nil)
(defvar emacs-stdio-jsonrpc--newsticker-pager-saved-next-item nil)
(defvar emacs-stdio-jsonrpc--newsticker-pager-saved-prev-item nil)
(defvar emacs-stdio-jsonrpc--newsticker-pager-saved-next-feed nil)
(defvar emacs-stdio-jsonrpc--newsticker-pager-saved-prev-feed nil)

;; --------------------------------------------------------------------
;; feed_reader lifecycle
;; --------------------------------------------------------------------

(defun emacs-stdio-jsonrpc--newsticker-pager-start ()
  "Start feed_reader subprocess.  Return t on success."
  (let* ((dir (file-name-directory (or load-file-name default-directory)))
          (bin (expand-file-name "build/feed_reader" dir))
          (db (if (and (boundp 'newsticker-dir) newsticker-dir)
                 (expand-file-name "cache.db" newsticker-dir)
               (expand-file-name "cache.db"
                                 (locate-user-emacs-file "newsticker")))))
    (condition-case err
        (progn
          (unless (file-exists-p bin)
            (error "feed_reader binary not found at %s" bin))
          ;; DB may not exist yet — feed_reader's sqlite3_open will create it.
          (let ((conn (emacs-stdio-jsonrpc-start-app
                       "feed_reader" bin (list db)))
                (proc nil))
            (setq proc (ignore-errors (jsonrpc--process conn)))
            (unless (and proc (process-live-p proc))
              (emacs-stdio-jsonrpc-stop-app "feed_reader")
              (error "feed_reader process died immediately"))
            (setq emacs-stdio-jsonrpc--newsticker-pager-conn conn)
            (emacs-stdio-jsonrpc--newsticker-debug
             "feed_reader started: %s DB=%s" (file-name-nondirectory bin) db)
            t))
      (error
       (emacs-stdio-jsonrpc--newsticker-debug
        "feed_reader start failed: %S" err)
       nil))))

(defun emacs-stdio-jsonrpc--newsticker-pager-stop ()
  "Stop feed_reader subprocess."
  (when emacs-stdio-jsonrpc--newsticker-pager-conn
    (emacs-stdio-jsonrpc-stop-app "feed_reader")
    (setq emacs-stdio-jsonrpc--newsticker-pager-conn nil
          emacs-stdio-jsonrpc--newsticker-pager-feed-name nil
          emacs-stdio-jsonrpc--newsticker-pager-offset 0
          emacs-stdio-jsonrpc--newsticker-pager-total 0
          emacs-stdio-jsonrpc--newsticker-pager-page-content nil)))

;; --------------------------------------------------------------------
;; Core pager functions
;; --------------------------------------------------------------------

(defun emacs-stdio-jsonrpc--newsticker-pager-json-to-item (json)
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

(defun emacs-stdio-jsonrpc--newsticker-pager-fetch-page (feed-name offset limit)
  "Return (ITEMS . TOTAL) for FEED-NAME at OFFSET with LIMIT."
  (let* ((result (jsonrpc-request
                  emacs-stdio-jsonrpc--newsticker-pager-conn
                  "get_page"
                  (list :feed feed-name :offset offset :limit limit)
                  :timeout 10))
         (items (mapcar
                 #'emacs-stdio-jsonrpc--newsticker-pager-json-to-item
                 (plist-get result :items)))
         (total (plist-get result :total)))
    (cons items total)))

(defun emacs-stdio-jsonrpc--newsticker-pager-feed-descriptor (feed-sym)
  "Return feed-descriptor item for FEED-SYM from in-memory cache."
  (let ((feed (assoc feed-sym newsticker--cache)))
    (when feed
      (catch 'found
        (dolist (item (cdr feed))
          (when (eq (newsticker--age item) 'feed)
            (throw 'found item)))))))

(defun emacs-stdio-jsonrpc--newsticker-pager-build-buffer ()
  "Clear *newsticker* and insert current page."
  (let ((buf (get-buffer "*newsticker*")))
    (unless buf (user-error "No *newsticker* buffer"))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (sym (intern emacs-stdio-jsonrpc--newsticker-pager-feed-name)))
        (erase-buffer)
        (set-buffer-modified-p nil)
        (let ((fd (emacs-stdio-jsonrpc--newsticker-pager-feed-descriptor sym)))
          (when fd
            (newsticker--buffer-insert-item fd sym)))
        (dolist (item emacs-stdio-jsonrpc--newsticker-pager-page-content)
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

(defun emacs-stdio-jsonrpc--newsticker-pager-goto (feed-name offset)
  "Switch to FEED-NAME at OFFSET."
  (setq emacs-stdio-jsonrpc--newsticker-pager-feed-name feed-name
        emacs-stdio-jsonrpc--newsticker-pager-offset offset)
  (let* ((result (emacs-stdio-jsonrpc--newsticker-pager-fetch-page
                  feed-name offset
                  emacs-stdio-jsonrpc--newsticker-pager-page-size))
         (items (car result))
         (total (cdr result)))
    (setq emacs-stdio-jsonrpc--newsticker-pager-total total
          emacs-stdio-jsonrpc--newsticker-pager-page-content items)
    (emacs-stdio-jsonrpc--newsticker-pager-build-buffer)))

(defun emacs-stdio-jsonrpc--newsticker-pager-next-page ()
  "Load next page of current feed.  Wrap to next feed at end."
  (let ((new (+ emacs-stdio-jsonrpc--newsticker-pager-offset
                emacs-stdio-jsonrpc--newsticker-pager-page-size)))
    (if (>= new emacs-stdio-jsonrpc--newsticker-pager-total)
        (condition-case nil
            (emacs-stdio-jsonrpc--newsticker-pager-next-feed)
          (error nil))
      (emacs-stdio-jsonrpc--newsticker-pager-goto
       emacs-stdio-jsonrpc--newsticker-pager-feed-name new))))

(defun emacs-stdio-jsonrpc--newsticker-pager-prev-page ()
  "Load previous page of current feed.  Wrap to prev feed at start."
  (let ((new (- emacs-stdio-jsonrpc--newsticker-pager-offset
                emacs-stdio-jsonrpc--newsticker-pager-page-size)))
    (if (< new 0)
        (condition-case nil
            (emacs-stdio-jsonrpc--newsticker-pager-prev-feed)
          (error nil))
      (emacs-stdio-jsonrpc--newsticker-pager-goto
       emacs-stdio-jsonrpc--newsticker-pager-feed-name new))))

(defun emacs-stdio-jsonrpc--newsticker-pager-next-feed ()
  "Load next feed's first page.  Cyclic through URL list."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (cur (assoc-string
               emacs-stdio-jsonrpc--newsticker-pager-feed-name feeds))
         (next (cadr (member cur feeds))))
    (unless next
      (setq next (car feeds)))            ; wrap to first
    (when next
      (emacs-stdio-jsonrpc--newsticker-pager-goto (car next) 0)
      (point))))

(defun emacs-stdio-jsonrpc--newsticker-pager-prev-feed ()
  "Load previous feed's first page.  Cyclic through URL list."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (cur (assoc-string
               emacs-stdio-jsonrpc--newsticker-pager-feed-name feeds))
         (prev (cadr (member cur (reverse feeds)))))
    (unless prev
      (setq prev (car (last feeds))))       ; wrap to last
    (when prev
      (emacs-stdio-jsonrpc--newsticker-pager-goto (car prev) 0)
      (point))))

;; --------------------------------------------------------------------
;; Pager advice
;; --------------------------------------------------------------------

(defun emacs-stdio-jsonrpc--newsticker-pager-advice-insert-all ()
  "Override `newsticker--buffer-insert-all-items'.
Insert first feed's first page."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (first (car feeds)))
    (if (null first)
        (user-error "No feeds configured")
      (emacs-stdio-jsonrpc--newsticker-pager-goto (car first) 0))))

(defun emacs-stdio-jsonrpc--newsticker-pager-advice-next-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-next-item'.
When at last item, load next page from feed_reader."
  (if (not emacs-stdio-jsonrpc--newsticker-pager-conn)
      (funcall orig-fn do-not-wrap)
    (if (save-excursion (newsticker--buffer-goto '(item)))
        (funcall orig-fn do-not-wrap)
      (emacs-stdio-jsonrpc--newsticker-pager-next-page))))

(defun emacs-stdio-jsonrpc--newsticker-pager-advice-prev-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-previous-item'.
When at first item, load previous page from feed_reader."
  (if (not emacs-stdio-jsonrpc--newsticker-pager-conn)
      (funcall orig-fn do-not-wrap)
    (if (save-excursion (newsticker--buffer-goto '(item) nil t))
        (funcall orig-fn do-not-wrap)
      (emacs-stdio-jsonrpc--newsticker-pager-prev-page))))

(defun emacs-stdio-jsonrpc--newsticker-pager-advice-next-feed (orig-fn)
  "Around advice for `newsticker-next-feed'.
Load next feed's first page from feed_reader."
  (if (not emacs-stdio-jsonrpc--newsticker-pager-conn)
      (funcall orig-fn)
    (emacs-stdio-jsonrpc--newsticker-pager-next-feed)))

(defun emacs-stdio-jsonrpc--newsticker-pager-advice-prev-feed (orig-fn)
  "Around advice for `newsticker-previous-feed'.
Load previous feed's first page from feed_reader."
  (if (not emacs-stdio-jsonrpc--newsticker-pager-conn)
      (funcall orig-fn)
    (emacs-stdio-jsonrpc--newsticker-pager-prev-feed)))

;; ======================================================================
;; SQLite cache backend (prin1 替代)
;; ======================================================================

(defvar emacs-stdio-jsonrpc--newsticker-sqlite-db nil
  "SQLite database handle for Newsticker cache.")

(defun emacs-stdio-jsonrpc--newsticker-sqlite-db-path ()
  (expand-file-name "cache.db" newsticker-dir))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-ensure-dir ()
  (unless (file-directory-p newsticker-dir)
    (make-directory newsticker-dir t)))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-init ()
  (emacs-stdio-jsonrpc--newsticker-sqlite-ensure-dir)
  (let ((path (emacs-stdio-jsonrpc--newsticker-sqlite-db-path)))
    (setq emacs-stdio-jsonrpc--newsticker-sqlite-db
          (sqlite-open path nil nil))
    (sqlite-execute emacs-stdio-jsonrpc--newsticker-sqlite-db
      "CREATE TABLE IF NOT EXISTS items (
         feed_name TEXT NOT NULL, title TEXT, description TEXT, link TEXT,
         time_high INTEGER, time_low INTEGER, time_micro INTEGER, time_pico INTEGER,
         age TEXT NOT NULL DEFAULT 'new', item_pos INTEGER,
         preformatted_contents TEXT, preformatted_title TEXT,
         extra_elements TEXT, guid TEXT)")
    (sqlite-execute emacs-stdio-jsonrpc--newsticker-sqlite-db
      "CREATE INDEX IF NOT EXISTS idx_items_feed ON items(feed_name)")
    (sqlite-execute emacs-stdio-jsonrpc--newsticker-sqlite-db
      "CREATE INDEX IF NOT EXISTS idx_items_guid ON items(guid)")
    (sqlite-execute emacs-stdio-jsonrpc--newsticker-sqlite-db
      "CREATE INDEX IF NOT EXISTS idx_items_age ON items(age)")
    (sqlite-execute emacs-stdio-jsonrpc--newsticker-sqlite-db
      "PRAGMA journal_mode=WAL")
    (sqlite-execute emacs-stdio-jsonrpc--newsticker-sqlite-db
      "PRAGMA synchronous=NORMAL")))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-close ()
  (when emacs-stdio-jsonrpc--newsticker-sqlite-db
    (sqlite-close emacs-stdio-jsonrpc--newsticker-sqlite-db)
    (setq emacs-stdio-jsonrpc--newsticker-sqlite-db nil)))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-item-to-row (feed-name item)
  (let ((tv (newsticker--time item)))
    (list feed-name
          (newsticker--title item) (newsticker--desc item)
          (newsticker--link item)
          (nth 0 tv) (nth 1 tv) (nth 2 tv) (nth 3 tv)
          (symbol-name (newsticker--age item))
          (newsticker--pos item)
          (newsticker--preformatted-contents item)
          (newsticker--preformatted-title item)
          (and (newsticker--extra item)
               (prin1-to-string (newsticker--extra item)))
          (newsticker--guid item))))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-row-to-item (row)
  (list (nth 1 row) (nth 2 row) (nth 3 row)
        (list (nth 4 row) (nth 5 row) (nth 6 row) (nth 7 row))
        (intern (nth 8 row))
        (nth 9 row) (nth 10 row) (nth 11 row)
        (let ((extra (nth 12 row)))
          (if extra (read extra) nil))))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-insert-item (db feed-name item)
  (sqlite-execute db
    (concat "INSERT INTO items "
            "(feed_name,title,description,link,"
            "time_high,time_low,time_micro,time_pico,"
            "age,item_pos,"
            "preformatted_contents,preformatted_title,"
            "extra_elements,guid) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    (emacs-stdio-jsonrpc--newsticker-sqlite-item-to-row feed-name item)))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-migrate ()
  (let ((cache-dir (expand-file-name "feeds/" newsticker-dir))
        (migrated (expand-file-name ".sqlite-migrated" newsticker-dir)))
    (unless (or (file-exists-p migrated) (not (file-directory-p cache-dir)))
      (emacs-stdio-jsonrpc--newsticker-sqlite-init)
      (let ((db emacs-stdio-jsonrpc--newsticker-sqlite-db))
        (with-sqlite-transaction db
          (dolist (feed-dir (directory-files cache-dir nil "^[^.]"))
            (let ((df (expand-file-name "data"
                                        (expand-file-name feed-dir cache-dir))))
              (when (file-exists-p df)
                (with-temp-buffer
                  (insert-file-contents df)
                  (goto-char (point-min))
                  (forward-line 1)
                  (condition-case err
                      (dolist (item (read (current-buffer)))
                        (emacs-stdio-jsonrpc--newsticker-sqlite-insert-item
                         db feed-dir item))
                    (error (message "newsticker-sqlite: migrate error %s: %s"
                                    feed-dir (error-message-string err)))))))))
        (with-temp-file migrated
          (insert (format-time-string ";; Migrated %Y-%m-%d %H:%M:%S\n")))
        (emacs-stdio-jsonrpc--newsticker-sqlite-close)))))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-save ()
  (unless emacs-stdio-jsonrpc--newsticker-sqlite-db
    (emacs-stdio-jsonrpc--newsticker-sqlite-init))
  (let ((db emacs-stdio-jsonrpc--newsticker-sqlite-db))
    (with-sqlite-transaction db
      (sqlite-execute db "DELETE FROM items")
      (dolist (feed newsticker--cache)
        (let ((feed-name (symbol-name (car feed))))
          (dolist (item (cdr feed))
            (emacs-stdio-jsonrpc--newsticker-sqlite-insert-item
             db feed-name item)))))))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-save-feed (feed)
  (unless emacs-stdio-jsonrpc--newsticker-sqlite-db
    (emacs-stdio-jsonrpc--newsticker-sqlite-init))
  (let ((db emacs-stdio-jsonrpc--newsticker-sqlite-db)
        (feed-name (symbol-name (car feed))))
    (with-sqlite-transaction db
      (sqlite-execute db "DELETE FROM items WHERE feed_name = ?"
                      (list feed-name))
      (dolist (item (cdr feed))
        (emacs-stdio-jsonrpc--newsticker-sqlite-insert-item
         db feed-name item)))))

(defun emacs-stdio-jsonrpc--newsticker-sqlite-read ()
  (unless emacs-stdio-jsonrpc--newsticker-sqlite-db
    (emacs-stdio-jsonrpc--newsticker-sqlite-init))
  (setq newsticker--cache nil)
  (let ((db emacs-stdio-jsonrpc--newsticker-sqlite-db)
        (cur-feed nil) (cur-items nil))
    (dolist (row (sqlite-select db
                   (concat "SELECT feed_name,title,description,link,"
                           "time_high,time_low,time_micro,time_pico,"
                           "age,item_pos,"
                           "preformatted_contents,preformatted_title,"
                           "extra_elements,guid "
                           "FROM items ORDER BY feed_name,item_pos")))
      (let ((feed-name (intern (nth 0 row))))
        (if (eq feed-name cur-feed)
            (push (emacs-stdio-jsonrpc--newsticker-sqlite-row-to-item row)
                  cur-items)
          (when cur-feed
            (push (cons cur-feed (nreverse cur-items)) newsticker--cache))
          (setq cur-feed feed-name
                cur-items (list (emacs-stdio-jsonrpc--newsticker-sqlite-row-to-item row))))))
    (when cur-feed
      (push (cons cur-feed (nreverse cur-items)) newsticker--cache))))

;; ======================================================================
;; Minor mode — one activation, all advice installed
;; ======================================================================

(defvar emacs-stdio-jsonrpc--newsticker-mode-active nil
  "Internal: non-nil when mode advice is installed.  Prevents double-setup.")

;;;###autoload
(define-minor-mode emacs-stdio-jsonrpc-newsticker-mode
  "Toggle C++ backend for Newsticker feed processing, SQLite persistence,
and plainview paging.

When enabled, this single mode replaces THREE old Newsticker behaviors
at once:

  • **Feed parsing** — RSS/Atom XML parsed by C++ feed_processor
    (instead of Emacs libxml2).
  • **Cache persistence** — `prin1` per-feed files replaced by a single
    SQLite database at `newsticker-dir/cache.db'.
  • **Plainview paging** — buffer shows one page (~20 items) at a time;
    `n` at the last item loads the next page from C++ feed_reader.

All standard Newsticker keys work unchanged.  Just enable this mode
and use Newsticker normally:

  M-x emacs-stdio-jsonrpc-newsticker-mode
  M-x newsticker-get-all-news
  M-x newsticker-plainview"
  :global t
  :group 'emacs-stdio-jsonrpc-newsticker
  (if emacs-stdio-jsonrpc-newsticker-mode
      (unless emacs-stdio-jsonrpc--newsticker-mode-active
        (setq emacs-stdio-jsonrpc--newsticker-mode-active t)
        (require 'newsticker nil t)

        ;; 1. SQLite persistence advice
        (emacs-stdio-jsonrpc--newsticker-sqlite-migrate)
        (advice-add 'newsticker--cache-save :override
                    #'emacs-stdio-jsonrpc--newsticker-sqlite-save)
        (advice-add 'newsticker--cache-read :override
                    #'emacs-stdio-jsonrpc--newsticker-sqlite-read)
        (advice-add 'newsticker--cache-save-feed :override
                    #'emacs-stdio-jsonrpc--newsticker-sqlite-save-feed)
        (emacs-stdio-jsonrpc--newsticker-debug "SQLite cache advice installed")

        ;; 2. Feed processing advice
        (advice-add 'newsticker--sentinel-work :around
                    #'emacs-stdio-jsonrpc--newsticker-sentinel-advice)
        (emacs-stdio-jsonrpc--newsticker-debug "sentinel advice installed")

        ;; 3. Start feed_processor
        (condition-case err
            (unless (emacs-stdio-jsonrpc-running-p)
              (let ((exe (emacs-stdio-jsonrpc--find-executable)))
                (unless exe
                  (error "feed_processor not found: set `emacs-stdio-jsonrpc-executable'"))
                (emacs-stdio-jsonrpc-start exe)
                (emacs-stdio-jsonrpc--newsticker-debug
                 "feed_processor started: %s" (file-name-nondirectory exe))))
          (error
           (message "jrpc-nw: feed_processor start failed: %s"
                    (error-message-string err))))

        ;; 4. Pager advice (feed_reader)
        (when (emacs-stdio-jsonrpc--newsticker-pager-start)
          (setq emacs-stdio-jsonrpc--newsticker-pager-saved-insert-all
                (symbol-function 'newsticker--buffer-insert-all-items))
          (advice-add 'newsticker--buffer-insert-all-items :override
                      #'emacs-stdio-jsonrpc--newsticker-pager-advice-insert-all)
          (setq emacs-stdio-jsonrpc--newsticker-pager-saved-next-item
                (symbol-function 'newsticker-next-item))
          (advice-add 'newsticker-next-item :around
                      #'emacs-stdio-jsonrpc--newsticker-pager-advice-next-item)
          (setq emacs-stdio-jsonrpc--newsticker-pager-saved-prev-item
                (symbol-function 'newsticker-previous-item))
          (advice-add 'newsticker-previous-item :around
                      #'emacs-stdio-jsonrpc--newsticker-pager-advice-prev-item)
          (setq emacs-stdio-jsonrpc--newsticker-pager-saved-next-feed
                (symbol-function 'newsticker-next-feed))
          (advice-add 'newsticker-next-feed :around
                      #'emacs-stdio-jsonrpc--newsticker-pager-advice-next-feed)
          (setq emacs-stdio-jsonrpc--newsticker-pager-saved-prev-feed
                (symbol-function 'newsticker-previous-feed))
          (advice-add 'newsticker-previous-feed :around
                      #'emacs-stdio-jsonrpc--newsticker-pager-advice-prev-feed)
          (emacs-stdio-jsonrpc--newsticker-debug "pager advice installed"))
        (unless emacs-stdio-jsonrpc--newsticker-pager-conn
          (emacs-stdio-jsonrpc--newsticker-debug "feed_reader unavailable — pager disabled")))

    (when emacs-stdio-jsonrpc--newsticker-mode-active
      (setq emacs-stdio-jsonrpc--newsticker-mode-active nil)

      (advice-remove 'newsticker--cache-save
                     #'emacs-stdio-jsonrpc--newsticker-sqlite-save)
      (advice-remove 'newsticker--cache-read
                     #'emacs-stdio-jsonrpc--newsticker-sqlite-read)
      (advice-remove 'newsticker--cache-save-feed
                     #'emacs-stdio-jsonrpc--newsticker-sqlite-save-feed)
      (emacs-stdio-jsonrpc--newsticker-sqlite-close)
      (emacs-stdio-jsonrpc--newsticker-debug "SQLite cache advice removed")

      (advice-remove 'newsticker--sentinel-work
                     #'emacs-stdio-jsonrpc--newsticker-sentinel-advice)
      (emacs-stdio-jsonrpc--newsticker-debug "sentinel advice removed")

      (when emacs-stdio-jsonrpc--newsticker-pager-conn
        (advice-remove 'newsticker--buffer-insert-all-items
                       #'emacs-stdio-jsonrpc--newsticker-pager-advice-insert-all)
        (advice-remove 'newsticker-next-item
                       #'emacs-stdio-jsonrpc--newsticker-pager-advice-next-item)
        (advice-remove 'newsticker-previous-item
                       #'emacs-stdio-jsonrpc--newsticker-pager-advice-prev-item)
        (advice-remove 'newsticker-next-feed
                       #'emacs-stdio-jsonrpc--newsticker-pager-advice-next-feed)
        (advice-remove 'newsticker-previous-feed
                       #'emacs-stdio-jsonrpc--newsticker-pager-advice-prev-feed)
        (when emacs-stdio-jsonrpc--newsticker-pager-saved-insert-all
          (fset 'newsticker--buffer-insert-all-items
                emacs-stdio-jsonrpc--newsticker-pager-saved-insert-all))
        (setq emacs-stdio-jsonrpc--newsticker-pager-saved-insert-all nil
              emacs-stdio-jsonrpc--newsticker-pager-saved-next-item nil
              emacs-stdio-jsonrpc--newsticker-pager-saved-prev-item nil
              emacs-stdio-jsonrpc--newsticker-pager-saved-next-feed nil
              emacs-stdio-jsonrpc--newsticker-pager-saved-prev-feed nil)
        (emacs-stdio-jsonrpc--newsticker-pager-stop)
        (emacs-stdio-jsonrpc--newsticker-debug "pager advice removed")))))

(provide 'emacs-stdio-jsonrpc-newsticker)
;;; emacs-stdio-jsonrpc-newsticker.el ends here
