import Foundation
import Combine

@available(iOS 13.0, macOS 12.0, tvOS 13.0, watchOS 8.0, *)
@MainActor
public final class SurveyConfigManager: ObservableObject {
    @Published private(set) public var currentConfig: SurveyConfig
    public var configPublisher: AnyPublisher<SurveyConfig, Never> { $currentConfig.eraseToAnyPublisher() }

    private var timer: AnyCancellable?
    private var lastDataHash: Int?

    public init(initial: SurveyConfig) {
        self.currentConfig = initial
    }

    public func loadRemote(url: URL, completion: (@MainActor (Result<SurveyConfig, Error>) -> Void)? = nil) {
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor in
                if let error = error { completion?(.failure(error)); return }
                guard let data = data else { completion?(.failure(NSError(domain: "CXHero", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data"]))); return }
                guard let self = self else { return }
                let hash = data.hashValue
                if self.lastDataHash == hash {
                    completion?(.success(self.currentConfig))
                    return
                }
                do {
                    let cfg = try JSONDecoder().decode(SurveyConfig.self, from: data)
                    self.currentConfig = cfg
                    self.lastDataHash = hash
                    completion?(.success(cfg))
                } catch {
                    completion?(.failure(error))
                }
            }
        }
        task.resume()
    }

    public func startAutoRefresh(url: URL, interval: TimeInterval) {
        timer?.cancel()
        // Immediately load once
        loadRemote(url: url, completion: nil)
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.loadRemote(url: url, completion: nil)
            }
    }

    public func stopAutoRefresh() { timer?.cancel(); timer = nil }
}
