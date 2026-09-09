import Foundation
import SwiftUI

// ===========================================================================
// MARK: - AICore — one brain, many providers, never a dead end
//
// The plumbing behind the "AI Intelligence" section in the Settings tab.
//
//   • apinex  — apinex.bond: ONE key (sk-apx…) → 20+ models from OpenAI,
//               Google, DeepSeek, Zhipu, Moonshot, xAI — including FREE
//               tiers (free/glm-5.3-flash, free/gpt-5.6-luna, …).
//               OpenAI-compatible: POST https://api.apinex.bond/v1/chat/completions
//   • gemini  — the user's own free Google AI Studio key, direct
//               (https://generativelanguage.googleapis.com), as before.
//   • onDevice — no key at all: every feature falls back to the offline
//               engine, so the app is never blocked on a network.
//
// The "never stop" guarantee lives in GeminiAI (SmartKit.swift): a request
// walks a chain [chosen model → next models of the same provider → the OTHER
// provider if it has a key → on-device fallback]. A dead model, a retired id,
// a rate limit or an empty reply only ever costs one silent retry.
//
// This file is deliberately UI-free: types + raw HTTP only.
// ===========================================================================

extension Notification.Name {
    /// Posted to jump straight to the Settings tab (AI Intelligence).
    static let openAISettings = Notification.Name("asmusic_open_settings_tab")
}

// MARK: - Provider selection

enum AIProvider: String, CaseIterable, Identifiable {
    case onDevice = "onDevice"
    case apinex = "apinex"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "On-device only"
        case .apinex:   return "APInex · many models"
        case .gemini:   return "Google Gemini"
        }
    }

    var shortName: String {
        switch self {
        case .onDevice: return "On-device"
        case .apinex:   return "APInex"
        case .gemini:   return "Gemini"
        }
    }

    var subtitle: String {
        switch self {
        case .onDevice:
            return "No key, nothing sent anywhere. Playlists, duplicate checks and mood picks still work — computed fully on this phone."
        case .apinex:
            return "One free key → 20+ cloud models (GPT, Gemini, DeepSeek, GLM, Qwen, Kimi, Grok). Free tiers included; models rotate automatically so a dead model never stops you."
        case .gemini:
            return "Your own free Google AI Studio key, called directly (aistudio.google.com)."
        }
    }

    var icon: String {
        switch self {
        case .onDevice: return "iphone.gen3"
        case .apinex:   return "square.stack.3d.up.fill"
        case .gemini:   return "sparkles"
        }
    }
}

// MARK: - Model catalog

/// One row of the APInex model list (Settings → AI Intelligence).
///
/// NOTE: deliberately NO custom init that consults APInexCatalog.knownModels.
/// Pack 5 shipped one, and it deadlocked the app: the first touch of
/// `knownModels` ran its initializer, which called AIModelInfo.init, which
/// read `knownModels` again → Swift's one-time init re-entered itself on the
/// main thread → frozen app (killed by the watchdog) whenever the user opened
/// Settings, For You or Playlists. Memberwise init only; enrich unknown ids
/// through APInexCatalog.info(for:) instead.
struct AIModelInfo: Identifiable, Equatable {
    let id: String        // e.g. "free/glm-5.3-flash" — the exact string sent to the API
    let label: String     // e.g. "GLM-5.3 Flash"
    let price: String     // "FREE" / "$0.05 / 1M"
    let isFree: Bool
}

/// Everything we know about the APInex platform's catalog.
enum APInexCatalog {
    static let baseURL = "https://api.apinex.bond/v1"
    static let siteURL = "https://apinex.bond"

