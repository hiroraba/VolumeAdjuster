//
//  VolumeAdjusterApp.swift
//  VolumeAdjuster
//
//  Created by matsuohiroki on 2025/09/03.
//

import SwiftUI
import MediaPlayer
import AVFAudio
import UIKit
import Combine

@main
struct VolumeOnlyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Volume Monitoring (Read-Only)

/// システム音量を監視するだけのオブザーバ
final class VolumeObserver: NSObject, ObservableObject {
    @Published var volume: Float = AVAudioSession.sharedInstance().outputVolume

    override init() {
        super.init()
        // 監視の安定のためカテゴリ設定（失敗しても致命ではない）
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        AVAudioSession.sharedInstance().addObserver(
            self,
            forKeyPath: "outputVolume",
            options: [.initial, .new],
            context: nil
        )
    }

    deinit {
        AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "outputVolume" else { return }
        DispatchQueue.main.async { [weak self] in
            self?.volume = AVAudioSession.sharedInstance().outputVolume
        }
    }
}

// MARK: - Volume Control (Write via MPVolumeView.UISlider)

/// MPVolumeView 内部の UISlider を介して音量を変更する制御器
final class VolumeController: ObservableObject {
    private weak var slider: UISlider?

    func bind(slider: UISlider) {
        self.slider = slider
    }

    func setVolume(to value: Float, animated: Bool = false) {
        let clamped = min(max(value, 0.0), 1.0)
        guard let slider else { return }
        DispatchQueue.main.async {
            slider.setValue(clamped, animated: animated)
            slider.sendActions(for: .valueChanged)
        }
    }
}

// MARK: - MPVolumeView Wrapper

/// ルートボタンを隠し、内部 UISlider を太くする
struct MPVolumeSliderView: UIViewRepresentable {
    @ObservedObject var controller: VolumeController
    private let scaleY: CGFloat = 1.8  // スライダーを太く

    func makeUIView(context: Context) -> MPVolumeView {
        let vv = MPVolumeView()
        // 警告は出ますが、スライダーのみの UI にするため非表示にします
        vv.showsRouteButton = false

        // レイアウト完了後に内部 UISlider を取得してカスタム
        DispatchQueue.main.async {
            if let slider = findSlider(in: vv) {
                slider.transform = CGAffineTransform(scaleX: 1.0, y: scaleY)
                slider.accessibilityLabel = "システム音量スライダー"
                controller.bind(slider: slider)
            }
        }
        return vv
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if let slider = findSlider(in: uiView) {
            if slider.transform.d != scaleY {
                slider.transform = CGAffineTransform(scaleX: 1.0, y: scaleY)
            }
            controller.bind(slider: slider)
        }
    }

    private func findSlider(in view: UIView) -> UISlider? {
        for sub in view.subviews {
            if let s = sub as? UISlider { return s }
            if let s = findSlider(in: sub) { return s }
        }
        return nil
    }
}

// MARK: - SwiftUI View

struct ContentView: View {
    @StateObject private var observer = VolumeObserver()
    @StateObject private var controller = VolumeController()

    // アクセシビリティ／視認性向上のためのフォーマッタ
    private var percentText: String {
        String(format: "%.0f%%", observer.volume * 100)
    }

    var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                // 大きな数値表示 + 進捗インジケータ
                VStack(alignment: .leading, spacing: 12) {
                    Text(percentText)
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel("音量")
                        .accessibilityValue(Text(percentText))

                    ProgressView(value: Double(observer.volume), total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(height: 10)
                        .clipShape(Capsule())
                        .accessibilityHidden(true)
                }

                Text("システム音量")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // 太い純正スライダー
                MPVolumeSliderView(controller: controller)
                    .frame(height: 54)

                // 微調整（±5%）
                Text("微調整（±5%）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                nudgeRow

                // クイックプリセット
                presetRow

                Spacer()
            }
            .padding(24)
            .navigationTitle("ボリューム")
            .navigationBarTitleDisplayMode(.inline)
    }

    // プリセットボタン群：ミュート／30%／50%／70%／最大
    private var presetRow: some View {
        let presets: [(String, Float)] = [
            ("ミュート", 0.0),
            ("10%", 0.1),
            ("20%", 0.2),
            ("25%", 0.25),
            ("30%", 0.3),
            ("50%", 0.5),
        ]
        return HStack(spacing: 12) {
            ForEach(presets, id: \.0) { label, value in
                Button(label) {
                    hapticSelection()
                    controller.setVolume(to: value, animated: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel(Text("音量を\(label)に設定"))
            }
        }
    }

    // 現在値を基準に ±5% の増減
    private var nudgeRow: some View {
        HStack(spacing: 12) {
            Button("− 5%") {
                hapticSelection()
                nudgeVolume(by: -0.05)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel(Text("音量を5%下げる"))

            Button("+ 5%") {
                hapticSelection()
                nudgeVolume(by: +0.05)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel(Text("音量を5%上げる"))
        }
    }

    // 現在のシステム音量を基準に微調整
    private func nudgeVolume(by delta: Float) {
        let current = AVAudioSession.sharedInstance().outputVolume
        let newValue = max(0.0, min(1.0, current + delta))
        controller.setVolume(to: newValue, animated: true)
    }

    // 触覚フィードバック
    private func hapticSelection() {
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }
}
