# Elfeed AI Summary 设计与实施方案

本文档为 `elfeed-ai-summary` Emacs Lisp 包提供一个详细的设计和实施方案。

## 1. 核心目标

创建一个与 `elfeed` 生态系统无缝集成的 Emacs 扩展，利用 `gptel` 包提供的 AI 能力，为用户提供灵活、可定制的 Feed 总结功能，以提高信息处理效率。

## 2. 设计原则

*   **模块化**: 遵循 Emacs Lisp 最佳实践，代码应清晰、易于理解和维护。
*   **用户友好**: 提供简单直观的交互式函数和易于理解的配置选项。
*   **可扩展性**: 允许用户通过 `defcustom` 变量轻松定制提示词、行为等。
*   **最小依赖**: 仅依赖 `elfeed` 和 `gptel`，不引入非必要的复杂性。

## 3. 文件结构

考虑到包的功能相对集中，所有代码将存放在一个主文件中：

*   `elfeed-ai-summary.el`: 包含所有函数、变量和逻辑的核心文件。
*   `README.md`: 提供用户文档、安装指南和使用示例。

## 4. 核心组件设计

### 4.1. 配置变量 (`defcustom`)

这些变量将允许用户根据自己的需求定制包的行为。

```elisp
(defgroup elfeed-ai-summary nil
  "An Emacs package for summarizing elfeed entries using AI."
  :group 'elfeed)

(defcustom elfeed-ai-summary-category-feeds-count 10
  "在 elfeed-summary-mode 中，为每个分类总结的最新 Feed 数量。"
  :type 'integer
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-auto-summary-hook nil
  "在 elfeed-search-mode 中，当一个条目被打开（即其内容被获取）时自动进行总结的钩子。
这个钩子将被添加到 `elfeed-show-entry-switch-hook` 中。"
  :type 'boolean
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-prompt-template-for-single-entry
  "请为以下文章生成一个简洁的中文摘要，包含其核心观点和主要信息。文章标题：'%s'，内容如下：\n\n%s"
  "用于总结单个条目的提示词模板。
 `%s` 将被依次替换为条目标题和内容。"
  :type 'string
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-prompt-template-for-multiple-entries
  "请根据以下多篇文章，生成一份综合性的新闻报告。请识别出关键主题、共同趋势和重要事件，并以清晰的结构进行总结。文章列表如下：\n\n%s"
  "用于总结多个条目的提示词模板。
 `%s` 将被替换为格式化的多条目内容。"
  :type 'string
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-org-report-headline-format "AI 新闻简报: %s"
  "在 Org-mode 中插入新闻报告时使用的标题格式。
 `%s` 将被替换为当前日期。"
  :type 'string
  :group 'elfeed-ai-summary)

(defcustom elfeed-ai-summary-use-streaming t
  "是否使用流式响应来显示 AI 生成的摘要。"
  :type 'boolean
  :group 'elfeed-ai-summary)
```

### 4.2. 内部核心函数

这些是实现主要功能的辅助函数。

*   `elfeed-ai-summary--get-entry-at-point ()`
    *   **职责**: 获取当前 `elfeed-search-mode` 或 `elfeed-summary-mode` 光标下条目（entry）或条目集合。
    *   **实现思路**:
        *   在 `elfeed-search-mode` 中, 使用 `(elfeed-search-selected :ignore-region)` 来获取光标下的单个 `elfeed-entry`。
        *   在 `elfeed-summary-mode` 中, 通过分析光标下的 widget 属性 (`widget-get (get-char-property (point) 'button) ...`) 来确定是 `feed` 还是 `group`，然后获取相应的 `entry` 列表。

*   `elfeed-ai-summary--format-entries-for-summary (entries)`
    *   **职责**: 将一个或多个 `elfeed-entry` 结构格式化为适合传递给 AI 的单个字符串。
    *   **实现思路**: 遍历 `entries` 列表，对每个条目，提取 `title` 和 `content`。将它们格式化为 "标题: [title]\n内容: [content]\n---\n" 的形式，然后拼接在一起。

*   `elfeed-ai-summary--call-gptel (prompt callback)`
    *   **职责**: 封装对 `gptel-request` 的调用。处理同步/异步逻辑，并将结果传递给回调函数。
    *   **实现思路**:
        1.  调用 `gptel-request` 并传入 `prompt`。
        2.  使用 `elfeed-ai-summary-use-streaming` 变量来控制 `:stream` 参数。
        3.  提供一个统一的 `:callback` 函数，该函数负责处理 `gptel` 返回的响应（无论是完整的还是流式的），并将最终的纯文本结果传递给作为参数传入的 `callback`。

*   `elfeed-ai-summary--insert-summary (summary entry)`
    *   **职责**: 将 AI 返回的 `summary` 显示出来。根据上下文决定显示方式。
    *   **实现思路**:
        *   如果当前在 `elfeed-show-mode` 缓冲区（通过检查 `elfeed-show-entry` 变量是否与 `entry` 匹配），则直接将 `summary` 插入到当前缓冲区内容的末尾，并添加一个明确的分隔符。
        *   在其他情况下（如 `elfeed-summary-mode` 或 `org-mode`），在一个新的专用缓冲区（例如 `*AI Summary: [Entry Title]*`）中显示 `summary`。

### 4.3. 交互式函数 (Interactive Functions)

