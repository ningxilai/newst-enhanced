;;; newst-jsonrpc.el --- Streaming plainview pager for Newsticker  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Streaming plainview pager for Newsticker over the in-memory cache.
;; Simply (require 'newst-jsonrpc) — navigation advice is installed
;; automatically.
;;
;; Pages are sliced directly from `newsticker--cache', so no subprocess,
;; no transport and no page cache are involved.  Items stream into the
;; buffer incrementally (append on n, prepend on p) with trimming.

;;; Code:

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

;; ----------------------------------------------------------------------
;; User options
;; ----------------------------------------------------------------------

(defgroup newst-jsonrpc nil
  "Newsticker streaming plainview pager."
  :group 'newsticker)

(defcustom newst-jsonrpc-page-size 20
  "Number of items to fetch when streaming more content."
  :type 'integer
  :group 'newst-jsonrpc)

(defcustom newst-jsonrpc-stream-max-items 200
  "Maximum items kept in the streaming buffer before trimming old ones."
  :type 'integer
  :group 'newst-jsonrpc)

(defvar newst-jsonrpc-max-desc-length 2000
  "Truncate item descriptions to this many characters.
Set to nil for no truncation.")

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

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
;; In-memory page fetch (replaces the pager subprocess)
;; ----------------------------------------------------------------------

(defun newst-jsonrpc--feed-items (feed-name)
  "Return the item list for FEED-NAME from the in-memory cache.
FEED-NAME is a string (as in `newsticker-url-list'); cache keys are
symbols, so intern before lookup."
  (cdr (assoc (if (symbolp feed-name) feed-name (intern feed-name))
              newsticker--cache)))

(defun newst-jsonrpc--truncate-item (item)
  "Return a copy of ITEM with its description truncated per config."
  (if (and newst-jsonrpc-max-desc-length (nth 1 item))
      (let ((copy (copy-sequence item)))
        (setcar (nthcdr 1 copy)
                (truncate-string-to-width
                 (nth 1 item) newst-jsonrpc-max-desc-length))
        copy)
    item))

