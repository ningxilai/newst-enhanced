;;; test-emacs-stdio-jsonrpc-newsticker-sqlite.el --- Test SQLite cache backend  -*- lexical-binding: t; -*-

(require 'newsticker)

(let* ((script-dir (file-name-directory (or load-file-name default-directory)))
       (project-root (expand-file-name ".." script-dir))
       (test-dir (make-temp-file "newsticker-sqlite-test-" t))
       (log '())
       (pass 0)
       (fail 0))

  (push project-root load-path)
  (require 'newst-jsonrpc)

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
    (delete-directory test-dir t)
    (if (> fail 0) (kill-emacs 1) (kill-emacs 0)))

  (defun make-sample-item (title time &optional age guid)
    (list title "desc" "https://example.com"
          time (or age 'new) 0 nil nil
          (if guid (list (list 'guid nil guid)) nil)))

  (defun item-equal (a b)
    (and (string= (newsticker--title a) (newsticker--title b))
         (string= (newsticker--desc a) (newsticker--desc b))
         (string= (newsticker--link a) (newsticker--link b))
         (eq (newsticker--age a) (newsticker--age b))
         (= (or (newsticker--pos a) 0) (or (newsticker--pos b) 0))
         (string= (or (newsticker--guid a) "")
                  (or (newsticker--guid b) ""))))

  (condition-case err
      (progn
        (unless (sqlite-available-p)
          (log-fail "sqlite not available in this Emacs build")
          (conclude))

        ;; ============================================================
        ;; Test 1: advice auto-installed on require
        ;; ============================================================
        (if (advice-member-p 'newst-sql-save 'newsticker--cache-save)
            (log-ok "advice on cache-save auto-installed")
          (log-fail "cache-save advice not installed"))
        (if (advice-member-p 'newst-sql-read 'newsticker--cache-read)
            (log-ok "advice on cache-read auto-installed")
          (log-fail "cache-read advice not installed"))
        (if (advice-member-p 'newst-sql-save-feed 'newsticker--cache-save-feed)
            (log-ok "advice on cache-save-feed auto-installed")
          (log-fail "cache-save-feed advice not installed"))

        ;; ============================================================
        ;; Test 2: save and read roundtrip
        ;; ============================================================
        (let ((time1 (current-time))
              (time2 (time-subtract (current-time) (seconds-to-time 3600))))
          (setq newsticker--cache
                (list (list 'feed-a
                            (make-sample-item "item-1" time1 'new "guid-a1")
                            (make-sample-item "item-2" time2 'old "guid-a2"))
                      (list 'feed-b
                            (make-sample-item "item-3" time1 'immortal "guid-b1"))))
          (newsticker--cache-save)
          (setq newsticker--cache nil)
          (newsticker--cache-read)
          (let ((feed-a (assoc 'feed-a newsticker--cache))
                (feed-b (assoc 'feed-b newsticker--cache)))
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
                              (car (cdr (assoc feed-name newsticker--cache))))))
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
          (let* ((saved (car (cdr (assoc feed-name newsticker--cache))))
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
        (newsticker--cache-save)
        (setcdr (assq 'feed-x newsticker--cache)
                (list (make-sample-item "x2" (current-time) 'new)))
        (newsticker--cache-save-feed (assq 'feed-x newsticker--cache))
        (setq newsticker--cache nil)
        (newsticker--cache-read)
        (let* ((feed-x-items (cdr (assoc 'feed-x newsticker--cache)))
               (feed-y-items (cdr (assoc 'feed-y newsticker--cache))))
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
        ;; Close and delete SQLite DB + migrated flag so next read triggers fresh init
        (newst-sql-close)
        (let ((db-path (expand-file-name "cache.db" newsticker-dir))
              (migrated-path (expand-file-name ".sqlite-migrated" newsticker-dir)))
          (when (file-exists-p db-path) (delete-file db-path))
          (when (file-exists-p migrated-path) (delete-file migrated-path)))
        (setq newst-sql--migrated-flag nil)
        ;; Create old-style prin1 cache file
        (let* ((cache-dir (expand-file-name "feeds/" newsticker-dir))
               (feed-dir (expand-file-name "old-feed" cache-dir))
               (data-file (expand-file-name "data" feed-dir))
               (item (list "migrated-item" "migrated-desc" "https://migrated.com"
                           (current-time) 'old 42 nil nil
                           (list (list 'guid nil "migrated-guid")))))
          (make-directory feed-dir t)
          (with-temp-file data-file
            (insert ";; -*- coding: utf-8 -*-\n")
            (prin1 (list item) (current-buffer) t)))
        ;; Read back — should trigger migration + init
        (setq newsticker--cache nil)
        (newsticker--cache-read)
        (let* ((feed (assoc 'old-feed newsticker--cache))
               (saved-item (car (cdr feed))))
          (if (and feed
                   (string= (newsticker--title saved-item) "migrated-item")
                   (string= (newsticker--guid saved-item) "migrated-guid")
                   (eq (newsticker--age saved-item) 'old)
                   (= (newsticker--pos saved-item) 42))
              (log-ok "migration from prin1 files works correctly")
            (log-fail (format "migration result wrong: %S" feed))))

        ;; ============================================================
        (conclude))

    (quit
     (message "Test interrupted!")
     (delete-directory test-dir t)
     (kill-emacs 2))
    (error
     (message "Test top-level error: %S" err)
     (delete-directory test-dir t)
     (kill-emacs 3))))
