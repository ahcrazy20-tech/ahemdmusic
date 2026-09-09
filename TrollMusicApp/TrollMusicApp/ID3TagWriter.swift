import Foundation

// ===========================================================================
// MARK: - ID3v2.4 tag writer
//
// After a successful MP3 download we write a minimal but valid ID3v2.4 tag
// (TIT2 title, TPE1 artist, TALB album, APIC front cover) so files are
// correct in any other player, not just AS Music.
//
// Rules:
//   • Only touches files that do NOT already start with an "ID3" header —
//     pre-tagged files are left untouched (this also makes repeated calls
//     safe no-ops).
//   • The tag is prepended; the audio frames are never modified.
//   • Everything happens on a background queue by the caller.
// ===========================================================================

enum ID3TagWriter {

    /// What the on-device analysis learned about a track, written into the
    /// tag so the numbers survive a restore and are visible to every other
    /// player. All fields are optional -- a track that was never analyzed
    /// simply doesn't get them.
    struct Analysis {
        var bpm: Int = 0
        /// "F# minor" / "C major".
        var key: String = ""
        /// Camelot wheel code ("8A"), the form DJ software reads.
        var camelot: String = ""
        /// Track gain in dB relative to the -14 dBFS reference.
        var replayGainDB: Double? = nil

        var isEmpty: Bool {
            bpm <= 0 && key.isEmpty && camelot.isEmpty && replayGainDB == nil
        }
    }

    /// Writes an ID3v2.4 tag if the file is an untagged MP3.
    /// Returns true if a tag was written.
    static func tagIfNeeded(at fileURL: URL, title: String, artist: String,
                            album: String, artworkJPEG: Data?,
                            analysis: Analysis = Analysis()) -> Bool {
        guard fileURL.pathExtension.lowercased() == "mp3" else { return false }

        // 1) Already tagged? Leave it alone.
        if let fh = try? FileHandle(forReadingFrom: fileURL) {
            let head = (try? fh.read(upToCount: 10)) ?? Data()
            try? fh.close()
            if head.count >= 10, [UInt8](head.prefix(3)) == [0x49, 0x44, 0x33] {
                return false
            }
        }

        // 2) Build frames.
        var payload = Data()
        payload.append(textFrame(id: "TIT2", text: title))
        payload.append(textFrame(id: "TPE1", text: artist))
        if !album.isEmpty { payload.append(textFrame(id: "TALB", text: album)) }
        if let art = artworkJPEG, !art.isEmpty {
            payload.append(picFrame(jpeg: art))
        }

        // The measured numbers. TBPM and TKEY are standard ID3v2.4 frames;
        // the rest go in TXXX user-defined frames under the names other
        // software already looks for (Mixed In Key, Rekordbox, foobar2000).
        if analysis.bpm > 0 {
            payload.append(textFrame(id: "TBPM", text: String(analysis.bpm)))
        }
        if !analysis.camelot.isEmpty {
            // TKEY officially wants the musical key; DJ tools read Camelot
            // from TXXX:INITIALKEY, so write both rather than guess.
            payload.append(textFrame(id: "TKEY", text: analysis.camelot))
            payload.append(txxxFrame(name: "INITIALKEY", value: analysis.camelot))
        }
        if !analysis.key.isEmpty {
            payload.append(txxxFrame(name: "KEY", value: analysis.key))
        }
        if let gain = analysis.replayGainDB {
            // ReplayGain's conventional format, to 2 dp with an explicit sign.
            let text = String(format: "%+.2f dB", gain)
            payload.append(txxxFrame(name: "REPLAYGAIN_TRACK_GAIN", value: text))
        }

        guard !payload.isEmpty else { return false }

        // 3) Tag header: "ID3" + version (4,10) + flags (0) + syncsafe size.
        var tag = Data([0x49, 0x44, 0x33, 0x04, 0x10, 0x00])
        tag.append(contentsOf: syncsafe(payload.count))
        tag.append(payload)

        // 4) Prepend to a copy of the audio, then atomically replace.
        guard let original = try? Data(contentsOf: fileURL) else { return false }
        var out = Data()
        out.append(tag)
        out.append(original)
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".asmusic_tagged_\(UUID().uuidString)")
        do {
            try out.write(to: tmp)
            try FileManager.default.replaceItem(at: fileURL, withItemAt: tmp,
                                                backupItemName: nil, options: [],
                                                resultingItemURL: nil)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: - Byte-level helpers (little-endian, as ID3v2 requires)

    /// ID3v2 size fields use "syncsafe" integers: 4 bytes, 7 bits each.
    private static func syncsafe(_ n: Int) -> Data {
        var d = Data()
        d.append(UInt8((n >> 21) & 0x7F))
        d.append(UInt8((n >> 14) & 0x7F))
        d.append(UInt8((n >> 7) & 0x7F))
        d.append(UInt8(n & 0x7F))
        return d
    }

    /// UTF-16 (little-endian on Apple platforms) with an explicit BOM,
    /// which is ID3 text encoding value 1.
    private static func utf16BOM(_ s: String) -> Data {
        var u = [UInt16]()
        u.reserveCapacity(s.utf16.count + 1)
        u.append(0xFEFF)
        u.append(contentsOf: Array(s.utf16))
        return u.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A text frame: 4-char ID + syncsafe size + 2 flag bytes + payload,
    /// where the payload is `encoding byte + text`.
    ///
    /// That leading encoding byte is mandatory and was missing: the frame
    /// began straight at the BOM, so every reader consumed 0xFF as the
    /// encoding and then tried to parse the text one byte out of alignment.
    /// The result was a corrupted first character in other players -- worse
    /// for Arabic titles, where every character is multi-byte. 0x01 is
    /// "UTF-16 with BOM" in ID3v2.4.
    private static func textFrame(id: String, text: String) -> Data {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return Data()
        }
        var payload = Data([0x01])
        payload.append(utf16BOM(text))
        var f = Data()
        f.append(contentsOf: Array(id.utf8).prefix(4))
        f.append(contentsOf: syncsafe(payload.count))
        f.append(Data([0x00, 0x00]))
        f.append(payload)
        return f
    }

    /// TXXX user-defined text frame: encoding, description, null, value.
    /// This is how BPM/key/ReplayGain travel between players.
    private static func txxxFrame(name: String, value: String) -> Data {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Data()
        }
        var payload = Data()
        payload.append(0x01)               // UTF-16 with BOM
        payload.append(utf16BOM(name))
        payload.append(Data([0x00, 0x00])) // UTF-16 null terminator
        payload.append(utf16BOM(value))

        var f = Data()
        f.append(contentsOf: Array("TXXX".utf8))
        f.append(contentsOf: syncsafe(payload.count))
        f.append(Data([0x00, 0x00]))
        f.append(payload)
        return f
    }

    /// APIC frame with a JPEG front cover.
    private static func picFrame(jpeg: Data) -> Data {
        var payload = Data()
        payload.append(0x00) // text encoding: ISO-8859-1
        payload.append(contentsOf: Array("image/jpeg".utf8))
        payload.append(0x00) // MIME type null terminator
        payload.append(0x03) // picture type: front cover
        payload.append(0x00) // empty description (null-terminated for enc. 0)
        payload.append(jpeg)

        var f = Data()
        f.append(contentsOf: Array("APIC".utf8))
        f.append(contentsOf: syncsafe(payload.count))
        f.append(Data([0x00, 0x00]))
        f.append(payload)
        return f
    }
}
