import XCTest
import SwiftUI
import UIKit
@testable import Amore134Components

@MainActor
final class Amore135CompanionTests: XCTestCase {
    func testCustomPortraitImmediatelyChangesImageAndPauses() {
        let view = AmoreAnimatedPortrait.Surface(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let first = image(.red), second = image(.blue)
        view.apply(image: first, emoji: "", mood: .thinking, pokes: 0, animate: true)
        XCTAssertTrue(view.imageView.image === first)
        XCTAssertFalse(view.imageView.isHidden)
        XCTAssertTrue(view.label.isHidden)
        XCTAssertNotNil(view.imageView.layer.animation(forKey: "amore.portrait.breathe"))
        XCTAssertNotNil(view.imageView.layer.animation(forKey: "amore.portrait.thinking"))
        view.apply(image: second, emoji: "", mood: .working, pokes: 1, animate: true)
        XCTAssertTrue(view.imageView.image === second)
        XCTAssertNotNil(view.layer.animation(forKey: "amore.portrait.hello"))
        view.apply(image: second, emoji: "", mood: .working, pokes: 1, animate: false)
        XCTAssertTrue(view.imageView.layer.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(view.layer.animationKeys()?.isEmpty ?? true)
    }
    func testImageEmojiSwitchMovesAnimationToVisibleLayer() {
        let view = AmoreAnimatedPortrait.Surface(frame: .zero)
        view.apply(image: image(.green), emoji: "", mood: .idle, pokes: 0, animate: true)
        view.apply(image: nil, emoji: "🌸", mood: .idle, pokes: 0, animate: true)
        XCTAssertTrue(view.imageView.isHidden)
        XCTAssertFalse(view.label.isHidden)
        XCTAssertEqual(view.label.text, "🌸")
        XCTAssertNotNil(view.label.layer.animation(forKey: "amore.portrait.breathe"))
    }
    func testAvatarDesignOnlyFillsItsNewEmptyDraftOnce() {
        let router = AmoreAvatarDraftRouter.shared
        router.enqueue(prompt: "Design a blue avatar", draftID: "draft-for-avatar")
        XCTAssertNil(router.consume(for: "existing-chat", composerIsEmpty: true))
        XCTAssertNil(router.consume(for: "draft-for-avatar", composerIsEmpty: false))
        XCTAssertEqual(router.consume(for: "draft-for-avatar", composerIsEmpty: true), "Design a blue avatar")
        XCTAssertNil(router.consume(for: "draft-for-avatar", composerIsEmpty: true))
    }
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
    }
}