    /// Bundled snapshot of the catalog (Sept 2026) so the very first run has
    /// a working model list even offline. Live list: GET /v1/models.
    /// Free tiers first, then the cheapest paid models.
    ///
    /// The table is a plain array built with AIModelInfo's MEMBERWISE init —
    /// nothing in here may read `knownModels` (see the note on AIModelInfo:
    /// reading it from inside its own initializer deadlocks the app).
    static let knownModels: [String: AIModelInfo] = {
        let table: [AIModelInfo] = [
            // id,                          label,              price,        free
            AIModelInfo(id: "free/glm-5.3-flash",          label: "GLM-5.3 Flash",     price: "FREE",        isFree: true),
            AIModelInfo(id: "free/gpt-5.6-luna",           label: "GPT-5.6 Luna",      price: "FREE",        isFree: true),
            AIModelInfo(id: "free/gemini-3.8-flash",       label: "Gemini 3.8 Flash",  price: "FREE",        isFree: true),
            AIModelInfo(id: "free/muse-spark-1.3",         label: "Muse Spark 1.3",    price: "FREE",        isFree: true),
            AIModelInfo(id: "free/qwen-3.8-max",           label: "Qwen 3.8 MAX",      price: "FREE",        isFree: true),
            AIModelInfo(id: "free/deepseek-v4-flash-0731", label: "DeepSeek V4 Flash", price: "FREE",        isFree: true),
            AIModelInfo(id: "free/deepseek-v4-pro-0813",   label: "DeepSeek V4 Pro",   price: "FREE",        isFree: true),
            AIModelInfo(id: "free/gemini-3.1-pro",         label: "Gemini 3.1 Pro",    price: "FREE",        isFree: true),
            AIModelInfo(id: "gemini/3.8-flash",            label: "Gemini 3.8 Flash",  price: "$0.10 / 1M",  isFree: false),
            AIModelInfo(id: "deepseek/v4-flash",           label: "DeepSeek V4 Flash", price: "$0.05 / 1M",  isFree: false),
            AIModelInfo(id: "deepseek/v4-pro",             label: "DeepSeek V4 Pro",   price: "$0.07 / 1M",  isFree: false),
            AIModelInfo(id: "glm/5.3-flash",               label: "GLM-5.3 Flash",     price: "$0.05 / 1M",  isFree: false),
            AIModelInfo(id: "gpt/5.6-luna",                label: "GPT-5.6 Luna",      price: "$0.05 / 1M",  isFree: false),
            AIModelInfo(id: "glm/5.3",                     label: "GLM 5.3",           price: "$0.15 / 1M",  isFree: false),
            AIModelInfo(id: "gemini/3.1-pro",              label: "Gemini 3.1 Pro",    price: "$0.15 / 1M",  isFree: false),
            AIModelInfo(id: "kimi/k3",                     label: "Kimi K3",           price: "$0.20 / 1M",  isFree: false),
            AIModelInfo(id: "gpt/5.6-sol",                 label: "GPT-5.6 Sol",       price: "$0.20 / 1M",  isFree: false),
            AIModelInfo(id: "grok/4.6",                    label: "Grok 4.6",          price: "$0.25 / 1M",  isFree: false),
        ]
        var map: [String: AIModelInfo] = [:]
        for m in table { map[m.id] = m }
        return map
    }()

    /// Model row for ANY id: bundled info when we have it, a sensible
    /// generic row when we don't (live /v1/models ids, custom ids the user
    /// typed, ids from a saved catalog). Safe to call from anywhere — this
    /// only READS knownModels after it is fully initialized.
    static func info(for id: String) -> AIModelInfo {
        if let m = knownModels[id] { return m }
        return AIModelInfo(id: id, label: id,
                           price: id.lowercased().hasPrefix("free/") ? "FREE" : "—",
                           isFree: id.lowercased().hasPrefix("free/"))
    }

    /// The bundled list, ordered: free models first, then cheapest paid.
    static var bundled: [AIModelInfo] {
        ordered(Array(knownModels.values))
    }

    /// Fallback model ids used for auto-rotation. The remote registry
    /// (backend-registry.json) can replace this list without an app update.
    static func fallbackModels() -> [String] {
        let reg = RegistryStore.shared.current
        if let list = reg.apinexFallbacks, !list.isEmpty { return list }
        if let pref = reg.preferredApinexModel, !pref.isEmpty { return [pref] }
        return bundled.map { $0.id }
    }

    /// Deterministic ordering: free first, then by price, then by label.
    static func ordered(_ models: [AIModelInfo]) -> [AIModelInfo] {
        models.sorted {
            if $0.isFree != $1.isFree { return $0.isFree }
            if $0.price != $1.price { return $0.price < $1.price }
            return $0.label < $1.label
        }
    }

    /// Parses GET /v1/models ({"data":[{"id":"…"}]}). Returns nil if the
    /// payload doesn't look like a model list at all.
    static func parseModelIDs(_ data: Data) -> [String]? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = j["data"] as? [[String: Any]] else { return nil }
        let ids = arr.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : ids
    }
}

// MARK: - Transport (one raw call, no retries)

