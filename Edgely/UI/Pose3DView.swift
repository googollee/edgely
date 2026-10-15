import SwiftUI
import SceneKit
import simd

/// F-005 技术实现：SceneKit（见 ADR-0002）。姿态计算方式（鞋形几何体 + 校准对齐 + 加速度计倾斜锚定）见 ADR-0005。
struct Pose3DView: UIViewRepresentable {
    /// nil 表示本次 session 未使用该侧传感器，或该侧没有可用的校准参考系（见 PRD F-001/F-005），对应几何体隐藏
    var leftOrientation: simd_quatf?
    var rightOrientation: simd_quatf?
    /// 相对窗口内平均位置的位移（渲染世界坐标系，米，见 ADR-0017）；nil 表示该时刻不展示位移，模型留在平均位置
    var leftDisplacement: SIMD3<Float>?
    var rightDisplacement: SIMD3<Float>?

    /// 位移的显示比例：鞋模型长 0.9 个场景单位，约对应 0.3 米的真实靴子
    private static let unitsPerMeter: Float = 3
    /// 每个方向最多偏离平均位置的场景单位数，避免长窗口下模型飞出画面
    private static let maxOffsetUnits: Float = 3

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.allowsCameraControl = true
        view.backgroundColor = .clear

        // 相机放在 -Z 一侧朝 +Z 看：配合鞋形模型局部坐标系"脚尖=+Z"的定义，
        // 静止/校准姿态下脚尖（+Z）朝屏幕里、脚跟（-Z）朝屏幕外，和人手持手机看自己脚的方向一致
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 1.2, -6)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.position = SCNVector3(0, 5, 5)
        scene.rootNode.addChildNode(lightNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.4, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // 相机从 -Z 往 +Z 看（见上）会把屏幕左右镜像：世界坐标 +X 对应屏幕左侧、-X 对应屏幕右侧，
        // 所以左脚模型要放在世界坐标 +X 才会显示在屏幕左侧，右脚放 -X 才显示在屏幕右侧
        let leftShoe = makeShoeNode(color: .systemBlue)
        leftShoe.position = SCNVector3(1.2, 0, 0)
        leftShoe.name = "left"
        scene.rootNode.addChildNode(leftShoe)

        let rightShoe = makeShoeNode(color: .systemOrange)
        rightShoe.position = SCNVector3(-1.2, 0, 0)
        rightShoe.name = "right"
        scene.rootNode.addChildNode(rightShoe)

        // 平均位置标记：位移是相对它的偏移，没有它看不出模型动了多少
        for name in ["leftMarker", "rightMarker"] {
            let marker = SCNNode(geometry: SCNSphere(radius: 0.05))
            marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGray
            marker.name = name
            scene.rootNode.addChildNode(marker)
        }

        return view
    }

    private static func offset(_ displacement: SIMD3<Float>?) -> SCNVector3 {
        guard let d = displacement else { return SCNVector3(0, 0, 0) }
        let v = simd_clamp(d * unitsPerMeter, SIMD3<Float>(repeating: -maxOffsetUnits), SIMD3<Float>(repeating: maxOffsetUnits))
        return SCNVector3(v.x, v.y, v.z)
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let showLeft = leftOrientation != nil
        let showRight = rightOrientation != nil
        // 只有一侧显示时（单传感器 session），把它挪到画面正中，而不是留在双脚并排时的偏移位置
        let onlyOneShown = showLeft != showRight

        if let leftNode = uiView.scene?.rootNode.childNode(withName: "left", recursively: false) {
            leftNode.isHidden = !showLeft
            let base = SCNVector3(onlyOneShown ? 0 : 1.2, 0, 0)
            let o = Self.offset(leftDisplacement)
            leftNode.position = SCNVector3(base.x + o.x, o.y, o.z)
            if let marker = uiView.scene?.rootNode.childNode(withName: "leftMarker", recursively: false) {
                marker.isHidden = !showLeft
                marker.position = base
            }
            if let leftOrientation { leftNode.simdOrientation = leftOrientation }
        }
        if let rightNode = uiView.scene?.rootNode.childNode(withName: "right", recursively: false) {
            rightNode.isHidden = !showRight
            let base = SCNVector3(onlyOneShown ? 0 : -1.2, 0, 0)
            let o = Self.offset(rightDisplacement)
            rightNode.position = SCNVector3(base.x + o.x, o.y, o.z)
            if let marker = uiView.scene?.rootNode.childNode(withName: "rightMarker", recursively: false) {
                marker.isHidden = !showRight
                marker.position = base
            }
            if let rightOrientation { rightNode.simdOrientation = rightOrientation }
        }
    }

    /// 简化的鞋形组合几何体（见 ADR-0005）：局部坐标系里脚尖 = +Z，鞋底 = -Y（对应 PoseAlignment 里的定义）。
    /// 主体是长方体，前端加一个锥体标出脚尖，鞋底面单独上色区分。不是精细雪靴/雪板模型。
    private func makeShoeNode(color: UIColor) -> SCNNode {
        let root = SCNNode()

        let bodyGeometry = SCNBox(width: 0.5, height: 0.18, length: 0.9, chamferRadius: 0.05)
        let sideMaterial = SCNMaterial()
        sideMaterial.diffuse.contents = color
        let soleMaterial = SCNMaterial()
        soleMaterial.diffuse.contents = UIColor.darkGray
        // SCNBox 材质顺序：front(+Z) right(+X) back(-Z) left(-X) top(+Y) bottom(-Y，鞋底)
        bodyGeometry.materials = [sideMaterial, sideMaterial, sideMaterial, sideMaterial, sideMaterial, soleMaterial]
        root.addChildNode(SCNNode(geometry: bodyGeometry))

        // 锥体底面半径跟着主体变宽同步放大，保持和主体前端截面比例协调。
        // SceneKit 没有椭圆锥这个几何体，用非均匀缩放把圆形截面压扁成椭圆——
        // 只压缩转向"上下"方向的那根局部轴（z，旋转后对应世界 -Y），左右宽度方向（x）不变，
        // 椭圆的扁平比例和主体的宽高比（0.5 宽 : 0.18 高）保持一致
        let toeGeometry = SCNCone(topRadius: 0, bottomRadius: 0.28, height: 0.25)
        toeGeometry.firstMaterial?.diffuse.contents = color
        let toeNode = SCNNode(geometry: toeGeometry)
        toeNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0) // 锥体默认轴向 +Y，转到 +Z 指向脚尖方向
        toeNode.scale = SCNVector3(1, 1, 0.32)
        toeNode.position = SCNVector3(0, 0, 0.575)
        root.addChildNode(toeNode)

        // 脚腕标记：一个朝上（+Y，圆柱默认轴向，不需要旋转）的圆柱，位置偏向后跟一侧，
        // 用形状（而不是颜色）区分"上"方向，比单靠鞋底变色更容易一眼看出来
        let ankleGeometry = SCNCylinder(radius: 0.13, height: 0.4)
        ankleGeometry.firstMaterial?.diffuse.contents = color
        let ankleNode = SCNNode(geometry: ankleGeometry)
        ankleNode.position = SCNVector3(0, 0.29, -0.15) // Y 跟着主体变扁同步下移，贴在主体新的顶面上
        root.addChildNode(ankleNode)

        return root
    }
}
