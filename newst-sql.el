;;; newst-sql.el --- SQLite cache backend for Newsticker  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: emacs-stdio-jsonrpc contributors
;; URL: https://github.com/anomalyco/emacs-stdio-jsonrpc
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: news, feed, newsticker

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Drop-in SQLite persistence for Newsticker's feed cache.
;; Simply (require 'newst-sql) — advice is installed automatically.
;;
;; Replaces the per-feed prin1 files with a single SQLite database
;; at `newsticker-dir/cache.db'.

;;; Code:

(require 'sqlite)

(eval-when-compile
  (require 'newsticker nil t))

(declare-function newsticker--age "newst-backend.el")
(declare-function newsticker--time "newst-backend.el")
(declare-function newsticker--title "newst-backend.el")
(declare-function newsticker--desc "newst-backend.el")
(declare-function newsticker--link "newst-backend.el")
(declare-function newsticker--pos "newst-backend.el")
(declare-function newsticker--preformatted-contents "newst-backend.el")
(declare-function newsticker--preformatted-title "newst-backend.el")
(declare-function newsticker--extra "newst-backend.el")
(declare-function newsticker--guid "newst-backend.el")

;; ----------------------------------------------------------------------
;; Internal state
;; ----------------------------------------------------------------------

(defvar newst-sql-db nil
  "SQLite database handle for Newsticker cache.")

(defvar newst-sql-debug nil
  "When non-nil, print diagnostic messages for SQLite cache.")

(defun newst-sql-debug (fmt &rest args)
  (when newst-sql-debug
    (apply #'message (concat "[newst-sql] " fmt) args)))

;; ----------------------------------------------------------------------
;; Database lifecycle
;; ----------------------------------------------------------------------

(defvar newst-sql--migrated-flag nil
  "Non-nil once the single-file `.sqlite-migrated' check has run.")

(defun newst-sql-db-path ()
  (expand-file-name "cache.db" newsticker-dir))

(defun newst-sql-ensure-dir ()
  (unless (file-directory-p newsticker-dir)
    (make-directory newsticker-dir t)))

(defun newst-sql-init ()
  (newst-sql-ensure-dir)
  (let ((path (newst-sql-db-path)))
    (setq newst-sql-db (sqlite-open path nil nil))
    (sqlite-execute newst-sql-db
      "CREATE TABLE IF NOT EXISTS items (
         feed_name TEXT NOT NULL, title TEXT, description TEXT, link TEXT,
         time_high INTEGER, time_low INTEGER, time_micro INTEGER, time_pico INTEGER,
         age TEXT NOT NULL DEFAULT 'new', item_pos INTEGER,
         preformatted_contents TEXT, preformatted_title TEXT,
         extra_elements TEXT, guid TEXT)")
    (sqlite-execute newst-sql-db
      "CREATE INDEX IF NOT EXISTS idx_items_feed ON items(feed_name)")
    (sqlite-execute newst-sql-db
      "CREATE INDEX IF NOT EXISTS idx_items_guid ON items(guid)")
    (sqlite-execute newst-sql-db
      "CREATE INDEX IF NOT EXISTS idx_items_age ON items(age)")
    (sqlite-execute newst-sql-db
      "PRAGMA journal_mode=WAL")
    (sqlite-execute newst-sql-db
      "PRAGMA synchronous=NORMAL")
    (newst-sql--maybe-migrate)))

(defun newst-sql-close ()
  (when newst-sql-db
    (sqlite-close newst-sql-db)
    (setq newst-sql-db nil)))

;; ----------------------------------------------------------------------
;; Migration from prin1 files
;; ----------------------------------------------------------------------

(defun newst-sql--maybe-migrate ()
  (unless newst-sql--migrated-flag
    (setq newst-sql--migrated-flag t)
    (let ((cache-dir (expand-file-name "feeds/" newsticker-dir))
          (migrated (expand-file-name ".sqlite-migrated" newsticker-dir)))
      (when (and (file-directory-p cache-dir)
                 (not (file-exists-p migrated)))
        (let ((db newst-sql-db))
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
                          (newst-sql--insert-item db feed-dir item))
                    (error (message "newst-sql: migrate error %s: %s"
                                    feed-dir (error-message-string err)))))))))))
      (with-temp-file migrated
        (insert (format-time-string ";; Migrated %Y-%m-%d %H:%M:%S\n")))
      (newst-sql-debug "migration complete"))))

