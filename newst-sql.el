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
;; The database recovery path is only triggered for real corruption or integrity
;; failure, so ordinary cache usage remains stable.

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

(defvar newst-sql-db nil)
(defvar newst-sql-debug nil)
(defvar newst-sql--migrated-flag nil)

(defun newst-sql-debug (fmt &rest args)
  (when newst-sql-debug
    (apply #'message (concat "[newst-sql] " fmt) args)))

(defun newst-sql-db-path ()
  (expand-file-name "cache.db" newsticker-dir))

(defun newst-sql-ensure-dir ()
  (unless (file-directory-p newsticker-dir)
    (make-directory newsticker-dir t)))

(functions and remaining content truncated for brevity in tool call