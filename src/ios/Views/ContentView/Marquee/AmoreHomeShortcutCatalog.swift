import Foundation

/// Curated Amore entry points, not promises of Poki's app-automation workflows.
/// Every prompt is only a draft; every page is checked against the actual router.
enum AmoreHomeShortcutCatalog {
    static var items: [AmoreHomeShortcut] {
        items(chinese: (UserDefaults.standard.string(forKey: "appLanguage").flatMap { $0.isEmpty ? nil : $0 } ?? Locale.preferredLanguages.first ?? "en").hasPrefix("zh"))
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
        func phone(_ id: String, _ app: String, _ zh: String, _ en: String, _ symbol: String,
                   _ zhTask: String, _ enTask: String) -> AmoreHomeShortcut {
            let policy = chinese
                ? "请使用 Amore 已连接的 iPhone 设备工具完成任务。先用 device_control 检查连接；未开启或配置不完整时说明缺少什么，不要假装操作。需要登录时停下来让我自行登录。发送消息、发布内容、付款、下单或删除前先让我明确确认。任务："
                : "Use Amore's connected iPhone device tools. Check the connection with device_control first; if disabled or incomplete, explain what is missing rather than claim an action. Let me sign in myself. Ask for explicit confirmation before sending, publishing, paying, ordering or deleting. Task: "
            return .init(id: "phone-" + id, appName: app, title: app + " · " + (chinese ? zh : en), symbol: symbol,
                         action: .init(kind: .prompt, value: policy + (chinese ? zhTask : enTask)))
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
            phone("wechat", "WeChat", "发消息", "Send a message", "message", "在微信给以下联系人发送消息。联系人和内容：", "Send a WeChat message. Contact and message: "),
            phone("taobao", "Taobao", "查物流", "Check delivery", "shippingbox", "打开淘宝查看最新订单的物流状态。", "Open Taobao and check delivery for my latest order."),
            phone("dianping", "Dianping", "找附近餐厅", "Find restaurants", "fork.knife", "在大众点评查找附近评分高的餐厅。", "Find top-rated nearby restaurants on Dianping."),
            phone("meituan", "Meituan", "选外卖", "Find takeout", "takeoutbag.and.cup.and.straw", "打开美团外卖查找附近好吃的外卖。", "Find good takeout nearby in Meituan Waimai."),
            phone("pinduoduo", "Pinduoduo", "查订单", "Check orders", "bag", "打开拼多多查看我的订单状态。", "Open Pinduoduo and check my order status."),
            phone("xiaohongshu", "Xiaohongshu", "搜攻略", "Search guides", "book", "在小红书搜索攻略。主题：", "Search Xiaohongshu for guides. Topic: "),
            phone("xianyu", "Xianyu", "查看商品消息", "Check listings", "bubble.left.and.bubble.right", "打开闲鱼查看我发布的商品有没有新消息。", "Open Xianyu and check for new messages on my listings."),
            phone("jd", "JD", "查价格", "Check prices", "tag", "在京东查看以下商品价格。商品：", "Check this product's price in JD. Product: "),
            phone("baidu-maps", "Baidu Maps", "导航回家", "Navigate home", "map", "打开百度地图规划回家的路线。", "Open Baidu Maps and plan my route home."),
            phone("amap", "Amap", "查路线", "Check routes", "location", "打开高德地图查看前往以下目的地的路线。目的地：", "Open Amap and check the route to this destination: "),
            phone("slack", "Slack", "通知团队迟到", "Tell the team I'm late", "person.3", "打开 Slack 起草给团队的迟到消息。频道和内容：", "Draft a Slack message telling the team I'm late. Channel and details: "),
            phone("messages", "Messages", "发短信", "Text Mom", "message.fill", "在信息中起草给妈妈的短信：我在路上了。", "Draft a text to Mom: I'm on my way."),
            phone("uber", "Uber", "规划叫车", "Book a ride home", "car", "打开 Uber 规划回家的行程，展示价格，等待我确认下单。", "Open Uber, plan a ride home, show the price and wait for my confirmation before booking."),
            phone("starbucks", "Starbucks", "准备常喝咖啡", "My usual coffee", "cup.and.saucer", "打开星巴克准备我常喝的咖啡，先展示订单等待确认，不付款。", "Prepare my usual coffee in Starbucks, show the order and wait for confirmation. Do not pay."),
            phone("notes", "Notes", "添加购物清单", "Add milk to my list", "note.text", "打开备忘录，在我的购物清单添加牛奶。", "Open Notes and add milk to my shopping list."),
            phone("instagram", "Instagram", "准备今天照片", "Today's photo", "photo", "打开 Instagram 准备今天照片的发布草稿，发布前等待我确认。", "Prepare today's photo as an Instagram draft and wait for my confirmation before publishing."),
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
