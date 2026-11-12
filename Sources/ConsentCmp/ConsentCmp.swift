import Foundation

/// Diem vao cua SDK: tai cau hinh, gui consent, luu quyet dinh cuc bo.
///
/// ```swift
/// // Khai CMPCodeConfig (+ CMPBaseUrl) trong Info.plist roi dung `ConsentCmp.shared`,
/// // hoac tu tao. Mac dinh tro toi PROD; chi truyen baseUrl khi can moi truong khac.
/// let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp_xxx::t_yyy"))
///
/// let uat = ConsentCmp(options: ConsentOptions(codeConfig: "cp_xxx::t_yyy",
///                                             baseUrl: "https://uat-cmp.biznext.vn"))
/// let config = try await cmp.fetchConfig()
/// var state = cmp.initialState(config)
/// ```
public final class ConsentCmp {

    private enum Keys {
        static let visitor = "visitorId"
        static let state = "state"
        static let config = "config"
        static let configAt = "configAt"
    }

    /// Nguon lay gia tri that cua truong du lieu tu form cua app.
    public typealias ValueSource = (ConsentField) -> String?

    public private(set) var appearance: ConsentAppearance = .defaults
    public let appearances: AppearanceRepository
    public func getAppearance() async -> ConsentAppearance {
        appearance = await appearances.get(); return appearance
    }
    public func refreshAppearance() async -> ConsentAppearance {
        appearance = await appearances.refresh(); return appearance
    }
    public func clearAppearanceCache() async { await appearances.clear(); appearance = .defaults }

    private let options: ConsentOptions
    private let api: ConsentApi
    private let storage: StoragePort
    private let uuid: () -> String
    private let now: () -> Date

    private var cachedConfig: ConsentConfig?
    private var cachedSource: String?
    private var valueSource: ValueSource?

    public init(options: ConsentOptions,
                http: HttpPort = URLSessionHttp(),
                storage: StoragePort = UserDefaultsStorage(),
                appearanceStorage: StoragePort? = nil,
                uuid: @escaping () -> String = { UUID().uuidString },
                now: @escaping () -> Date = { Date() }) {
        self.appearances = AppearanceRepository(options: options, http: http, storage: appearanceStorage)
        self.options = options
        self.api = ConsentApi(options: options, http: http)
        self.storage = storage
        self.uuid = uuid
        self.now = now
    }

    /// Cau hinh da tai gan nhat trong phien nay; nil neu chua goi `fetchConfig`.
    public var config: ConsentConfig? { cachedConfig }

    /// Khai bao noi lay gia tri that cua truong du lieu. SDK chi hoi cho truong
    /// `sharedWithSystem = true`; tra nil khi form khong co truong tuong ung.
    ///
    /// - Important: Trong SwiftUI, closure nay **chup ban copy cua struct View** tai thoi diem tao.
    ///   Dat no o `onAppear` roi doc `@State` ben trong se luon ra gia tri cu (thuong la chuoi rong).
    ///   Hoac goi lai ngay truoc khi submit, hoac dung `setValues(_:)` cho gon.
    public func setValueSource(_ source: ValueSource?) {
        valueSource = source
    }

    /// Khai gia tri bang mot snapshot — cach an toan nhat trong SwiftUI.
    ///
    /// Khoa la `name` cua truong (hoac `"name|dataType"` khi can phan biet 2 truong trung ten),
    /// doi chieu khong phan biet hoa thuong. Goi ngay truoc `submit`:
    ///
    /// ```swift
    /// cmp.setValues([
    ///     "full_name": fullName,
    ///     "email|EMAIL": email,
    /// ])
    /// try await cmp.submit(&state)
    /// ```
    ///
    /// - Note: Gon hon la truyen thang `submit(&state, values:)` — khong phai nho goi 2 buoc,
    ///   va gia tri khong bi giu lai cho lan submit sau.
    public func setValues(_ values: [String: String]) {
        setValueSource(ConsentCmp.makeSource(values))
    }

    /// Doi chieu `name|dataType` truoc, `name` sau; khong phan biet hoa thuong.
    static func makeSource(_ values: [String: String]) -> ValueSource {
        var normalized: [String: String] = [:]
        for (key, value) in values {
            normalized[ConsentCmp.normalizeKey(key)] = value
        }
        return { field in
            guard let name = field.name else { return nil }
            if let dataType = field.dataType,
               let exact = normalized[ConsentCmp.normalizeKey("\(name)|\(dataType)")] {
                return exact
            }
            return normalized[ConsentCmp.normalizeKey(name)]
        }
    }

    private static func normalizeKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Nguon gui ban ghi consent — di kem field `source` cua `/sendData`.
    ///
    /// Mac dinh doc tu `Bundle.main`: ten hien thi + bundle id + version, vd
    /// `"CMP Consent Sample (vn.fpt.fis.cmp.sample) 1.0"`. App ghi de bang `ConsentOptions(source:)`.
    public func source() -> String {
        if let custom = options.source?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let cached = cachedSource {
            return cached
        }
        let described = ConsentCmp.describeApp()
        cachedSource = described
        return described
    }

