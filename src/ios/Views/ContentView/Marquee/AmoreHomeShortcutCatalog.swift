import Foundation

/// Curated Amore entry points, not promises of Poki's app-automation workflows.
/// Every prompt is only a draft; every page is checked against the actual router.
enum AmoreHomeShortcutCatalog {
    static var items: [AmoreHomeShortcut] {
        items(chinese: Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    static func items(chinese: Bool) -> [AmoreHomeShortcut] {
        func prompt(_ id: String, _ zh: String, _ en: String, _ symbol: String,
                    _ zhPrompt: String, _ enPrompt: String) -> AmoreHomeShortcut {
            .init(id: id, appName: "Amore", title: chinese ? zh : en, symbol: symbol,
                  action: .init(kind: .prompt, value: chinese ? zhPrompt : enPrompt))
        }
        func page(_ id: String, _ zh: String, _ en: String, _ symbol: String, _ path: String) -> AmoreHomeShortcut {
            .init(id: id, appName: "Amore", title: chinese ? zh : en, symbol: symbol,
                  action: .init(kind: .page, value: path))
        }
        return [
            prompt("new-task", "拆解任务", "Plan a task", "checklist",
                   "请帮我把下面的目标拆成可执行步骤，标出优先级、所需信息和验收标准。目标：", "Break this goal into actionable steps, priorities, required information and acceptance criteria. Goal: "),
            prompt("summarize", "总结重点", "Summarize text", "text.alignleft",
                   "请总结以下内容，列出关键结论、待办事项和不确定的信息。内容：", "Summarize this content into key conclusions, action items and uncertainties. Content: "),
            prompt("code", "编写代码", "Write code", "chevron.left.forwardslash.chevron.right",
                   "请根据以下需求编写代码，说明运行方式、边界条件并补充测试。需求：", "Write code for the following requirements, with run instructions, edge cases and tests. Requirements: "),
            prompt("translate", "翻译润色", "Translate text", "character.bubble",
                   "请翻译以下文字，保留原意与格式，并简要解释容易误解的表达。目标语言：\n原文：", "Translate the following text, preserving meaning and formatting, and explain ambiguous expressions. Target language:\nText: "),
            prompt("writing", "起草文案", "Draft writing", "square.and.pencil",
                   "请帮我起草以下文案，先确认受众、用途和语气，再给出可编辑的版本。主题：", "Help draft this text. Clarify the audience, purpose and tone, then provide an editable draft. Topic: "),
            prompt("explain", "讲解知识", "Explain a concept", "lightbulb",
                   "请由浅入深解释以下概念，提供一个例子并指出常见误区。概念：", "Explain this concept from first principles, give an example and identify common misconceptions. Concept: "),
            prompt("debug", "排查问题", "Debug a problem", "ladybug",
                   "请分析以下问题，区分已知事实与猜测，给出最小复现、排查步骤和修复建议。问题与日志：", "Analyze this problem, separate facts from hypotheses, and propose a minimal reproduction, diagnostic steps and fixes. Problem and logs: "),
            prompt("compare", "比较方案", "Compare options", "arrow.left.arrow.right",
                   "请比较以下方案，从成本、收益、风险和适用场景给出对照表，并说明还缺哪些信息。方案：", "Compare these options by cost, benefits, risks and fit, and identify missing information. Options: "),
            prompt("weekly-plan", "安排本周", "Plan the week", "calendar",
                   "请根据以下目标、空闲时间和截止日期制定一周计划，预留缓冲时间；先给出计划草稿，不创建日历或提醒。我的安排：", "Create a weekly plan from these goals, availability and deadlines, leaving buffer time. Draft only; do not create calendar events or reminders. Schedule: "),
            prompt("research", "整理研究", "Research a topic", "magnifyingglass",
                   "请帮我研究以下问题，优先使用可核验的来源，区分事实、推断与未知；不能联网时请明确说明。问题：", "Research this question with verifiable sources, separating facts, inferences and unknowns. State explicitly if live web access is unavailable. Question: "),
            page("providers", "模型提供商", "Model providers", "server.rack", "providers"),
            page("model-groups", "模型分组", "Model groups", "square.stack.3d.up", "model-groups"),
            page("skills", "管理技能", "Manage skills", "sparkles", "skills"),
            page("memory", "记忆设置", "Memory settings", "brain.head.profile", "memory"),
            page("settings", "外观设置", "Appearance", "paintpalette", "appearance"),
            page("rootfs", "运行环境", "Manage runtime", "shippingbox", "rootfs"),
            page("storage", "存储管理", "Manage storage", "internaldrive", "storage"),
            page("shortcuts", "管理胶囊", "Manage shortcuts", "slider.horizontal.3", "shortcuts")
        ]
    }
}
