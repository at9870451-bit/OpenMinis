#!/usr/bin/env python3
"""Build-only extraction for the isolated 1.35 UIKit/header/drawer UI host."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

root, host = map(Path, sys.argv[1:])
records = []


def extract(relative, declaration):
    path = root / relative
    text = path.read_text()
    assert text.count(declaration) == 1, f'Expected exactly one {declaration}: {path}'
    start = text.index(declaration)
    opening = text.index('{', start)
    depth = 0
    end = None
    tokens = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}]')
    for token in tokens.finditer(text, opening):
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if depth == 0:
                end = token.end()
                break
    assert end is not None, f'Unbalanced declaration: {declaration}'
    source = text[start:end]
    records.append(dict(path=relative, declaration=declaration,
                        startLine=text.count('\n', 0, start) + 1,
                        endLine=text.count('\n', 0, end) + 1,
                        sha256=hashlib.sha256(source.encode()).hexdigest(),
                        overlay='none; complete declaration preserved byte-for-byte'))
    return source


menu_path = 'src/ios/Views/Chat/AIChatView/Toolbar/ChatToolbarHost.swift'
menu = extract(menu_path, 'struct ChatTrailingMenuButton: UIViewRepresentable')
for anchor in ('final class HitPaddedButton: UIButton', 'button.showsMenuAsPrimaryAction = true',
               'fileprivate static func buildMenu(', 'UIDeferredMenuElement.uncached'):
    assert anchor in menu, f'Menu production structure changed: {anchor}'
# Independent runtime assertions use these English keys, not guessed translations.
expected = {'Open Terminal': 'onOpenTerminal', 'Search in Chat': 'onSearchInChat',
            'Browse Chat Files': 'onBrowseFiles', 'Open Browser': 'onOpenBrowser'}
for title, callback in expected.items():
    assert re.search(r'UIAction\(title: AppLocalized\("' + re.escape(title) +
                     r'"\)[\s\S]*?coordinator\.parent\.' + callback + r'\(\)', menu), title
assert 'UIAction(title: AppLocalized("Browse Files")' not in menu, 'Review renamed original action'
(host / 'App/ExtractedChatTrailingMenuButton.swift').write_text(
    '// Generated from production at build time. No menu/body overlay.\n'
    'import SwiftUI\nimport UIKit\nimport Foundation\n\n' + menu + '\n')

copies = []
for relative in ('src/ios/Providers/OpenAI/SpeedTier.swift',
                 'src/ios/Views/Chat/AIChatView/Toolbar/SpeedTier+Display.swift'):
    path = root / relative
    shutil.copyfile(path, host / 'App' / path.name)
    copies.append(dict(path=relative, sha256=hashlib.sha256(path.read_bytes()).hexdigest(), overlay='none'))

layout = 'src/ios/Views/ContentView/ContentView+Layout.swift'
header = extract(layout, 'private var drawerHeader: some View')
footer = extract(layout, 'private var drawerAccountFooter: some View')
assert '"amore.sidebar.newConversation"' in footer
assert '"amore.sidebar.settings"' in footer
assert 'DeepLinkCoordinator.shared.pendingSettingsTarget = .home' in footer
assert 'activeToolSheet = .settings' in footer
(host / 'App/Amore135DrawerProbe.swift').write_text(
    (root / 'scripts/Amore135DrawerProbe.swift').read_text() +
    '\n// Generated ORIGINAL production members; host dependencies are inert stubs.\n'
    'extension Amore135DrawerProbe {\n' + header + '\n\n' + footer + '\n}\n')

chat = (root / 'src/ios/Views/Chat/AIChatView/AIChatView.swift').read_text()
assert 'trailing: AnyView(trailingMenuButton' in chat, 'Production header trailing composition drifted'
assert '.accessibilityIdentifier("amore.conversationOptions")' in chat
trailing = (root / 'src/ios/Views/Chat/AIChatView/AIChatView+TrailingMenu.swift').read_text()
assert 'var trailingMenuButton: ChatTrailingMenuButton' in trailing
assert 'ChatTrailingMenuButton(' in trailing, 'Production chat lost its UIKit menu'
manifest = dict(extractions=records, copies=copies, englishActionKeys=expected,
                stubs=['AppLocalized returns English key', 'NavbarEvalStats / ChatNavMenuBarItem Logger',
                       'LastAPIRequestBody empty synthetic array',
                       'Footer drawerIsSliding=false / drawerSearchFocused FocusState',
                       'snapDrawer no-op / startHomeChat counter',
                       'DeepLinkCoordinator in-memory test store / activeToolSheet state'],
                scope='Real Chrome + Companion + extracted UIKit menu; drawer real header/shortcuts/footer, synthetic history. Not full App/kernel/settings/services.')
(host / 'header-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