    /// Doc thong tin app tu `Bundle.main`; that bai o phan nao thi bo phan do.
    ///
    /// Luon tra ve chuoi khac rong: doc het cac khoa ma van khong co gi thi tra `"iOS app"`, de bang
    /// chung consent it nhat con biet den tu nen tang nao.
    static func describeApp(_ bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? (info?["CFBundleExecutable"] as? String)
        let identifier = bundle.bundleIdentifier
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)

        var parts: [String] = []
        if let name = name, !name.isEmpty { parts.append(name) }
        if let identifier = identifier, !identifier.isEmpty { parts.append("(\(identifier))") }
        if let version = version, !version.isEmpty { parts.append(version) }

        let source = parts.joined(separator: " ")
        if source.isEmpty { return "iOS app" }
        // Cot `source` phia backend gioi han 255.
        return source.count <= 255 ? source : String(source.prefix(255))
    }

    /// Visitor ID on dinh theo thiet bi; sinh moi o lan goi dau tien (R14).
    public func visitorId() -> String {
        if let saved = storage.get(Keys.visitor) { return saved }
        let created = uuid()
        storage.set(Keys.visitor, created)
        return created
    }

    // MARK: - Cau hinh

    /// Tai `/config`. Mac dinh **luon goi mang** de bat kip thay doi tren portal (R15);
    /// mat mang thi rot ve ban cache neu co.
    @discardableResult
    public func fetchConfig(preferCache: Bool = false) async throws -> ConsentConfig {
        if preferCache, options.cacheConfig, let cached = loadCachedConfig(ttlMs: options.configTtlMs) {
            appearance = await appearances.fromCachedConfig(storage.get(Keys.config))
            cachedConfig = cached
            return cached
        }
        do {
            let result = try await api.fetchConfig()
            appearance = await appearances.fromConfig(result.raw)
            if options.cacheConfig {
                storage.set(Keys.config, result.raw)
                storage.set(Keys.configAt, String(now().timeIntervalSince1970 * 1000))
            }
            cachedConfig = result.config
            return result.config
        } catch let error as ConsentError {
            appearance = await appearances.fromConfig(nil)
            // Mat mang: dung tam ban cache cu de nguoi dung van tra loi duoc.
            if error.httpStatus == 0, let fallback = loadCachedConfig(ttlMs: .greatestFiniteMagnitude) {
                appearance = await appearances.fromCachedConfig(storage.get(Keys.config))
                cachedConfig = fallback
                return fallback
            }
            throw error
        }
    }

    /// Xoa rieng ban cache cua `/config`; giu quyet dinh da luu va visitor ID.
    public func invalidateConfigCache() {
        cachedConfig = nil
        storage.remove(Keys.config)
        storage.remove(Keys.configAt)
    }

    /// Trang thai de hien thi: gop lua chon da luu theo cau hinh dang dung (R13).
    public func initialState(_ config: ConsentConfig) -> ConsentState {
        ConsentState.merge(config, saved: savedState())
    }

    // MARK: - Gui consent

    /// Gui quyet dinh len `POST /sendData`, luu lai khi thanh cong.
    ///
    /// `consentId` sinh moi moi lan goi; `visitorId` giu nguyen (R14).
    ///
    /// - Parameter values: gia tri nguoi dung da nhap, khoa nhu `setValues(_:)`
    ///   (`"name"` hoac `"name|dataType"`). Chi dung cho lan goi nay va **thay** nguon da khai qua
    ///   `setValues` / `setValueSource`; nil = dung nguon da khai (neu co).
    ///
    /// ```swift
    /// try await cmp.submit(&state, values: ["full_name": fullName, "email|EMAIL": email])
    /// ```
    @discardableResult
    public func submit(_ state: inout ConsentState,
                       values: [String: String]? = nil) async throws -> SendConsentResult {
        let config = cachedConfig
        if let missing = state.firstMissing(config) {
            let target: String
            if let field = missing.field {
                target = "\(missing.item.label ?? "") / \(field.displayName)"
            } else {
                target = missing.item.label ?? ""
            }
            throw ConsentError(message: "Vui long dong y muc bat buoc: \(target)")
        }

        // Chi gui khoa co trong cau hinh hien tai (R3).
        state.retainOnly(config)
        collectValues(&state, config, values.map(ConsentCmp.makeSource) ?? valueSource)

        let consentId = uuid()
        var body: [String: Any] = [
            "consentId": consentId,
            "code": options.codeConfig,
            "dateCreated": Iso8601.format(now()),
            "status": options.status,
            "visitorId": visitorId(),
            "values": state.toValues(),
        ]
        // Nguon gui: ten app + bundle id + version (cot `source` trong bao cao). Luon co gia tri.
        body["source"] = source()

        let result = try await api.sendData(body: body)
        state.consentId = result.consentId ?? consentId
        state.configCode = options.codeConfig
        state.submittedAtMs = now().timeIntervalSince1970 * 1000
        saveState(state)
        return result
    }

    // MARK: - Quyet dinh da luu

    /// Nguoi dung da tra loi consent it nhat mot lan.
    public func hasConsented() -> Bool {
        storage.get(Keys.state) != nil
    }

    /// Quyet dinh gan nhat da submit; nil neu chua tra loi lan nao.
    public func savedState() -> ConsentState? {
        guard let raw = storage.get(Keys.state),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ConsentCmp.deserialize(json)
    }

    /// Kiem tra nhanh mot purpose truoc khi bat SDK ben thu ba.
    public func isGranted(_ purposeKey: String) -> Bool {
        savedState()?.isGranted(purposeKey) == true
    }

    /// Xoa quyet dinh + cache config + nguon gia tri da khai; giu visitor ID (R14).
    public func clear() {
        cachedConfig = nil
        // Dang xuat: khong duoc de gia tri cua nguoi dung cu lot vao ban ghi cua nguoi sau.
        valueSource = nil
        storage.remove(Keys.state)
        storage.remove(Keys.config)
        storage.remove(Keys.configAt)
    }

    // MARK: - Noi bo

    /// Gan gia tri form vao cac truong `sharedWithSystem = true`.
    /// Lay ca cho truong dang tat — ban ghi phai the hien nguoi dung tu choi du lieu nao (R4).
    private func collectValues(_ state: inout ConsentState, _ config: ConsentConfig?,
                               _ source: ValueSource?) {
        guard let source = source, let config = config else { return }
        for item in config.items {
            // Lay ca truong an (`display = false`): khong hoi nguoi dung nhung van phai ghi lai
            // du lieu duoc chia se cho he thong (R16).
            for field in item.dataFields where field.sharedWithSystem {
                if let value = source(field),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.setFieldValue(item.key, field.key, value)
                }
            }
        }
    }

    private func loadCachedConfig(ttlMs: Double) -> ConsentConfig? {
        guard options.cacheConfig,
              let raw = storage.get(Keys.config),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if ttlMs != .greatestFiniteMagnitude {
            let at = Double(storage.get(Keys.configAt) ?? "") ?? 0
            let ageMs = now().timeIntervalSince1970 * 1000 - at
            if at <= 0 || ageMs > ttlMs { return nil }
        }
        return ConsentParser.parseConfig(json)
    }

    private func saveState(_ state: ConsentState) {
        let json = ConsentCmp.serialize(state)
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let raw = String(data: data, encoding: .utf8) else { return }
        storage.set(Keys.state, raw)
    }

    static func serialize(_ state: ConsentState) -> [String: Any] {
        var fields: [String: Any] = [:]
        for (purposeKey, group) in state.fieldEntries {
            var node: [String: Any] = [:]
            for (fieldKey, decision) in group {
                var item: [String: Any] = ["isAccept": decision.accepted]
                if let value = decision.value { item["value"] = value }
                node[fieldKey] = item
            }
            fields[purposeKey] = node
        }
        return [
            "consentId": state.consentId ?? NSNull(),
            "configCode": state.configCode ?? NSNull(),
            "submittedAtMs": state.submittedAtMs,
            "purposes": state.purposeEntries,
            "fields": fields,
            "extras": state.extraEntries,
        ]
    }

    static func deserialize(_ json: [String: Any]) -> ConsentState {
        var state = ConsentState()
        // Doc truong truoc, purpose sau: `setGranted(false)` se don sach truong con sot lai `true`
        // tu ban ghi cu (R1).
        if let fields = json["fields"] as? [String: Any] {
            for (purposeKey, rawGroup) in fields {
                guard let group = rawGroup as? [String: Any] else { continue }
                for (fieldKey, rawDecision) in group {
                    guard let decision = rawDecision as? [String: Any] else { continue }
                    state.setFieldGranted(purposeKey, fieldKey, (decision["isAccept"] as? Bool) ?? false)
                    if let value = decision["value"] as? String {
                        state.setFieldValue(purposeKey, fieldKey, value)
                    }
                }
            }
        }
        if let purposes = json["purposes"] as? [String: Any] {
            for (key, value) in purposes {
                state.setGranted(key, (value as? Bool) ?? false)
            }
        }
        if let extras = json["extras"] as? [String: Any] {
            for (key, value) in extras {
                state.putExtra(key, value)
            }
        }
        state.consentId = json["consentId"] as? String
        state.configCode = json["configCode"] as? String
        state.submittedAtMs = (json["submittedAtMs"] as? Double) ?? 0
        return state
    }
}
