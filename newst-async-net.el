;;; newst-async-net.el --- Async feed download queue for Newsticker  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;; Based on async-http-queue.el by Andros Fenollosa <hi@andros.dev>
;; (https://git.andros.dev/andros/async-http-queue-el).  The queue management, timeout handling, and
;; concurrent download pattern are derived from his original work.

;;; Commentary:

;; Concurrent feed download queue for Newsticker using url-retrieve
;; with timeout timers.  No external dependencies beyond Emacs 29.1.
;;
;; Simply (require 'newst-async-net) — advice is installed automatically.
;; Or require newst-jsonrpc which pulls this in.

;;; Code:

(require 'newst-sql)

(eval-when-compile
  (require 'newsticker nil t))

(declare-function newsticker--cache-add "newst-backend.el")
(declare-function newsticker--cache-replace-age "newst-backend.el")
(declare-function newsticker--cache-remove "newst-backend.el")
(declare-function newsticker--cache-mark-expired "newst-backend.el")
(declare-function newsticker--cache-get-feed "newst-backend.el")
(declare-function newsticker--cache-save-feed "newst-backend.el")
(declare-function newsticker--update-process-ids "newst-backend.el")
(declare-function newsticker--buffer-set-uptodate "newst-plainview.el")
(declare-function dom-by-tag "dom.el")
(declare-function dom-tag "dom.el")
(declare-function dom-text "dom.el")
(declare-function dom-inner-text "dom.el")
(declare-function dom-attr "dom.el")

;; ----------------------------------------------------------------------
;; User options
;; ----------------------------------------------------------------------

(defgroup newst-async-net nil
  "Async feed download queue for Newsticker."
  :group 'newsticker)

(defcustom newst-async-net-max-concurrent 3
  "Maximum concurrent feed downloads.
This is the legacy/static default used when autoscale is disabled."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-auto-scale-enabled nil
  "When non-nil, dynamically adjust concurrency and timeout from
runtime metrics and feed count.  This keeps legacy/static behavior when nil."
  :type 'boolean :group 'newst-async-net)

(defcustom newst-async-net-min-concurrent 4
  "Minimum concurrency when autoscale is enabled."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-max-concurrent-hardcap 64
  "Absolute max concurrency when autoscale is enabled."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-latency-target 1500
  "Target median latency in milliseconds used by autoscale heuristics."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-timeout 15
  "Timeout in seconds for each feed download.
Used as the static/default timeout when autoscale is disabled."
  :type 'integer :group 'newst-async-net)

(defvar newst-async-net-debug nil
  "When non-nil, print diagnostic messages for download queue.")

(defun newst-async-net-debug (fmt &rest args)
  (when newst-async-net-debug
    (apply #'message (concat "[async-net] " fmt) args)))

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

(defvar newst-async-net--active 0
  "Number of currently active feed downloads.")

(defvar newst-async-net--queue nil
  "Queue of (FEED-NAME URL) pending download.")

(defvar newst-async-net--metrics (make-hash-table :test 'equal)
  "Recent latency/error metrics for autoscaling.")

;; ----------------------------------------------------------------------
;; Metrics / autoscale helpers
;; ----------------------------------------------------------------------

(defun newst-async-net--record-metric (latency-ms ok)
  "Record one request latency metric.
LATENCY-MS is a number, OK is non-nil on success."
  (let* ((vec (gethash :latencies newst-async-net--metrics))
         (idx (gethash :lat-index newst-async-net--metrics 0)))
    (unless vec
      (puthash :latencies (make-vector 128 nil) newst-async-net--metrics)
      (puthash :lat-index 0 newst-async-net--metrics)
      (setq vec (gethash :latencies newst-async-net--metrics)))
    (aset vec idx latency-ms)
    (puthash :lat-index (mod (1+ idx) (length vec)) newst-async-net--metrics)
    (puthash :count (1+ (gethash :count newst-async-net--metrics 0))
             newst-async-net--metrics)
    (unless ok
      (puthash :errors (1+ (gethash :errors newst-async-net--metrics 0))
               newst-async-net--metrics))))

(defun newst-async-net--recent-median-latency-ms ()
  "Return the median latency from the recent metric window, or 0 if empty."
  (let* ((vec (gethash :latencies newst-async-net--metrics))
         (vals (and vec (cl-remove-if-not #'numberp (append vec nil)))))
    (if (null vals)
        0
      (let* ((sorted (sort (copy-sequence vals) #'<))
             (n (length sorted)))
        (if (oddp n)
            (nth (/ n 2) sorted)
          (/ (+ (nth (/ n 2) sorted)
                (nth (1- (/ n 2)) sorted))
             2))))))

(defun newst-async-net--suggest-concurrency (feed-count)
  "Return a concurrency recommendation based on FEED-COUNT and metrics.
Uses the legacy/static value when autoscale is disabled."
  (if (not newst-async-net-auto-scale-enabled)
      (min newst-async-net-max-concurrent newst-async-net-max-concurrent-hardcap)
    (let* ((base (max newst-async-net-min-concurrent
                      (ceiling (/ (float feed-count) 20.0))))
           (median-ms (newst-async-net--recent-median-latency-ms))
           (adj (cond
                 ((and (> median-ms 0)
                       (< median-ms newst-async-net-latency-target))
                  (min newst-async-net-max-concurrent-hardcap
                       (1+ base)))
                 ((and (> median-ms 0)
                       (> median-ms (* 2 newst-async-net-latency-target)))
                  (max newst-async-net-min-concurrent
                       (floor (* base 0.6))))
                 (t base))))
      (min adj newst-async-net-max-concurrent-hardcap))))

(defun newst-async-net--suggest-timeout ()
  "Return a timeout recommendation in seconds for the current metrics."
  (if (not newst-async-net-auto-scale-enabled)
      newst-async-net-timeout
    (let ((median-ms (newst-async-net--recent-median-latency-ms)))
      (cond
       ((= median-ms 0) newst-async-net-timeout)
       ((< median-ms 1000) 8)
       ((< median-ms 2000) 12)
       ((< median-ms 4000) 16)
       (t 20)))))

;; ----------------------------------------------------------------------
;; Feed item extractor
;; ----------------------------------------------------------------------

(defun newst-async-net--mime-strip ()
  "Remove MIME headers from current buffer."
  (goto-char (point-min))
  (when (search-forward "\n\n" nil t)
    (delete-region (point-min) (point))))

(defun newst-async-net--dom-text (node)
  "Return the textual content of NODE.
Prefer `dom-inner-text' (Emacs 31 and later), which also picks up
nested markup, and fall back to the older `dom-text' on earlier
versions of Emacs."
  (if (fboundp 'dom-inner-text)
      (dom-inner-text node)
    (with-no-warnings (dom-text node))))

(defun newst-async-net--extract-items (dom)
  "Extract feed items from DOM.
Returns (FEED-NAME FEED-TITLE (ITEM ...)) where each ITEM is
\(TITLE DESCRIPTION LINK TIME AGE POS PREFORMATTED-CONTENTS
 PREFORMATTED-TITLE EXTRA).

Time is (HIGH LOW MICRO PICO) as returned by `current-time'."
  (let* ((top (if (eq 'rss (dom-tag dom)) dom
                (or (car (dom-by-tag dom 'feed)) dom)))
         (is-atom (eq 'feed (dom-tag top)))
         (top-for-title (if (and (not is-atom)
                                   (eq 'rss (dom-tag top)))
                            (car (dom-by-tag top 'channel))
                          top))
         (feed-title (let ((t-el (dom-by-tag top-for-title 'title)))
                       (when t-el (newst-async-net--dom-text (car t-el)))))
         (raw-items (if is-atom
                        (dom-by-tag top 'entry)
                      (dom-by-tag top 'item)))
         (time (current-time))
         (pos 0))
    (list feed-title
          (mapcar (lambda (item)
                    (setq pos (1+ pos))
                    (newst-async-net--item-to-list item is-atom time pos))
                  raw-items))))

(defun newst-async-net--item-to-list (item is-atom time pos)
  (let* ((title-el (car (dom-by-tag item 'title)))
         (title (if title-el (newst-async-net--dom-text title-el) "[untitled]"))
         (desc (if is-atom
                   (or (let ((c (car (dom-by-tag item 'content))))
                         (and c (newst-async-net--dom-text c)))
                       (let ((s (car (dom-by-tag item 'summary))))
                         (and s (newst-async-net--dom-text s))))
                 (let ((d (car (dom-by-tag item 'description))))
                   (and d (newst-async-net--dom-text d)))))
         (link (if is-atom
                   (let ((l (car (dom-by-tag item 'link))))
                     (if l (or (dom-attr l 'href) (newst-async-net--dom-text l)) ""))
                 (let ((l (car (dom-by-tag item 'link))))
                   (if l (newst-async-net--dom-text l) ""))))
         (guid (if is-atom
                   (let ((i (car (dom-by-tag item 'id))))
                     (and i (newst-async-net--dom-text i)))
                 (let ((g (car (dom-by-tag item 'guid))))
                   (and g (newst-async-net--dom-text g)))))
         (extra (when guid
                  `((guid nil ,guid)))))
    (list title (or desc "") link
          time 'new pos nil nil extra)))

;; ----------------------------------------------------------------------
;; Queue lifecycle
;; ----------------------------------------------------------------------

(defun newst-async-net--dequeue ()
  "Start next queued download if under limit."
  (let* ((feed-count (length (append newsticker-url-list newsticker-url-list-defaults)))
         (limit (newst-async-net--suggest-concurrency feed-count)))
    (when (and newst-async-net--queue
               (< newst-async-net--active limit))
      (let ((item (pop newst-async-net--queue)))
        (newst-async-net--fetch-url (car item) (cadr item))))))

;; ----------------------------------------------------------------------
;; Result processing
;; ----------------------------------------------------------------------

(defun newst-async-net--process-result (feed-name items)
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

;; ----------------------------------------------------------------------
;; url-retrieve with timeout (async-http-queue pattern)
;; ----------------------------------------------------------------------

(defun newst-async-net--fetch-url (feed-name url)
  "Download URL asynchronously, parse XML, add to cache.
Adapted from async-http-queue.el pattern: url-retrieve with
timeout timer, concurrency tracking via newst-async-net--active."
  (cl-incf newst-async-net--active)
  (let ((timeout-timer nil)
        (callback-called nil)
        (url-buffer nil)
        (start-time (current-time))
        (timeout-seconds (if newst-async-net-auto-scale-enabled
                             (newst-async-net--suggest-timeout)
                           newst-async-net-timeout)))
    (setq url-buffer
          (let ((coding-system-for-read 'no-conversion))
            (url-retrieve
             url
             (lambda (status)
               (when timeout-timer
                 (cancel-timer timeout-timer))
               (unless callback-called
                 (setq callback-called t)
                 (let ((buf (current-buffer)))
                   (unwind-protect
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (let ((err-flag (plist-get status :error)))
                             (if err-flag
                                 (progn
                                   (newst-async-net-debug
                                    "download error %s: %S" url err-flag)
                                   (newst-async-net--record-metric
                                    (* 1000 newst-async-net-timeout) nil))
                               (newst-async-net--mime-strip)
                               (condition-case parse-err
                                   (let* ((dom (libxml-parse-xml-region
                                                (point-min) (point-max)))
                                          (result (and dom
                                                       (newst-async-net--extract-items
                                                        dom))))
                                     (when result
                                       (newst-async-net--process-result
                                        feed-name
                                        (cons feed-name (cadr result)))
                                       (newst-async-net--record-metric
                                        (round (* 1000.0 (float-time
                                                          (time-subtract (current-time)
                                                                         start-time))))
                                        t)))
                                 (error
                                  (newst-async-net-debug
                                   "parse error %s: %S" url parse-err)
                                  (newst-async-net--record-metric
                                   (* 1000 newst-async-net-timeout) nil))))))))
                     (condition-case nil
                         (kill-buffer buf)
                       (error nil)))
                   (setq newst-async-net--active
                         (1- newst-async-net--active))
                   (newst-async-net--dequeue))))
             nil t))))
    (ignore timeout-timer callback-called url-buffer)
    (setq timeout-timer
          (run-at-time timeout-seconds nil
                       (lambda ()
                         (unless callback-called
                           (setq callback-called t)
                           (newst-async-net-debug "timeout %s" url)
                           (newst-async-net--record-metric
                            (* 1000 timeout-seconds) nil)
                           (when (and url-buffer
                                      (buffer-live-p url-buffer))
                             (let ((proc (get-buffer-process url-buffer)))
                               (when (and proc (process-live-p proc))
                                 (delete-process proc)))
                             (condition-case nil
                                 (kill-buffer url-buffer)
                               (error nil)))
                           (setq newst-async-net--active
                                 (1- newst-async-net--active))
                           (newst-async-net--dequeue)))))))

;; ----------------------------------------------------------------------
;; Advice: intercept get-news-by-url to use queue
;; ----------------------------------------------------------------------

(defun newst-async-net-advice-get-news-by-url (_orig-fn feed-name url)
  ":around advice for `newsticker--get-news-by-url'.
Routes through concurrent download queue with url-retrieve."
  (let* ((feed-count (length (append newsticker-url-list newsticker-url-list-defaults)))
         (limit (newst-async-net--suggest-concurrency feed-count)))
    (if (< newst-async-net--active limit)
        (newst-async-net--fetch-url feed-name url)
      (push (list feed-name url) newst-async-net--queue)
      (newst-async-net-debug "queued %s (active=%d queue=%d)"
                            feed-name newst-async-net--active
                            (length newst-async-net--queue)))))

;; Install advice unconditionally.
(advice-add 'newsticker--get-news-by-url :around
            #'newst-async-net-advice-get-news-by-url)

(provide 'newst-async-net)
;;; newst-async-net.el ends here















































































































































































































































































































































































n




























































































































































a















n



















n

















n



























n















n























n