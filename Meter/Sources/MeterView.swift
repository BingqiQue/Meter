import SwiftUI
import AVFoundation

struct MeterView: View {
    @StateObject private var camera = CameraService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("grid") private var grid = true
    @AppStorage("calibration") private var calibration = 0.0
    @State private var compensation = 0.0
    @State private var exposure = Exposure()
    @State private var locks = ExposureLocks()
    private var automatic: ExposureParameter { locks.automatic }
    @State private var filter = MeterFilter()
    @State private var ev: Double?
    @State private var outsideRange = false
    @State private var editing: ExposureParameter?
    @State private var settings = false
    @State private var preview: CapturedPhoto?
    @State private var showingCompensation = false

    private var status: String {
        if camera.zoom.changing { return "正在切换焦距" }
        if camera.meteringChanging { return "正在切换测光区域" }
        guard camera.ready, let reading = camera.reading else { return "等待相机测光" }
        if outsideRange { return "超出建议档位范围 · 请调整固定参数" }
        if reading.offset < -1.5 { return "光线不足 · 测光结果仅供参考" }
        if reading.offset > 1.5 { return "光线过强 · 测光结果仅供参考" }
        if reading.ev100 < 2 { return "低光环境 · 建议多次测量" }
        if reading.adjusting { return "正在适应光线" }
        return "连续测光 · 建议曝光"
    }
    var body: some View {
        GeometryReader { geometry in
            // All controls have reserved space; only the viewfinder adapts to screen height.
            // No ScrollView: the shutter and locks stay inside the safe area on every iPhone.
            VStack(spacing: 8) {
                toolbar.frame(height: 44)
                viewfinder
                    .frame(height: max(0, geometry.size.height - 386))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                focalLengthControls.frame(height: 44)
                meteringControls.frame(height: 32)
                HStack(spacing: 6) {
                    Circle().fill(camera.ready && ev != nil ? Color.meterAmber : .gray).frame(width: 5, height: 5)
                    Text(status).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 2)
                    if let ev {
                        Text(String(format: "EV %.1f", ev + calibration)).font(.system(size: 10, design: .monospaced)).fixedSize()
                    }
                }.foregroundStyle(.secondary).frame(height: 20)
                HStack(spacing: 8) {
                    ForEach(ExposureParameter.allCases) { parameter in parameterCard(parameter) }
                }.frame(height: 110)
                shutterBar.frame(height: 76).padding(.horizontal, 12)
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
            .frame(maxWidth: 600).frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color(uiColor: .systemBackground))
        }
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { filter.reset(); ev = nil; camera.start() }
            else { camera.stop(); ev = nil }
        }
        .onChange(of: camera.reading) { _, value in
            guard let value else { ev = nil; filter.reset(); return }
            ev = filter.update(value.ev100); recalculate()
        }
        .onChange(of: calibration) { _, _ in recalculate() }
        .sheet(item: $editing) { parameter in
            ParameterEditor(parameter: parameter, value: Binding(get: { exposure[parameter] }, set: { exposure[parameter] = $0; recalculate() }), automatic: automatic == parameter, makeFixed: { makeFixed(parameter) })
                .presentationDetents([.height(350)])
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $showingCompensation) {
            CompensationEditor(value: Binding(get: { compensation }, set: { compensation = $0; recalculate() }))
                .presentationDetents([.height(260)])
        }
        .sheet(item: $preview) { PhotoPreview(photo: $0) }
        .onChange(of: camera.lastPhoto?.id) { _, _ in
            if let photo = camera.lastPhoto { preview = photo }
        }
        .alert("相机提示", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("重试") { camera.start() }; Button("关闭", role: .cancel) {}
        } message: { Text(camera.message ?? "") }
    }
    private var toolbar: some View {
        HStack {
            Text("测光").font(.system(size: 22, weight: .semibold))
            Spacer()
            Text("METER").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            if camera.canSwitch {
                Button { camera.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 44, height: 44) }.disabled(!camera.ready || camera.capturing || camera.meteringChanging || camera.zoom.changing).accessibilityLabel("切换前后摄像头")
            }
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("测光设置")
        }.foregroundStyle(.primary)
    }
    private var viewfinder: some View {
        ZStack {
            Color.black
            CameraPreview(session: camera.session, metering: camera.metering, showMetering: camera.ready) { point in
                guard !camera.meteringChanging, !camera.capturing, !camera.zoom.changing else { return }
                camera.setMeteringPoint(point)
                UISelectionFeedbackGenerator().selectionChanged()
            }
            if camera.ready {
                if grid {
                    GeometryReader { proxy in
                        Path { path in
                            for part in 1...2 {
                                let x = proxy.size.width * CGFloat(part) / 3
                                let y = proxy.size.height * CGFloat(part) / 3
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            }
                        }.stroke(.white.opacity(0.25), lineWidth: 0.5)
                    }.allowsHitTesting(false)
                }
                VStack {
                    HStack {
                        Label(camera.metering.mode.title, systemImage: camera.metering.mode.symbol).font(.system(size: 10, weight: .medium)).allowsHitTesting(false)
                        Spacer()
                        Button { grid.toggle() } label: { Image(systemName: "grid").frame(width: 40, height: 40).foregroundStyle(grid ? Color.orange : .white) }.accessibilityLabel(grid ? "关闭构图网格" : "开启构图网格")
                    }
                    Spacer()
                    HStack {
                        Text(camera.metering.mode.allowsPointSelection ? "轻点画面测光" : "LIVE").font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text(camera.zoom.caption).font(.system(size: 10, design: .monospaced))
                    }.allowsHitTesting(false)
                }.foregroundStyle(.white).padding(14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.aperture").font(.system(size: 26, weight: .ultraLight))
                    Text(camera.denied ? "允许相机访问，开始测光" : "正在连接相机").font(.system(size: 14, weight: .medium))
                    if camera.denied {
                        Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(.borderedProminent)
                    }
                }.foregroundStyle(.white).padding()
            }
        }
    }
    private var focalLengthControls: some View {
        HStack(spacing: 6) {
            ForEach(FocalLengthPreset.allCases) { preset in
                let selected = camera.zoom.selected == preset
                let supported = camera.zoom.profile.factor(for: preset) != nil
                Button {
                    camera.setFocalLength(preset)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(preset.title).font(.system(size: 14, weight: selected ? .semibold : .regular, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(selected ? Color.meterAmber.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(selected ? Color.meterAmber : .primary)
                .disabled(!supported || !camera.ready || camera.capturing || camera.meteringChanging || camera.zoom.changing)
                .opacity(supported ? 1 : 0.3)
                .accessibilityLabel(preset == .native ? "恢复原生视角" : "\(preset.rawValue) 毫米等效焦距")
                .accessibilityValue(selected ? "已选中" : (supported ? "" : "当前镜头不支持"))
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("等效焦距")
    }
    private var meteringControls: some View {
        Picker("测光模式", selection: Binding(get: { camera.metering.mode }, set: { mode in
            camera.setMeteringMode(mode)
            UISelectionFeedbackGenerator().selectionChanged()
        })) {
            ForEach(camera.metering.availableModes) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.segmented)
        .disabled(!camera.ready || camera.capturing || camera.meteringChanging || camera.zoom.changing)
        .accessibilityHint(camera.metering.detail)
    }
    private func parameterCard(_ parameter: ExposureParameter) -> some View {
        let isAuto = automatic == parameter
        let nextAutomatic = locks.automaticAfterToggling(parameter)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(parameter.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(isAuto ? "AUTO" : "固定").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isAuto ? Color.meterAmber : .secondary)
                }
                Button { editing = parameter } label: {
                    Text(isAuto && ev == nil ? "—" : parameter.format(exposure[parameter]))
                        .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .foregroundStyle(isAuto ? Color.meterAmber : .primary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }.buttonStyle(.plain)
                    .accessibilityLabel("调整\(parameter.title)，\(parameter.format(exposure[parameter]))")
            }.padding(.horizontal, 10).frame(height: 65)
            Divider().overlay(Color.primary.opacity(0.04))
            Button { toggleLock(parameter) } label: {
                Label(isAuto ? "锁定" : "已锁定", systemImage: isAuto ? "lock.open" : "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .foregroundStyle(isAuto ? Color.meterAmber : .primary)
                .background(isAuto ? Color.meterAmber.opacity(0.07) : Color.primary.opacity(0.035))
                .disabled(isAuto && ev == nil)
                .accessibilityLabel(isAuto ? "锁定\(parameter.title)" : "解锁\(parameter.title)")
                .accessibilityValue(isAuto ? "自动计算" : "已锁定")
                .accessibilityHint("\(nextAutomatic.title)将自动计算，其余两项锁定")
        }
        .background(isAuto ? Color.meterAmber.opacity(0.08) : Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isAuto ? Color.meterAmber.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 0.5))
    }
    private var shutterBar: some View {
        HStack {
            Button { preview = camera.lastPhoto } label: {
                Group {
                    if let photo = camera.lastPhoto { Image(uiImage: photo.image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .secondarySystemBackground)) }
                }.frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 7))
            }.disabled(camera.lastPhoto == nil).accessibilityLabel("预览最近的照片")
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                camera.capture(exposure: exposure)
            } label: {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.7), lineWidth: 1.5).frame(width: 76, height: 76)
                    Circle().fill(Color.primary).frame(width: 64, height: 64)
                    if camera.capturing { ProgressView().tint(Color(uiColor: .systemBackground)) }
                }
            }.disabled(!camera.ready || ev == nil || camera.capturing || camera.meteringChanging || camera.zoom.changing).opacity(camera.ready && ev != nil ? 1 : 0.3).accessibilityLabel("拍照并记录当前建议曝光")
            Spacer()
            Button { showingCompensation = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plusminus.circle").font(.system(size: 19, weight: .light))
                    Text(String(format: "%+.1f EV", compensation)).font(.system(size: 10, weight: .medium, design: .monospaced))
                }.frame(width: 56, height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(compensation == 0 ? Color.secondary : .meterAmber)
                .accessibilityLabel("曝光补偿，\(String(format: "%+.1f", compensation)) EV")
        }
    }
    private func recalculate() {
        guard let ev else { return }
        let result = ExposureMath.solve(ev100: ev + calibration, compensation: compensation, fixed: exposure, automatic: automatic)
        exposure = result.exposure; outsideRange = result.outsideRange
    }
    private func toggleLock(_ parameter: ExposureParameter) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.18)) { locks.toggle(parameter); recalculate() }
    }
    private func makeFixed(_ parameter: ExposureParameter) {
        guard automatic == parameter else { return }
        withAnimation(.easeInOut(duration: 0.18)) { locks.lock(parameter); recalculate() }
    }

}

