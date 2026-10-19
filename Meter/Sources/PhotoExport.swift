import SwiftUI
import Photos
import UIKit

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
    let exposure: Exposure
}

enum PrintStyle: String, CaseIterable, Identifiable {
    case white, black
    var id: String { rawValue }
    var title: String { self == .white ? "白色印相" : "黑色印相" }
}

enum PhotoRenderer {
    static func render(_ photo: CapturedPhoto, style: PrintStyle) -> UIImage {
        // UIImage.draw applies EXIF orientation. Append the footer without cropping.
        let size = photo.image.size
        let footer = size.width * 0.19
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height + footer), format: format)
        return renderer.image { context in
            let background: UIColor = style == .white ? .white : .black
            let foreground: UIColor = style == .white ? .black : .white
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height + footer))
            photo.image.draw(in: CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size.width * 0.036, weight: .medium),
                .foregroundColor: foreground, .paragraphStyle: paragraph
            ]
            (photo.exposure.caption as NSString).draw(in: CGRect(x: size.width * 0.03, y: size.height + footer * 0.25, width: size.width * 0.94, height: footer * 0.3), withAttributes: attributes)
            ("建议曝光 / METERED" as NSString).draw(in: CGRect(x: 0, y: size.height + footer * 0.62, width: size.width, height: footer * 0.2), withAttributes: [
                .font: UIFont.systemFont(ofSize: size.width * 0.021, weight: .regular),
                .foregroundColor: foreground.withAlphaComponent(0.55), .paragraphStyle: paragraph
            ])
        }
    }
}

@MainActor
final class ExportModel: ObservableObject {
    @Published var rendered: UIImage?
    @Published var busy = false
    @Published var alert: String?
    @Published var permissionDenied = false
    @Published var shareURL: URL?
    private var generation = UUID()
    private var temporaryFiles: [URL] = []

    func render(_ photo: CapturedPhoto, style: PrintStyle) {
        let token = UUID(); generation = token; rendered = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let image = PhotoRenderer.render(photo, style: style)
            DispatchQueue.main.async { if self.generation == token { self.rendered = image } }
        }
    }
    func save() {
        guard let rendered, !busy else { return }; busy = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.busy = false; self.permissionDenied = true; self.alert = "请在系统设置中允许添加照片，或使用系统分享导出。" }; return
            }
            guard let data = rendered.jpegData(compressionQuality: 0.96) else {
                DispatchQueue.main.async { self.busy = false; self.alert = "照片编码失败，请重试。" }; return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                DispatchQueue.main.async { self.busy = false; self.permissionDenied = false; self.alert = success ? "已保存带边框的照片。" : (error?.localizedDescription ?? "保存失败，请重试。") }
            }
        }
    }
    func share() {
        guard let rendered, !busy else { return }; busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Metered-\(UUID().uuidString).jpg")
                guard let data = rendered.jpegData(compressionQuality: 0.96) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { self.temporaryFiles.append(url); self.shareURL = url; self.busy = false }
            } catch { DispatchQueue.main.async { self.busy = false; self.alert = error.localizedDescription } }
        }
    }
    func cleanup() {
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file) }
        temporaryFiles.removeAll(); shareURL = nil
    }
}

struct PhotoPreview: View {
    let photo: CapturedPhoto
    @Environment(\.dismiss) private var dismiss
    @AppStorage("printStyle") private var style: PrintStyle = .white
    @StateObject private var model = ExportModel()
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Group {
                    if let image = model.rendered { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("照片成品，建议曝光 \(photo.exposure.caption)") }
                    else { ProgressView("正在生成印相边框").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .secondarySystemBackground))
                Picker("边框颜色", selection: $style) {
                    ForEach(PrintStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(model.busy).padding(.horizontal, 24)
                Text("按下快门时的建议参数 · 非照片实际拍摄参数")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button(action: model.save) { Label(model.busy ? "处理中" : "保存到相册", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    Button(action: model.share) { Label("分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }.controlSize(.large).disabled(model.rendered == nil || model.busy).padding(.horizontal, 24).padding(.bottom, 16)
            }
            .navigationTitle("场景记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { model.render(photo, style: style) }
            .onChange(of: style) { _, value in model.render(photo, style: value) }
            .sheet(isPresented: Binding(get: { model.shareURL != nil }, set: { if !$0 { model.cleanup() } })) {
                if let url = model.shareURL { ShareSheet(url: url) }
            }
            .alert("照片导出", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                if model.permissionDenied { Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
                Button("好", role: .cancel) {}
            } message: { Text(model.alert ?? "") }
            .onDisappear { model.cleanup() }
        }.tint(.meterAmber)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
