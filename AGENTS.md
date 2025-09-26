# Repository Guidelines

## Project Structure & Module Organization
The repository is intentionally compact. `elfeed-ai-summary.el` houses the entire Emacs Lisp package, including interactive commands, helpers, and customisation variables. `README.md` documents end-user setup, while `design_plan.md` records the architectural rationale; keep both in sync when behaviour changes. Place experimental helpers in feature branches until they are stable enough to merge into `elfeed-ai-summary.el`, and mirror any new personal configuration snippets under an `examples/` folder before publishing.

## Build, Test, and Development Commands
Run `emacs --batch -Q -L . -l elfeed-ai-summary.el -f batch-byte-compile elfeed-ai-summary.el` to verify the file byte-compiles cleanly. When iterating interactively, load the package in a scratch Emacs with `(load-file "elfeed-ai-summary.el")` to exercise commands in Elfeed buffers. If you add a test harness, prefer invoking `emacs --batch -Q -L . -l test/elfeed-ai-summary-tests.el -f ert-run-tests-batch-and-exit`.

## Coding Style & Naming Conventions
Follow standard Emacs Lisp conventions: two-space indentation, docstrings in imperative mood, and function or variable names prefixed with `elfeed-ai-summary-`. Maintain lexical binding and avoid introducing global state outside the package namespace. Use `checkdoc` before opening a PR and keep prompts or strings ASCII-compatible unless localisation is intentional.

## Testing Guidelines
Adopt ERT for regression coverage. Name test files `test/elfeed-ai-summary-*.el` and individual tests `ert-deftest elfeed-ai-summary--feature-scenario`. Target new behaviour with focused assertions and stub GPTel interactions where necessary. Ensure every feature branch passes `ert-run-tests-batch-and-exit`, and add fixtures or sample entries under `test/data/` if you need reproducible feeds.

## Commit & Pull Request Guidelines
Write commits in imperative present tense (e.g., “Add category summary formatter”) and limit scope to a single logical change. Reference relevant issues in the body, describe manual test steps, and note any user-facing configuration changes. Pull requests should summarise motivation, list verification steps (byte-compile, tests, manual checks), and include screenshots or GIFs only when UI behaviour is affected.

## Security & Configuration Tips
Do not commit API keys or `gptel` credentials; rely on user-local Emacs configuration. When sharing prompt templates, redact sensitive feed data. Flag any dependency upgrades that might alter network behaviour so reviewers can evaluate the impact.