/// The outcome of ONE chat call to ONE provider+model. Rotation and
/// cross-provider failover live in GeminiAI — this type just reports facts.
struct AIOutcome {
    let text: String?
    let status: Int?
    let error: String?
    /// True when the failure smells like "this model id doesn't exist /
    /// was retired" — rotating to another model is the right response.
    let modelGone: Bool
    /// True on 401/403 — the key is wrong, so rotating models cannot help;
    /// the only sane next step is the OTHER provider (if configured).
    let keyRejected: Bool

    static func success(_ text: String) -> AIOutcome {
        AIOutcome(text: text, status: 200, error: nil, modelGone: false, keyRejected: false)
    }
    static func failure(status: Int?, error: String?) -> AIOutcome {
        AIOutcome(text: nil, status: status, error: error,
                  modelGone: Self.isModelGone(status: status, message: error ?? ""),
                  keyRejected: status == 401 || status == 403)
    }
    static func networkError(_ message: String) -> AIOutcome {
        AIOutcome(text: nil, status: nil, error: message, modelGone: false, keyRejected: false)
    }

    static func isModelGone(status: Int?, message: String) -> Bool {
        if status == 404 { return true }
        let m = message.lowercased()
        guard m.contains("model") else { return false }
        return m.contains("not found") || m.contains("not exist") || m.contains("unknown")
            || m.contains("invalid") || m.contains("retired") || m.contains("deprecated")
            || m.contains("unsupported") || m.contains("removed") || m.contains("unavailable")
    }
}

/// Raw HTTP chat for both providers. One call, one answer — the failover
/// loop is deliberately NOT in here so it stays trivially testable.
enum AITransport {

    // ------------------------------------------------------------------
    // Chat
    // ------------------------------------------------------------------

