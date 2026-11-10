//
//  EdgeSwipeCatcher.swift
//  Minis - home screen
//
//  Reliable left-edge swipe detection for the ChatGPT-style history drawer.
//
//  A SwiftUI DragGesture on the chat surface never fires: the message list is
//  a UIKit collection view and wins the pan. UIScreenEdgePanGestureRecognizer
//  is the system's own mechanism for exactly this (it is what the interactive
//  pop uses) and it wins over scrolling content, so install one on the window.
//

import SwiftUI
import UIKit

struct EdgeSwipeCatcher: UIViewControllerRepresentable {
    /// Live progress 0…1 while the finger moves (fraction of drawer width).
    var onProgress: (CGFloat) -> Void
    /// Final progress and horizontal velocity when the finger lifts.
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onEnd: onEnd)
    }

    func makeUIViewController(context: Context) -> CatcherViewController {
        let vc = CatcherViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: CatcherViewController, context: Context) {
        context.coordinator.onProgress = onProgress
        context.coordinator.onEnd = onEnd
        vc.coordinator = context.coordinator
        vc.attachIfPossible()
    }

    final class CatcherViewController: UIViewController {
        weak var coordinator: Coordinator?

        override func loadView() {
            // Zero-size, non-interactive: only the window recognizer matters.
            let v = UIView()
            v.backgroundColor = .clear
            v.isUserInteractionEnabled = false
            view = v
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachIfPossible()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attachIfPossible()
        }

        func attachIfPossible() {
            guard let window = view.window, let coordinator else { return }
            coordinator.attach(to: window)
        }
    }

    final class Coordinator: NSObject {
        var onProgress: (CGFloat) -> Void
        var onEnd: (CGFloat, CGFloat) -> Void
        private weak var installedWindow: UIWindow?
        private var recognizer: UIScreenEdgePanGestureRecognizer?
        /// Drawer width the progress is normalised against, refreshed from the
        /// window bounds on each gesture.
        private var drawerWidth: CGFloat = 320

        init(onProgress: @escaping (CGFloat) -> Void,
             onEnd: @escaping (CGFloat, CGFloat) -> Void) {
            self.onProgress = onProgress
            self.onEnd = onEnd
        }

        func attach(to window: UIWindow) {
            guard installedWindow !== window || recognizer == nil else { return }
            if let old = recognizer, let oldWindow = installedWindow {
                oldWindow.removeGestureRecognizer(old)
            }
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            g.edges = .left
            g.cancelsTouchesInView = false
            window.addGestureRecognizer(g)
            recognizer = g
            installedWindow = window
        }

        @objc private func handle(_ g: UIScreenEdgePanGestureRecognizer) {
            let view = g.view
            drawerWidth = max(240, (view?.bounds.width ?? 390) * 0.78)
            let translation = max(0, g.translation(in: view).x)
            let progress = min(1, translation / drawerWidth)

            switch g.state {
            case .changed:
                onProgress(progress)
            case .ended, .cancelled:
                let velocity = g.velocity(in: view).x
                onEnd(progress, velocity)
            default:
                break
            }
        }
    }
}
