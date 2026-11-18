import SwiftUI
import UIKit
import QuartzCore

/// Online/custom images remain a 2D portrait. Core Animation provides quiet
/// breathing and task feedback; it does not claim to reconstruct a 3D model.
struct AmoreAnimatedPortrait: UIViewRepresentable {
    let image: UIImage?
    let emoji: String
    let mood: AmoreCompanionMood
    let pokes: Int
    let animate: Bool
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.apply(image: image, emoji: emoji, mood: mood, pokes: pokes, animate: animate)
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.layer.removeAllAnimations(); view.imageView.layer.removeAllAnimations()
    }
    final class Surface: UIView {
        let imageView = UIImageView()
        let label = UILabel()
        private var animationKey: String?
        private var previousPokes: Int?
        private var previousImage: UIImage?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false; backgroundColor = .clear; isOpaque = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            label.textAlignment = .center
            addSubview(imageView); addSubview(label)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds.insetBy(dx: bounds.width * 0.06, dy: bounds.height * 0.06)
            imageView.layer.cornerRadius = bounds.width * 0.38
            label.frame = bounds; label.font = .systemFont(ofSize: bounds.height * 0.64)
        }
        func apply(image: UIImage?, emoji: String, mood: AmoreCompanionMood, pokes: Int, animate: Bool) {
            if previousImage !== image { imageView.image = image; previousImage = image }
            imageView.isHidden = image == nil; label.isHidden = image != nil; label.text = emoji
            let key = (animate ? mood.rawValue : "paused") + (image == nil ? "-emoji" : "-image")
            if key != animationKey {
                layer.removeAllAnimations(); imageView.layer.removeAllAnimations(); label.layer.removeAllAnimations()
                animationKey = key
                if animate {
                    let target = image == nil ? label.layer : imageView.layer
                    let breathe = CABasicAnimation(keyPath: "transform.scale")
                    breathe.fromValue = 0.98; breathe.toValue = mood == .idle ? 1.02 : 1.04
                    breathe.duration = mood == .working ? 0.8 : 1.7
                    breathe.autoreverses = true; breathe.repeatCount = .infinity
                    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    target.add(breathe, forKey: "amore.portrait.breathe")
                    if mood == .thinking {
                        let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
                        tilt.fromValue = -0.04; tilt.toValue = 0.04; tilt.duration = 1.3
                        tilt.autoreverses = true; tilt.repeatCount = .infinity
                        target.add(tilt, forKey: "amore.portrait.thinking")
                    }
                }
            }
            if let previousPokes, previousPokes != pokes, animate {
                let wave = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                wave.values = [0, -0.12, 0.12, -0.08, 0]; wave.duration = 0.5
                layer.add(wave, forKey: "amore.portrait.hello")
            }
            previousPokes = pokes
        }
    }
}
