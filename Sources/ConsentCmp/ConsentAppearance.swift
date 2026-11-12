import Foundation
import CryptoKit
import CoreText

/// Native appearance tokens; no CSS or remote executable content.
public struct ConsentAppearance {
    let payload: [String: Any]
    var fontNames: [Int: String] = [:]
    public static var defaults: ConsentAppearance { ConsentAppearance(payload: [:]) }
    public var revision: String { payload["revision"] as? String ?? "default" }
    public var family: String { typography["family"] as? String ?? "system" }
    var typography: [String: Any] { payload["typography"] as? [String: Any] ?? [:] }
    var theme: [String: Any] { payload["theme"] as? [String: Any] ?? [:] }
    static func parse(_ raw: String) throws -> ConsentAppearance {
        guard raw.utf8.count <= 32768, let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConsentError(message: "Invalid appearance")
        }
        let json = root["data"] as? [String: Any] ?? root
        guard json["schemaVersion"] as? Int == 1, json["theme"] is [String: Any],
              json["typography"] is [String: Any] else { throw ConsentError(message: "Unsupported appearance") }
        return ConsentAppearance(payload: json)
    }
    static func fromConfig(_ raw: String) throws -> ConsentAppearance {
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appearance = (root["data"] as? [String: Any] ?? root)["appearance"] as? [String: Any] else {
            throw ConsentError(message: "Config response has no valid appearance object")
        }
        let serialized = try JSONSerialization.data(withJSONObject: appearance)
        return try parse(String(decoding: serialized, as: UTF8.self))
    }
    public func color(_ token: String) -> UInt32? {
        guard let colors = theme["colors"] as? [String: Any], let text = colors[token] as? String,
              text.range(of: "^#[a-fA-F0-9]{6}$", options: .regularExpression) != nil else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }
    public func radius(_ token: String, fallback: Double) -> Double {
        number(theme["shape"] as? [String: Any], token, fallback, 0...32)
    }
    public func size(_ role: String, fallback: Double) -> Double {
        number(typography[role] as? [String: Any], "size", fallback, 10...32)
    }
    public func weight(_ role: String, fallback: Double) -> Double {
        number(typography[role] as? [String: Any], "weight", fallback, 100...900)
    }
    private func number(_ node: [String: Any]?, _ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        guard let value = node?[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, range.contains(value.doubleValue) else { return fallback }
        return value.doubleValue
    }
    func fontName(weight: Int) -> String? {
        if let closest = fontNames.keys.min(by: { abs($0 - weight) < abs($1 - weight) }) { return fontNames[closest] }
        return family == "system" ? nil : family
    }
}

/// Separate app-private storage; clearing consent or logging out does not remove appearance.
struct AppearanceFileStorage: StoragePort {
    let directory: URL
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FPTConsentAppearance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func get(_ key: String) -> String? { try? String(contentsOf: directory.appendingPathComponent(key), encoding: .utf8) }
    func set(_ key: String, _ value: String) {
        // Data.write keeps the atomic replace but applies an explicit protection class to the written file.
        try? Data(value.utf8).write(to: directory.appendingPathComponent(key),
                                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ key: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key)) }
}