(defun newst-jsonrpc--fetch (feed-name offset limit)
  "Return (ITEMS . TOTAL) slicing the in-memory cache.
ITEMS are truncated copies; the shared cache is never mutated."
  (let* ((items (newst-jsonrpc--feed-items feed-name))
         (total (length items))
         (page (seq-take (nthcdr offset items) limit)))
    (cons (mapcar #'newst-jsonrpc--truncate-item page) total)))

(defun newst-jsonrpc--feed-descriptor (feed-sym)
  "Return feed-descriptor item for FEED-SYM from in-memory cache."
  (let ((feed (assoc feed-sym newsticker--cache)))
    (when feed
      (catch 'found
        (dolist (item (cdr feed))
          (when (eq (newsticker--age item) 'feed)
            (throw 'found item)))))))

(defun newst-jsonrpc--build-buffer ()
  "Clear *newsticker* and insert all loaded items.
Point at first item."
  (let ((buf (get-buffer "*newsticker*")))
    (unless buf (user-error "No *newsticker* buffer"))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (sym (intern newst-jsonrpc-feed-name)))
        (erase-buffer)
        (set-buffer-modified-p nil)
        (when-let* ((fd (newst-jsonrpc--feed-descriptor sym)))
          (newsticker--buffer-insert-item fd sym))
        (dolist (item newst-jsonrpc-page-content)
          (newsticker--buffer-insert-item item sym))
        (let ((p (point)))
          (insert "\n")
          (put-text-property p (point) 'hard t))
        (newst-jsonrpc--post-render)))
    (goto-char (point-min))
    (newsticker--buffer-goto '(item))))

(defun newst-jsonrpc--post-render ()
  "Apply face, invisibility, and hiding settings to current buffer."
  (newsticker--buffer-set-faces (point-min) (point-max))
  (newsticker--buffer-set-invisibility (point-min) (point-max))
  (newsticker-hide-all-desc)
  (when newsticker-hide-old-items-in-newsticker-buffer
    (newsticker-hide-old-items))
  (when newsticker-hide-old-feed-header
    (newsticker-hide-old-feed-header))
  (when newsticker-show-descriptions-of-new-items
    (newsticker-show-new-item-desc)))

(defun newst-jsonrpc--stream-append (new-items)
  "Append NEW-ITEMS to the buffer and `newst-jsonrpc-page-content'.
Trim from front if over `newst-jsonrpc-stream-max-items'.
Point is preserved or moved to first item if a rebuild was needed."
  (let* ((buf (get-buffer "*newsticker*"))
         (sym (intern newst-jsonrpc-feed-name))
         (over 0))
    (setq newst-jsonrpc-page-content
          (append newst-jsonrpc-page-content new-items))
    ;; Trim from front if over limit
    (let ((total (length newst-jsonrpc-page-content)))
      (when (> total newst-jsonrpc-stream-max-items)
        (setq over (- total newst-jsonrpc-stream-max-items)
              newst-jsonrpc-page-content (nthcdr over newst-jsonrpc-page-content)
              newst-jsonrpc-offset (+ newst-jsonrpc-offset over))))
    (if (> over 0)
        ;; Rebuild from scratch after trimming
        (newst-jsonrpc--build-buffer)
      ;; No trim — append incrementally
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (forward-line -1)
          (delete-region (point) (point-max))
          (dolist (item new-items)
            (newsticker--buffer-insert-item item sym))
          (let ((p (point)))
            (insert "\n")
            (put-text-property p (point) 'hard t))
          (newst-jsonrpc--post-render))))))

(defun newst-jsonrpc--stream-prepend (new-items)
  "Prepend NEW-ITEMS to the buffer and `newst-jsonrpc-page-content'.
Updates `newst-jsonrpc-offset'.  Trim from end if over limit.
Point is preserved or moved to first item if a rebuild was needed."
  (let* ((buf (get-buffer "*newsticker*"))
         (sym (intern newst-jsonrpc-feed-name))
         (over 0))
    (setq newst-jsonrpc-offset (- newst-jsonrpc-offset (length new-items))
          newst-jsonrpc-page-content (append new-items newst-jsonrpc-page-content))
    ;; Trim from end if over limit
    (let ((total (length newst-jsonrpc-page-content)))
      (when (> total newst-jsonrpc-stream-max-items)
        (setq over (- total newst-jsonrpc-stream-max-items)
              newst-jsonrpc-page-content (butlast newst-jsonrpc-page-content over))))
    (if (> over 0)
        ;; Rebuild from scratch after trimming
        (newst-jsonrpc--build-buffer)
      ;; No trim — prepend incrementally
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-min))
          (if (newsticker--buffer-goto '(item))
              (dolist (item new-items)
                (newsticker--buffer-insert-item item sym))
            ;; No items yet — append at end
            (dolist (item new-items)
              (newsticker--buffer-insert-item item sym))
            (let ((p (point)))
              (insert "\n")
              (put-text-property p (point) 'hard t)))
          (newst-jsonrpc--post-render))))))

(defun newst-jsonrpc-goto (feed-name offset)
  "Switch to FEED-NAME at OFFSET (full reset, not streaming)."
  (setq newst-jsonrpc-feed-name feed-name
        newst-jsonrpc-offset offset)
  (let* ((result (newst-jsonrpc--fetch
                  feed-name offset newst-jsonrpc-page-size))
         (items (car result))
         (total (cdr result)))
    (setq newst-jsonrpc-total total
          newst-jsonrpc-page-content items)
    (newst-jsonrpc--build-buffer)))

(defun newst-jsonrpc--pos-at-offset (target-offset)
  "Move point to the first item whose offset is TARGET-OFFSET.
Start searching from the first item in the buffer."
  (goto-char (point-min))
  (when (newsticker--buffer-goto '(item))
    (let ((current-offset newst-jsonrpc-offset))
      (while (and (< current-offset target-offset)
                  (newsticker--buffer-goto '(item) nil t))
        (setq current-offset (1+ current-offset))))))

(defun newst-jsonrpc-next-page ()
  "Stream next chunk: append items to buffer.
Wraps to next feed at end."
  (let ((buf-end (+ newst-jsonrpc-offset (length newst-jsonrpc-page-content))))
    (if (>= buf-end newst-jsonrpc-total)
        (progn
          (newst-jsonrpc--next-feed)
          (newsticker--buffer-goto '(item)))
      (let* ((result (newst-jsonrpc--fetch
                      newst-jsonrpc-feed-name buf-end
                      newst-jsonrpc-page-size))
             (new-items (car result))
             (new-total (cdr result)))
        (setq newst-jsonrpc-total new-total)
        (newst-jsonrpc--stream-append new-items)
        ;; Position at first new item (offset buf-end)
        (newst-jsonrpc--pos-at-offset buf-end)))))

(defun newst-jsonrpc-prev-page ()
  "Stream previous chunk: prepend items to buffer.
Wraps to prev feed at start."
  (let ((buf-start newst-jsonrpc-offset))
    (if (<= buf-start 0)
        (progn
          (newst-jsonrpc--prev-feed)
          (newsticker--buffer-goto '(item)))
      (let* ((prev-offset (max 0 (- buf-start newst-jsonrpc-page-size)))
             (chunk-size (- buf-start prev-offset))
             (result (newst-jsonrpc--fetch
                      newst-jsonrpc-feed-name prev-offset chunk-size))
             (new-items (car result))
             (new-total (cdr result)))
        (setq newst-jsonrpc-total new-total)
        (newst-jsonrpc--stream-prepend new-items)
        ;; Position at first new item (offset prev-offset)
        (goto-char (point-min))
        (newsticker--buffer-goto '(item))))))

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
Load the first page of the first feed into the streaming buffer."
  (let* ((feeds (append newsticker-url-list newsticker-url-list-defaults))
         (first (car feeds)))
    (if (null first)
        (user-error "No feeds configured")
      (newst-jsonrpc-goto (car first) 0)
      (when (and (null newst-jsonrpc-page-content)
                 (eq 0 newst-jsonrpc-total))
        ;; feed exists but has 0 items — show empty page
        (newst-jsonrpc--build-buffer)))))

(defun newst-jsonrpc-advice-next-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-next-item'.
When at last item, load next page from the cache."
  (if (save-excursion (newsticker--buffer-goto '(item)))
      (funcall orig-fn do-not-wrap)
    (newst-jsonrpc-next-page)))

(defun newst-jsonrpc-advice-prev-item
    (orig-fn &optional do-not-wrap)
  "Around advice for `newsticker-previous-item'.
When at first item, load previous page from the cache."
  (if (save-excursion (newsticker--buffer-goto '(item) t t))
      (funcall orig-fn do-not-wrap)
    (newst-jsonrpc-prev-page)))

(defun newst-jsonrpc-advice-next-feed (orig-fn)
  "Around advice for `newsticker-next-feed'.
Load next feed's first page from the cache."
  (ignore orig-fn)
  (newst-jsonrpc--next-feed))

(defun newst-jsonrpc-advice-prev-feed (orig-fn)
  "Around advice for `newsticker-previous-feed'.
Load previous feed's first page from the cache."
  (ignore orig-fn)
  (newst-jsonrpc--prev-feed))

;; ----------------------------------------------------------------------
;; Auto-install pager advice on load
;; ----------------------------------------------------------------------

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
