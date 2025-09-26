;;; elfeed-ai-summary.el --- AI summaries for Elfeed -*- lexical-binding: t; -*-

;; Author: dingchengyi <dingchengyi@example.com>
;; Maintainer: dingchengyi <dingchengyi@example.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (elfeed "3.4.1") (gptel "0.6"))
;; Keywords: convenience, news
;; URL: https://github.com/dingchengyi/elfeed-ai-summary

;; This file is not part of GNU Emacs.

;;; Commentary:

;; elfeed-ai-summary integrates Elfeed with GPTel to provide AI generated
;; summaries for individual entries, feeds, and Org-mode reports.  See the
;; README for configuration and usage details.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'elfeed nil t)
(require 'gptel nil t)

(eval-when-compile
  (declare-function elfeed-search-selected "elfeed-search" (&optional ignore-region))
  (declare-function elfeed-entry-content-data "elfeed-db" (content))
  (declare-function elfeed-entry-content-p "elfeed-db" (object))
  (declare-function elfeed-entry-title "elfeed-db" (entry))
  (declare-function elfeed-entry-link "elfeed-db" (entry))
  (declare-function elfeed-entry-date "elfeed-db" (entry))
  (declare-function elfeed-entry-tags "elfeed-db" (entry))
  (declare-function elfeed-feed-entries "elfeed-db" (feed))
  (declare-function elfeed-deref "elfeed-db" (ref))
  (declare-function gptel-request "gptel" (prompt &rest args))
  (declare-function org-insert-heading "org" (&optional arg invisible-ok))
  (defvar org-insert-heading-respect-content))

(defgroup elfeed-ai-summary nil
  "Summarize Elfeed entries with GPTel."
  :group 'elfeed)

(defcustom elfeed-ai-summary-category-feeds-count 10
  "Number of recent entries per feed or group to include in category summaries."
  :type 'integer
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-auto-summary-hook nil
  "When non-nil, generate AI summaries automatically when showing entries.
The hook is attached to `elfeed-show-entry-switch-hook'."
  :type 'boolean
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-prompt-template-for-single-entry
  "请为以下文章生成一个简洁的中文摘要，包含其核心观点和主要信息。文章标题：'%s'，内容如下：\n\n%s"
  "Prompt template for summarizing a single entry.
The first %s receives the entry title, the second %s receives the content."
  :type 'string
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-prompt-template-for-multiple-entries
  "请根据以下多篇文章，生成一份综合性的新闻报告。请识别出关键主题、共同趋势和重要事件，并以清晰的结构进行总结。文章列表如下：\n\n%s"
  "Prompt template for summarizing multiple entries.
%s is replaced by a formatted list of entry contents."
  :type 'string
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-org-report-headline-format "AI 新闻简报: %s"
  "Org headline format used when inserting a generated report.
%s is replaced with the current date."
  :type 'string
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-use-streaming nil
  "When non-nil request streaming responses from GPTel."
  :type 'boolean
  :group 'elfeed-ai-summary)

(defconst elfeed-ai-summary--summary-buffer-name "*Elfeed AI Summary*"
  "Default buffer name used for displaying generated summaries.")

(defun elfeed-ai-summary--ensure-dependencies ()
  "Ensure required packages are present, signaling a user error otherwise."
  (unless (featurep 'elfeed)
    (user-error "elfeed-ai-summary expects the elfeed package to be loaded"))
  (unless (fboundp 'gptel-request)
    (user-error "elfeed-ai-summary requires gptel to be installed and loaded"))
  ;; Check if gptel is properly configured
  (unless (and (boundp 'gptel-model) gptel-model)
    (user-error "GPTel is not configured. Please set gptel-model and other required variables"))
  (unless (and (boundp 'gptel-backend) gptel-backend)
    (user-error "GPTel backend is not configured. Please set gptel-backend")))

(defun elfeed-ai-summary--entry-at-point ()
  "Return the `elfeed-entry' under point.
When invoked from `elfeed-search-mode', the selected entry is returned.
When invoked from `elfeed-show-mode', the currently displayed entry is
returned.  In all other contexts signal an error."
  (cond
   ((derived-mode-p 'elfeed-search-mode)
    (car (elfeed-search-selected :ignore-region)))
   ((derived-mode-p 'elfeed-show-mode)
    (or (bound-and-true-p elfeed-show-entry)
        (user-error "No Elfeed entry available in this buffer")))
   (t
    (user-error "No Elfeed entry at point"))))

(defun elfeed-ai-summary--entry-content-string (entry)
  "Return a best-effort plain string representation for ENTRY's content."
  ;; First ensure we have a proper elfeed entry, not a reference
  (let ((resolved-entry (elfeed-ai-summary--ensure-entry entry)))
    (unless resolved-entry
      (error "Cannot resolve entry: %s" entry))
    
    (let* ((content (when (fboundp 'elfeed-entry-content)
                      (elfeed-entry-content resolved-entry)))
           (data (cond
                  ((null content) nil)
                  ((stringp content) content)
                  ((and (fboundp 'elfeed-entry-content-data)
                        (elfeed-entry-content-p content))
                   (elfeed-entry-content-data content))
                  ;; Handle elfeed-ref objects by dereferencing them
                  ((and (fboundp 'elfeed-ref-p) (elfeed-ref-p content))
                   (let ((deref-content (elfeed-deref content)))
                     (cond
                      ((stringp deref-content) deref-content)
                      ((and (fboundp 'elfeed-entry-content-data)
                            (elfeed-entry-content-p deref-content))
                       (elfeed-entry-content-data deref-content))
                      (t (format "%s" deref-content)))))
                  (t content)))
           (text (cond
                  ((stringp data) data)
                  ((vectorp data)
                   (let ((bytes (apply #'unibyte-string (append data nil))))
                     (condition-case nil
                         (decode-coding-string bytes 'utf-8)
                       (error bytes))))
                  (data
                   (format "%s" data))
                  (t nil))))
      ;; Clean up HTML tags and excessive whitespace if text contains HTML
      (when (and text (stringp text))
        (setq text (replace-regexp-in-string "<[^>]*>" "" text))
        (setq text (replace-regexp-in-string "[ \t\n\r]+" " " text))
        (setq text (string-trim text)))
      
      (or text
          (and (fboundp 'elfeed-meta)
               (or (elfeed-meta resolved-entry :summary)
                   (elfeed-meta resolved-entry :description)))
          ""))))

(defun elfeed-ai-summary--format-entries-for-summary (entries)
  "Format ENTRIES for inclusion in a prompt string.
ENTRIES should be a list of `elfeed-entry' values.  Returns a single
string where each entry is separated by a dashed divider."
  (mapconcat
   (lambda (entry)
     (let* ((title (or (elfeed-entry-title entry) "(untitled)"))
            (link (elfeed-entry-link entry))
            (content (elfeed-ai-summary--entry-content-string entry))
            (parts (delq nil (list (format "标题: %s" title)
                                   (when (and link (not (string-empty-p link)))
                                     (format "链接: %s" link))
                                   (when (and content (not (string-empty-p content)))
                                     (format "内容:\n%s" content))))))
       (string-join (cl-remove-if #'string-empty-p parts) "\n\n")))
   entries
   "\n\n---\n\n"))

(defun elfeed-ai-summary--call-gptel (prompt callback)
  "Send PROMPT to GPTel and invoke CALLBACK with the full response string.
CALLBACK is called once, after the response is complete.  Errors from
GPTel are re-signalled as user errors."
  (elfeed-ai-summary--ensure-dependencies)
  (message "Requesting AI summary...")
  
  (condition-case err
      (gptel-request
          prompt
        :stream elfeed-ai-summary-use-streaming
        :callback
        (lambda (response info)
          (condition-case callback-err
              (cond
               ((plist-get info :error)
                (message "GPTel request failed: %s" (plist-get info :error))
                (user-error "GPTel request failed: %s" (plist-get info :error)))
               ((and response (stringp response) (not (string-empty-p response)))
                (message "AI summary completed successfully!")
                (funcall callback response))
               (t
                (message "Warning: Received empty response from GPTel")))
            (error
             (message "Error in GPTel callback: %s" callback-err)
             (user-error "Error processing GPTel response: %s" callback-err)))))
    (error
     (user-error "Failed to start GPTel request: %s" err))))

(defun elfeed-ai-summary--display-summary (summary &optional entry)
  "Display SUMMARY for ENTRY in an appropriate buffer.
When ENTRY matches the currently displayed `elfeed-show-entry', append
the summary to that buffer; otherwise show it in a dedicated summary
buffer."
  (if (and entry
           (derived-mode-p 'elfeed-show-mode)
           (bound-and-true-p elfeed-show-entry)
           (eq entry elfeed-show-entry))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (unless (bolp)
            (insert "\n"))
          (insert "\n----- AI Summary -----\n" summary "\n")))
    (let* ((title (when (and entry (elfeed-entry-title entry))
                    (elfeed-entry-title entry)))
           (buffer-name (if title
                            (format "*AI Summary: %s*" title)
                          elfeed-ai-summary--summary-buffer-name))
           (buffer (get-buffer-create buffer-name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert summary)
          (goto-char (point-min))
          (view-mode 1)))
      (display-buffer buffer))))

(defun elfeed-ai-summary--ensure-list (object)
  "Return OBJECT as a list, converting vectors or single values."
  (cond
   ((null object) nil)
   ((listp object) object)
   ((vectorp object) (append object nil))
   (t (list object))))

(defun elfeed-ai-summary--ensure-entry (entry)
  "Return ENTRY as an `elfeed-entry' instance, dereferencing if needed."
  (cond
   ((and (fboundp 'elfeed-entry-p) (elfeed-entry-p entry)) entry)
   ((and (fboundp 'elfeed-ref-p) (elfeed-ref-p entry)) (elfeed-deref entry))
   ((and entry (fboundp 'elfeed-db-get-entry)) (elfeed-db-get-entry entry))
   (t nil)))

(defun elfeed-ai-summary--normalize-entry-list (entries)
  "Normalize ENTRIES into a list of valid `elfeed-entry' objects."
  (cl-loop for entry in (elfeed-ai-summary--ensure-list entries)
           for resolved = (elfeed-ai-summary--ensure-entry entry)
           when resolved collect resolved))

(defun elfeed-ai-summary--sort-entries (entries)
  "Return ENTRIES sorted by descending date without duplicates."
  (let* ((normalized (elfeed-ai-summary--normalize-entry-list entries))
         (unique (cl-delete-duplicates normalized :test #'eq)))
    (sort unique (lambda (a b) (> (elfeed-entry-date a)
                                  (elfeed-entry-date b))))))

(defun elfeed-ai-summary--sort-and-limit (entries limit)
  "Return ENTRIES sorted by date, restricted to LIMIT if non-nil."
  (let ((sorted (elfeed-ai-summary--sort-entries entries)))
    (if (and limit (> limit 0))
        (cl-loop for entry in sorted
                 for index from 1
                 collect entry into result
                 when (>= index limit) return result
                 finally return result)
      sorted)))

(defun elfeed-ai-summary--entries-from-feeds (feeds limit)
  "Collect recent entries from FEEDS limited to LIMIT results."
  (elfeed-ai-summary--sort-and-limit
   (cl-loop for feed in (elfeed-ai-summary--ensure-list feeds)
            when (and feed (fboundp 'elfeed-feed-p) (elfeed-feed-p feed))
            append (elfeed-ai-summary--normalize-entry-list (elfeed-feed-entries feed)))
   limit))

(defun elfeed-ai-summary--normalize-tags (tags)
  "Normalize TAGS into a list of unique, non-empty symbols."
  (let ((result nil))
    (cl-loop for tag in (elfeed-ai-summary--ensure-list tags)
             for symbol = (cond
                           ((null tag) nil)
                           ((stringp tag)
                            (let ((trimmed (string-trim tag)))
                              (unless (string-empty-p trimmed)
                                (intern trimmed))))
                           ((symbolp tag) tag)
                           (t (intern (format "%s" tag))))
             do (when (and symbol (keywordp symbol))
                  (let* ((name (symbol-name symbol))
                         (stripped (and (> (length name) 1)
                                        (substring name 1))))
                    (when stripped
                      (setq symbol (intern stripped)))))
             when symbol
             unless (memq symbol result)
             do (push symbol result)
             finally return (nreverse result))))

(defun elfeed-ai-summary--entries-from-tags-scan (tags limit)
  "Collect entries that match TAGS by scanning the Elfeed database.
LIMIT restricts the number of results when positive."
  (let ((collected nil)
        (count 0)
        (max (and limit (> limit 0) limit)))
    (when (and tags (fboundp 'with-elfeed-db-visit))
      (with-elfeed-db-visit (entry _feed)
        (when (cl-every (lambda (tag)
                          (memq tag (elfeed-entry-tags entry)))
                        tags)
          (push entry collected)
          (when max
            (setq count (1+ count))
            (when (and (fboundp 'elfeed-db-return)
                       (>= count max))
              (elfeed-db-return))))))
    collected))

(defun elfeed-ai-summary--entries-from-tags (tags limit)
  "Collect entries matching TAGS limited to LIMIT results."
  (let ((normalized-tags (elfeed-ai-summary--normalize-tags tags)))
    (when (and normalized-tags (not (fboundp 'with-elfeed-db-visit)))
      (user-error "Elfeed database helpers are unavailable"))
    (let ((entries (and normalized-tags
                        (elfeed-ai-summary--entries-from-tags-scan
                         normalized-tags limit))))
      (elfeed-ai-summary--sort-and-limit entries limit))))

(defun elfeed-ai-summary--entries-from-query-scan (query limit)
  "Collect entries that satisfy QUERY by evaluating it against the database.
LIMIT restricts the number of results when positive."
  (require 'elfeed-search nil t)
  (unless (and (fboundp 'elfeed-search-parse-filter)
               (fboundp 'with-elfeed-db-visit))
    (user-error "Elfeed search helpers are unavailable"))
  (let* ((filter (elfeed-search-parse-filter query))
         (collected nil)
         (count 0)
         (max (and limit (> limit 0) limit))
         (compiled (when (and (boundp 'elfeed-search-compile-filter)
                              elfeed-search-compile-filter)
                     (let ((lexical-binding t))
                       (byte-compile (elfeed-search-compile-filter filter))))))
    (with-elfeed-db-visit (entry feed)
      (when (if compiled
                (funcall compiled entry feed count)
              (elfeed-search-filter filter entry feed count))
        (push entry collected)
        (setq count (1+ count))
        (when (and max (>= count max) (fboundp 'elfeed-db-return))
          (elfeed-db-return))))
    collected))

(defun elfeed-ai-summary--entries-from-query (query limit)
  "Collect entries by running QUERY string, limiting to LIMIT results."
  (unless (and (stringp query) (not (string-empty-p query)))
    (user-error "Invalid query for elfeed-ai-summary"))
  (let ((entries (cond
                  ((fboundp 'with-elfeed-db-visit)
                   (elfeed-ai-summary--entries-from-query-scan query limit))
                  (t
                   (user-error "Elfeed search helpers are unavailable")))))
    (elfeed-ai-summary--sort-and-limit entries limit)))

(defun elfeed-ai-summary--summary-entries-at-point ()
  "Return a list of recent entries for the summary item at point."
  (unless (derived-mode-p 'elfeed-summary-mode)
    (user-error "Not in elfeed-summary-mode"))
  (unless (featurep 'elfeed-summary)
    (require 'elfeed-summary nil t))
  (let* ((button (or (get-char-property (point) 'button)
                     (user-error "No summary node at point")))
         (limit elfeed-ai-summary-category-feeds-count))
    (or (elfeed-ai-summary--sort-and-limit (widget-get button :entries) limit)
        (let ((entry (widget-get button :entry)))
          (when entry
            (elfeed-ai-summary--sort-and-limit (list entry) limit)))
        (elfeed-ai-summary--entries-from-feeds
         (or (widget-get button :feeds)
             (let ((feed (widget-get button :feed)))
               (when feed (list feed))))
         limit)
        (elfeed-ai-summary--entries-from-tags
         (or (widget-get button :tags)
             (let ((tag (widget-get button :tag)))
               (when tag (list tag))))
         limit)
        (let ((query (widget-get button :query)))
          (when query
            (elfeed-ai-summary--entries-from-query query limit))))))

(defun elfeed-ai-summary--current-buffer ()
  "Return the current buffer, forcing a live buffer or nil."
  (let ((buffer (current-buffer)))
    (and (buffer-live-p buffer) buffer)))

(defun elfeed-ai-summary-for-entry ()
  "Generate an AI summary for the Elfeed entry at point."
  (interactive)
  (elfeed-ai-summary--ensure-dependencies)
  (let* ((entry (elfeed-ai-summary--entry-at-point))
         (content (elfeed-ai-summary--entry-content-string entry)))
    (unless (and entry (not (string-empty-p content)))
      (user-error "No usable content found for this entry"))
    (let* ((prompt (format elfeed-ai-summary-prompt-template-for-single-entry
                           (or (elfeed-entry-title entry) "")
                           content))
           (origin (elfeed-ai-summary--current-buffer)))
      (message "Requesting AI summary for '%s'..." (elfeed-entry-title entry))
      (message prompt)
      (elfeed-ai-summary--call-gptel
       prompt
       (lambda (summary)
         (when (and summary origin (buffer-live-p origin))
           (with-current-buffer origin
             (elfeed-ai-summary--display-summary summary entry))))))))


(defun elfeed-ai-summary-for-category ()
  "Generate an AI summary for the summary node at point."
  (interactive)
  (elfeed-ai-summary--ensure-dependencies)
  (let* ((entries (elfeed-ai-summary--summary-entries-at-point)))
    (unless entries
      (user-error "No entries found for this category"))
    (let* ((formatted (elfeed-ai-summary--format-entries-for-summary entries))
           (prompt (format elfeed-ai-summary-prompt-template-for-multiple-entries
                           formatted))
           (origin (elfeed-ai-summary--current-buffer)))
      (message "Requesting AI category summary (%d entries)..." (length entries))
      (elfeed-ai-summary--call-gptel
       prompt
       (lambda (summary)
         (when (and summary origin (buffer-live-p origin))
           (with-current-buffer origin
             (elfeed-ai-summary--display-summary summary))))))))

(defun elfeed-ai-summary--collect-all-tags ()
  "Return all tag symbols currently present in the Elfeed database."
  (when (fboundp 'with-elfeed-db-visit)
    (let ((table (make-hash-table :test #'eq)))
      (with-elfeed-db-visit (entry _feed)
        (dolist (tag (elfeed-entry-tags entry))
          (puthash tag t table)))
      (let (result)
        (maphash (lambda (tag _value) (push tag result)) table)
        (sort result
              (lambda (a b)
                (string-lessp (symbol-name a)
                              (symbol-name b))))))))

(defun elfeed-ai-summary--all-tags ()
  "Return a list of all known Elfeed tags as strings."
  (let* ((symbols (or (and (fboundp 'elfeed-db-get-all-tags)
                            (ignore-errors (elfeed-db-get-all-tags)))
                      (elfeed-ai-summary--collect-all-tags)))
         (strings (mapcar (lambda (tag)
                            (if (symbolp tag)
                                (symbol-name tag)
                              (format "%s" tag)))
                          (or symbols '()))))
    (sort (cl-remove-duplicates strings :test #'string=)
          #'string-lessp)))

(defun elfeed-ai-summary--insert-org-report (summary)
  "Insert SUMMARY into the current Org buffer as a new heading."
  (require 'org)
  (let* ((headline (format elfeed-ai-summary-org-report-headline-format
                           (format-time-string "%Y-%m-%d")))
         (org-insert-heading-respect-content t))
    (unless (bolp)
      (insert "\n"))
    (org-insert-heading)
    (insert headline)
    (insert "\n\n" summary "\n")))

(defun elfeed-ai-summary-for-org-report (tags)
  "Generate an AI report for TAGS and insert it into the Org buffer.
When called interactively prompt for tags using completion."
  (interactive
   (list
    (let ((available (elfeed-ai-summary--all-tags)))
      (unless available
        (user-error "No Elfeed tags available"))
      (completing-read-multiple "Tags for report: " available nil t))))
  (elfeed-ai-summary--ensure-dependencies)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command must be run from an Org buffer"))
  (let* ((tag-symbols (elfeed-ai-summary--normalize-tags tags))
         (entries (elfeed-ai-summary--entries-from-tags
                   tag-symbols
                   elfeed-ai-summary-category-feeds-count)))
    (unless entries
      (user-error "No entries found for selected tags"))
    (let* ((formatted (elfeed-ai-summary--format-entries-for-summary entries))
           (prompt (format elfeed-ai-summary-prompt-template-for-multiple-entries
                           formatted))
           (origin (elfeed-ai-summary--current-buffer)))
      (message "Requesting AI Org report for tags: %s" (string-join tags ", "))
      (elfeed-ai-summary--call-gptel
       prompt
       (lambda (summary)
         (when (and summary origin (buffer-live-p origin))
           (with-current-buffer origin
             (elfeed-ai-summary--insert-org-report summary))))))))

(defun elfeed-ai-summary-auto-summary-function-for-hook (&optional entry)
  "Generate an automatic summary for ENTRY when hooks request it."
  (when elfeed-ai-summary-auto-summary-hook
    (let* ((entry (or entry (and (boundp 'elfeed-show-entry) elfeed-show-entry)))
           (buffer (elfeed-ai-summary--current-buffer)))
      (when (and entry buffer)
        (let ((content (elfeed-ai-summary--entry-content-string entry)))
          (if (string-empty-p content)
              (message "elfeed-ai-summary: entry has no content to summarize")
            (let ((prompt (format elfeed-ai-summary-prompt-template-for-single-entry
                                  (or (elfeed-entry-title entry) "")
                                  content)))
              (elfeed-ai-summary--call-gptel
               prompt
               (lambda (summary)
                 (when (and summary (buffer-live-p buffer))
                   (with-current-buffer buffer
                     (elfeed-ai-summary--display-summary summary entry))))))))))))

(defun elfeed-ai-summary-enable-auto-summary ()
  "Enable automatic AI summaries in `elfeed-show-mode'."
  (interactive)
  (setq elfeed-ai-summary-auto-summary-hook t)
  (add-hook 'elfeed-show-entry-switch-hook
            #'elfeed-ai-summary-auto-summary-function-for-hook))

(defun elfeed-ai-summary-disable-auto-summary ()
  "Disable automatic AI summaries in `elfeed-show-mode'."
  (interactive)
  (setq elfeed-ai-summary-auto-summary-hook nil)
  (remove-hook 'elfeed-show-entry-switch-hook
               #'elfeed-ai-summary-auto-summary-function-for-hook))

(defun elfeed-ai-summary-toggle-auto-summary ()
  "Toggle automatic AI summaries in `elfeed-show-mode'."
  (interactive)
  (if elfeed-ai-summary-auto-summary-hook
      (elfeed-ai-summary-disable-auto-summary)
    (elfeed-ai-summary-enable-auto-summary)))

(when (fboundp 'add-variable-watcher)
  (add-variable-watcher
   'elfeed-ai-summary-auto-summary-hook
   (lambda (_symbol new-value _operation _where)
     (if new-value
         (add-hook 'elfeed-show-entry-switch-hook
                   #'elfeed-ai-summary-auto-summary-function-for-hook)
       (remove-hook 'elfeed-show-entry-switch-hook
                    #'elfeed-ai-summary-auto-summary-function-for-hook)))))

(when elfeed-ai-summary-auto-summary-hook
  (add-hook 'elfeed-show-entry-switch-hook
            #'elfeed-ai-summary-auto-summary-function-for-hook))

(defun elfeed-ai-summary-check-gptel-config ()
  "Check GPTel configuration and display current settings."
  (interactive)
  (let ((buffer (get-buffer-create "*GPTel Configuration*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "GPTel Configuration Check:\n")
        (insert "==========================\n\n")
        
        (insert (format "GPTel loaded: %s\n" (featurep 'gptel)))
        (insert (format "gptel-request function available: %s\n" (fboundp 'gptel-request)))
        
        (if (boundp 'gptel-model)
            (insert (format "gptel-model: %s\n" gptel-model))
          (insert "gptel-model: NOT SET\n"))
        
        (if (boundp 'gptel-backend)
            (insert (format "gptel-backend: %s\n" gptel-backend))
          (insert "gptel-backend: NOT SET\n"))
        
        (if (boundp 'gptel-api-key)
            (insert (format "gptel-api-key: %s\n" (if gptel-api-key "SET" "NOT SET")))
          (insert "gptel-api-key: NOT SET\n"))
        
        (when (boundp 'gptel--backends)
          (insert (format "Available backends: %s\n" (mapcar #'car gptel--backends))))
        
        (insert "\nTo configure GPTel, you typically need to:\n")
        (insert "1. Set gptel-model (e.g., \"gpt-3.5-turbo\")\n")
        (insert "2. Set gptel-backend (e.g., gptel-openai)\n")
        (insert "3. Set gptel-api-key or configure authentication\n\n")
        
        (insert "Example configuration:\n")
        (insert "(setq gptel-model \"gpt-3.5-turbo\"\n")
        (insert "      gptel-backend gptel-openai\n")
        (insert "      gptel-api-key \"your-api-key\")\n")
        
        (goto-char (point-min))
        (view-mode 1)))
    (display-buffer buffer)))

(defun elfeed-ai-summary-test-gptel ()
  "Test GPTel integration with a sample prompt."
  (interactive)
  (condition-case err
      (progn
        (elfeed-ai-summary--ensure-dependencies)
        (let ((test-prompt "请为以下文章生成一个简洁的中文摘要，包含其核心观点和主要信息。文章标题：'Dual Modes of Gene Regulation by CDK12'，内容如下：The process of transcription is driven forward by the activity of kinases including CDK7, CDK9 and CDK12. Accordingly, acute inhibition of any of these kinases results in profound downregulation of gene expression. Here, we discover that loss or inhibition of CDK12 also significantly upregulates a set of coding and non-coding loci, whose activation could contribute to the anti-proliferative effects of CDK12 inhibitors. Mechanistically, CDK12 inhibition impairs transcription elongation, leading to increased RNA polymerase II termination or arrest in long genes. However, short genes such as MYC and enhancer RNAs are highly transcribed in the absence of CDK12 activity. Indeed, in HER2+ breast cancer, a malignancy where CDK12 is co-amplified with HER2 and its expression correlates with disease status, CDK12 inhibition markedly elevates MYC expression to induce lethality. The dual effects of CDK12 inhibition elucidated herein clarify its role in transcriptional control and have significant translational implications."))
          (message "Starting GPTel test...")
          (elfeed-ai-summary--call-gptel
           test-prompt
           (lambda (summary)
             (message "GPTel test completed successfully!")
             (let ((buffer (get-buffer-create "*GPTel Test Result*")))
               (with-current-buffer buffer
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert "GPTel Test Result:\n")
                   (insert "==================\n\n")
                   (insert summary)
                   (goto-char (point-min))
                   (view-mode 1)))
               (display-buffer buffer))))))
    (error
     (message "GPTel test failed: %s" err)
     (message "Running configuration check...")
     (elfeed-ai-summary-check-gptel-config))))

(provide 'elfeed-ai-summary)

;;; elfeed-ai-summary.el ends here
