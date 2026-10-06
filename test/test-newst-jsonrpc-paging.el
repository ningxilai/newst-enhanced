;;; test-newst-jsonrpc-paging.el --- In-memory paging tests  -*- lexical-binding: t; -*-

;; newsticker is built-in; the buffer-insert helpers used below live there.
(require 'newsticker)
(require 'newst-plainview nil t)

(let* ((script-dir (file-name-directory (or load-file-name default-directory)))
       (project-root (expand-file-name ".." script-dir))
       (log '())
       (pass 0)
       (fail 0))

  (push project-root load-path)
  (require 'newst-jsonrpc)

  (defun log-ok (msg)
    (push (concat "PASS: " msg) log)
    (setq pass (1+ pass)))

  (defun log-fail (msg)
    (push (concat "FAIL: " msg) log)
    (setq fail (1+ fail)))

  (defun conclude ()
    (message "=== Paging Test Results ===")
    (dolist (l (reverse log))
      (message "%s" l))
    (message "--- %d passed, %d failed ---" pass fail)
    (kill-emacs (if (> fail 0) 1 0)))

  (defun make-item (n)
    (list (format "title%d" n) (format "desc%d" n)
          (format "https://example.com/%d" n)
          (current-time) 'new n nil nil nil))

  (condition-case err
      (progn
        ;; Fake cache: feed1 with 10 items, no subprocess involved.
        (setq newsticker--cache
              (list (cons 'feed1 (mapcar #'make-item
                                         (number-sequence 0 9)))))
        (setq newsticker-url-list nil
              newsticker-url-list-defaults nil
              newst-jsonrpc-page-size 4
              newst-jsonrpc-stream-max-items 200)

        ;; Test 1: fetch slices correctly.
        (let ((res (newst-jsonrpc--fetch 'feed1 3 4)))
          (if (and (= (cdr res) 10)
                   (= (length (car res)) 4)
                   (string= (newsticker--title (car (car res))) "title3"))
              (log-ok "fetch slices (offset . total)")
            (log-fail (format "fetch wrong: %S" res))))

        ;; Test 2: goto sets state and builds buffer.
        (get-buffer-create "*newsticker*")
        (newst-jsonrpc-goto "feed1" 0)
        (if (and (equal newst-jsonrpc-feed-name "feed1")
                 (= newst-jsonrpc-offset 0)
                 (= newst-jsonrpc-total 10)
                 (= (length newst-jsonrpc-page-content) 4))
            (log-ok "goto initializes state")
          (log-fail "goto state wrong"))

        ;; Test 3: next page streams forward.
        (newst-jsonrpc-next-page)
        (if (and (= (length newst-jsonrpc-page-content) 8)
                 (string= (newsticker--title
                           (nth 4 newst-jsonrpc-page-content))
                          "title4"))
            (log-ok "next page appends")
          (log-fail "next page wrong"))

        ;; Test 4: prev page streams backward.
        (newst-jsonrpc-goto "feed1" 4)
        (newst-jsonrpc-prev-page)
        (if (and (= newst-jsonrpc-offset 0)
                 (= (length newst-jsonrpc-page-content) 8)
                 (string= (newsticker--title
                           (car newst-jsonrpc-page-content))
                          "title0"))
            (log-ok "prev page prepends")
          (log-fail (format "prev page wrong: offset=%S len=%S"
                            newst-jsonrpc-offset
                            (length newst-jsonrpc-page-content))))

        ;; Test 5: trimming caps the buffer.
        (setq newst-jsonrpc-stream-max-items 6)
        (newst-jsonrpc-next-page)
        (if (and (<= (length newst-jsonrpc-page-content) 6)
                 (> newst-jsonrpc-offset 0))
            (log-ok "trimming caps content")
          (log-fail "trimming wrong"))
        (setq newst-jsonrpc-stream-max-items 200)

        ;; Test 6: advice installed, pager state vars fully gone.
        (if (and (advice-member-p 'newst-jsonrpc-advice-insert-all
                                  'newsticker--buffer-insert-all-items)
                 (not (boundp 'newst-jsonrpc-conn))
                 (not (boundp 'newst-jsonrpc--page-cache)))
            (log-ok "advice installed, no pager state")
          (log-fail "advice/pager state wrong"))

        (conclude))
    (error
     (message "FATAL: %S" err)
     (kill-emacs 1))))
