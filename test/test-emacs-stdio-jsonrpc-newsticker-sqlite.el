;;; test-emacs-stdio-jsonrpc-newsticker-sqlite.el --- Test SQLite cache backend  -*- lexical-binding: t; -*-

(require 'newsticker)

(let* ((script-dir (file-name-directory (or load-file-name default-directory)))
       (project-root (expand-file-name ".." script-dir))
       (sibling-root (expand-file-name "deps/emacs-stdio-jsonrpc" project-root))
       (el-path (expand-file-name "emacs-stdio-jsonrpc-newsticker.el" project-root))
       (test-dir (make-temp-file "newsticker-sqlite-test-" t))
       (log '())
       (pass 0)
       (fail 0))

  (push sibling-root load-path)
  (push project-root load-path)
  (require 'emacs-stdio-jsonrpc)
  (load el-path nil t)

  ;; Override newsticker-dir to our temp dir
  (setq newsticker-dir (expand-file-name "newsticker/" test-dir))

  (defun log-ok (msg)
    (push (concat "PASS: " msg) log)
    (setq pass (1+ pass)))

  (defun log-fail (msg)
    (push (concat "FAIL: " msg) log)
    (setq fail (1+ fail)))

  (defun conclude ()
    (message "=== SQLite Cache Backend Test Results ===")
    (dolist (l (reverse log))
      (message "%s" l))
    (message "--- %d passed, %d failed ---" pass fail)
    ;; Cleanup
    (delete-directory test-dir t)
    (if (> fail 0) (kill-emacs 1) (kill-emacs 0)))

  (defun make-sample-item (title time &optional age guid)
    (list title "desc" "https://example.com"
          time (or age 'new) 0 nil nil
          (if guid (list (list 'guid nil guid)) nil)))

  (defun item-equal (a b)
    "Compare two item lists, ignoring time and preformatted fields."
    (and (string= (newsticker--title a) (newsticker--title b))
         (string= (newsticker--desc a) (newsticker--desc b))
         (string= (newsticker--link a) (newsticker--link b))
         (eq (newsticker--age a) (newsticker--age b))
         (= (or (newsticker--pos a) 0) (or (newsticker--pos b) 0))
         (string= (or (newsticker--guid a) "")
                  (or (newsticker--guid b) ""))))

  (condition-case err
      (progn
        ;; Check sqlite availability
        (unless (sqlite-available-p)
          (log-fail "sqlite not available in this Emacs build")
          (conclude))

        ;; ============================================================
        ;; Test 1: mode enable/disable
        ;; ============================================================
        (emacs-stdio-jsonrpc-newsticker-mode 1)
        (if (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sqlite-save
                             'newsticker--cache-save)
            (log-ok "mode enables advice on cache-save")
          (log-fail "mode did not enable cache-save advice"))
        (if (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sqlite-read
                             'newsticker--cache-read)
            (log-ok "mode enables advice on cache-read")
          (log-fail "mode did not enable cache-read advice"))
        (emacs-stdio-jsonrpc-newsticker-mode 0)
        (if (not (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sqlite-save
                                  'newsticker--cache-save))
            (log-ok "mode off removes cache-save advice")
          (log-fail "mode off did not remove cache-save advice"))
        (if (not (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sqlite-read
                                  'newsticker--cache-read))
            (log-ok "mode off removes cache-read advice")
          (log-fail "mode off did not remove cache-read advice"))

        ;; ============================================================
        ;; Test 2: save and read roundtrip
        ;; ============================================================
        (emacs-stdio-jsonrpc-newsticker-mode 1)
        (let ((time1 (current-time))
              (time2 (time-subtract (current-time) (seconds-to-time 3600))))
          (setq newsticker--cache
                (list (list 'feed-a
                            (make-sample-item "item-1" time1 'new "guid-a1")
                            (make-sample-item "item-2" time2 'old "guid-a2"))
                      (list 'feed-b
                            (make-sample-item "item-3" time1 'immortal "guid-b1"))))
          ;; Save to SQLite
          (newsticker--cache-save)
          ;; Clear in-memory cache and re-read
          (setq newsticker--cache nil)
          (newsticker--cache-read)
          ;; Verify
          (let ((feed-a (newsticker--cache-get-feed 'feed-a))
                (feed-b (newsticker--cache-get-feed 'feed-b)))
            (if (and feed-a feed-b
                     (= (length (cdr feed-a)) 2)
                     (= (length (cdr feed-b)) 1)
                     (item-equal (car (cdr feed-a))
                                 (make-sample-item "item-1" time1 'new "guid-a1"))
                     (item-equal (cadr (cdr feed-a))
                                 (make-sample-item "item-2" time2 'old "guid-a2"))
                     (item-equal (car (cdr feed-b))
                                 (make-sample-item "item-3" time1 'immortal "guid-b1")))
                (log-ok "save/read roundtrip preserves all data")
              (log-fail (format "roundtrip failed: %S" newsticker--cache)))))

        ;; ============================================================
        ;; Test 3: time precision survives roundtrip
        ;; ============================================================
        (let* ((original-time (current-time))
               (item (make-sample-item "time-test" original-time 'new))
               (feed-name 'time-feed))
          (setq newsticker--cache (list (list feed-name item)))
          (newsticker--cache-save)
          (setq newsticker--cache nil)
          (newsticker--cache-read)
          (let* ((saved-time (newsticker--time
                              (car (cdr (newsticker--cache-get-feed feed-name))))))
            (if (time-equal-p original-time saved-time)
                (log-ok "time precision preserved through save/read")
              (log-fail (format "time changed: %S -> %S"
                                original-time saved-time)))))

        ;; ============================================================
        ;; Test 4: extra-elements with guid roundtrip
        ;; ============================================================
        (let* ((extra '((guid nil "test-guid-123") (enclosure (url "https://e.com/e") length "1000")))
               (item (list "extra-test" "desc" "https://ex.com"
                           (current-time) 'new 5 nil nil extra))
               (feed-name 'extra-feed))
          (setq newsticker--cache (list (list feed-name item)))
          (newsticker--cache-save)
          (setq newsticker--cache nil)
          (newsticker--cache-read)
          (let* ((saved (car (cdr (newsticker--cache-get-feed feed-name))))
                 (saved-extra (newsticker--extra saved))
                 (saved-guid (newsticker--guid saved)))
            (if (and (string= saved-guid "test-guid-123")
                     (equal saved-extra extra))
                (log-ok "extra-elements and guid roundtrip correctly")
              (log-fail (format "extra/guid changed: %S -> (extra=%S guid=%S)"
                                extra saved-extra saved-guid)))))

        ;; ============================================================
        ;; Test 5: save-feed replaces only that feed
        ;; ============================================================
        (setq newsticker--cache
              (list (list 'feed-x (make-sample-item "x1" (current-time) 'new))
                    (list 'feed-y (make-sample-item "y1" (current-time) 'new))))
        (newsticker--cache-save)  ;; save both
        ;; Replace feed-x items in memory
        (setcdr (assq 'feed-x newsticker--cache)
                (list (make-sample-item "x2" (current-time) 'new)))
        ;; save-feed only for feed-x
        (newsticker--cache-save-feed (assq 'feed-x newsticker--cache))
        ;; Clear and read back
        (setq newsticker--cache nil)
        (newsticker--cache-read)
        (let* ((feed-x-items (cdr (newsticker--cache-get-feed 'feed-x)))
               (feed-y-items (cdr (newsticker--cache-get-feed 'feed-y))))
          (if (and (= (length feed-x-items) 1)
                   (string= (newsticker--title (car feed-x-items)) "x2")
                   (= (length feed-y-items) 1)
                   (string= (newsticker--title (car feed-y-items)) "y1"))
              (log-ok "save-feed only replaces the specified feed")
            (log-fail (format "save-feed corrupted: x=%S y=%S"
                              feed-x-items feed-y-items))))

        ;; ============================================================
        ;; Test 6: empty cache save/read
        ;; ============================================================
        (setq newsticker--cache nil)
        (newsticker--cache-save)
        (newsticker--cache-read)
        (if (null newsticker--cache)
            (log-ok "empty cache save/read works")
          (log-fail (format "empty cache read gave: %S" newsticker--cache)))

        ;; ============================================================
        ;; Test 7: migration from prin1 files
        ;; ============================================================
        ;; Disable mode first
        (emacs-stdio-jsonrpc-newsticker-mode 0)
        ;; Create old-style prin1 cache file
        (let* ((cache-dir (expand-file-name "feeds/" newsticker-dir))
               (feed-dir (expand-file-name "old-feed" cache-dir))
               (data-file (expand-file-name "data" feed-dir))
               (time-str (format-time-string "%Y-%m-%d %H:%M:%S"))
               (item (list "migrated-item" "migrated-desc" "https://migrated.com"
                           (current-time) 'old 42 nil nil
                           (list (list 'guid nil "migrated-guid")))))
          (make-directory feed-dir t)
          (with-temp-file data-file
            (insert ";; -*- coding: utf-8 -*-\n")
            (prin1 (list item) (current-buffer) t)))
        ;; Now enable mode — should auto-migrate
        (emacs-stdio-jsonrpc-newsticker-mode 1)
        (if (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sqlite-save
                             'newsticker--cache-save)
            (log-ok "mode enabled after creating old-style prin1 cache")
          (log-fail "mode enable failed"))
        ;; Re-read and verify migrated data
        (setq newsticker--cache nil)
        (newsticker--cache-read)
        (let* ((feed (newsticker--cache-get-feed 'old-feed))
               (item (car (cdr feed))))
          (if (and feed
                   (string= (newsticker--title item) "migrated-item")
                   (string= (newsticker--guid item) "migrated-guid")
                   (eq (newsticker--age item) 'old)
                   (= (newsticker--pos item) 42))
              (log-ok "migration from prin1 files works correctly")
            (log-fail (format "migration result wrong: %S" feed))))
        ;; Cleanup migrated flag so subsequent runs re-test migration
        (let ((migrated-file (expand-file-name ".sqlite-migrated" newsticker-dir)))
          (when (file-exists-p migrated-file)
            (delete-file migrated-file)))

        ;; ============================================================
        (emacs-stdio-jsonrpc-newsticker-mode 0)
        (conclude))

    (quit
     (message "Test interrupted!")
     (delete-directory test-dir t)
     (kill-emacs 2))
    (error
     (message "Test top-level error: %S" err)
     (delete-directory test-dir t)
     (kill-emacs 3))))
