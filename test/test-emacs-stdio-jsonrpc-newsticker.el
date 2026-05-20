;;; test-emacs-stdio-jsonrpc-newsticker.el --- Test newsticker integration  -*- lexical-binding: t; -*-

(require 'jsonrpc)
(require 'newsticker)

(let* ((script-dir (file-name-directory (or load-file-name default-directory)))
       (project-root (expand-file-name ".." script-dir))
       (sibling-root (expand-file-name "deps/emacs-stdio-jsonrpc" project-root))
       (el-path (expand-file-name "emacs-stdio-jsonrpc.el" sibling-root))
       (nw-path (expand-file-name "emacs-stdio-jsonrpc-newsticker.el" project-root))
       (bin-path (expand-file-name "build/feed_processor" project-root))
       (log '())
       (pass 0)
       (fail 0))

  (load el-path nil t)
  (load nw-path nil t)

  (defun log-ok (msg)
    (push (concat "PASS: " msg) log)
    (setq pass (1+ pass)))

  (defun log-fail (msg)
    (push (concat "FAIL: " msg) log)
    (setq fail (1+ fail)))

  (defun conclude ()
    (message "=== Newsticker Integration Test Results ===")
    (dolist (l (reverse log))
      (message "%s" l))
    (message "--- %d passed, %d failed ---" pass fail)
    (if (> fail 0) (kill-emacs 1) (kill-emacs 0)))

  (defconst test-rss-xml
    "<?xml version=\"1.0\"?>
<rss version=\"2.0\">
  <channel>
    <title>Test Feed</title>
    <link>https://example.com</link>
    <description>Test</description>
    <item>
      <title>Item 1</title>
      <link>https://example.com/1</link>
      <description>First item</description>
      <pubDate>Mon, 18 May 2026 12:00:00 +0000</pubDate>
      <guid>guid-1</guid>
    </item>
    <item>
      <title>Item 2</title>
      <link>https://example.com/2</link>
      <description>Second item</description>
      <pubDate>Mon, 18 May 2026 13:00:00 +0000</pubDate>
      <guid>guid-2</guid>
    </item>
    <item>
      <title>Item 3</title>
      <link>https://example.com/3</link>
      <description>Third item</description>
      <pubDate>Mon, 18 May 2026 14:00:00 +0000</pubDate>
      <guid>guid-3</guid>
    </item>
  </channel>
</rss>")

  (condition-case err
      (progn
        ;; Start subprocess
        (emacs-stdio-jsonrpc-start bin-path)

        ;; Enable mode
        (emacs-stdio-jsonrpc-newsticker-mode 1)

        ;; Test 1: mode activates advice
        (if (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sentinel-advice
                             'newsticker--sentinel-work)
            (log-ok "mode activates advice on newsticker--sentinel-work")
          (log-fail "mode did not activate advice"))

        ;; Test 2: do-parse adds items to empty cache
        (condition-case e
            (let* ((feed-name "Test Feed")
                   (buf (generate-new-buffer " *test-feed*")))
              (with-current-buffer buf
                (insert test-rss-xml))
              ;; Set up newsticker-url-list for feed link resolution
              (let ((newsticker-url-list (list (list "Test Feed" "https://example.com")))
                    (newsticker-url-list-defaults nil)
                    (newsticker--cache nil)
                    (newsticker-obsolete-item-max-age (* 7 24 60 60))
                    (newsticker-keep-obsolete-items nil)
                    (newsticker--process-ids nil))
                (emacs-stdio-jsonrpc--newsticker-do-parse feed-name "test" buf)
                (let* ((feed (newsticker--cache-get-feed (intern feed-name)))
                       (items (cdr feed))
                       (feed-item (car items))
                       (news-items (cdr items)))
                  (if (and feed (= (length news-items) 3)
                           (string= (newsticker--title feed-item) "Test Feed")
                           (string= (newsticker--title (nth 0 news-items)) "Item 1")
                           (string= (newsticker--title (nth 1 news-items)) "Item 2")
                           (string= (newsticker--title (nth 2 news-items)) "Item 3"))
                      (log-ok (format "do-parse: %d items in cache" (length news-items)))
                    (log-fail (format "do-parse: cache state wrong: %S"
                                      (mapcar (lambda (i) (newsticker--title i)) news-items))))))
              (kill-buffer buf))
          (error (log-fail (format "do-parse threw: %S" e))))

        ;; Test 3: do-parse ages old items from cache
        (condition-case e
            (let* ((feed-name "Test Feed")
                   (name-symbol (intern feed-name))
                   (buf (generate-new-buffer " *test-feed*")))
              (with-current-buffer buf
                (insert test-rss-xml))
              (let ((newsticker-url-list (list (list "Test Feed" "https://example.com")))
                    (newsticker-url-list-defaults nil)
                    (newsticker--cache
                     (list (list name-symbol
                                 (list "Old Feed Info" "" "" (current-time)
                                       'feed 0 nil nil nil)
                                 (list "Old Item" "" "" (current-time)
                                       'new 0 nil nil nil))))
                    (newsticker-obsolete-item-max-age (* 7 24 60 60))
                    (newsticker-keep-obsolete-items nil)
                    (newsticker--process-ids nil))
                (emacs-stdio-jsonrpc--newsticker-do-parse feed-name "test" buf)
                (let* ((feed (newsticker--cache-get-feed name-symbol))
                       (items (cdr feed))
                       (ages (mapcar #'newsticker--age items)))
                  ;; Old feed info should be aged to 'obsolete-old and removed
                  ;; Old item should be aged to 'obsolete-new and removed
                  (if (and (not (member 'obsolete-old ages))
                           (not (member 'obsolete-new ages))
                           (= (length (cl-remove-if
                                       (lambda (a) (memq a '(obsolete obsolete-expired)))
                                       ages))
                              4))  ; feed info + 3 new items
                      (log-ok "do-parse ages and removes old items")
                    (log-fail (format "do-parse: ages wrong: %S" ages)))))
              (kill-buffer buf))
          (error (log-fail (format "age test threw: %S" e))))

        ;; Test 4: malformed XML adds error headline to cache
        (condition-case e
            (let* ((feed-name "Bad Feed")
                   (buf (generate-new-buffer " *test-bad*"))
                   (name-symbol (intern feed-name)))
              (with-current-buffer buf
                (insert "not xml"))
              (let ((newsticker-url-list nil)
                    (newsticker-url-list-defaults nil)
                    (newsticker--cache nil)
                    (newsticker-obsolete-item-max-age (* 7 24 60 60))
                    (newsticker-keep-obsolete-items nil)
                    (newsticker--process-ids nil))
                (emacs-stdio-jsonrpc--newsticker-do-parse feed-name "test" buf)
                (let* ((feed (newsticker--cache-get-feed name-symbol))
                       (items (cdr feed)))
                  (if (and feed (= (length items) 1)
                           (string= (newsticker--title (car items))
                                    newsticker--error-headline))
                      (log-ok "malformed XML adds error headline to cache")
                    (log-fail (format "malformed XML: cache state wrong: %S" items)))))
              (kill-buffer buf))
          (error (log-fail (format "malformed XML threw: %S" e))))

        ;; Test 5: mode off removes advice
        (emacs-stdio-jsonrpc-newsticker-mode 0)
        (if (not (advice-member-p 'emacs-stdio-jsonrpc--newsticker-sentinel-advice
                                  'newsticker--sentinel-work))
            (log-ok "mode off removes advice")
          (log-fail "mode off did not remove advice"))

        ;; Cleanup
        (emacs-stdio-jsonrpc-stop)
        (conclude))

    (quit
     (message "Test interrupted!")
     (kill-emacs 2))
    (error
     (message "Test top-level error: %S" err)
     (kill-emacs 3))))
