# elfeed-ai-summary

`elfeed-ai-summary` integrates [Elfeed](https://github.com/skeeto/elfeed) with [gptel](https://github.com/karthink/gptel) to generate AI powered summaries for feeds, categories, and Org-mode reports directly inside Emacs. The package offers interactive commands as well as optional automation so you can skim large volumes of content quickly without leaving Elfeed.

## Features

- Summarise the entry at point from `elfeed-search-mode` or `elfeed-show-mode`.
- Summarise an entire feed or group from `elfeed-summary-mode` with a single command.
- Generate Org-mode reports that aggregate multiple tags or feeds into a dated headline.
- Optional automatic summarisation whenever a new `elfeed-show` buffer is displayed.
- Customisable prompt templates, output destinations, and streaming behaviour via `defcustom` options.

## Requirements

- Emacs 27.1 or newer (Org integration tested on Emacs 28+).
- [`elfeed`](https://github.com/skeeto/elfeed).
- [`gptel`](https://github.com/karthink/gptel).
- [`elfeed-summary`](https://github.com/SqrtMinusOne/elfeed-summary) (optional, required for category summaries).

Make sure `gptel` is configured with a backend (OpenAI, Claude, Gemini, etc.) before using the commands below.

## Installation

Clone the repository somewhere on your `load-path` and require it from your init file:

```emacs-lisp
(use-package elfeed-ai-summary
  :load-path "/path/to/elfeed-ai-summary"
  :after (elfeed gptel)
  :commands (elfeed-ai-summary-for-entry
             elfeed-ai-summary-for-category
             elfeed-ai-summary-for-org-report)
  :init
  ;; Optional: enable automatic summaries when showing entries.
  ;; (elfeed-ai-summary-enable-auto-summary)
  )
```

If you prefer manual configuration, simply `(require 'elfeed-ai-summary)` after loading Elfeed and gptel.

## Interactive Commands

| Command | Context | Description |
| --- | --- | --- |
| `elfeed-ai-summary-for-entry` | `elfeed-search-mode`, `elfeed-show-mode` | Summarise the entry at point. Summaries in `elfeed-show-mode` are appended to the current buffer; summaries from `elfeed-search-mode` appear in a dedicated buffer. |
| `elfeed-ai-summary-for-category` | `elfeed-summary-mode` | Summarise the feed or group under point, collecting the most recent entries based on `elfeed-ai-summary-category-feeds-count`. |
| `elfeed-ai-summary-for-org-report` | `org-mode` | Prompt for one or more Elfeed tags and insert an AI-generated report under a new headline. |

You can bind these commands to keys of your choice, e.g.:

```emacs-lisp
(with-eval-after-load 'elfeed-search
  (define-key elfeed-search-mode-map (kbd "S") #'elfeed-ai-summary-for-entry))
(with-eval-after-load 'elfeed-show
  (define-key elfeed-show-mode-map (kbd "S") #'elfeed-ai-summary-for-entry))
(with-eval-after-load 'elfeed-summary
  (define-key elfeed-summary-mode-map (kbd "S") #'elfeed-ai-summary-for-category))
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c C-e s") #'elfeed-ai-summary-for-org-report))
```

## Automatic Summaries

To request a summary every time a new `elfeed-show` buffer appears, enable the auto-summary helper:

```emacs-lisp
(elfeed-ai-summary-enable-auto-summary)
```

Toggle or disable the behaviour with `elfeed-ai-summary-toggle-auto-summary` and `elfeed-ai-summary-disable-auto-summary`. The helper respects `elfeed-ai-summary-auto-summary-hook`, so you can also customise that variable directly when loading the package.

## Configuration

The following user options control the package:

- `elfeed-ai-summary-category-feeds-count` (default `10`): maximum number of recent entries collected for feed or group summaries.
- `elfeed-ai-summary-auto-summary-hook` (default `nil`): when non-nil, automatically summarise entries as they open in `elfeed-show-mode`.
- `elfeed-ai-summary-prompt-template-for-single-entry`: template string for single-entry prompts. `%s` placeholders are replaced with the title and the body text.
- `elfeed-ai-summary-prompt-template-for-multiple-entries`: template string used when summarising multiple entries.
- `elfeed-ai-summary-org-report-headline-format` (default `"AI 新闻简报: %s"`): `format` string used for the inserted Org headline. The placeholder receives the current date.
- `elfeed-ai-summary-use-streaming` (default `t`): whether requests should ask gptel for streaming output.

Because the prompts are plain strings, you can easily switch languages or inject extra instructions. For example:

```emacs-lisp
(setq elfeed-ai-summary-prompt-template-for-single-entry
      "Summarise the following article in English bullet points.")
```

## Org Reports

`elfeed-ai-summary-for-org-report` targets the current Org buffer. After selecting one or more tags (completion supports multi selection), the generated report is inserted beneath a new headline formatted with `elfeed-ai-summary-org-report-headline-format`. The command reuses the multi-entry prompt template, so adjust that variable if you want reports in a different language or style.

## Notes

- Large category summaries can produce long prompts. Reduce `elfeed-ai-summary-category-feeds-count` if you run into backend limits.
- The package always requires both Elfeed and gptel to be loaded; `elfeed-summary` is optional but adds category support.
- Errors from gptel (authentication, network, etc.) are surfaced as regular Emacs `user-error`s for easier debugging.

## Contributing

Bug reports and patches are welcome. After making changes, run `byte-compile-file` on `elfeed-ai-summary.el` to catch syntax issues, and include usage notes or config examples when relevant.
