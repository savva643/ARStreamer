import SwiftUI
import ARKit

struct ARPreviewView: UIViewRepresentable {
    var session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
