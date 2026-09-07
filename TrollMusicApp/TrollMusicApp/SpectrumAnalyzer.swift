import Foundation
import Accelerate
import AVFoundation

// ===========================================================================
// MARK: - Real audio-reactive spectrum
//
// A small, render-thread-safe FFT pipeline:
//   mainMixer tap (1024 samples) → Hann window → vDSP complex FFT → 24
//   log-spaced bands (30 Hz … 16 kHz) → dB values published to the UI.
//
// All buffers are pre-allocated once in `setupSpectrum()`; the tap itself
// only fills existing buffers and runs the in-place FFT (no allocations on
// the real-time thread, matching the rest of the engine's discipline).
// ===========================================================================

/// Lock-guarded band values: written by the audio tap, read by the display
/// link / view timer.
final class SpectrumMeter {
    static let bands = 24

    private var values: [Float]
    private let lock = NSLock()

    init() {
        values = Array(repeating: -100, count: Self.bands)
    }

    func store(_ newValues: [Float]) {
        guard newValues.count == values.count else { return }
        lock.lock(); values = newValues; lock.unlock()
    }

    func read() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Pre-allocated FFT state owned by MusicManager.
final class FFTProcessor {
    static let fftSize = 1024          // samples per frame
    static let bins = fftSize / 2      // unique DFT bins

    var window: [Float] = []
    var buffer: [Float] = []           // [re(1024) | im(1024)] — vDSP zrip layout
    var bandRanges: [(Int, Int)] = []  // (binLo, binHi) per visual band
    private(set) var setup: UnsafeMutablePointer<vDSP_FFT_ZEROPHASE_STAGGERED_DIT64_INPLACEDescriptor>?

    init() {
        window = Array(repeating: 0, count: Self.fftSize)
        buffer = Array(repeating: 0, count: 2 * Self.fftSize)
        vDSP.window(ofType: Float.self, usingSequence: nil, count: Self.fftSize,
                    isHalfWindow: false, to: &window)

        let log2n = UInt(log2(Double(Self.fftSize)))
        guard let s = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRADIX2) else {
            // FFT setup failed — the spectrum simply stays flat; playback is unaffected.
            return
        }
        setup = s

        // Log-spaced bands from 30 Hz to 16 kHz. The engine output rate is
        // normally 44.1 kHz — close enough for any other negotiated rate.
        let binWidth = 44100.0 / Double(Self.fftSize)
        let bandCount = SpectrumMeter.bands
        var ranges = [(Int, Int)]()
        for b in 0..<bandCount {
            let fLo = 30.0 * pow(16000.0 / 30.0, Double(b) / Double(bandCount))
            let fHi = 30.0 * pow(16000.0 / 30.0, Double(b + 1) / Double(bandCount))
            let kLo = max(1, Int(fLo / binWidth))
            let kHi = min(Self.bins - 1, max(kLo + 1, Int(fHi / binWidth)))
            ranges.append((kLo, kHi))
        }
        bandRanges = ranges
    }

    deinit {
        if let s = setup { vDSP_destroy_fftsetup(s) }
    }

    /// Runs on the audio render thread. Fills `out` (must have
    /// `SpectrumMeter.bands` elements) with band levels in dB.
    func process(buffer pcm: AVAudioPCMBuffer, into out: inout [Float]) {
        guard setup != nil, let data = pcm.floatChannelData else { return }
        let n = Self.fftSize
        guard Int(pcm.frameLength) >= n else { return }

        // re = windowed samples, im = 0 (the FFT overwrites im, so clear first)
        vDSP_vclr(&buffer, 1, vDSP_Length(2 * n))
        vDSP_vmul(data[0], 1, &window, 1, &buffer, 1, vDSP_Length(n))

        if let s = setup {
            withUnsafeMutableBufferPointer(of: &buffer) { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_fft_zrip(s, base, 1, 1)
            }
        }

        for (b, range) in bandRanges.enumerated() {
            var e: Float = 0
            var k = range.0
            while k < range.1 {
                let re = buffer[k]
                let im = buffer[n + k]
                e += re * re + im * im
                k += 1
            }
            let count = Float(max(1, range.1 - range.0))
            let avg = e / count
            out[b] = avg > 0 ? 10 * log10f(avg) : -100
        }
    }
}
