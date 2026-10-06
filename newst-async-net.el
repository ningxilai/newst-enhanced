;;; newst-async-net.el --- Async feed download queue for Newsticker  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Concurrent feed download queue for Newsticker using url-retrieve.
;; The queue is intentionally adaptive by default: it measures latency and
;; failure rate, and adjusts concurrency/timeout on the fly while keeping a
;; hard safety cap and per-host protection.

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

(defgroup newst-async-net nil
  "Async feed download queue for Newsticker."
  :group 'newsticker)

(defcustom newst-async-net-auto-scale-enabled t
  "When non-nil, auto-scale concurrency and timeout by runtime metrics.
This is the default high-performance mode, while preserving compatibility by
keeping the lower and upper safety bounds conservative."
  :type 'boolean :group 'newst-async-net)

(defcustom newst-async-net-max-concurrent 3
  "Legacy/static default used as a compatibility floor when the user has not
configured a value explicitly. In dynamic mode this acts as a lower/upper bound
only when it has been customized by the user."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-min-concurrent 2
  "Minimum concurrency when auto-scale is enabled."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-hardcap-global 128
  "Absolute global upper bound for active downloads; this is a safety cap."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-per-host-hardcap 8
  "Absolute limit for active requests to the same host."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-timeout 15
  "Legacy/default timeout in seconds used when the controller is not active."
  :type 'integer :group 'newst-async-net)

(defcustom newst-async-net-timeout-hardcap 60
  "Upper bound for adaptive timeout."
  :type 'integer :group 'newst-async-net)

(defvar newst-async-net-debug nil
  "When non-nil, print diagnostic messages for download queue.")

(defun newst-async-net-debug (fmt &rest args)
  (when newst-async-net-debug
    (apply #'message (concat "[async-net] " fmt) args)))

(defvar newst-async-net--active 0
  "Number of currently active feed downloads.")

(defvar newst-async-net--queue nil
  "Queue of (FEED-NAME URL) pending download.")

(defvar newst-async-net--metrics (make-hash-table :test 'equal)
  "Recent latency/error metrics for autoscaling.")

(defvar newst-async-net--host-active (make-hash-table :test 'equal)
  "Per-host active download counts used to protect remote sites.")

(defun newst-async-net--host-from-url (url)
  "Return a host string for URL, or nil if it cannot be parsed."
  (condition-case nil
      (let* ((parsed (url-generic-parse-url url))
             (host (url-host parsed)))
        (if (stringp host) host nil))
    (error nil)))

(defun newst-async-net--host-bump (host)
  "Register one active request for HOST."
  (unless (null host)
    (puthash host (1+ (gethash host newst-async-net--host-active 0))
             newst-async-net--host-active)))

(defun newst-async-net--host-release (host)
  "Release one active request for HOST."
  (unless (null host)
    (let ((count (gethash host newst-async-net--host-active 0)))
      (if (<= count 1)
          (remhash host newst-async-net--host-active)
        (puthash host (1- count) newst-async-net--host-active)))))

(defun newst-async-net--host-allowed-p (host)
  "Return non-nil if HOST is under its hard safety cap."
  (or (null host)
      (< (gethash host newst-async-net--host-active 0)
         newst-async-net-per-host-hardcap)))

(defun newst-async-net--record-metric (latency-ms ok)
  "Record one request latency metric. LATENCY-MS is a number, OK is non-nil on success."
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
  "Return the median latency from recent requests, or 0 if empty."
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

(defun newst-async-net--user-max-override-p ()
  "Return non-nil if the user has explicitly customized the legacy max concurrency."
  (not (equal newst-async-net-max-concurrent 3)))

(defun newst-async-net--suggest-concurrency (feed-count)
  "Suggest a concurrency value based on FEED-COUNT and current metrics."
  (let* ((base (max newst-async-net-min-concurrent
                    (ceiling (/ (float feed-count) 20.0))))
         (median-ms (newst-async-net--recent-median-latency-ms)))
    (if (not newst-async-net-auto-scale-enabled)
        (min newst-async-net-max-concurrent newst-async-net-hardcap-global)
      (let* ((adjusted (cond
                        ((and (> median-ms 0)
                              (< median-ms 1500))
                         (min newst-async-net-hardcap-global (1+ base)))
                        ((and (> median-ms 0)
                              (> median-ms 3000))
                         (max newst-async-net-min-concurrent (floor (* base 0.6))))
                        (t base)))
             (cap (if (newst-async-net--user-max-override-p)
                      (min newst-async-net-max-concurrent
                           newst-async-net-hardcap-global)
                    newst-async-net-hardcap-global)))
        (min adjusted cap)))))

(defun newst-async-net--suggest-timeout ()
  "Return a timeout recommendation in seconds."
  (if (not newst-async-net-auto-scale-enabled)
      newst-async-net-timeout
    (let* ((median-ms (newst-async-net--recent-median-latency-ms))
           (raw (cond
                 ((= median-ms 0) 15)
                 ((< median-ms 1000) 8)
                 ((< median-ms 2000) 12)
                 ((< median-ms 4000) 16)
                 (t 20))))
      (min raw newst-async-net-timeout-hardcap))))

(defun newst-async-net--mime-strip ()
  "Remove MIME headers from current buffer."
  (goto-char (point-min))
  (when (search-forward "\n\n" nil t)
    (delete-region (point-min) (point))))

(defun newst-async-net--dom-text (node)
  "Return the textual content of NODE."
  (if (fboundp 'dom-inner-text)
      (dom-inner-text node)
    (with-no-warnings (dom-text node))))

(defun newst-async-net--extract-items (dom)
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
         (extra (when guid `((guid nil ,guid)))))
    (list title (or desc "") link time 'new pos nil nil extra)))

(defun newst-async-net--dequeue ()
  "Start the next queued download if under global and per-host limits."
  (let* ((feed-count (length (append newsticker-url-list newsticker-url-list-defaults)))
         (limit (newst-async-net--suggest-concurrency feed-count)))
    (when (and newst-async-net--queue
               (< newst-async-net--active limit))
      (let ((item (pop newst-async-net--queue)))
        (let* ((url (cadr item))
               (host (newst-async-net--host-from-url url)))
          (when (newst-async-net--host-allowed-p host)
            (newst-async-net--fetch-url (car item) url)))))))

(defun newst-async-net--process-result (feed-name items)
  "Add parsed ITEMS to the in-memory cache and persist to SQLite."
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
        (newsticker--cache-remove newsticker--cache name-symbol 'obsolete-new)
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
    (newsticker--cache-save-feed (newsticker--cache-get-feed name-symbol))
    (when (fboundp 'newsticker--buffer-set-uptodate)
      (newsticker--buffer-set-uptodate nil))))

(defun newst-async-net--fetch-url (feed-name url)
  "Download URL asynchronously and parse XML."
  (let* ((host (newst-async-net--host-from-url url))
         (timeout-seconds (if newst-async-net-auto-scale-enabled
                              (newst-async-net--suggest-timeout)
                            newst-async-net-timeout)))
    (when (and (not (newst-async-net--host-allowed-p host))
               (not (null host)))
      (push (list feed-name url) newst-async-net--queue)
      (newst-async-net-debug "host throttled %s" host)
      (cl-return))
    (newst-async-net--host-bump host)
    (cl-incf newst-async-net--active)
    (let ((timeout-timer nil)
          (callback-called nil)
          (url-buffer nil)
          (start-time (current-time)))
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
                                      (* 1000 timeout-seconds) nil))
                                 (newst-async-net--mime-strip)
                                 (condition-case parse-err
                                     (let* ((dom (libxml-parse-xml-region
                                                  (point-min) (point-max)))
                                            (result (and dom
                                                         (newst-async-net--extract-items dom))))
                                       (when result
                                         (newst-async-net--process-result
                                          feed-name (cons feed-name (cadr result)))
                                         (newst-async-net--record-metric
                                          (round (* 1000.0 (float-time
                                                            (time-subtract (current-time) start-time))))
                                          t)))
                                   (error
                                    (newst-async-net-debug
                                     "parse error %s: %S" url parse-err)
                                    (newst-async-net--record-metric
                                     (* 1000 timeout-seconds) nil))))))))
                       (condition-case nil
                           (kill-buffer buf)
                         (error nil)))
                     (newst-async-net--host-release host)
                     (setq newst-async-net--active (1- newst-async-net--active))
                     (newst-async-net--dequeue))))
               nil t))))
      (setq timeout-timer
            (run-at-time timeout-seconds nil
                         (lambda ()
                           (unless callback-called
                             (setq callback-called t)
                             (newst-async-net-debug "timeout %s" url)
                             (newst-async-net--record-metric (* 1000 timeout-seconds) nil)
                             (when (and url-buffer (buffer-live-p url-buffer))
                               (let ((proc (get-buffer-process url-buffer)))
                                 (when (and proc (process-live-p proc))
                                   (delete-process proc)))
                               (condition-case nil
                                   (kill-buffer url-buffer)
                                 (error nil)))
                             (newst-async-net--host-release host)
                             (setq newst-async-net--active (1- newst-async-net--active))
                             (newst-async-net--dequeue)))))))

(defun newst-async-net-advice-get-news-by-url (_orig-fn feed-name url)
  ":around advice for `newsticker--get-news-by-url'."
  (let* ((host (newst-async-net--host-from-url url))
         (feed-count (length (append newsticker-url-list newsticker-url-list-defaults)))
         (limit (newst-async-net--suggest-concurrency feed-count)))
    (if (and (< newst-async-net--active limit)
             (newst-async-net--host-allowed-p host))
        (newst-async-net--fetch-url feed-name url)
      (push (list feed-name url) newst-async-net--queue)
      (newst-async-net-debug "queued %s (active=%d queue=%d host=%s)"
                            feed-name newst-async-net--active
                            (length newst-async-net--queue)
                            host))))

(advice-add 'newsticker--get-news-by-url :around
            #'newst-async-net-advice-get-news-by-url)

(provide 'newst-async-net)
;;; newst-async-net.el ends here

