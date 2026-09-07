import Foundation
import UIKit
import SwiftUI
import AVFoundation
import WebKit
import os.log
import Combine
import CryptoKit

// ---------------------------------------------------------------------------
// MARK: - Logging
// ---------------------------------------------------------------------------
fileprivate let log = Logger(subsystem: "com.ahmedsoliman.trollmusicapp", category: "MagicDL")

// ---------------------------------------------------------------------------
// MARK: - TitleCleaner
// ---------------------------------------------------------------------------
enum TitleCleaner {
    private static let noisePatterns: [String] = [
        #"\(Official Music Video\)\s*"#,
        #"\(Official Video\)\s*"#,
        #"\(Official Audio\)\s*"#,
        #"\(Official Lyric Video\)\s*"#,
        #"\(Official Lyrics Video\)\s*"#,
        #"\(Lyrics\)\s*"#,
        #"\(Lyric Video\)\s*"#,
        #"\(Lyrics Video\)\s*"#,
        #"\(Audio)\s*"#,
        #"\(HD)\s*"#, #"\(HQ)\s*"#, #"\(4K)\s*"#, #"\(1080p)\s*"#, #"\(720p)\s*"#,
        #"\[Official Music Video\]\s*"#,
        #"\[Official Video\]\s*"#,
        #"\[Official Audio\]\s*"#,
        #"\[HD\]\s*"#, #"\[HQ\]\s*"#, #"\[4K\]\s*"#,
        #"Official Music Video\s*"#,
        #"Official Video\s*"#,
        #"Official Audio\s*"#,
        #"Official Lyric Video\s*"#,
        #"Lyrics\s*"#,
        #"Official\s*"#,
        #"Prod\.\s*by\s+[^-\|()\[\]]*"#,
        #"\s*-\s*Topic\b"#,
        #"\s*\|+\s*YouTube\b"#,
        #"\s*\|\s*"#,
        #"\s*[|｜]\s*"#,
    ]
    private static let artistSplit = #/^\s*(?<artist>[^-–—|]{2,60}?)\s*[-–—]\s*(?<title>.+)$/#
    private static let ftPattern = #/\s*\(?\s*(?:ft\.?|feat\.?|featuring)\s+[^)]*\)?\s*/#