;; ----------------------------------------------------------------------
;; Core SQLite operations
;; ----------------------------------------------------------------------

(defun newst-sql--item-to-row (feed-name item)
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

(defun newst-sql--row-to-item (row)
  (list (nth 1 row) (nth 2 row) (nth 3 row)
        (list (nth 4 row) (nth 5 row) (nth 6 row) (nth 7 row))
        (intern (nth 8 row))
        (nth 9 row) (nth 10 row) (nth 11 row)
        (let ((extra (nth 12 row)))
          (if extra (read extra) nil))))

(defun newst-sql--insert-item (db feed-name item)
  (sqlite-execute db
    (concat "INSERT INTO items "
            "(feed_name,title,description,link,"
            "time_high,time_low,time_micro,time_pico,"
            "age,item_pos,"
            "preformatted_contents,preformatted_title,"
            "extra_elements,guid) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    (newst-sql--item-to-row feed-name item)))

;; ----------------------------------------------------------------------
;; Cache advice implementations (replace newsticker--cache-*)
;; ----------------------------------------------------------------------

(defun newst-sql-save ()
  "Override for `newsticker--cache-save': write entire cache to SQLite."
  (unless newst-sql-db
    (newst-sql-init))
  (let ((db newst-sql-db))
    (with-sqlite-transaction db
      (sqlite-execute db "DELETE FROM items")
      (dolist (feed newsticker--cache)
        (let ((feed-name (symbol-name (car feed))))
          (dolist (item (cdr feed))
            (newst-sql--insert-item db feed-name item))))))
  (newst-sql-debug "cache saved (%d feeds)" (length newsticker--cache)))

(defun newst-sql-save-feed (feed)
  "Override for `newsticker--cache-save-feed': save one feed to SQLite."
  (unless newst-sql-db
    (newst-sql-init))
  (let ((db newst-sql-db)
        (feed-name (symbol-name (car feed))))
    (with-sqlite-transaction db
      (sqlite-execute db "DELETE FROM items WHERE feed_name = ?"
                      (list feed-name))
      (dolist (item (cdr feed))
        (newst-sql--insert-item db feed-name item))))
  (newst-sql-debug "feed saved: %s" (car feed)))

(defun newst-sql-read ()
  "Override for `newsticker--cache-read': load entire cache from SQLite."
  (unless newst-sql-db
    (newst-sql-init))
  (setq newsticker--cache nil)
  (let ((db newst-sql-db)
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
            (push (newst-sql--row-to-item row) cur-items)
          (when cur-feed
            (push (cons cur-feed (nreverse cur-items)) newsticker--cache))
          (setq cur-feed feed-name
                cur-items (list (newst-sql--row-to-item row))))))
    (when cur-feed
      (push (cons cur-feed (nreverse cur-items)) newsticker--cache)))
  (newst-sql-debug "cache loaded (%d feeds)" (length newsticker--cache)))

;; ----------------------------------------------------------------------
;; Interactive commands
;; ----------------------------------------------------------------------

(defun newst-sql-rebuild-cache ()
  "Delete SQLite cache and re-migrate from prin1 files."
  (interactive)
  (require 'newsticker)
  (let ((db-path (newst-sql-db-path))
        (migrated (expand-file-name ".sqlite-migrated" newsticker-dir)))
    (newst-sql-close)
    (when (file-exists-p db-path)
      (delete-file db-path)
      (message "newst-sql: deleted %s" db-path))
    (when (file-exists-p migrated)
      (delete-file migrated)
      (message "newst-sql: deleted %s" migrated))
    (setq newst-sql--migrated-flag nil)
    (newst-sql-init)
    (message "newst-sql: cache rebuilt from prin1 files")))

;; ----------------------------------------------------------------------
;; Auto-install cache advice on load
;; ----------------------------------------------------------------------

;; Safe even if newsticker is not yet loaded: advice-add stores pending
;; advice that is applied when the target function is later defined.
(advice-add 'newsticker--cache-save :override #'newst-sql-save)
(advice-add 'newsticker--cache-read :override #'newst-sql-read)
(advice-add 'newsticker--cache-save-feed :override #'newst-sql-save-feed)

(provide 'newst-sql)
;;; newst-sql.el ends here
