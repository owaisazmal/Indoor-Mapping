import SceneKit
import UIKit

// MARK: - AR Node Builder
// Pure factory: creates and removes SceneKit breadcrumb/sign nodes for a navigation
// destination. Has no mutable state — all methods are static.

enum ARNodeBuilder {

    static func buildPath(to dest: NavDestination, in scene: SCNScene) -> [SCNNode] {
        let dx = dest.worldX, dz = dest.worldZ
        let dist  = sqrt(dx * dx + dz * dz)
        let steps = max(1, Int(dist / 2.5))
        var nodes: [SCNNode] = []

        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let p = SCNVector3(dx * t, -0.4, dz * t)
            let crumb = makeCrumb(at: p, color: dest.uiColor, pulse: i == steps)
            scene.rootNode.addChildNode(crumb)
            nodes.append(crumb)
        }

        let sign = makeSign(dest.name, at: SCNVector3(dx, 0.45, dz), color: dest.uiColor)
        scene.rootNode.addChildNode(sign)
        nodes.append(sign)
        return nodes
    }

    static func clearNodes(_ nodes: inout [SCNNode]) {
        nodes.forEach { $0.removeFromParentNode() }
        nodes.removeAll()
    }

    // MARK: - Private node factories

    private static func makeCrumb(at p: SCNVector3, color: UIColor, pulse: Bool) -> SCNNode {
        let geo = SCNSphere(radius: pulse ? 0.20 : 0.11)
        geo.firstMaterial?.diffuse.contents  = color.withAlphaComponent(0.9)
        geo.firstMaterial?.emission.contents = color.withAlphaComponent(0.45)
        geo.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: geo)
        node.position = p
        if pulse {
            let anim = CABasicAnimation(keyPath: "scale")
            anim.fromValue = SCNVector3(1, 1, 1); anim.toValue = SCNVector3(1.4, 1.4, 1.4)
            anim.duration = 0.85; anim.autoreverses = true; anim.repeatCount = .infinity
            node.addAnimation(anim, forKey: "pulse")
        }
        return node
    }

    private static func makeSign(_ label: String, at p: SCNVector3, color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.position = p
        let bb = SCNBillboardConstraint(); bb.freeAxes = .Y
        root.constraints = [bb]

        let texture = makeSignTexture(label, color: color)
        let aspectW: CGFloat = 2.2
        let aspectH: CGFloat = aspectW * (texture.size.height / texture.size.width)
        let bg = SCNPlane(width: aspectW, height: aspectH)
        bg.firstMaterial?.diffuse.contents = texture
        bg.firstMaterial?.isDoubleSided    = true
        bg.firstMaterial?.lightingModel    = .constant
        root.addChildNode(SCNNode(geometry: bg))

        let stemH = CGFloat(abs(p.y) + 0.6)
        let stem  = SCNCylinder(radius: 0.028, height: stemH)
        stem.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.70)
        stem.firstMaterial?.lightingModel    = .constant
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = SCNVector3(0, -Float(stemH) / 2 - Float(aspectH) / 2, 0)
        root.addChildNode(stemNode)
        return root
    }

    private static func makeSignTexture(_ label: String, color: UIColor) -> UIImage {
        let size = CGSize(width: 440, height: 110)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 22)
            color.withAlphaComponent(0.94).setFill(); path.fill()
            UIColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 3; path.stroke()
            let para = NSMutableParagraphStyle()
            para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            ("→  \(label)" as NSString).draw(
                in: CGRect(x: 20, y: (size.height - 44) / 2, width: size.width - 40, height: 50),
                withAttributes: attrs)
        }
    }
}
