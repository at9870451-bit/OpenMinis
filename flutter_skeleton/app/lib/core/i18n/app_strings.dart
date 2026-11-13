import 'dart:ui';

import 'package:flutter/widgets.dart';

/// UI copy in the three languages the Swift app shipped.
///
/// The locale is never chosen in-app: it always follows the system setting
/// (`MaterialApp` has no fixed `locale`), and `of(context)` re-reads
/// `Localizations.localeOf` so a language change in iOS Settings applies on the
/// next rebuild. Simplified/Traditional Chinese are distinguished by scriptCode.
class AppStrings {
  const AppStrings(this.code);

  /// 'zh-Hans' | 'zh-Hant' | 'en'
  final String code;

  static const supportedLocales = <Locale>[
    Locale('en'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ];

  static AppStrings of(BuildContext context) =>
      AppStrings.fromLocale(Localizations.localeOf(context));

  static AppStrings fromLocale(Locale locale) {
    final lang = locale.languageCode.toLowerCase();
    if (lang == 'zh') {
      final script = (locale.scriptCode ?? '').toLowerCase();
      final country = (locale.countryCode ?? '').toUpperCase();
      final traditional = script == 'hant' ||
          (script.isEmpty &&
              const ['TW', 'HK', 'MO'].contains(country));
      return AppStrings(traditional ? 'zh-Hant' : 'zh-Hans');
    }
    return const AppStrings('en');
  }

  static AppStrings get system {
    final locales = PlatformDispatcher.instance.locales;
    return fromLocale(locales.isNotEmpty ? locales.first : const Locale('en'));
  }

  String _pick({required String en, required String hans, required String hant}) =>
      switch (code) {
        'zh-Hans' => hans,
        'zh-Hant' => hant,
        _ => en,
      };

  // Shell / sidebar
  String get appName => 'Amore';
  String get chats => _pick(en: 'Chats', hans: '会话', hant: '會話');
  String get chat => _pick(en: 'Chat', hans: '聊天', hant: '聊天');
  String get recent => _pick(en: 'Recent', hans: '最近', hant: '最近');
  String get noConversations =>
      _pick(en: 'No conversations yet', hans: '暂无会话', hant: '暫無會話');
  String get settings => _pick(en: 'Settings', hans: '设置', hant: '設定');
  String get newChat => _pick(en: 'New chat', hans: '新会话', hant: '新會話');
  String get history => _pick(en: 'History', hans: '历史', hant: '歷史');

  // Chat
  String get messageHint =>
      _pick(en: 'Message Amore', hans: '发消息给 Amore', hant: '傳訊息給 Amore');
  String get howCanIHelp =>
      _pick(en: 'How can I help?', hans: '有什么可以帮你？', hant: '有什麼可以幫你？');
  String get emptySubtitle => _pick(
        en: 'Ask anything, attach a file, or start with @',
        hans: '问点什么，或附加文件开始',
        hant: '問點什麼，或附加檔案開始',
      );
  String get copy => _pick(en: 'Copy', hans: '复制', hant: '複製');
  String get copied => _pick(en: 'Copied', hans: '已复制', hant: '已複製');
  String get regenerate => _pick(en: 'Regenerate', hans: '重新生成', hant: '重新產生');
  String get edit => _pick(en: 'Edit', hans: '编辑', hant: '編輯');
  String get stop => _pick(en: 'Stop', hans: '停止', hant: '停止');
  String get model => _pick(en: 'Model', hans: '模型', hant: '模型');

  // Settings
  String get models => _pick(en: 'Models', hans: '模型', hant: '模型');
  String get providersApiKeys => _pick(
      en: 'Providers & API Keys', hans: '服务商与 API 密钥', hant: '服務商與 API 金鑰');
  String get providersSubtitle => _pick(
      en: 'Catalog served by the Rust core',
      hans: '目录由 Rust 核心提供',
      hant: '目錄由 Rust 核心提供');
  String get appearance => _pick(en: 'Appearance', hans: '外观', hant: '外觀');
  String get themeTextSize => _pick(en: 'Theme & Text Size', hans: '主题与字体大小', hant: '主題與字體大小');
  String get themeSubtitle =>
      _pick(en: 'Light, dark or follow the system', hans: '浅色、深色或跟随系统', hant: '淺色、深色或跟隨系統');
  String get data => _pick(en: 'Data', hans: '数据', hant: '資料');
  String get storage => _pick(en: 'Storage', hans: '存储', hant: '儲存');
  String get storageSubtitle => _pick(en: 'Chat database and cache', hans: '会话数据库与缓存', hant: '會話資料庫與快取');
  String get agentRuntime => _pick(en: 'Agent Runtime', hans: '智能体运行时', hant: '智能體執行環境');
  String get agentTools => _pick(en: 'Agent Tools', hans: '可用工具', hant: '可用工具');
  String get subAgents => _pick(en: 'Sub Agents', hans: '子代理任务', hant: '子代理任務');
  String get skills => _pick(en: 'Skills', hans: '技能', hant: '技能');
  String get memory => _pick(en: 'Memory', hans: '记忆', hant: '記憶');
  String get mcpServers => _pick(en: 'MCP Servers', hans: 'MCP 服务', hant: 'MCP 服務');
  String get about => _pick(en: 'About', hans: '关于', hant: '關於');
  String get followSystem => _pick(en: 'Follow System', hans: '跟随系统', hant: '跟隨系統');
  String get light => _pick(en: 'Light', hans: '浅色', hant: '淺色');
  String get dark => _pick(en: 'Dark', hans: '深色', hant: '深色');
  String get sessions => _pick(en: 'Sessions', hans: '会话数', hant: '會話數');
  String get messages => _pick(en: 'Messages', hans: '消息数', hant: '訊息數');
  String get database => _pick(en: 'Database', hans: '数据库', hant: '資料庫');

  // Agent pages
  String get noSkillsInstalled => _pick(
      en: 'No skills installed.\n\nDrop a folder with SKILL.md into var/minis/skills.',
      hans: '暂无技能。\n\n把含 SKILL.md 的文件夹放进 var/minis/skills。',
      hant: '暫無技能。\n\n把含 SKILL.md 的資料夾放進 var/minis/skills。');
  String get noMemoryFiles => _pick(en: 'No memory files yet.', hans: '暂无记忆文件。', hant: '暫無記憶檔案。');
  String get noMcpServers => _pick(
      en: 'No MCP servers configured.\n\nAdd entries to var/minis/mcp-servers/servers.json.',
      hans: '暂无 MCP 服务。\n\n在 var/minis/mcp-servers/servers.json 中添加条目。',
      hant: '暫無 MCP 服務。\n\n在 var/minis/mcp-servers/servers.json 中加入項目。');
  String get emptyFile => _pick(en: 'This file is empty.', hans: '该文件为空。', hant: '該檔案為空。');

  // Failure screen
  String get nativeCoreUnavailable =>
      _pick(en: 'Native core unavailable', hans: '原生核心不可用', hant: '原生核心不可用');
  String get nativeCoreDetail => _pick(
      en: 'The Rust engine did not load, so chat and the sandbox are disabled. The UI below still works.',
      hans: 'Rust 引擎未能加载，聊天与沙盒已禁用，界面仍可使用。',
      hant: 'Rust 引擎未能載入，聊天與沙盒已停用，介面仍可使用。');
}
