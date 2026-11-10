//
//  ContentView+ChatTab.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The Chat tab: a single, always-available conversation that lives outside
//  the session list ("Chats"). It keeps its own session id; sessions created
//  from it are hidden from the list so the tab stays a private scratch chat.
//

import SwiftUI

/// Sessions created from the Chat tab and hidden from the Chats list.
enum ChatTabRegistry {
    private static let key = "chatTab.hiddenSessionIds"

    static var hiddenIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func register(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        // Keep the registry bounded; old ids are harmless once deleted.
        if ids.count > 50 { ids.removeFirst(ids.count - 50) }
        UserDefaults.standard.set(ids, forKey: key)
    }
}

struct ChatTabView: View {
    @AppStorage("chatTab.sessionId") private var storedSessionId: String = ""
    @AppStorage("chatTab.draftId") private var draftId: String = "__new__chat-tab"

    var body: some View {
        NavigationStack {
            Group {
                if storedSessionId.isEmpty {
                    AIChatView(sessionId: nil, draftId: draftId)
                        .id(draftId)
                } else {
                    AIChatView(sessionId: storedSessionId)
                        .id(storedSessionId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startFresh()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(Text("New Chat"))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidCreate)) { note in
            guard let newId = note.object as? String,
                  (note.userInfo as? [String: String])?["draftId"] == draftId else { return }
            ChatTabRegistry.register(newId)
            storedSessionId = newId
            draftId = "__new__" + UUID().uuidString
        }
    }

    private func startFresh() {
        storedSessionId = ""
        draftId = "__new__" + UUID().uuidString
    }
}
