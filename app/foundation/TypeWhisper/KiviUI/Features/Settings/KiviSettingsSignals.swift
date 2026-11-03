import Foundation
import Combine

/// Settings observes preferences and preview lifecycle, never audio samples or duration ticks.
@MainActor final class KiviSettingsSignals: ObservableObject {
    @Published private(set) var revision = 0
    private var subscriptions = Set<AnyCancellable>()
    init() {
        let vm = DictationViewModel.shared
        let devices = ServiceContainer.shared.audioDeviceService
        let preview = IndicatorPreviewSession.shared
        let signals: [AnyPublisher<Void, Never>] = [
            vm.$cancellationBehavior.map { _ in () }.eraseToAnyPublisher(),
            vm.$indicatorStyle.map { _ in () }.eraseToAnyPublisher(),
            vm.$indicatorTheme.map { _ in () }.eraseToAnyPublisher(),
            vm.$notchIndicatorRightContent.map { _ in () }.eraseToAnyPublisher(),
            vm.$notchIndicatorVisibility.map { _ in () }.eraseToAnyPublisher(),
            vm.$overlayPosition.map { _ in () }.eraseToAnyPublisher(),
            vm.$indicatorVisibleInScreenCaptures.map { _ in () }.eraseToAnyPublisher(),
            vm.$liveFieldTranscriptEnabled.map { _ in () }.eraseToAnyPublisher(),
            vm.$soundFeedbackEnabled.map { _ in () }.eraseToAnyPublisher(),
            vm.$spokenFeedbackEnabled.map { _ in () }.eraseToAnyPublisher(),
            devices.$inputDevices.map { _ in () }.eraseToAnyPublisher(),
            devices.$selectedDeviceUID.map { _ in () }.eraseToAnyPublisher(),
            devices.$disconnectedDeviceName.map { _ in () }.eraseToAnyPublisher(),
            devices.$isPreviewActive.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            devices.$previewError.map { _ in () }.eraseToAnyPublisher(),
            preview.$isActive.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(signals).debounce(for: .milliseconds(10), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.revision += 1 }.store(in: &subscriptions)
    }
}
