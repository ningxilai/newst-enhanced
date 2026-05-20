;;; emacs-stdio-jsonrpc-newsticker-sqlite.el --- SQLite cache compat  -*- lexical-binding:t -*-

;; Copyright (C) 2026  emacs-stdio-jsonrpc

;; Author: emacs-stdio-jsonrpc
;; Keywords: News, RSS, Atom

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Backward-compatibility alias for
;; `emacs-stdio-jsonrpc-newsticker-mode'.  SQLite persistence is now
;; integrated directly into the main mode; enabling this alias just
;; toggles the main mode.

;;; Code:

(require 'emacs-stdio-jsonrpc-newsticker)

;;;###autoload
(define-minor-mode emacs-stdio-jsonrpc-newsticker-sqlite-mode
  "Alias for `emacs-stdio-jsonrpc-newsticker-mode'.
SQLite cache persistence is now built into the main mode.
Enable that instead."
  :global t
  :group 'newsticker
  :lighter ""
  (emacs-stdio-jsonrpc-newsticker-mode
   (if emacs-stdio-jsonrpc-newsticker-sqlite-mode 1 -1)))

(provide 'emacs-stdio-jsonrpc-newsticker-sqlite)
;;; emacs-stdio-jsonrpc-newsticker-sqlite.el ends here