    static func chat(provider: AIProvider, key: String, model: String,
                     system: String, user: String,
                     temperature: Double, maxTokens: Int,
                     completion: @escaping (AIOutcome) -> Void) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .onDevice:
            completion(.networkError("No AI provider selected."))
        case .apinex:
            chatOpenAICompatible(base: APInexCatalog.baseURL + "/chat/completions",
                                 key: k, model: model, system: system, user: user,
                                 temperature: temperature, maxTokens: maxTokens,
                                 timeout: 45, completion: completion)
        case .gemini:
            chatGemini(key: k, model: model, system: system, user: user,
                       temperature: temperature, maxTokens: maxTokens, completion: completion)
        }
    }

    /// OpenAI-compatible chat (APInex). `message.content` may be a string or
    /// an array of {type/text} parts depending on the upstream model, so both
    /// shapes are accepted.
    private static func chatOpenAICompatible(base: String, key: String, model: String,
                                             system: String, user: String,
                                             temperature: Double, maxTokens: Int,
                                             timeout: TimeInterval,
                                             completion: @escaping (AIOutcome) -> Void) {
        guard let url = URL(string: base) else {
            completion(.networkError("Bad URL")); return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.networkError(err.localizedDescription)); return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode
            guard let data = data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(status: status, error: "Unexpected reply from the AI service.")); return
            }
            if let s = status, s >= 400 {
                completion(.failure(status: s, error: Self.apiErrorMessage(j) ?? "Server error \(s)."))
                return
            }
            if let text = Self.openAIContentText(j), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                completion(.success(text))
            } else {
                // 200 but empty/unusable — treat like a model problem so the
                // engine rotates instead of showing the user a dead end.
                completion(.failure(status: status, error: "The model returned an empty answer."))
            }
        }.resume()
    }

    /// Direct Google Gemini (generateContent), exactly the protocol the app
    /// used before — same URL, same body, same parsing.
    private static func chatGemini(key: String, model: String, system: String, user: String,
                                   temperature: Double, maxTokens: Int,
                                   completion: @escaping (AIOutcome) -> Void) {
        let keyEnc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let modelEnc = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelEnc):generateContent?key=\(keyEnc)") else {
            completion(.networkError("Bad URL")); return
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]],
            "generationConfig": ["temperature": temperature, "maxOutputTokens": maxTokens]
        ]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.networkError(err.localizedDescription)); return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode
            guard let data = data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(status: status, error: "Unexpected reply from the AI.")); return
            }
            if let s = status, s >= 400 {
                completion(.failure(status: s, error: Self.geminiErrorMessage(j) ?? "Server error \(s)."))
                return
            }
            if let text = Self.geminiContentText(j) {
                completion(.success(text))
            } else {
                completion(.failure(status: status, error: "The model returned an empty answer."))
            }
        }.resume()
    }

    // ------------------------------------------------------------------
    // Model list & key test (APInex)
    // ------------------------------------------------------------------

    /// GET /v1/models with the user's key. Falls back to the bundled list on
    /// any failure, so the picker is never empty.
    static func fetchApinexModels(key: String, completion: @escaping ([AIModelInfo], String?) -> Void) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            completion(APInexCatalog.bundled, nil); return
        }
        guard let url = URL(string: APInexCatalog.baseURL + "/models") else {
            completion(APInexCatalog.bundled, "Bad URL"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode
            if let data = data, status == 200, let ids = APInexCatalog.parseModelIDs(data) {
                let models = APInexCatalog.ordered(ids.map { APInexCatalog.info(for: $0) })
                completion(models, nil)
            } else if let data = data, status == 401 || status == 403 {
                completion(APInexCatalog.bundled, "Key rejected (\(status ?? 0)).")
            } else {
                completion(APInexCatalog.bundled,
                           err?.localizedDescription ?? "Could not load the model list (HTTP \(status ?? 0)).")
            }
        }.resume()
    }

    /// Verifies the APInex key and reports balance + model count in one
    /// human sentence. Uses /v1/balance (cheap) and /v1/models.
    static func testApinexKey(key: String, completion: @escaping (String) -> Void) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            completion("Paste your APInex key (sk-apx…) first."); return
        }
        guard let url = URL(string: APInexCatalog.baseURL + "/balance") else {
            completion("Bad URL."); return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode
            if let data = data, status == 200,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let balance = Self.balanceString(from: j)
                let extra = balance.map { " · balance \($0)" } ?? ""
                completion("✓ Key works\(extra). Models: \(APInexCatalog.bundled.count)+ — see the model picker.")
            } else if status == 401 || status == 403 {
                completion("✗ Key rejected — check that you copied the whole sk-apx… key from the APInex dashboard.")
            } else if let err = err {
                completion("✗ No answer from apinex.bond (\(err.localizedDescription)).")
            } else {
                completion("✗ Unexpected reply (HTTP \(status ?? 0)).")
            }
        }.resume()
    }

    /// Verifies a Gemini key against Google's ListModels endpoint.
    static func testGeminiKey(key: String, model: String, completion: @escaping (String) -> Void) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { completion("Paste your Gemini key first."); return }
        guard let ke = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(ke)&pageSize=100") else {
            completion("Bad URL."); return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode
            if let data = data, status == 200,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = j["models"] as? [[String: Any]] {
                let names = arr.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                let modelOK = names.contains(model)
                let note = modelOK ? "" : " · your model “\(model)” isn't listed — Auto model will fix that on first use"
                completion("✓ Key works · \(names.count) models available\(note).")
            } else if status == 401 || status == 403 {
                completion("✗ Key rejected — create a fresh one at aistudio.google.com.")
            } else if let err = err {
                completion("✗ No answer from Google (\(err.localizedDescription)).")
            } else {
                completion("✗ Unexpected reply (HTTP \(status ?? 0)).")
            }
        }.resume()
    }

    // ------------------------------------------------------------------
    // Tolerant response parsing helpers
    // ------------------------------------------------------------------

    /// `choices[0].message.content` — plain string OR array of parts.
    static func openAIContentText(_ j: [String: Any]) -> String? {
        guard let choices = j["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String {
            return s.isEmpty ? nil : s
        }
        if let parts = msg["content"] as? [[String: Any]] {
            let t = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// Gemini candidates → parts → text.
    static func geminiContentText(_ j: [String: Any]) -> String? {
        guard let candidates = j["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let t = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return t.isEmpty ? nil : t
    }

    /// Short human error from an OpenAI-compatible error body.
    static func apiErrorMessage(_ j: [String: Any]) -> String? {
        if let e = j["error"] as? [String: Any], let m = e["message"] as? String {
            return String(m.prefix(160))
        }
        if let m = j["message"] as? String { return String(m.prefix(160)) }
        return nil
    }

    /// Short human error from a Gemini error body.
    static func geminiErrorMessage(_ j: [String: Any]) -> String? {
        if let e = j["error"] as? [String: Any], let m = e["message"] as? String {
            return String(m.prefix(160))
        }
        return nil
    }

    /// Balance out of a /v1/balance payload, tolerating several key names and
    /// both numeric and string amounts.
    static func balanceString(from j: [String: Any]) -> String? {
        let candidates: [Any?] = [j["balance_usd"], j["balance"], j["usd"], j["credits"]]
        for c in candidates {
            if let n = c as? Double { return String(format: "$%.2f", n) }
            if let s = c as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