    static func clean(_ raw: String, artistHint: String? = nil) -> (title: String, artist: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var artist = ""
        if let h = artistHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !h.isEmpty,
           !["AS Music","YouTube","SoundCloud","YouTube Track"].contains(h) {
            artist = h
        }
        var title = s
        if artist.isEmpty {
            if let m = try? artistSplit.wholeMatch(in: s) {
                let left = String(m.output.artist).trimmingCharacters(in: .whitespaces)
                let right = String(m.output.title).trimmingCharacters(in: .whitespaces)
                if left.count <= 50 && !left.contains(where: { c in "[({".contains(c) }) {
                    artist = left; title = right
                }
            }
        }
        for p in noisePatterns {
            title = title.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        title = title.replacingOccurrences(of: #"\s*\([^)]{0,20}\)\s*$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s*\[[^\]]{0,20}\]\s*$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^\d{1,2}[\.\-]\s+"#, with: "", options: .regularExpression)
        let cs = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—_|"))
        title = title.trimmingCharacters(in: cs)
        artist = artist.trimmingCharacters(in: cs)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        artist = artist.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if title.isEmpty { title = raw }
        if artist.isEmpty { artist = "AS Music" }
        if artist == title { artist = "AS Music" }
        return (title, artist)
    }

    static func sha256OfFile(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fh.closeFile() }
        var hash = SHA256()
        while autoreleasepool(invoking: {
            let chunk = fh.readData(ofLength: 1 << 16)
            if chunk.isEmpty { return false }
            hash.update(data: chunk)
            return true
        }) {}
        let digest = hash.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}


// ---------------------------------------------------------------------------
// MARK: - Search results
// ---------------------------------------------------------------------------
enum SearchResultSource: String, Codable {
    case mp3juice_yt, mp3juice_sc, piped_yt
}

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    let source: SearchResultSource
    let title: String
    let artist: String
    let duration: TimeInterval?
    let platform: String
    let extId: String
    let directURL: URL?
    let thumbnail: String?
    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool { lhs.id == rhs.id }
    var durationFormatted: String {
        guard let d = duration else { return "" }
        let s = Int(d)
        return "• " + String(format: "%d:%02d", s / 60, s % 60)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Download Task
// ---------------------------------------------------------------------------
enum DownloadTaskStatus: Equatable {
    case queued
    case racing(Double)        // racing multiple backends in parallel (0..1 progress)
    case contacting(Double)
    case converting(Double)
    case downloading(Double)
    case done
    case cancelled
    case failed(String)
}

class DownloadTask: ObservableObject, Identifiable {
    let id = UUID()
    let vid: String
    let platform: String
    let proposedName: String
    var directURL: URL?
    var resolvedArtist: String = ""
    var thumbnail: String? = nil
    @Published var status: DownloadTaskStatus = .queued
    @Published var fileName: String = ""
    @Published var backendLabel: String = ""     // which backend won the race (shown in queue UI)
    var autoRetries: Int = 0
    var finalFileURL: URL? = nil
    // Cancellation
    var isCancelled: Bool = false
    // In-flight requests so we can cancel
    var inFlightDataTasks = NSHashTable<URLSessionDataTask>.weakObjects()
    var inFlightDownloadTasks = NSHashTable<URLSessionDownloadTask>.weakObjects()
    var activeChunkedDownloader: ChunkedDownloader?
    var pollTimers: [Timer] = []
    var raceCancelled = false                   // set when another backend won the race
    // Known content length (filled when we probe/head before chunked download)
    var knownContentLength: Int64 = 0

    init(vid: String, platform: String, proposedName: String, directURL: URL? = nil,
         artist: String = "", thumbnail: String? = nil) {
        self.vid = vid; self.platform = platform; self.proposedName = proposedName
        self.directURL = directURL
        self.resolvedArtist = artist
        self.thumbnail = thumbnail
    }

    func cancelAllRequests() {
        isCancelled = true
        raceCancelled = true
        activeChunkedDownloader?.cancel()
        activeChunkedDownloader = nil
        for t in inFlightDataTasks.allObjects { t.cancel() }
        for t in inFlightDownloadTasks.allObjects { t.cancel() }
        for t in pollTimers { t.invalidate() }
        pollTimers.removeAll()
        inFlightDataTasks.removeAllObjects()
        inFlightDownloadTasks.removeAllObjects()
    }
}

// ---------------------------------------------------------------------------
// MARK: - Chunked parallel downloader (beats Cloudflare/y2jar per-connection
// throttle that limits single connections to ~15-25 KB/s after a few MB).
// Opens N parallel connections, each requesting a byte range; collects each
// chunk into memory then writes to the temp file. Reports progress and
// completion on the main queue.
// ---------------------------------------------------------------------------
class ChunkedDownloader: NSObject {
    private let url: URL
    private let referer: String
    private let userAgent: String
    private let totalBytes: Int64
    private let chunkSize: Int
    private let maxConnections: Int
    private let tempFileURL: URL
    private let fileHandle: FileHandle
    private let syncQueue = DispatchQueue(label: "asMusic.chunked")
    private let session: URLSession
    private var nextChunkIndex: Int = 0
    private let totalChunks: Int
    private var bytesWritten: Int64 = 0
    private var failed = false
    private var didFinish = false
    private var activeCount = 0
    private var completedChunks = Set<Int>()
    private let onProgress: (Double) -> Void
    private let onComplete: (Result<URL, Error>) -> Void
    private var isCancelled = false
    private var retriesPerChunk: [Int: Int] = [:]

    init(url: URL, referer: String, userAgent: String, totalBytes: Int64,
         chunkSize: Int = 2_000_000, connections: Int = 6,
         onProgress: @escaping (Double) -> Void,
         onComplete: @escaping (Result<URL, Error>) -> Void) throws {
        self.url = url; self.referer = referer; self.userAgent = userAgent
        self.totalBytes = totalBytes; self.chunkSize = chunkSize
        self.maxConnections = connections
        self.onProgress = onProgress; self.onComplete = onComplete
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpName = "asmusic_chunked_\(UUID().uuidString).dat"
        self.tempFileURL = tmpDir.appendingPathComponent(tmpName)
        // Pre-allocate full file
        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tempFileURL)
        try fh.truncate(atOffset: UInt64(totalBytes))
        self.fileHandle = fh
        let tch = Int((totalBytes + Int64(chunkSize) - 1) / Int64(chunkSize))
        self.totalChunks = tch
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 1800
        cfg.httpMaximumConnectionsPerHost = connections
        cfg.httpShouldUsePipelining = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    func start() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            let n = min(self.maxConnections, self.totalChunks)
            for _ in 0..<n { self.scheduleNext() }
        }
    }

    func cancel() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.failed = true
            self.session.invalidateAndCancel()
            try? self.fileHandle.close()
            try? FileManager.default.removeItem(at: self.tempFileURL)
        }
    }

    private func scheduleNext() {
        if failed || isCancelled { return }
        let idx = nextChunkIndex
        if idx >= totalChunks {
            if activeCount == 0 { finalizeFile() }
            return
        }
        nextChunkIndex += 1
        activeCount += 1
        fetchChunk(idx: idx)
    }

    private func fetchChunk(idx: Int) {
        let start = Int64(idx) * Int64(chunkSize)
        var end = start + Int64(chunkSize) - 1
        if end >= totalBytes { end = totalBytes - 1 }
        let expected = Int(end - start + 1)

        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("keep-alive", forHTTPHeaderField: "Connection")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let t = session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.syncQueue.async {
                self.handleChunkResult(idx: idx, start: start, expected: expected,
                                       data: data, error: err)
            }
        }
        t.resume()
    }

    private func handleChunkResult(idx: Int, start: Int64, expected: Int,
                                   data: Data?, error: Error?) {
        if isCancelled || failed { return }
        if let e = error {
            let code = (e as NSError).code
            if code == -999 { return }
            let r = retriesPerChunk[idx, default: 0]
            if r < 3 {
                retriesPerChunk[idx] = r + 1
                // Deliberately keep `activeCount` unchanged: this slot stays
                // busy while we re-issue the same chunk.
                fetchChunk(idx: idx)
                return
            }
            fail(NSError(domain: "ChunkedDownloader", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Download failed at part \(idx+1): \(e.localizedDescription)"]))
            return
        }
        guard let d = data, d.count == expected else {
            let got = data?.count ?? -1
            let r = retriesPerChunk[idx, default: 0]
            if r < 3 {
                retriesPerChunk[idx] = r + 1
                // Deliberately keep `activeCount` unchanged: this slot stays
                // busy while we re-issue the same chunk.
                fetchChunk(idx: idx)
                return
            }
            fail(NSError(domain: "ChunkedDownloader", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Part \(idx+1) size mismatch: got \(got), expected \(expected)"]))
            return
        }
        // Write directly to the pre-allocated file at the right offset.
        // The old `seek(toFileOffset:)` couldn't report failure, so a bad seek
        // silently wrote the chunk to the wrong place = corrupt audio.
        do {
            try fileHandle.seek(toOffset: UInt64(start))
            try fileHandle.write(contentsOf: d)
        } catch {
            fail(NSError(domain: "ChunkedDownloader", code: -7,
                         userInfo: [NSLocalizedDescriptionKey: "Write failed: \(error.localizedDescription)"]))
            return
        }
        completedChunks.insert(idx)
        bytesWritten += Int64(d.count)
        let p = Double(bytesWritten) / Double(totalBytes)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress(min(0.999, p))
        }
        activeCount -= 1
        if nextChunkIndex < totalChunks {
            scheduleNext()
        } else if activeCount == 0 {
            finalizeFile()
        }
    }

    private func finalizeFile() {
        if didFinish || failed || isCancelled { return }
        didFinish = true
        syncQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fileHandle.synchronize()
                try self.fileHandle.close()
            } catch {}
            self.session.invalidateAndCancel()
            // Sanity: assembled size should equal totalBytes
            let attrs = try? FileManager.default.attributesOfItem(atPath: self.tempFileURL.path)
            let actualSize = (attrs?[.size] as? Int64) ?? 0
            if actualSize != self.totalBytes {
                try? FileManager.default.removeItem(at: self.tempFileURL)
                DispatchQueue.main.async {
                    self.onComplete(.failure(NSError(domain:"ChunkedDownloader",code:-6,
                        userInfo:[NSLocalizedDescriptionKey:"File size mismatch: \(actualSize) vs \(self.totalBytes)"])))
                }
                return
            }
            DispatchQueue.main.async {
                self.onProgress(1.0)
                self.onComplete(.success(self.tempFileURL))
            }
        }
    }

    private func fail(_ error: Error) {
        if failed { return }
        failed = true
        session.invalidateAndCancel()
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: tempFileURL)
        DispatchQueue.main.async { [weak self] in
            self?.onComplete(.failure(error))
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Shared Download Center
// ---------------------------------------------------------------------------
class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadCenter()

    @Published var tasks: [DownloadTask] = []
    @Published var showBanner: Bool = false
    @Published var toastMessage: String? = nil

    private var session: URLSession!
    private var activeTask: DownloadTask?
    private var activeURLTask: URLSessionDownloadTask?
    private var pollTimer: Timer?

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300      // 5 minutes between bytes (for slow mobile)
        config.timeoutIntervalForResource = 7200    // 2 hours for long mixes
        config.httpMaximumConnectionsPerHost = 8
        config.httpShouldUsePipelining = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static let audioExts = ["mp3","m4a","wav","webm","mp4","aac","ogg","opus"]
    static func ensureExt(_ name: String, ext: String) -> String {
        let low = name.lowercased()
        for e in audioExts { if low.hasSuffix("." + e) { return name } }
        return name + "." + ext
    }
    static func y2jarName(_ proposed: String) -> String {
        let low = proposed.lowercased()
        for e in audioExts {
            if low.hasSuffix("." + e) {
                if e == "mp3" { return String(proposed.dropLast(4)) + ".m4a" }
                return proposed
            }
        }
        return proposed + ".m4a"
    }

    // ---- Public API -------------------------------------------------------
    func enqueue(vid: String, platform: String, suggestedName: String,
                 artist: String = "", thumbnail: String? = nil) {
        let name = sanitize(suggestedName)
        if platform == "yt", let existing = MusicManager.shared.songByVID(vid) {
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                self.flashMessage("\(existing.title) is already in your Library")
            }
            return
        }
        let task = DownloadTask(vid: vid, platform: platform, proposedName: name,
                                artist: artist, thumbnail: thumbnail)
        schedule(task)
    }
    func enqueueDirect(url: URL, suggestedName: String, artist: String = "SoundCloud") {
        let name = sanitize(suggestedName)
        let task = DownloadTask(vid: url.absoluteString, platform: "direct",
                                proposedName: name, directURL: url, artist: artist)
        schedule(task)
    }
    func enqueueBatch(_ items: [(vid: String, platform: String, name: String, artist: String, thumb: String?)]) {
        var skipped = 0
        for it in items {
            if it.platform == "yt", MusicManager.shared.songByVID(it.vid) != nil { skipped += 1; continue }
            let name = sanitize(it.name)
            let task = DownloadTask(vid: it.vid, platform: it.platform, proposedName: name,
                                    artist: it.artist, thumbnail: it.thumb)
            DispatchQueue.main.async {
                self.objectWillChange.send()
                self.tasks.insert(task, at: 0)
                self.showBanner = true
            }
        }
        if skipped > 0 {
            DispatchQueue.main.async { self.flashMessage("\(skipped) song(s) already in Library — skipped") }
        }
        DispatchQueue.main.async { if self.activeTask == nil { self.startNext() } }
    }

    /// Cancel a download (whether queued, converting, or downloading).
    func cancel(_ task: DownloadTask) {
        let wasActive = (activeTask?.id == task.id)
        task.cancelAllRequests()
        DispatchQueue.main.async {
            self.objectWillChange.send()
            task.status = .cancelled
            task.backendLabel = ""
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            if wasActive {
                self.activeTask = nil
                self.activeURLTask = nil
                self.pollTimer?.invalidate(); self.pollTimer = nil
                self.startNext()
            }
        }
    }

    private func flashMessage(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toastMessage == msg { self?.toastMessage = nil }
        }
    }

    /// Public toast used by the Discover tab (recommendations).
    func flashDiscovery(_ msg: String) { flashMessage(msg) }

    private func schedule(_ task: DownloadTask) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            self.tasks.insert(task, at: 0)
            self.showBanner = true
            if self.activeTask == nil { self.startNext() }
        }
    }

    func retry(_ task: DownloadTask) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            task.status = .queued
            task.fileName = ""
            task.autoRetries = 0
            task.isCancelled = false
            task.raceCancelled = false
            task.backendLabel = ""
            if self.activeTask == nil { self.startNext() }
            else if self.activeTask?.id == task.id {
                self.activeTask = nil; self.pollTimer?.invalidate(); self.pollTimer = nil
                self.startNext()
            }
        }
    }
    func remove(_ task: DownloadTask) {
        // If active, cancel first
        if activeTask?.id == task.id { cancel(task) }
        else { task.cancelAllRequests() }
        DispatchQueue.main.async {
            self.objectWillChange.send()
            self.tasks.removeAll { $0.id == task.id }
            if self.tasks.isEmpty { self.showBanner = false }
        }
    }
    func clearCompleted() {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            // Remove finished/failed/cancelled
            self.tasks.removeAll { t in
                switch t.status {
                case .done, .failed, .cancelled: return true
                default: return false
                }
            }
            if self.tasks.isEmpty { self.showBanner = false }
        }
    }

    // ---- Queue driver ----------------------------------------------------
    private func startNext() {
        guard let next = tasks.first(where: {
            if case .queued = $0.status { return true }; return false
        }) else { activeTask = nil; pollTimer?.invalidate(); pollTimer = nil; return }
        activeTask = next
        next.isCancelled = false
        next.raceCancelled = false
        next.inFlightDataTasks.removeAllObjects()
        next.inFlightDownloadTasks.removeAllObjects()
        next.pollTimers.removeAll()
        if next.platform == "direct", let u = next.directURL {
            DispatchQueue.main.async { self.objectWillChange.send(); next.status = .downloading(0); next.backendLabel = "Direct"; next.fileName = next.proposedName }
            startMediaDownload(task: next, url: u, finalName: next.proposedName, backendLabel: "Direct")
        } else if next.platform == "sc", let u = next.directURL {
            DispatchQueue.main.async { self.objectWillChange.send(); next.status = .contacting(0.3); next.backendLabel = "SoundCloud"; next.fileName = next.proposedName }
            preflightAndDownloadSC(task: next, url: u)
        } else {
            DispatchQueue.main.async { self.objectWillChange.send(); next.status = .racing(0.05); next.backendLabel = ""; next.fileName = next.proposedName }
            // ------ PARALLEL RACE across fast backends ---------------------
            // Fire them all at once. Whichever produces a valid media URL first
            // wins the race; we cancel the others. If ALL fast backends fail,
            // fall back to the slow Theta/mp3juice poll pipeline.
            startFastRace(task: next)
        }
    }

    // =====================================================================
    // FAST RACE: y2jar (DIRECT, no transcode) + worker mirrors + cnvmp3
    // y2jar goes FIRST because it returns direct M4A links in ~0.5s with
    // ZERO server conversion time (it proxies YouTube's native audio),
    // making it the fastest backend by far for long songs/mixes.
    // =====================================================================
    private func startFastRace(task: DownloadTask) {
        let winnerQueue = DispatchQueue(label: "asMusic.race")
        var resolved = false
        var failedCount = 0
        // NEW: extra alternative-engine contenders join the classic 3.
        // Additive: with none configured this is exactly the classic race.
        let extraRacers = NewExtractors.racers()
        let totalContenders = 3 + extraRacers.count
        func tryWin(_ label: String, downloadURL: URL, finalName: String, referer: String = "https://mp3juice.sc/") {
            winnerQueue.async { [weak self] in
                guard let self = self else { return }
                if resolved || task.isCancelled { return }
                resolved = true
                task.raceCancelled = true
                for t in task.inFlightDataTasks.allObjects { t.cancel() }
                for tm in task.pollTimers { tm.invalidate() }
                task.pollTimers.removeAll()
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                    task.backendLabel = label
                    task.status = .downloading(0)
                    task.fileName = finalName
                }
                self.startMediaDownload(task: task, url: downloadURL, finalName: finalName,
                                        validate: true, referer: referer, backendLabel: label)
            }
        }
        func oneFailed(_ reason: String) {
            winnerQueue.async { [weak self] in
                guard let self = self else { return }
                failedCount += 1
                let p = min(0.5, Double(failedCount) / Double(totalContenders + 1))
                if !resolved && !task.isCancelled {
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                        if case .racing = task.status { task.status = .racing(p) }
                    }
                }
                log.debug("[\(reason)] failed, \(failedCount)/\(totalContenders)")
                if failedCount >= totalContenders && !resolved && !task.isCancelled {
                    DispatchQueue.main.async {
                        self.objectWillChange.send()
                        task.status = .contacting(0.2)
                        task.backendLabel = ""
                    }
                    // Try the slow theta/worker pipeline (longer timeout for long tracks)
                    self.beginMp3Juice(task: task)
                }
            }
        }

        // Contender 1: y2jar — returns instant M4A direct link, NO TRANSCODE.
        // For long videos/mixes this is always the fastest because YouTube
        // already serves the AAC audio natively; we just stream it.
        y2jarRace(task: task, win: { url,name in tryWin("Y2JAR⚡", downloadURL:url, finalName:name, referer:"https://v2.y2jar.cc/") },
                  lose: { oneFailed("y2jar") })

        // Contender 2: mp3juice worker mirrors (instant MP3 for short songs,
        // may need MP3 re-encode poll for longer tracks — hence slower).
        workerRace(task: task, win: { url,name,ref in tryWin("Mp3Juice", downloadURL:url, finalName:name, referer:ref) },
                   lose: { oneFailed("worker") })

        // Contender 3: cnvmp3 — often duration-limited to ~90min, but fast
        // for short songs. Detect the limit error quickly and move on.
        cnvmp3Race(task: task, win: { url,name in tryWin("cnvmp3", downloadURL:url, finalName:name, referer:"https://cnvmp3.com/v55") },
                   lose: { oneFailed("cnvmp3") })

        // NEW contenders 4+: Piped / Invidious / Cobalt / MyServer. Each must
        // probe-validate its URL before it may win; losers just call oneFailed.
        for c in extraRacers {
            c.run(task,
                  { url, name in tryWin(c.label, downloadURL: url, finalName: name, referer: c.referer) },
                  { oneFailed(c.label) })
        }
    }

    // ---- Fast-race: worker mirrors (parallel within the group) -----------
    private func workerRace(task: DownloadTask,
                            win: @escaping (URL, String, String) -> Void,
                            lose: @escaping () -> Void) {
        let mirrors = workerURLs
        let g = DispatchGroup()
        var anySucceeded = false
        let lock = NSLock()
        for (idx, base) in mirrors.enumerated() {
            g.enter()
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            let urlStr = "\(base)&v=\(task.vid)&f=mp3&_=\(ts)"
            guard let u = URL(string: urlStr) else { g.leave(); continue }
            var req = URLRequest(url: u, timeoutInterval: 15)
            req.httpMethod = "GET"
            req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
            req.setValue("https://mp3juice.sc/", forHTTPHeaderField: "Referer")
            req.setValue("https://mp3juice.sc", forHTTPHeaderField: "Origin")
            req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
            let t = URLSession.shared.dataTask(with: req) { data, resp, err in
                defer { g.leave() }
                if task.raceCancelled || task.isCancelled { return }
                lock.lock(); let already = anySucceeded; lock.unlock()
                if already { return }
                if let err = err { log.debug("worker mirror \(idx) err: \(err.localizedDescription)"); return }
                guard let data = data,
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] else { return }
                if let e = d["error"] as? Int, e != 0 { log.debug("worker mirror \(idx) err=\(e)"); return }
                // Direct download URL (instant short track, OR sometimes returned
                // immediately alongside progress for long tracks — try it!).
                if let dl = d["downloadURL"] as? String, !dl.isEmpty {
                    let decoded = self.decodeWorkerURL(dl)
                    if let du = URL(string: decoded) {
                        // Probe the decoded URL with a tiny Range request: if it
                        // returns audio/mpeg with real Content-Length, it's ready.
                        self.probeForAudio(url: du, referer: "https://mp3juice.sc/") { [weak self] ready in
                            guard let self = self else { return }
                            if task.raceCancelled || task.isCancelled { return }
                            lock.lock(); let already2 = anySucceeded; lock.unlock()
                            if already2 { return }
                            if ready {
                                lock.lock(); anySucceeded = true; lock.unlock()
                                var name = task.proposedName
                                if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                                win(du, name, "https://mp3juice.sc/")
                                return
                            }
                            // Not ready yet — fall into polling if progressURL exists
                            if let purl = d["progressURL"] as? String, !purl.isEmpty {
                                self.workerPollRace(task: task, progURL: purl, mirrorIndex: idx,
                                                    lock: lock, anySucceeded: { lock.lock(); let v=anySucceeded; lock.unlock(); return v },
                                                    setSucceeded: { lock.lock(); anySucceeded=true; lock.unlock() },
                                                    win: { url in
                                                        lock.lock(); anySucceeded = true; lock.unlock()
                                                        var name = task.proposedName
                                                        if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                                                        win(url, name, "https://mp3juice.sc/")
                                                    })
                            }
                        }
                        return
                    }
                }
                // Progress URL — poll until ready (slow MP3 transcode path)
                if let purl = d["progressURL"] as? String, !purl.isEmpty {
                    self.workerPollRace(task: task, progURL: purl, mirrorIndex: idx,
                                        lock: lock, anySucceeded: { lock.lock(); let v=anySucceeded; lock.unlock(); return v },
                                        setSucceeded: { lock.lock(); anySucceeded=true; lock.unlock() },
                                        win: { url in
                                            lock.lock(); anySucceeded = true; lock.unlock()
                                            var name = task.proposedName
                                            if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                                            win(url, name, "https://mp3juice.sc/")
                                        })
                }
            }
            task.inFlightDataTasks.add(t)
            t.resume()
        }
        g.notify(queue: .global()) {
            lock.lock(); let ok = anySucceeded; lock.unlock()
            if !ok { lose() }
        }
    }

    /// Probe a URL quickly: send a small Range request and return true if it
    /// looks like a real audio response (right content-type or magic bytes).
    /// Internal (not private) so NEW race contenders in ExtractorKit can
    /// validate their URLs too — zero behavior change to existing callers.
    func probeForAudio(url: URL, referer: String, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let probeTask = URLSession.shared.dataTask(with: req) { data, resp, err in
            if err != nil { completion(false); return }
            guard let hr = resp as? HTTPURLResponse else { completion(false); return }
            // 206 Partial Content = range accepted; 200 = server ignores range but returns full file
            guard hr.statusCode == 206 || hr.statusCode == 200 else { completion(false); return }
            let ct = hr.mimeType ?? ""
            if ct.contains("audio") || ct.contains("mpeg") || ct.contains("mp4") { completion(true); return }
            // Magic byte sniff
            if let d = data, d.count >= 3 {
                let b = [UInt8](d.prefix(8))
                if b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { completion(true); return }
                if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { completion(true); return }
                if d.count >= 8 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { completion(true); return }
            }
            // text/plain with long content-length = not ready yet
            completion(false)
        }
        probeTask.resume()
    }

    private func workerPollRace(task: DownloadTask, progURL: String, mirrorIndex: Int,
                                lock: NSLock,
                                anySucceeded: @escaping () -> Bool,
                                setSucceeded: @escaping () -> Void,
                                win: @escaping (URL) -> Void) {
        var ticks = 0
        // Longer timeout for long tracks: 180 ticks * 2s = 6 minutes (covers 2+hr mixes).
        let maxTicks = 180
        func tick() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                if task.raceCancelled || task.isCancelled { return }
                if anySucceeded() { return }
                ticks += 1
                if ticks > maxTicks { return }
                guard let u = URL(string: progURL) else { return }
                var req = URLRequest(url: u, timeoutInterval: 10)
                req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
                req.setValue("https://mp3juice.sc/", forHTTPHeaderField: "Referer")
                let dt = URLSession.shared.dataTask(with: req) { data, _, _ in
                    if task.raceCancelled || task.isCancelled { return }
                    if anySucceeded() { return }
                    guard let data = data,
                          let d = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] else {
                        tick(); return
                    }
                    if let e = d["error"] as? Int, e != 0 { return }
                    let status = d["status"] as? String ?? ""
                    let prog = (d["progress"] as? NSNumber)?.doubleValue ?? 0
                    // "download" = fully ready
                    if status == "download", let dl = d["downloadURL"] as? String {
                        let decoded = self.decodeWorkerURL(dl)
                        if let du = URL(string: decoded) { setSucceeded(); win(du); return }
                    }
                    // For theta numeric progress >= 3 (converting/uploading) we
                    // also re-probe the direct download URL — it may already be
                    // partially served. We only take it if it validates as audio.
                    if prog >= 3, let dl = d["downloadURL"] as? String {
                        let decoded = self.decodeWorkerURL(dl)
                        if let du = URL(string: decoded) {
                            self.probeForAudio(url: du, referer: "https://mp3juice.sc/") { ready in
                                if task.raceCancelled || task.isCancelled { return }
                                if anySucceeded() { return }
                                if ready { setSucceeded(); win(du); return }
                                tick()
                            }
                            return
                        }
                    }
                    tick()
                }
                task.inFlightDataTasks.add(dt)
                dt.resume()
            }
        }
        tick()
    }

    // ---- Fast-race: y2jar (nbike.pl) --------------------------------------
    private func y2jarRace(task: DownloadTask,
                           win: @escaping (URL, String) -> Void,
                           lose: @escaping () -> Void) {
        guard let infoURL = URL(string: "\(y2jarInfoURL)\(task.vid)") else { lose(); return }
        var req = URLRequest(url: infoURL, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://v2.y2jar.cc/", forHTTPHeaderField: "Referer")
        let t = URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            if task.raceCancelled || task.isCancelled { return }
            guard let data = data, err == nil,
                  let info = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
                  let _ = info["title"] as? String else { lose(); return }
            self.y2jarRaceToken(task: task, win: win, lose: lose)
        }
        task.inFlightDataTasks.add(t); t.resume()
    }

    private func y2jarRaceToken(task: DownloadTask,
                                win: @escaping (URL, String) -> Void,
                                lose: @escaping () -> Void) {
        guard let tokenURL = URL(string: "\(self.y2jarStreamTokenURL)\(task.vid)?a=") else { lose(); return }
        var tr = URLRequest(url: tokenURL, timeoutInterval: 12)
        tr.httpMethod = "GET"
        tr.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        tr.setValue("application/json", forHTTPHeaderField: "Accept")
        tr.setValue("https://v2.y2jar.cc/", forHTTPHeaderField: "Referer")
        tr.setValue("https://v2.y2jar.cc", forHTTPHeaderField: "Origin")
        let t2 = URLSession.shared.dataTask(with: tr) { [weak self] tdata, _, terr in
            guard let self = self else { return }
            if task.raceCancelled || task.isCancelled { return }
            guard let tdata = tdata, terr == nil,
                  let tj = (try? JSONSerialization.jsonObject(with: tdata)) as? [String:Any],
                  let token = tj["token"] as? String, token.count > 10,
                  let enc = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let dlURL = URL(string: "\(self.y2jarDownloadURL)\(task.vid)?token=\(enc)") else {
                lose(); return
            }
            let finalName = DownloadCenter.y2jarName(task.proposedName)
            win(dlURL, finalName)
        }
        task.inFlightDataTasks.add(t2); t2.resume()
    }

    // ---- Fast-race: cnvmp3.com -------------------------------------------
    private func cnvmp3Race(task: DownloadTask,
                            win: @escaping (URL, String) -> Void,
                            lose: @escaping () -> Void) {
        guard let infoURL = URL(string: cnvmp3GetInfoURL),
              let convURL = URL(string: cnvmp3ConvertURL) else { lose(); return }
        let ytURL = "https://www.youtube.com/watch?v=\(task.vid)"
        var infoReq = URLRequest(url: infoURL, timeoutInterval: 15)
        infoReq.httpMethod = "POST"
        infoReq.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        infoReq.setValue("application/json", forHTTPHeaderField: "Accept")
        infoReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        infoReq.setValue("https://cnvmp3.com/v55", forHTTPHeaderField: "Referer")
        infoReq.setValue("https://cnvmp3.com", forHTTPHeaderField: "Origin")
        let infoBody: [String:Any] = ["url": ytURL, "token": "1234"]
        guard let infoBodyData = try? JSONSerialization.data(withJSONObject: infoBody) else { lose(); return }
        infoReq.httpBody = infoBodyData
        let infoTask = URLSession.shared.dataTask(with: infoReq) { [weak self] data, _, err in
            guard let self = self else { return }
            if task.raceCancelled || task.isCancelled { return }
            var resolvedTitle = task.proposedName
            if let data = data, err == nil,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
               let titleStr = j["title"] as? String, !titleStr.isEmpty {
                resolvedTitle = titleStr
            }
            self.cnvmp3RaceConvert(task: task, convURL: convURL, ytURL: ytURL,
                                   resolvedTitle: resolvedTitle, win: win, lose: lose)
        }
        task.inFlightDataTasks.add(infoTask); infoTask.resume()
    }

    private func cnvmp3RaceConvert(task: DownloadTask, convURL: URL, ytURL: String,
                                   resolvedTitle: String,
                                   win: @escaping (URL, String) -> Void,
                                   lose: @escaping () -> Void) {
        var convReq = URLRequest(url: convURL, timeoutInterval: 120)
        convReq.httpMethod = "POST"
        convReq.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        convReq.setValue("application/json", forHTTPHeaderField: "Accept")
        convReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        convReq.setValue("https://cnvmp3.com/v55", forHTTPHeaderField: "Referer")
        convReq.setValue("https://cnvmp3.com", forHTTPHeaderField: "Origin")
        let convBody: [String:Any] = ["url": ytURL, "quality": 4, "title": resolvedTitle, "formatValue": 1]
        guard let convBodyData = try? JSONSerialization.data(withJSONObject: convBody) else { lose(); return }
        convReq.httpBody = convBodyData
        let t2 = URLSession.shared.dataTask(with: convReq) { cdata, _, cerr in
            if task.raceCancelled || task.isCancelled { return }
            guard let cdata = cdata, cerr == nil else { lose(); return }
            guard let cj = (try? JSONSerialization.jsonObject(with: cdata)) as? [String:Any] else { lose(); return }
            if (cj["success"] as? Bool) == false { lose(); return }
            guard let dl = cj["download_link"] as? String, !dl.isEmpty,
                  let dlURL = URL(string: dl) else { lose(); return }
            let finalName = DownloadCenter.ensureExt(task.proposedName, ext: "mp3")
            win(dlURL, finalName)
        }
        task.inFlightDataTasks.add(t2); t2.resume()
    }

    // ---- SoundCloud preflight --------------------------------------------
    private func preflightAndDownloadSC(task: DownloadTask, url: URL) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://mp3juice.sc/", forHTTPHeaderField: "Referer")
        req.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let dt = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if task.isCancelled { return }
            if let err = err {
                self.failOrRetry(task: task, message: "SoundCloud link failed: \(err.localizedDescription)")
                return
            }
            let ct = (resp as? HTTPURLResponse)?.mimeType ?? ""
            let d = data ?? Data()
            if ct.contains("audio") || ct.contains("mpeg") {
                self.startMediaDownload(task: task, url: url, finalName: task.proposedName,
                                        validate: true, backendLabel: "SoundCloud")
                return
            }
            let b = [UInt8](d.prefix(12))
            if b.count >= 3 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { self.startMediaDownload(task: task, url: url, finalName: task.proposedName, validate: true, backendLabel: "SoundCloud"); return }
            if b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { self.startMediaDownload(task: task, url: url, finalName: task.proposedName, validate: true, backendLabel: "SoundCloud"); return }
            self.failOrRetry(task: task, message: "SoundCloud track unavailable (try another result)")
        }
        task.inFlightDataTasks.add(dt)
        dt.resume()
    }

    // ---- Finish / fail ---------------------------------------------------
    private func finish(task: DownloadTask) {
        let finalName = task.fileName.isEmpty ? task.proposedName : task.fileName
        let destDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let finalURL = destDir.appendingPathComponent(finalName)
        task.finalFileURL = finalURL
        let sourceVid = (task.platform == "yt" || task.platform == "sc") ? task.vid : nil
        MusicManager.shared.registerDownloadedSong(
            title: task.proposedName,
            artist: task.resolvedArtist,
            url: finalURL,
            sourceVid: sourceVid,
            artworkURL: task.thumbnail
        )
        DispatchQueue.main.async {
            task.status = .done
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            MusicManager.shared.loadSongs()
            self.activeTask = nil
            self.pollTimer?.invalidate(); self.pollTimer = nil
            self.startNext()
        }
    }
    /// Task ids that already consumed their one SoundCloud fallback attempt.
    private var scFallbackTried = Set<UUID>()
    private let scFallbackLock = NSLock()

    /// One additive SoundCloud-API attempt after the classic engines failed.
    /// Returns true when an attempt was launched (caller must return without
    /// marking failed — this method re-invokes failOrRetry when the attempt
    /// resolves). Returns false to proceed with the classic failure path.
    private func soundCloudFallback(task: DownloadTask, message: String) -> Bool {
        if task.isCancelled { return false }
        let q = task.proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return false }
        scFallbackLock.lock()
        let already = scFallbackTried.contains(task.id)
        if !already { scFallbackTried.insert(task.id) }
        scFallbackLock.unlock()
        if already { return false }
        log.debug("[scapi] classic engines failed — trying SoundCloud API fallback")
        SoundCloudResolver.resolve(pageURL: nil, titleQuery: q) { [weak self] url in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard let u = url else {
                self.failOrRetry(task: task, message: message)
                return
            }
            self.probeForAudio(url: u, referer: "https://soundcloud.com/") { [weak self] ready in
                guard let self = self else { return }
                if task.isCancelled { return }
                if !ready {
                    self.failOrRetry(task: task, message: message)
                    return
                }
                BackendHealth.shared.recordSuccess("scapi")
                var name = task.proposedName
                if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                self.startMediaDownload(task: task, url: u, finalName: name,
                                        referer: "https://soundcloud.com/", backendLabel: "SoundCloud")
            }
        }
        return true
    }

    private func failOrRetry(task: DownloadTask, message: String) {
        if task.isCancelled { return }
        if task.autoRetries < 3 {
            task.autoRetries += 1
            log.warning("Retrying (\(task.autoRetries)): \(message)")
            DispatchQueue.main.async {
                self.objectWillChange.send()
                task.status = .queued
                task.fileName = ""
                task.backendLabel = ""
                task.raceCancelled = false
                self.pollTimer?.invalidate(); self.pollTimer = nil
                if self.activeTask?.id == task.id { self.activeTask = nil }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    DispatchQueue.main.async { self.startNext() }
                }
            }
            return
        }
        // NEW: one additive SoundCloud-API attempt before terminal failure.
        if self.soundCloudFallback(task: task, message: message) { return }
        DispatchQueue.main.async {
            task.status = .failed(message)
            log.error("Download failed: \(message, privacy: .public)")
            self.activeTask = nil
            self.pollTimer?.invalidate(); self.pollTimer = nil
            self.startNext()
        }
    }

    private func sanitize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "-")
        let invalid = CharacterSet(charactersIn: "\\:*?\"<>|")
        out = out.components(separatedBy: invalid).joined(separator: "-")
        // Strip control characters that would otherwise survive into the name.
        out = out.components(separatedBy: .controlCharacters).joined()
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot makes the file hidden — and `loadSongs()` filters hidden
        // files out, so the track would download fine and never appear in the
        // library (e.g. "...Baby One More Time").
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return "Track" }
        // APFS caps a file name at 255 *bytes*; Arabic titles are 2 bytes/char,
        // so a ~130 character title used to fail the final move outright.
        let ext = (out as NSString).pathExtension
        var stem = (out as NSString).deletingPathExtension
        let budget = 200 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        while stem.utf8.count > budget && !stem.isEmpty { stem.removeLast() }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = "Track" }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    // ---- Backend URLs ----------------------------------------------------
    private let workerURLs = [
        "https://fancy-sea-5d3d.holy-breeze-fec5.workers.dev/?m=i",
    ]
    private let y2jarInfoURL = "https://v2.y2jar.cc/i/"
    private let y2jarStreamTokenURL = "https://capi.y2jar.cc/st/a/"
    private let y2jarDownloadURL = "https://capi.y2jar.cc/s/"
    private let cnvmp3GetInfoURL = "https://cnvmp3.com/get_video_data.php"
    private let cnvmp3ConvertURL  = "https://cnvmp3.com/download_video_ucep.php"
    private let thetaMirrors = ["theta","ocococ","cocooo","cooooo","occcco","ccccco","cococo","ococco","ccocco"]

    // ---- Sequential fallbacks (kept for slow path) -----------------------
    private func workerStart(task: DownloadTask) {
        // Used only as fallback if fast-race isn't invoked.
        tryWorkerOnMirrors(task: task, mirrors: workerURLs, index: 0)
    }
    private func tryWorkerOnMirrors(task: DownloadTask, mirrors: [String], index: Int) {
        guard index < mirrors.count else { startY2jar(task: task); return }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let urlStr = "\(mirrors[index])&v=\(task.vid)&f=mp3&_=\(ts)"
        guard let u = URL(string: urlStr) else { tryWorkerOnMirrors(task:task, mirrors:mirrors, index:index+1); return }
        DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(0.3 + 0.1*Double(index)) }
        jsonGet(u, bearer: nil, task: task) { [weak self] result in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard case let .success(d) = result else { self.tryWorkerOnMirrors(task:task, mirrors:mirrors, index:index+1); return }
            if let e = d["error"] as? Int, e != 0 {
                if index+1 < mirrors.count { self.tryWorkerOnMirrors(task:task, mirrors:mirrors, index:index+1) }
                else { self.startY2jar(task: task) }
                return
            }
            if let dl = d["downloadURL"] as? String, !dl.isEmpty {
                let decoded = self.decodeWorkerURL(dl)
                if let du = URL(string: decoded) {
                    var name = task.proposedName
                    if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                    self.startMediaDownload(task: task, url: du, finalName: name, validate: true, backendLabel: "Mp3Juice")
                    return
                }
            }
            if let purl = d["progressURL"] as? String, !purl.isEmpty {
                self.workerPoll(task: task, progURL: purl, ticks: 0)
                return
            }
            self.startY2jar(task: task)
        }
    }

    private func workerPoll(task: DownloadTask, progURL: String, ticks: Int) {
        pollTimer?.invalidate()
        // 1.5s * 300 = 7.5 min max — enough for 2hr+ MP3 encodes on theta workers
        let maxTicks = 300
        var tickCount = ticks
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if task.isCancelled { t.invalidate(); return }
            tickCount += 1
            guard let u = URL(string: progURL) else { t.invalidate(); self.failOrRetry(task: task, message: "Bad worker URL"); return }
            self.jsonGet(u, bearer: nil, task: task) { [weak self] result in
                guard let self = self else { return }
                if task.isCancelled { t.invalidate(); return }
                guard case let .success(d) = result else { return }
                if let e = d["error"] as? Int, e != 0 {
                    t.invalidate(); self.pollTimer = nil
                    self.startY2jar(task: task); return
                }
                let status = d["status"] as? String ?? ""
                let displayProg: Double
                if status == "download" { displayProg = 0.99 }
                else if status == "processing" { displayProg = 0.5 + min(0.45, Double(tickCount)/200.0) }
                else { displayProg = 0.2 + min(0.3, Double(tickCount)/100.0) }
                DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(displayProg) }
                if status == "download", let dl = d["downloadURL"] as? String {
                    t.invalidate(); self.pollTimer = nil
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        let decoded = self.decodeWorkerURL(dl)
                        if let du = URL(string: decoded) {
                            var name = task.proposedName
                            if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                            self.startMediaDownload(task: task, url: du, finalName: name, validate: true, backendLabel: "Mp3Juice")
                        } else {
                            self.failOrRetry(task: task, message: "Bad final URL")
                        }
                    }
                    return
                }
                if tickCount > maxTicks {
                    t.invalidate(); self.pollTimer = nil
                    self.startY2jar(task: task)
                }
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        task.pollTimers.append(pollTimer!)
    }

    private func decodeWorkerURL(_ s: String) -> String {
        if s.contains("m=d&u=") || s.contains("m=p&u=") {
            guard let comps = URLComponents(string: s),
                  let u = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return s }
            let pad = u + String(repeating: "=", count: (4 - u.count % 4) % 4)
            if let data = Data(base64Encoded: pad), let dec = String(data: data, encoding: .utf8) {
                return dec
            }
        }
        return s
    }

    // ---- Theta / mp3juice pipeline (slow fallback) -----------------------
    private func beginMp3Juice(task: DownloadTask) {
        mp3JuiceAuth { [weak self] key in
            guard let self = self else { return }
            if task.isCancelled { return }
            if let key = key {
                self.mp3JuiceInit(task: task, key: key)
            } else {
                self.failOrRetry(task: task, message: "All download servers failed")
            }
        }
    }
    private func thetaURL(_ sub: String, path: String, _ ts: Int) -> URL? {
        URL(string: "https://\(sub).thetacloud.org/api/v1/\(path)?_=\(ts)")
    }
    private func startY2jar(task: DownloadTask) {
        DispatchQueue.main.async { self.objectWillChange.send(); task.status = .contacting(0.3); task.backendLabel = "Y2JAR⚡" }
        guard let infoURL = URL(string: "\(y2jarInfoURL)\(task.vid)") else {
            startCnvmp3(task: task); return
        }
        var req = URLRequest(url: infoURL, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://v2.y2jar.cc/", forHTTPHeaderField: "Referer")
        let dt = URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard let data = data, err == nil,
                  let info = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
                  let _ = info["title"] as? String else {
                self.startCnvmp3(task: task); return
            }
            self.startY2jarToken(task: task)
        }
        task.inFlightDataTasks.add(dt); dt.resume()
    }

    private func startY2jarToken(task: DownloadTask) {
        guard let tokenURL = URL(string: "\(self.y2jarStreamTokenURL)\(task.vid)?a=") else { self.startCnvmp3(task: task); return }
        var tr = URLRequest(url: tokenURL, timeoutInterval: 15)
        tr.httpMethod = "GET"
        tr.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        tr.setValue("application/json", forHTTPHeaderField: "Accept")
        tr.setValue("https://v2.y2jar.cc/", forHTTPHeaderField: "Referer")
        tr.setValue("https://v2.y2jar.cc", forHTTPHeaderField: "Origin")
        let t2 = URLSession.shared.dataTask(with: tr) { [weak self] tdata, _, terr in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard let tdata = tdata, terr == nil,
                  let tj = (try? JSONSerialization.jsonObject(with: tdata)) as? [String:Any],
                  let token = tj["token"] as? String, token.count > 10 else {
                self.startCnvmp3(task: task); return
            }
            DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(0.7) }
            let finalName = DownloadCenter.y2jarName(task.proposedName)
            let enc = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            guard let dlURL = URL(string: "\(self.y2jarDownloadURL)\(task.vid)?token=\(enc)") else { self.startCnvmp3(task: task); return }
            DispatchQueue.main.async { task.fileName = finalName }
            self.startMediaDownload(task: task, url: dlURL, finalName: finalName, validate: true, referer:"https://v2.y2jar.cc/", backendLabel: "Y2JAR⚡")
        }
        task.inFlightDataTasks.add(t2); t2.resume()
    }

    private func startCnvmp3(task: DownloadTask) {
        DispatchQueue.main.async { self.objectWillChange.send(); task.status = .contacting(0.4); task.backendLabel = "cnvmp3" }
        guard let infoURL = URL(string: cnvmp3GetInfoURL),
              let convURL = URL(string: cnvmp3ConvertURL) else { beginMp3Juice(task: task); return }
        let ytURL = "https://www.youtube.com/watch?v=\(task.vid)"
        var infoReq = URLRequest(url: infoURL, timeoutInterval: 20)
        infoReq.httpMethod = "POST"
        infoReq.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        infoReq.setValue("application/json", forHTTPHeaderField: "Accept")
        infoReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        infoReq.setValue("https://cnvmp3.com/v55", forHTTPHeaderField: "Referer")
        infoReq.setValue("https://cnvmp3.com", forHTTPHeaderField: "Origin")
        let infoBody: [String:Any] = ["url": ytURL, "token": "1234"]
        guard let infoBodyData = try? JSONSerialization.data(withJSONObject: infoBody) else { beginMp3Juice(task: task); return }
        infoReq.httpBody = infoBodyData
        let dtInfo = URLSession.shared.dataTask(with: infoReq) { [weak self] data, _, err in
            guard let self = self else { return }
            if task.isCancelled { return }
            var resolvedTitle = task.proposedName
            if let data = data, err == nil,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
               let titleStr = j["title"] as? String, !titleStr.isEmpty { resolvedTitle = titleStr }
            DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(0.6) }
            self.startCnvmp3Convert(task: task, convURL: convURL, ytURL: ytURL, resolvedTitle: resolvedTitle)
        }
        task.inFlightDataTasks.add(dtInfo); dtInfo.resume()
    }

    private func startCnvmp3Convert(task: DownloadTask, convURL: URL, ytURL: String, resolvedTitle: String) {
        var convReq = URLRequest(url: convURL, timeoutInterval: 90)
        convReq.httpMethod = "POST"
        convReq.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        convReq.setValue("application/json", forHTTPHeaderField: "Accept")
        convReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        convReq.setValue("https://cnvmp3.com/v55", forHTTPHeaderField: "Referer")
        convReq.setValue("https://cnvmp3.com", forHTTPHeaderField: "Origin")
        let convBody: [String:Any] = ["url": ytURL, "quality": 4, "title": resolvedTitle, "formatValue": 1]
        guard let convBodyData = try? JSONSerialization.data(withJSONObject: convBody) else { self.beginMp3Juice(task: task); return }
        convReq.httpBody = convBodyData
        let t2 = URLSession.shared.dataTask(with: convReq) { [weak self] cdata, _, cerr in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard let cdata = cdata, cerr == nil else { self.beginMp3Juice(task: task); return }
            guard let cj = (try? JSONSerialization.jsonObject(with: cdata)) as? [String:Any] else { self.beginMp3Juice(task: task); return }
            if (cj["success"] as? Bool) == false { self.beginMp3Juice(task: task); return }
            guard let dl = cj["download_link"] as? String, !dl.isEmpty,
                  let dlURL = URL(string: dl) else { self.beginMp3Juice(task: task); return }
            DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(0.9) }
            let finalName = DownloadCenter.ensureExt(task.proposedName, ext: "mp3")
            DispatchQueue.main.async { task.fileName = finalName }
            self.startMediaDownload(task: task, url: dlURL, finalName: finalName, validate: true,
                                    referer: "https://cnvmp3.com/v55", backendLabel: "cnvmp3")
        }
        task.inFlightDataTasks.add(t2); t2.resume()
    }

    private func mp3JuiceAuth(completion: @escaping (String?) -> Void) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        tryThetaAuth(mirrors: thetaMirrors, ts: ts, completion: completion)
    }
    private func tryThetaAuth(mirrors: [String], ts: Int, completion: @escaping (String?) -> Void) {
        var remaining = Array(mirrors)
        func attempt() {
            guard let mirror = remaining.first else { completion(nil); return }
            remaining.removeFirst()
            guard let url = thetaURL(mirror, path: "auth", ts) else { attempt(); return }
            jsonGet(url, bearer: nil, task: nil) { result in
                if case let .success(d) = result, let key = d["key"] as? String, !key.isEmpty {
                    completion(key); return
                }
                attempt()
            }
        }
        attempt()
    }
    private func mp3JuiceInit(task: DownloadTask, key: String) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        tryThetaInit(mirrors: thetaMirrors, ts: ts, key: key, retries: 2) { [weak self] convertURL in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard let convertURL = convertURL else {
                self.failOrRetry(task: task, message: "Could not reach download server"); return
            }
            DispatchQueue.main.async { self.objectWillChange.send(); task.status = .contacting(0.3); task.backendLabel = "Mp3Juice" }
            let ts2 = Int(Date().timeIntervalSince1970 * 1000)
            let full = convertURL + "&v=\(task.vid)&f=mp3&_=\(ts2)"
            self.mp3JuiceConvert(task: task, key: key, url: full, hops: 0)
        }
    }
    private func tryThetaInit(mirrors: [String], ts: Int, key: String, retries: Int, completion: @escaping (String?) -> Void) {
        var rem = Array(mirrors)
        func attempt(retryCount: Int) {
            guard let mirror = rem.first else {
                if retryCount > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self = self else { return }
                        self.tryThetaInit(mirrors: mirrors, ts: Int(Date().timeIntervalSince1970*1000),
                                          key: key, retries: retryCount-1, completion: completion)
                    }
                } else { completion(nil) }
                return
            }
            rem.removeFirst()
            guard let url = thetaURL(mirror, path: "init", ts) else { attempt(retryCount:retryCount); return }
            jsonGet(url, bearer: key, task: nil) { result in
                if case let .success(d) = result, let cu = d["convertURL"] as? String, !cu.isEmpty { completion(cu); return }
                attempt(retryCount:retryCount)
            }
        }
        attempt(retryCount: retries)
    }
    private func mp3JuiceConvert(task: DownloadTask, key: String?, url: String, hops: Int) {
        guard hops < 15 else { failOrRetry(task: task, message: "Too many server redirects"); return }
        guard let u = URL(string: url) else { failOrRetry(task: task, message: "Bad URL"); return }
        if task.isCancelled { return }
        DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(0.1) }
        jsonGet(u, bearer: key, task: task) { [weak self] result in
            guard let self = self else { return }
            if task.isCancelled { return }
            guard case let .success(d) = result else {
                self.failOrRetry(task: task, message: "Convert network error"); return
            }
            if let e = d["error"] as? Int, e != 0 {
                self.failOrRetry(task: task, message: "Convert error \(e)"); return
            }
            if let redir = d["redirect"] as? Int, redir == 1, let next = d["redirectURL"] as? String {
                self.mp3JuiceConvert(task: task, key: key, url: next, hops: hops+1); return
            }
            if let prog = d["progressURL"] as? String, !prog.isEmpty {
                self.pollConvertProgress(task: task, key: key, progURL: prog, ticks: 0); return
            }
            if let dl = d["downloadURL"] as? String, !dl.isEmpty, let du = URL(string: dl) {
                var name = task.proposedName
                if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                self.startMediaDownload(task: task, url: du, finalName: name, validate: true, backendLabel: "Mp3Juice"); return
            }
            self.failOrRetry(task: task, message: "Unexpected server response")
        }
    }
    private func pollConvertProgress(task: DownloadTask, key: String?, progURL: String, ticks: Int) {
        pollTimer?.invalidate()
        // 2s * 300 = 10 minutes for long tracks
        let maxTicks = 300
        if ticks > maxTicks { failOrRetry(task: task, message: "Conversion timed out"); return }
        var tickCount = ticks
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if task.isCancelled { t.invalidate(); return }
            tickCount += 1
            guard let u = URL(string: progURL) else { t.invalidate(); self.failOrRetry(task: task, message: "Bad progress URL"); return }
            self.jsonGet(u, bearer: key, task: task) { [weak self] result in
                guard let self = self else { return }
                if task.isCancelled { t.invalidate(); return }
                guard case let .success(d) = result else { return }
                if let e = d["error"] as? Int, e != 0 {
                    t.invalidate(); self.pollTimer = nil
                    self.failOrRetry(task: task, message: "Convert error \(e)"); return
                }
                let status = d["status"] as? String ?? ""
                let prog = (d["progress"] as? NSNumber)?.doubleValue ?? 0
                let dp: Double
                if prog >= 0.99 { dp = 0.99 }
                else if prog > 1 { dp = 0.3 + min(0.65, (prog-1)/4.0) }
                else { dp = prog }
                DispatchQueue.main.async { self.objectWillChange.send(); task.status = .converting(dp) }
                if status == "download" || prog >= 0.99,
                   let dl = d["downloadURL"] as? String, let du = URL(string: dl) {
                    t.invalidate(); self.pollTimer = nil
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                        if task.isCancelled { return }
                        var name = task.proposedName
                        if !name.lowercased().hasSuffix(".mp3") { name += ".mp3" }
                        self.startMediaDownload(task: task, url: du, finalName: name, validate: true, backendLabel: "Mp3Juice")
                    }
                    return
                }
                if tickCount > maxTicks {
                    t.invalidate(); self.pollTimer = nil
                    self.failOrRetry(task: task, message: "Conversion timed out")
                }
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        task.pollTimers.append(pollTimer!)
    }

    // ---- Generic JSON GET helper -----------------------------------------
    private func jsonGet(_ url: URL, bearer: String?, task: DownloadTask?,
                         completion: @escaping (Result<[String:Any],Error>) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "GET"
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://mp3juice.sc/", forHTTPHeaderField: "Referer")
        req.setValue("https://mp3juice.sc", forHTTPHeaderField: "Origin")
        req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        let t = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data else {
                completion(.failure(NSError(domain: "DownloadCenter", code: -1, userInfo: [NSLocalizedDescriptionKey:"No data"])))
                return
            }
            do {
                if let d = try JSONSerialization.jsonObject(with: data) as? [String:Any] { completion(.success(d)) }
                else { completion(.failure(NSError(domain:"DownloadCenter",code:-2,userInfo:[NSLocalizedDescriptionKey:"Not JSON"]))) }
            } catch { completion(.failure(error)) }
        }
        task?.inFlightDataTasks.add(t)
        t.resume()
    }

    // ---- Binary download -------------------------------------------------
    // Threshold for switching to parallel chunked downloader. Files larger
    // than this from backends known to throttle single long connections
    // (y2jar/Cloudflare) will be pulled via 6 parallel Range connections.
    private let chunkedThreshold: Int64 = 5_000_000   // 5 MB
    private let chunkedChunkSize: Int  = 2_000_000   // 2 MB per chunk
    private let chunkedConnections = 6

    private func startMediaDownload(task: DownloadTask, url: URL, finalName: String, validate: Bool = false,
                                    referer: String = "https://mp3juice.sc/",
                                    backendLabel: String = "") {
        if task.isCancelled { return }
        DispatchQueue.main.async {
            self.objectWillChange.send()
            task.status = .downloading(0)
            task.fileName = finalName
            if !backendLabel.isEmpty { task.backendLabel = backendLabel }
        }

        // Decide whether this backend needs the fast path.
        // y2jar (Cloudflare front) throttles single long connections to ~25 KB/s
        // after a few MB but serves Range requests at 5-25 MB/s each.
        let isY2jar = referer.contains("y2jar") || backendLabel.uppercased().contains("Y2JAR")

        if isY2jar {
            // First send a small Range probe to learn content-length.
            var probe = URLRequest(url: url, timeoutInterval: 20)
            probe.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
            probe.setValue(referer, forHTTPHeaderField: "Referer")
            probe.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            probe.httpMethod = "GET"
            let pt = URLSession.shared.dataTask(with: probe) { [weak self] pdata, presp, perr in
                guard let self else { return }
                if task.isCancelled { return }
                if perr != nil {
                    // Fallback to plain download with Range: bytes=0-
                    self.plainDownload(task: task, url: url, finalName: finalName,
                                       referer: referer, backendLabel: backendLabel, addRange: true)
                    return
                }
                var cl: Int64 = 0
                if let hr = presp as? HTTPURLResponse {
                    // Content-Range: bytes 0-1023/TOTAL  (or */TOTAL)
                    if let cr = hr.allHeaderFields["Content-Range"] as? String
                        ?? hr.allHeaderFields["content-range"] as? String {
                        if let slash = cr.lastIndex(of: "/") {
                            let tail = cr[cr.index(after: slash)...]
                            if let n = Int64(tail), n > 0 { cl = n }
                        }
                    }
                    if cl == 0, let len = hr.allHeaderFields["Content-Length"] as? String,
                       let n = Int64(len) { cl = n }
                }
                task.knownContentLength = cl
                if cl > self.chunkedThreshold {
                    self.startChunkedDownload(task: task, url: url, finalName: finalName,
                                              referer: referer, backendLabel: backendLabel,
                                              totalBytes: cl)
                } else if cl > 0 {
                    // Small file (size known and <threshold) — single Range request is enough.
                    self.plainDownload(task: task, url: url, finalName: finalName,
                                       referer: referer, backendLabel: backendLabel, addRange: true)
                } else {
                    // Cloudflare didn't reveal Content-Length in the probe (can
                    // happen on certain edge nodes). Be safe and still use the
                    // plain Range request for the first ~5 MB; if the real
                    // length turns out larger the plain downloader will still
                    // pull it (Range: bytes=0- is honored), just at single-
                    // connection speed. Correctness > speed here.
                    self.plainDownload(task: task, url: url, finalName: finalName,
                                       referer: referer, backendLabel: backendLabel, addRange: true)
                }
            }
            task.inFlightDataTasks.add(pt)
            pt.resume()
        } else {
            // Non-y2jar backends: plain download (no forced Range, to avoid
            // breaking cnvmp3/Direct/SC responses).
            plainDownload(task: task, url: url, finalName: finalName,
                          referer: referer, backendLabel: backendLabel, addRange: false)
        }
    }

    private func plainDownload(task: DownloadTask, url: URL, finalName: String,
                               referer: String, backendLabel: String, addRange: Bool) {
        if task.isCancelled { return }
        var req = URLRequest(url: url, timeoutInterval: 1800)
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if addRange {
            // Ask for full content via Range so Cloudflare/y2jar serves us the
            // fast path (verified: 8-11 MB/s with Range, 15 KB/s without).
            req.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }
        let t = session.downloadTask(with: req)
        activeURLTask = t
        // Bind this URLSession task to its DownloadTask so the delegate
        // callbacks can't misattribute a late response to whatever happens to
        // be `activeTask` at the time (which used to rename files wrongly).
        register(urlTask: t, for: task, finalName: finalName)
        task.inFlightDownloadTasks.add(t)
        t.resume()
    }

    // ---- URLSessionTask ➜ DownloadTask binding ---------------------------
    private struct TaskBinding {
        weak var task: DownloadTask?
        let finalName: String
    }
    private var bindings: [Int: TaskBinding] = [:]
    private let bindingsLock = NSLock()

    private func register(urlTask: URLSessionTask, for task: DownloadTask, finalName: String) {
        bindingsLock.lock()
        bindings[urlTask.taskIdentifier] = TaskBinding(task: task, finalName: finalName)
        bindingsLock.unlock()
    }
    private func binding(for urlTask: URLSessionTask) -> TaskBinding? {
        bindingsLock.lock(); defer { bindingsLock.unlock() }
        return bindings[urlTask.taskIdentifier]
    }
    private func unbind(_ urlTask: URLSessionTask) {
        bindingsLock.lock()
        bindings.removeValue(forKey: urlTask.taskIdentifier)
        bindingsLock.unlock()
    }

    private func startChunkedDownload(task: DownloadTask, url: URL, finalName: String,
                                      referer: String, backendLabel: String, totalBytes: Int64) {
        if task.isCancelled { return }
        do {
            let cd = try ChunkedDownloader(
                url: url, referer: referer, userAgent: Self.mobileUA,
                totalBytes: totalBytes,
                chunkSize: chunkedChunkSize, connections: chunkedConnections,
                onProgress: { [weak self, weak task] p in
                    guard let self, let task, self.activeTask?.id == task.id else { return }
                    if task.isCancelled { return }
                    self.objectWillChange.send()
                    task.status = .downloading(p)
                },
                onComplete: { [weak self, weak task] result in
                    guard let self, let task, self.activeTask?.id == task.id else { return }
                    if task.isCancelled { return }
                    task.activeChunkedDownloader = nil
                    switch result {
                    case .success(let tmpURL):
                        self.handleChunkedCompletion(task: task, tmpURL: tmpURL,
                                                     finalName: finalName)
                    case .failure(_):
                        // Fall back to plain download if chunked failed (e.g.
                        // server stops honoring ranges mid-way).
                        self.plainDownload(task: task, url: url, finalName: finalName,
                                           referer: referer, backendLabel: backendLabel, addRange: true)
                    }
                })
            task.activeChunkedDownloader = cd
            cd.start()
        } catch {
            plainDownload(task: task, url: url, finalName: finalName,
                          referer: referer, backendLabel: backendLabel, addRange: true)
        }
    }

    private func handleChunkedCompletion(task: DownloadTask, tmpURL: URL, finalName: String) {
        // Validate magic bytes and move into place.
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: tmpURL.path),
              let size = attrs[.size] as? Int64, size > 1_000 else {
            failOrRetry(task: task, message: "Downloaded file was too small (corrupt).")
            try? fm.removeItem(at: tmpURL)
            return
        }
        let head: Data = {
            guard let fh = try? FileHandle(forReadingFrom: tmpURL) else { return Data() }
            defer { try? fh.close() }
            return fh.readData(ofLength: 12)
        }()
        let bytes = [UInt8](head)
        let validAudio: Bool = {
            guard head.count >= 4 else { return false }
            if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { return true }
            if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 { return true }
            if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 { return true }
            if head.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return true }
            if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 { return true }
            return false
        }()
        if !validAudio {
            failOrRetry(task: task, message: "File was not a valid audio track.")
            try? fm.removeItem(at: tmpURL)
            return
        }
        var actualFinal = finalName
        let fl = actualFinal.lowercased()
        var hasKnown = false
        for e in DownloadCenter.audioExts { if fl.hasSuffix("." + e) { hasKnown = true; break } }
        if !hasKnown { actualFinal = DownloadCenter.y2jarName(actualFinal) }
        actualFinal = sanitize(actualFinal)
        let destDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destPath = destDir.appendingPathComponent(actualFinal)
        if fm.fileExists(atPath: destPath.path) {
            let stem = (actualFinal as NSString).deletingPathExtension
            let ext = (actualFinal as NSString).pathExtension
            var i = 2
            while fm.fileExists(atPath: destPath.path) {
                let cand = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
                destPath = destDir.appendingPathComponent(cand); i += 1
            }
        }
        do {
            try fm.moveItem(at: tmpURL, to: destPath)
            try fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: destPath.path)
        } catch {
            failOrRetry(task: task, message: "Could not save: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async { task.fileName = destPath.lastPathComponent }
        finish(task: task)
    }

    // ---- URLSessionDownloadDelegate --------------------------------------
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        guard let task = binding(for: downloadTask)?.task ?? activeTask else { return }
        if task.isCancelled { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.objectWillChange.send(); task.status = .downloading(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Resolve the owning DownloadTask from the URLSession task identifier —
        // `activeTask` can already point at a different item by now.
        let bound = binding(for: downloadTask)
        defer { unbind(downloadTask) }
        guard let task = bound?.task ?? activeTask else { return }
        if task.isCancelled { return }
        let fm = FileManager.default

        guard let attrs = try? fm.attributesOfItem(atPath: location.path),
              let size = attrs[.size] as? Int64, size > 1_000 else {
            failOrRetry(task: task, message: "Downloaded file was too small (corrupt)."); return
        }

        let head: Data = {
            guard let fh = FileHandle(forReadingAtPath: location.path) else { return Data() }
            defer { fh.closeFile() }
            return fh.readData(ofLength: 12)
        }()
        let bytes = [UInt8](head)
        let validAudio: Bool = {
            guard head.count >= 4 else { return false }
            if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { return true }
            if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 { return true }
            if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 { return true }
            if head.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return true }
            if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 { return true }
            return false
        }()
        if !validAudio {
            if !bytes.isEmpty && bytes[0] == 0x7B { failOrRetry(task: task, message: "Server not ready, retrying…"); return }
            if !bytes.isEmpty && bytes[0] == 0x3C { failOrRetry(task: task, message: "Source returned an error page."); return }
            failOrRetry(task: task, message: "File was not a valid audio track."); return
        }

        var finalName = task.fileName.isEmpty ? (bound?.finalName ?? task.proposedName) : task.fileName
        let fl = finalName.lowercased()
        var hasKnownExt = false
        for e in DownloadCenter.audioExts { if fl.hasSuffix("." + e) { hasKnownExt = true; break } }
        if !hasKnownExt {
            if let mt = (downloadTask.response as? HTTPURLResponse)?.mimeType {
                if mt.contains("mpeg") || mt.contains("mp3") { finalName += ".mp3" }
                else if mt.contains("mp4") || mt.contains("m4a") || mt.contains("aac") { finalName += ".m4a" }
                else if mt.contains("ogg") || mt.contains("opus") { finalName += ".opus" }
                else { finalName += ".mp3" }
            } else { finalName += ".mp3" }
        }
        finalName = sanitize(finalName)
        let destDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destPath = destDir.appendingPathComponent(finalName)
        if fm.fileExists(atPath: destPath.path) {
            let stem = (finalName as NSString).deletingPathExtension
            let ext = (finalName as NSString).pathExtension
            var i = 2
            while fm.fileExists(atPath: destPath.path) {
                let cand = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
                destPath = destDir.appendingPathComponent(cand); i += 1
            }
        }
        do {
            try fm.moveItem(at: location, to: destPath)
            try fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: destPath.path)
        } catch {
            failOrRetry(task: task, message: "Could not save: \(error.localizedDescription)"); return
        }
        DispatchQueue.main.async { task.fileName = destPath.lastPathComponent }
        finish(task: task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let bound = binding(for: task)
        defer { unbind(task) }
        guard let err = error else { return }
        guard let active = bound?.task ?? activeTask else { return }
        if active.isCancelled { return }
        if case .done = active.status { return }
        if case .cancelled = active.status { return }
        if case .failed = active.status { return }
        // NSURLErrorCancelled (-999) happens when we cancel losers in the fast race — ignore
        if (err as NSError).code == -999 { return }
        failOrRetry(task: active, message: err.localizedDescription)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Lyrics
// ---------------------------------------------------------------------------
class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published var lyrics: String = ""
    @Published var loading: Bool = false
    private var cache = NSCache<NSString, NSString>()

    func fetch(for title: String, artist: String = "") {
        let key = "\(artist)||\(title)" as NSString
        if let c = cache.object(forKey: key) { lyrics = c as String; return }
        loading = true; lyrics = ""
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        var qItems: [URLQueryItem] = []
        if !artist.isEmpty && artist != "AS Music" {
            qItems.append(URLQueryItem(name: "artist_name", value: artist))
            qItems.append(URLQueryItem(name: "track_name", value: title))
        } else {
            qItems.append(URLQueryItem(name: "q", value: title))
        }
        comps?.queryItems = qItems
        guard let url = comps?.url else { loading = false; return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("ASMusic/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data else { DispatchQueue.main.async { self?.loading = false }; return }
            var txt = ""
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String:Any]], let first = arr.first {
                if let p = first["plainLyrics"] as? String, !p.isEmpty { txt = p }
                else if let p = first["syncedLyrics"] as? String, !p.isEmpty {
                    txt = p.replacingOccurrences(of: #"\[[0-9:\.\s\-]+\]"#, with: "", options: .regularExpression)
                        .split(whereSeparator: { $0.isNewline }).map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
            if txt.isEmpty { txt = "No lyrics found for this track." }
            self.cache.setObject(txt as NSString, forKey: key)
            DispatchQueue.main.async { self.lyrics = txt; self.loading = false }
        }.resume()
    }
}

// ---------------------------------------------------------------------------
// MARK: - SmartDownloaderManager
// ---------------------------------------------------------------------------
class SmartDownloaderManager: NSObject, ObservableObject {
    @Published var isSearching = false
    @Published var statusMessage = ""
    @Published var showError = false
    @Published var errorDetails = ""
    @Published var searchResults: [SearchResult] = []
    @Published var showSearchResults = false

    @Published var pendingNameVid: String? = nil
    @Published var pendingNamePlatform: String = "yt"
    @Published var pendingNameURL: URL? = nil
    @Published var pendingNameSuggestion: String = ""
    @Published var pendingNameArtist: String = ""
    @Published var pendingNameThumb: String? = nil
    @Published var showNamePrompt: Bool = false
    @Published var nameInput: String = ""

    @Published var trendingResults: [SearchResult] = []
    @Published var isLoadingTrending: Bool = false
    /// Trending region for the Magic DL tab (Deezer/Piped country code).
    @Published var trendRegion: String = UserDefaults.standard.string(forKey: "asmusic_trend") ?? "eg"

    private var radioSearchCancellable: AnyCancellable?
    private var lastRadioSearchAt: Date = .distantPast

    override init() {
        super.init()
        radioSearchCancellable = NotificationCenter.default.publisher(for: .smartRadioAutoSearch)
            .sink { [weak self] note in
                guard let self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastRadioSearchAt) > 90 else { return }
                self.lastRadioSearchAt = now
                let artist = (note.userInfo?["artist"] as? String) ?? ""
                let title  = (note.userInfo?["title"] as? String) ?? ""
                guard !artist.isEmpty, artist != "AS Music" else { return }
                self.autoSearchForRadio(artist: artist, title: title)
            }
    }

    private let pipedMirrors = [
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.adminforge.de",
        "https://pipedapi.leptons.xyz",
        "https://api.piped.private.coffee",
        "https://piped-api.lunar.icu"
    ]

    func requestDownload(result: SearchResult) {
        let (ct, ca) = TitleCleaner.clean(result.title, artistHint: result.artist == "YouTube" || result.artist == "SoundCloud" ? nil : result.artist)
        let suggestedArtist = ca.isEmpty ? result.artist : ca
        let name = "\(suggestedArtist) - \(ct)".replacingOccurrences(of:"/",with:"-")
        pendingNameVid = result.extId
        pendingNamePlatform = result.platform
        pendingNameURL = result.directURL
        pendingNameArtist = suggestedArtist
        pendingNameThumb = result.thumbnail
        pendingNameSuggestion = name
        nameInput = name
        showNamePrompt = true
    }
    func confirmNamedDownload() {
        showNamePrompt = false
        hideKeyboard()
        let (t, a) = TitleCleaner.clean(nameInput, artistHint: pendingNameArtist)
        let finalName = (a == "AS Music" || a.isEmpty) ? t : "\(a) - \(t)"
        if let u = pendingNameURL {
            DownloadCenter.shared.enqueueDirect(url: u, suggestedName: finalName, artist: a)
        } else if let vid = pendingNameVid {
            DownloadCenter.shared.enqueue(vid: vid, platform: pendingNamePlatform,
                                          suggestedName: finalName, artist: a,
                                          thumbnail: pendingNameThumb)
        }
        pendingNameVid = nil; pendingNameURL = nil; pendingNameThumb = nil; pendingNameArtist = ""
    }
    func cancelNamePrompt() { showNamePrompt = false; pendingNameVid = nil; pendingNameURL = nil; pendingNameThumb = nil; pendingNameArtist = "" }

    func downloadAllResults() {
        var items: [(vid: String, platform: String, name: String, artist: String, thumb: String?)] = []
        for r in searchResults {
            let (ct, ca) = TitleCleaner.clean(r.title, artistHint: r.artist == "YouTube" || r.artist == "SoundCloud" ? nil : r.artist)
            let artist = ca.isEmpty ? r.artist : ca
            let finalName = "\(artist) - \(ct)"
            if r.platform == "sc" && r.directURL != nil {
                DownloadCenter.shared.enqueueDirect(url: r.directURL!, suggestedName: finalName, artist: artist)
            } else {
                items.append((r.extId, r.platform, finalName, artist, r.thumbnail))
            }
        }
        if !items.isEmpty { DownloadCenter.shared.enqueueBatch(items) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func handlePaste() {
        guard let s = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        let low = s.lowercased()
        if low.contains("youtu.be/") || low.contains("youtube.com/") || low.contains("music.youtube.com/") {
            if extractYouTubeID(s) != nil { requestLinkDownload(link: s, name: ""); return }
        }
        if low.contains("soundcloud.com/") {
            errorDetails = "SoundCloud link detected! Use the search field to search by track name instead."
            showError = true; return
        }
        performMagicSearch(query: s)
    }

    func requestLinkDownload(link: String, name: String) {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        if low.contains("soundcloud.com") {
            errorDetails = "For SoundCloud links, please search by artist/track name instead."
            showError = true; return
        }
        guard let id = extractYouTubeID(s) else {
            errorDetails = "Could not parse YouTube link. Try searching by name instead."
            showError = true; return
        }
        let (ct, ca) = TitleCleaner.clean(name)
        let suggested = name.isEmpty ? "YouTube Track" : (ca == "AS Music" ? ct : "\(ca) - \(ct)")
        pendingNameVid = id; pendingNamePlatform = "yt"; pendingNameURL = nil
        pendingNameArtist = ca; pendingNameThumb = nil
        pendingNameSuggestion = suggested; nameInput = suggested; showNamePrompt = true
    }

    static let arabicArtistChips = [
        ("Amr Diab", "عمرو دياب"),
        ("Tamer Hosny", "تامر حسني"),
        ("Wegz", "ويجز"),
        ("Mohamed Hamaki", "محمد حماقي"),
        ("Sherine", "شيرين"),
        ("Nancy Ajram", "نانسي عجرم"),
        ("Marwan Pablo", "مروان بابلو"),
        ("Cairokee", "كايروكي"),
    ]

    func loadTrending(region: String? = nil) {
        if let r = region, r != trendRegion {
            trendRegion = r
            UserDefaults.standard.set(r, forKey: "asmusic_trend")
        }
        guard trendingResults.isEmpty else { return }
        isLoadingTrending = true
        let ua = DownloadCenter.mobileUA
        let code = trendRegion.uppercased()
        let regionName = ChartRegion(rawValue: trendRegion)?.displayName ?? "your region"
        var mirrors = Array(pipedMirrors)
        func tryTrending() {
            guard let base = mirrors.first else {
                mirrors = []
                let fbQuery = trendRegion == "eg" ? "Amr Diab best hits" : "top \(regionName) hits"
                guard let raw = fbQuery.data(using: .utf8)?.base64EncodedString(),
                      let b64enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    DispatchQueue.main.async { self.isLoadingTrending = false }
                    return
                }
                fetchMp3Juice(b64enc: b64enc, param: "y", responseKey: "yt",
                              source: .mp3juice_yt, platform: "yt", ua: ua) { [weak self] rs in
                    DispatchQueue.main.async { self?.trendingResults = Array(rs.prefix(12)); self?.isLoadingTrending = false }
                }
                return
            }
            mirrors.removeFirst()
            guard let url = URL(string: "\(base)/trending?region=\(code)") else { tryTrending(); return }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, _, err in
                if let data = data,
                   let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String:Any]],
                   !items.isEmpty {
                    var out = [SearchResult]()
                    for it in items.prefix(15) {
                        guard var vid = it["url"] as? String else { continue }
                        vid = vid.replacingOccurrences(of: "/watch?v=", with: "")
                        if vid.count > 11 { vid = String(vid.prefix(11)) }
                        guard let title = it["title"] as? String else { continue }
                        let thumb = it["thumbnail"] as? String
                        let artist = (it["uploaderName"] as? String) ?? "Trending"
                        let dur = it["duration"] as? Int
                        out.append(SearchResult(source: .piped_yt, title: title, artist: artist,
                                                duration: dur.map(TimeInterval.init),
                                                platform: "yt", extId: vid, directURL: nil, thumbnail: thumb))
                    }
                    DispatchQueue.main.async { self.trendingResults = out; self.isLoadingTrending = false }
                    return
                }
                tryTrending()
            }.resume()
        }
        tryTrending()
    }

    private func extractYouTubeID(_ s: String) -> String? {
        let patterns = [
            #"(?:youtu\.be/)([a-zA-Z0-9-_]{11})"#,
            #"(?:youtube\.com/(?:embed/|live/|shorts/|v/|watch/))([a-zA-Z0-9-_]{11})"#,
            #"[?&]v=([a-zA-Z0-9-_]{11})"#
        ]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression),
               let m = s[r].range(of: #"[a-zA-Z0-9-_]{11}"#, options: .regularExpression) {
                return String(s[r][m])
            }
        }
        return nil
    }

    func performMagicSearch(query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        hideKeyboard()
        DispatchQueue.main.async {
            self.isSearching = true
            self.statusMessage = "Searching YouTube & SoundCloud…"
            self.searchResults = []
            self.showSearchResults = false
        }
        guard let raw = clean.data(using: .utf8)?.base64EncodedString(),
              let b64enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            DispatchQueue.main.async { self.isSearching = false; self.errorDetails = "Bad query"; self.showError = true }
            return
        }
        let ua = DownloadCenter.mobileUA
        let group = DispatchGroup()
        var collected = [SearchResult]()
        let collectLock = NSLock()
        func append(_ r: [SearchResult]) { collectLock.lock(); collected.append(contentsOf: r); collectLock.unlock() }

        group.enter()
        fetchMp3Juice(b64enc: b64enc, param: "y", responseKey: "yt", source: .mp3juice_yt, platform: "yt", ua: ua) { rs in append(rs); group.leave() }
        group.enter()
        fetchMp3Juice(b64enc: b64enc, param: "s", responseKey: "sc", source: .mp3juice_sc, platform: "sc", ua: ua) { rs in append(rs); group.leave() }
        group.enter()
        fetchPipedBackup(query: clean, ua: ua) { rs in append(rs); group.leave() }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isSearching = false
            if collected.isEmpty {
                self.errorDetails = "No results found. Try a different query."; self.showError = true
            } else {
                var seen = Set<String>()
                var ordered = [SearchResult]()
                for r in collected where r.source == .mp3juice_yt {
                    let k = "\(r.platform)|\(r.extId)"
                    if seen.insert(k).inserted { ordered.append(r) }
                }
                for r in collected where r.source == .mp3juice_sc {
                    let k = "\(r.platform)|\(r.extId)"
                    if seen.insert(k).inserted { ordered.append(r) }
                }
                for r in collected where r.source == .piped_yt {
                    let k = "\(r.platform)|\(r.extId)"
                    if seen.insert(k).inserted { ordered.append(r) }
                }
                self.searchResults = ordered
                self.showSearchResults = true
            }
        }
    }

    private func fetchMp3Juice(b64enc: String, param: String, responseKey: String,
                               source: SearchResultSource, platform: String, ua: String,
                               completion: @escaping ([SearchResult]) -> Void) {
        let us = "https://mp3juice.sc/api/v1/search?y=\(param)&q=\(b64enc)&_=\(Int(Date().timeIntervalSince1970*1000))"
        guard let url = URL(string: us) else { completion([]); return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://mp3juice.sc/", forHTTPHeaderField: "Referer")
        req.setValue("https://mp3juice.sc", forHTTPHeaderField: "Origin")
        req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard let data = data, err == nil,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] else { completion([]); return }
            var out = [SearchResult]()
            for item in (j[responseKey] as? [[String:Any]] ?? []) {
                let idStr: String
                if let s = item["id"] as? String { idStr = s }
                else if let n = item["id"] as? NSNumber { idStr = n.stringValue }
                else { continue }
                guard let title = item["title"] as? String else { continue }
                let durStr = item["duration"] as? String
                let dur = durStr.flatMap { Self.parseDuration($0) }
                var artist = platform == "sc" ? "SoundCloud" : "YouTube"
                var ttl = title
                if let r = title.range(of: " - ") {
                    artist = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    ttl = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                var direct: URL? = nil
                if platform == "sc",
                   let ib = item["id_base64"] as? String,
                   let tb = item["title_base64"] as? String,
                   let ibe = ib.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let tbe = tb.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let u = URL(string: "https://thetacloud.org/s/\(ibe)/\(tbe)/") {
                    direct = u
                }
                let thumb = item["thumb"] as? String
                out.append(SearchResult(source: source, title: ttl, artist: artist, duration: dur,
                                        platform: platform, extId: idStr, directURL: direct, thumbnail: thumb))
            }
            completion(out)
        }.resume()
    }

    private func fetchPipedBackup(query: String, ua: String, completion: @escaping ([SearchResult]) -> Void) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var mirrors = Array(pipedMirrors)
        func tryNext() {
            guard let base = mirrors.first else { completion([]); return }
            mirrors.removeFirst()
            guard let url = URL(string: "\(base)/search?q=\(q)&filter=videos") else { tryNext(); return }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, _, err in
                if let data = data,
                   let j = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
                   let items = j["items"] as? [[String:Any]], !items.isEmpty {
                    var out = [SearchResult]()
                    for it in items.prefix(12) {
                        guard var vid = it["url"] as? String else { continue }
                        vid = vid.replacingOccurrences(of: "/watch?v=", with: "")
                        if vid.count > 11 { vid = String(vid.prefix(11)) }
                        guard let title = it["title"] as? String else { continue }
                        let dur = it["duration"] as? Int
                        let thumb = it["thumbnail"] as? String
                        let artist = (it["uploaderName"] as? String) ?? "YouTube"
                        out.append(SearchResult(source: .piped_yt, title: title, artist: artist,
                                                duration: dur.map(TimeInterval.init),
                                                platform: "yt", extId: vid, directURL: nil, thumbnail: thumb))
                    }
                    completion(out); return
                }
                tryNext()
            }.resume()
        }
        tryNext()
    }

    func autoSearchForRadio(artist: String, title: String) {
        guard !artist.isEmpty, artist != "AS Music" else { return }
        let query = artist
        guard let raw = query.data(using: .utf8)?.base64EncodedString(),
              let b64enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let ua = DownloadCenter.mobileUA
        let us = "https://mp3juice.sc/api/v1/search?y=y&q=\(b64enc)&_=\(Int(Date().timeIntervalSince1970*1000))"
        guard let url = URL(string: us) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://mp3juice.sc/", forHTTPHeaderField: "Referer")
        req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
                  let items = j["yt"] as? [[String:Any]] else { return }
            let (_, cleanArtist) = TitleCleaner.clean(title, artistHint: artist)
            var added = 0
            for it in items.prefix(8) {
                guard added < 3 else { break }
                guard let idStr = (it["id"] as? String) ?? (it["id"] as? NSNumber)?.stringValue,
                      let t = it["title"] as? String else { continue }
                if MusicManager.shared.songByVID(idStr) != nil { continue }
                let (ct, ca) = TitleCleaner.clean(t, artistHint: cleanArtist)
                let finalName = "\(ca) - \(ct)"
                let thumb = it["thumb"] as? String
                DispatchQueue.main.async {
                    DownloadCenter.shared.enqueue(vid: idStr, platform: "yt",
                                                  suggestedName: finalName,
                                                  artist: ca, thumbnail: thumb)
                }
                added += 1
            }
        }.resume()
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0]*60 + parts[1] }
        if parts.count == 3 { return parts[0]*3600 + parts[1]*60 + parts[2] }
        return nil
    }

    // -----------------------------------------------------------------------
    // MARK: - Discovery bridge
    // Resolve a recommended track (from Deezer metadata) to an actual
    // downloadable YouTube video and enqueue it — one tap = in your Library.
    // -----------------------------------------------------------------------
    /// Search "<artist> <title>" on the YT pipeline, then enqueue the best hit.
    /// `completion(true)` means a download was queued.
    func downloadDiscoTrack(artist: String, title: String,
                            thumbnail: String? = nil,
                            completion: ((Bool) -> Void)? = nil) {
        // Skip if we already own it.
        let key = TasteEngine.normKey(artist: artist, title: title)
        if MusicManager.shared.songs.contains(where: {
            TasteEngine.normKey(artist: $0.artist, title: $0.title) == key
        }) {
            DispatchQueue.main.async {
                DownloadCenter.shared.flashDiscovery("\(title) is already in your Library")
                completion?(false)
            }
            return
        }
        let query = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard let raw = query.data(using: .utf8)?.base64EncodedString(),
              let b64enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion?(false); return
        }
        let ua = DownloadCenter.mobileUA
        fetchMp3Juice(b64enc: b64enc, param: "y", responseKey: "yt",
                      source: .mp3juice_yt, platform: "yt", ua: ua) { [weak self] results in
            guard let self = self else { return }
            if let best = self.bestMatch(results, artist: artist, title: title) {
                let (ct, ca) = TitleCleaner.clean(best.title,
                    artistHint: best.artist == "YouTube" ? artist : best.artist)
                let finalArtist = ca.isEmpty ? artist : ca
                let finalName = "\(finalArtist) - \(ct)"
                DispatchQueue.main.async {
                    DownloadCenter.shared.enqueue(vid: best.extId, platform: "yt",
                                                  suggestedName: finalName,
                                                  artist: finalArtist,
                                                  thumbnail: best.thumbnail ?? thumbnail)
                    completion?(true)
                }
            } else {
                // Fallback to Piped if mp3juice returned nothing.
                self.fetchPipedBackup(query: query, ua: ua) { piped in
                    if let best = self.bestMatch(piped, artist: artist, title: title) {
                        let (ct, ca) = TitleCleaner.clean(best.title, artistHint: artist)
                        let finalArtist = ca.isEmpty ? artist : ca
                        let finalName = "\(finalArtist) - \(ct)"
                        DispatchQueue.main.async {
                            DownloadCenter.shared.enqueue(vid: best.extId, platform: "yt",
                                                          suggestedName: finalName,
                                                          artist: finalArtist,
                                                          thumbnail: best.thumbnail ?? thumbnail)
                            completion?(true)
                        }
                    } else {
                        DispatchQueue.main.async {
                            DownloadCenter.shared.flashDiscovery("Couldn't find \(title) to download")
                            completion?(false)
                        }
                    }
                }
            }
        }
    }

    /// Prefer the result whose title actually contains the wanted song title;
    /// otherwise fall back to the first result.
    private func bestMatch(_ results: [SearchResult], artist: String, title: String) -> SearchResult? {
        guard !results.isEmpty else { return nil }
        let want = TasteEngine.normKey(artist: artist, title: title)
        let wantTitleTokens = title.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .split(separator: " ").map(String.init).filter { $0.count > 2 }
        func score(_ r: SearchResult) -> Int {
            let k = TasteEngine.normKey(artist: r.artist, title: r.title)
            if k == want { return 100 }
            let hay = "\(r.artist) \(r.title)".lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
            var s = 0
            for tok in wantTitleTokens where hay.contains(tok) { s += 5 }
            if hay.contains(artist.lowercased().folding(options: .diacriticInsensitive, locale: .current)) { s += 10 }
            return s
        }
        return results.max { score($0) < score($1) }
    }
}

extension Notification.Name {
    static let downloadCenterChanged = Notification.Name("downloadCenterChanged")
    static let smartRadioAutoSearch = Notification.Name("smartRadioAutoSearch")
}