struct CompensationEditor: View {
    @Binding var value: Double
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("曝光补偿").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            HStack {
                Button { change(-1.0 / 3) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }.accessibilityLabel("减少曝光补偿")
                Spacer()
                Text(String(format: "%+.1f EV", value)).font(.system(size: 30, weight: .medium, design: .monospaced))
                Spacer()
                Button { change(1.0 / 3) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("增加曝光补偿")
            }
            Button("恢复 0 EV") { value = 0; UISelectionFeedbackGenerator().selectionChanged() }
            Text("正值增加建议曝光，负值减少建议曝光").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
    private func change(_ delta: Double) {
        value = max(-3, min(3, (value * 3 + delta * 3).rounded() / 3))
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct ParameterEditor: View {
    let parameter: ExposureParameter
    @Binding var value: Double
    let automatic: Bool
    let makeFixed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Double = 0
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("调整\(parameter.title)").font(.headline); Spacer(); Button("完成") { dismiss() } }.padding(.horizontal, 24).padding(.top, 24)
            Text(automatic ? "选择档位后将固定此项，并自动计算另一项" : "滑动选择摄影常用档位").font(.caption).foregroundStyle(.secondary)
            Picker(parameter.title, selection: $selected) {
                ForEach(parameter.stops, id: \.self) { stop in Text(parameter.format(stop)).font(.system(.title2, design: .monospaced)).tag(stop) }
            }.pickerStyle(.wheel).frame(height: 210)
            .onChange(of: selected) { old, new in
                guard old != 0, old != new else { return }
                makeFixed(); value = new; UISelectionFeedbackGenerator().selectionChanged()
            }
        }.onAppear { selected = value }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("grid") private var grid = true
    @AppStorage("calibration") private var calibration = 0.0
    @AppStorage("printStyle") private var printStyle: PrintStyle = .white
    var body: some View {
        NavigationStack {
            Form {
                Section("界面") {
                    Picker("外观", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
                    Toggle("三分构图网格", isOn: $grid)
                    Picker("导出边框", selection: $printStyle) { ForEach(PrintStyle.allCases) { Text($0.title).tag($0) } }
                }
                Section {
                    HStack { Text("测光校准"); Spacer(); Text(String(format: "%+.1f EV", calibration)).monospacedDigit() }
                    Slider(value: $calibration, in: -3...3, step: 0.1).accessibilityLabel("测光校准 EV")
                    Button("恢复校准值") { calibration = 0 }
                } header: { Text("校准") } footer: { Text("校准值加到估算的场景 EV 上，正值会使建议曝光减少。可对照可信的测光表调整；它不会改变手机拍摄设置。主界面的正曝光补偿则增加建议曝光。") }
                Section("快捷焦距") {
                    Text("35、50、85、100mm 表示 35mm 等效视角。点击后使用当前镜头裁切缩放，取景和照片一起变化；“原生”恢复当前镜头的完整视角。裁切放大会减少画面细节，不等于切换到对应焦距的光学镜头。")
                    Text("iOS 26 优先读取系统提供的镜头标称等效焦距；旧系统按视场角估算。实际视角仍可能受镜头校正与处理影响。超出当前镜头缩放范围的档位会变灰。切换焦距后测光点回到中央，建议参数重新更新。")
                }.font(.footnote).foregroundStyle(.secondary)
                Section("测光模式") {
                    Text("全画面：整幅画面作为曝光参考。中央区域：以画面中央约四分之一面积为参考。点测光：点击取景选择小区域，实际大小取决于镜头支持的最小范围，取景框显示真实设置范围。")
                    Text("区域测光需要 iOS 26 及支持的镜头。其他设备仅显示自动测光或选点参考，选点参考不代表严格点测光。切换镜头后会重新检查支持的模式。")
                    Text("测光模式调整相机的自动曝光参考区域，不设置建议快门、光圈或 ISO 到硬件。中央区域也不等同于传统相机的中央加权算法。")
                }.font(.footnote).foregroundStyle(.secondary)
                Section("关于测光") {
                    Text("通过相机实际光圈、ISO、曝光时间和曝光目标偏差估算 EV₁₀₀。切换测光区域后会重新等待并平滑相机读数。")
                    Text("建议参数用于其他相机的摄影参考。手机照片使用自身自动曝光与固定镜头光圈，闪光灯关闭。结果受硬件、场景反射率、自动曝光和计算摄影影响，未经过专业精度认证。")
                    Text("自动参数按常用档位取近似值；达到范围边界时会提示。高反差场景仍可能出现局部过曝，建议结合实际相机试拍检查。")
                    Text("照片仅在本机处理，不上传。最近一张场景记录保留在本次运行内，请及时保存或分享。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