public actor AppearanceRepository {
    private let api: ConsentApi
    private let storage: StoragePort
    private let key: String
    private var current: ConsentAppearance?
    private var attempted = false
    private var inFlight: Task<ConsentAppearance, Never>?
    private var generation = 0
    private var resetGeneration = 0
    public init(options: ConsentOptions, http: HttpPort = URLSessionHttp(), storage: StoragePort? = nil) {
        api = ConsentApi(options: options, http: http)
        self.storage = storage ?? AppearanceFileStorage()
        let identity = "\(options.baseUrl)|\(options.apiPath)|\(options.codeConfig)|1"
        key = "appearance-" + Self.hash(Data(identity.utf8))
    }
    public func get() async -> ConsentAppearance {
        await resolve(config: nil, useNetwork: true, force: false)
    }
    public func fromConfig(_ raw: String?) async -> ConsentAppearance {
        await resolve(config: raw, useNetwork: false, force: false)
    }
    func fromCachedConfig(_ raw: String?) async -> ConsentAppearance {
        let cached = await resolve(config: nil, useNetwork: false, force: false)
        if cached.payload["schemaVersion"] as? Int == 1 { return cached }
        return await fromConfig(raw)
    }
    public func refresh() async -> ConsentAppearance {
        await resolve(config: nil, useNetwork: true, force: true)
    }
    private func resolve(config: String?, useNetwork: Bool, force: Bool) async -> ConsentAppearance {
        if let pending = inFlight {
            let waitingGeneration = generation
            let waitingReset = resetGeneration
            let result = await pending.value
            guard waitingReset == resetGeneration else { return current ?? .defaults }
            if waitingGeneration == generation { current = result; inFlight = nil }
            if config == nil { return result }
            // A new config response must not be discarded behind an older in-flight load.
            return await resolve(config: config, useNetwork: useNetwork, force: force)
        }
        if config == nil, !force, let current = current { return current }
        let active = current
        let stored = active == nil ? storage.get(key).flatMap { try? ConsentAppearance.parse($0) } : nil
        if config == nil, !force, active == nil, stored == nil {
            if attempted || !useNetwork { return .defaults }
        }
        if config != nil || force || stored == nil { attempted = true }
        generation += 1
        let snapshot = generation
        let task = Task<ConsentAppearance, Never> {
            let previous: ConsentAppearance
            if let active = active { previous = active }
            else if let stored = stored { previous = await prepareFonts(stored, download: false) }
            else { previous = .defaults }
            if config == nil, !force, active != nil || stored != nil { return previous }
            do {
                let raw: String
                if let supplied = config { raw = supplied }
                else { raw = try await api.fetchConfig().raw }
                let parsed = try ConsentAppearance.fromConfig(raw)
                if !force && NSDictionary(dictionary: parsed.payload).isEqual(NSDictionary(dictionary: previous.payload)) {
                    return previous
                }
                let resolved = await prepareFonts(parsed, download: true)
                if snapshot == generation {
                    let data = try JSONSerialization.data(withJSONObject: parsed.payload)
                    storage.set(key, String(decoding: data, as: UTF8.self))
                }
                return resolved
            } catch { return previous }
        }
        inFlight = task
        let result = await task.value
        if snapshot == generation { current = result; inFlight = nil }
        return result
    }
    public func clear() {
        resetGeneration += 1; generation += 1; inFlight?.cancel(); inFlight = nil
        storage.remove(key); current = nil; attempted = false
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func prepareFonts(_ appearance: ConsentAppearance, download: Bool) async -> ConsentAppearance {
        var result = appearance
        let directory = AppearanceFileStorage().directory.appendingPathComponent("fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(3)
        for font in (appearance.typography["fonts"] as? [[String: Any]] ?? []).prefix(4) {
            guard let digest = font["sha256"] as? String,
                  digest.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                  let weight = font["weight"] as? Int else { continue }
            let path = directory.appendingPathComponent(digest.lowercased() + ".font")
            var data = try? Data(contentsOf: path, options: .mappedIfSafe)
            if data.map({ Self.hash($0) != digest.lowercased() }) ?? true {
                data = nil
                if download, Date() < deadline, let text = font["url"] as? String,
                   let url = URL(string: text), url.scheme == "https" {
                    data = try? await AppearanceFontDownload.load(url, timeout: max(0.1, deadline.timeIntervalSinceNow))
                    if data.map({ Self.hash($0) == digest.lowercased() }) == true { try? data?.write(to: path, options: .atomic) }
                    else { data = nil }
                }
            }
            guard data != nil, let descriptors = CTFontManagerCreateFontDescriptorsFromURL(path as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
            CTFontManagerRegisterFontsForURL(path as CFURL, .process, nil)
            result.fontNames[weight] = name
        }
        return result
    }
}

/// Bounded download, no credentials or redirects; accepts only the configured HTTPS asset.
private final class AppearanceFontDownload: NSObject, URLSessionDataDelegate {
    private var bytes = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    static func load(_ url: URL, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = AppearanceFontDownload()
            delegate.completion = { continuation.resume(with: $0) }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler((response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 4 * 1024 * 1024 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > 4 * 1024 * 1024 { dataTask.cancel() } else { bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion?(error.map { .failure($0) } ?? .success(bytes)); completion = nil; session.finishTasksAndInvalidate()
    }
}
