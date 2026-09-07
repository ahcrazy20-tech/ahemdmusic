import Foundation
import Accelerate
import AVFoundation

// ===========================================================================
// MARK: - Real audio-reactive spectrum
//
// A small, render-thread-safe FFT pipeline:
//   mainMixer tap (1024 samples) → Hann window → vDSP real FFT → 24
//   log-spaced bands (30 Hz … 16 kHz) → dB values published to the UI.
//
// All buffers are pre-allocated once in `init()`; the tap itself only fills
// existing buffers and runs the FFT (no allocations on the real-time thread,
// matching the rest of the engine's discipline).
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
///
/// Uses the classic `vDSP_fft_zrip` packed real-input transform:
///   • `vDSP_ctoz` splits the interleaved windowed frame into even/odd halves,
///   • `vDSP_fft_zrip` transforms in place (DC in realp[0], Nyquist imagp[0]),
///   • `vDSP_zvmags` gives |X(k)|² for each of the 512 unique bins.
final class FFTProcessor {
    static let fftSize = 1024          // real samples per frame
    static let bins = fftSize / 2      // unique DFT bins

    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    private let log2n: vDSP_Length
    private var setup: FFTSetup?

    /// (binLo, binHi) per visual band.
    private(set) var bandRanges: [(Int, Int)] = []

    /// Normalizes |X|² so a full-scale tone lands near 0 dB. `vDSP_fft_zrip`
    /// carries a factor of 2, hence the n² denominator.
    private let magScale: Float

    init() {
        let n = Self.fftSize
        let half = Self.bins

        window = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: half)
        imagp = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)

        log2n = vDSP_Length(log2(Float(n)))
        magScale = 1.0 / (Float(n) * Float(n))

        // Periodic Hann window.
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // If the setup fails the spectrum simply stays flat; playback is
        // unaffected.
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // Log-spaced bands from 30 Hz to 16 kHz. The engine output rate is
        // normally 44.1 kHz — close enough for any other negotiated rate.
        let binWidth = 44100.0 / Double(n)
        let bandCount = SpectrumMeter.bands
        var ranges = [(Int, Int)]()
        for b in 0..<bandCount {
            let fLo = 30.0 * pow(16000.0 / 30.0, Double(b) / Double(bandCount))
            let fHi = 30.0 * pow(16000.0 / 30.0, Double(b + 1) / Double(bandCount))
            let kLo = max(1, Int(fLo / binWidth))
            let kHi = min(half - 1, max(kLo + 1, Int(fHi / binWidth)))
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
        guard let setup = setup, let data = pcm.floatChannelData else { return }
        let n = Self.fftSize
        let half = Self.bins
        guard Int(pcm.frameLength) >= n, out.count == SpectrumMeter.bands else { return }

        // 1) Window the frame (channel 0 is enough for a visualizer).
        vDSP_vmul(data[0], 1, window, 1, &windowed, 1, vDSP_Length(n))

        // 2) Pack → transform → magnitudes, all into pre-allocated storage.
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                guard let rb = rp.baseAddress, let ib = ip.baseAddress else { return }
                var split = DSPSplitComplex(realp: rb, imagp: ib)

                windowed.withUnsafeBufferPointer { wp in
                    guard let wb = wp.baseAddress else { return }
                    wb.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                magnitudes.withUnsafeMutableBufferPointer { mp in
                    guard let mb = mp.baseAddress else { return }
                    vDSP_zvmags(&split, 1, mb, 1, vDSP_Length(half))
                }
            }
        }

        // 3) Reduce the bins to visual bands, in dB.
        for (b, range) in bandRanges.enumerated() {
            var e: Float = 0
            var k = range.0
            while k < range.1 {
                e += magnitudes[k]
                k += 1
            }
            let count = Float(max(1, range.1 - range.0))
            let avg = (e / count) * magScale
            out[b] = avg > 0 ? 10 * log10f(avg) : -100
        }
    }
}