这些是直接面向用户的功能。

*   `elfeed-ai-summary-for-category ()`
    *   **模式**: `elfeed-summary-mode`
    *   **职责**: 总结光标下分类的最近 N 篇 Feeds。
    *   **实现思路**:
        1.  从 `elfeed-summary-mode` 的当前行确定是 `feed` 还是 `group`。
        2.  如果是 `feed`，获取其最近的 `elfeed-ai-summary-category-feeds-count` 条 `entry`。
        3.  如果是 `group`，获取该组下所有 `feed` 的最近条目。
        4.  调用 `elfeed-ai-summary--format-entries-for-summary` 格式化内容。
        5.  使用 `elfeed-ai-summary-prompt-template-for-multiple-entries` 构建提示词。
        6.  调用 `elfeed-ai-summary--call-gptel` 发送请求，回调函数将结果插入一个新的临时缓冲区（例如 `*AI Summary*`）。

*   `elfeed-ai-summary-for-entry ()`
    *   **模式**: `elfeed-search-mode`
    *   **职责**: 总结光标下的单个条目。
    *   **实现思路**:
        1.  调用 `elfeed-ai-summary--get-entry-at-point` 获取当前条目 `entry`。
        2.  调用 `elfeed-ai-summary--format-entries-for-summary` 格式化内容。
        3.  使用 `elfeed-ai-summary-prompt-template-for-single-entry` 构建提示词。
        4.  调用 `elfeed-ai-summary--call-gptel` 并将 `entry` 传入。回调函数 `elfeed-ai-summary--insert-summary` 会根据上下文智能地决定是在当前 `elfeed-show-mode` 缓冲区内插入摘要，还是打开一个新窗口。

*   `elfeed-ai-summary-for-org-report ()`
    *   **模式**: `org-mode`
    *   **职责**: 在 Org 文件中，让用户选择一个或多个 `elfeed` 分类（tags），总结这些分类下的最新 Feeds，并将结果作为新闻报告插入当前缓冲区。
    *   **实现思路**:
        1.  使用 `completing-read-multiple` 让用户从所有可用的 elfeed tags 中选择。
        2.  根据所选 tags，从 `elfeed-db` 中筛选出所有相关 `feed` 的最新条目。
        3.  调用 `elfeed-ai-summary--format-entries-for-summary`。
        4.  使用 `elfeed-ai-summary-prompt-template-for-multiple-entries` 构建提示词。
        5.  调用 `elfeed-ai-summary--call-gptel`，回调函数 `elfeed-ai-summary--insert-summary` 负责：
            a.  在当前 Org buffer 的光标位置下方插入一个新的标题（格式由 `elfeed-ai-summary-org-report-headline-format` 定义）。
            b.  将总结内容插入该标题下。

### 4.4. 自动总结钩子

*   `elfeed-ai-summary-auto-summary-function-for-hook (&optional _entry)`
    *   **职责**: 作为 `elfeed-show-entry-switch-hook` 的一部分被调用。Emacs 29+ 的 'elfeed-show-entry-switch-hook' 可以传递 entry 参数。
    *   **实现思路**:
        1.  此函数会检查 `elfeed-ai-summary-auto-summary-hook` 是否为 `t`。
        2.  如果是，它会获取当前 `elfeed-show-mode` 缓冲区对应的 `entry`。
        3.  然后执行与 `elfeed-ai-summary-for-entry` 类似的逻辑来生成并显示摘要。

*   **集成**:
    ```elisp
    (defun elfeed-ai-summary-setup-hooks ()
      (add-hook 'elfeed-show-entry-switch-hook #'elfeed-ai-summary-auto-summary-function-for-hook))
    ```
    这个函数将在包加载时被调用。

## 5. 实施步骤 (TODO List)

我将使用 `update_todo_list` 工具来创建和跟踪实施步骤。

[ ] 1. **项目初始化**: 创建 `elfeed-ai-summary.el` 和 `README.md` 文件。在 `.el` 文件中设置好包头信息 (Package-Requires, Version, etc.) 和 `defgroup`。
[ ] 2. **定义配置变量**: 实现第 4.1 节中设计的所有 `defcustom` 变量。
[ ] 3. **实现核心辅助函数**: 编码实现第 4.2 节中的 `elfeed-ai-summary--get-entry-content-at-point`，`elfeed-ai-summary--format-entries-for-summary` 和 `elfeed-ai-summary--call-gptel`。
[ ] 4. **实现单条目总结**: 编码 `elfeed-ai-summary-for-entry` 函数 (需求 3b)。这是最直接的功能，可以快速验证核心逻辑。
[ ] 5. **实现自动总结钩子**: 编码 `elfeed-ai-summary-auto-summary-function-for-hook` 并设置 `elfeed-show-entry-switch-hook` (需求 3c)。
[ ] 6. **实现分类总结**: 编码 `elfeed-ai-summary-for-category` 函数 (需求 3a)。
[ ] 7. **实现 Org 报告功能**: 编码 `elfeed-ai-summary-for-org-report` 函数 (需求 3e)。
[ ] 8. **撰写文档**: 填充 `README.md`，包括功能介绍、安装方法、配置示例和使用指南。
[ ] 9. **最终审查和清理**: 回顾所有代码，确保其符合设计原则，移除调试信息，并进行格式化。

---

现在，我将根据这个计划创建待办事项列表。