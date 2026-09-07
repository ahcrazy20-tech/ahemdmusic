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
    static let fftSize = 1024          // real samples per frame
    static let bins = fftSize / 2      // unique DFT bins (DC + Nyquist included)

    /// Hann-window taps, split into the even/odd halves the packed real-FFT
    /// input expects, so the render thread only does strided multiplies.
    private let windowEven: [Float]    // w(2i)
    private let windowOdd: [Float]     // w(2i + 1)
    /// Split-complex scratch buffers, pre-allocated once (never on the audio
    /// render thread). The forward transform is real-input packed:
    ///   input  = split(windowed even samples, windowed odd samples)
    ///   output = split(X(0..<bins)) with DC in re[0] and Nyquist in im[0].
    private var inputReal: [Float]
    private var inputImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]
    private let fft: vDSP.FFT?
    var bandRanges: [(Int, Int)] = []  // (binLo, binHi) per visual band

    init() {
        // Hann window: w(i) = 0.5 * (1 - cos(2πi / (n - 1))), endpoints 0.
        let n = Self.fftSize
        let half = Self.bins
        let scale = 2 * Float.pi / Float(n - 1)
        var wEven = [Float](repeating: 0, count: half)
        var wOdd = [Float](repeating: 0, count: half)
        for i in 0..<half {
            let twoI = 2 * i
            wEven[i] = 0.5 * (1 - cos(scale * Float(twoI)))
            wOdd[i] = 0.5 * (1 - cos(scale * Float(twoI + 1)))
        }
        windowEven = wEven
        windowOdd = wOdd
        inputReal = [Float](repeating: 0, count: half)
        inputImag = [Float](repeating: 0, count: half)
        outputReal = [Float](repeating: 0, count: half)
        outputImag = [Float](repeating: 0, count: half)
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(Self.fftSize))),
                       radix: .radix2,
                       ofType: DSPSplitComplex.self)

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

    /// Runs on the audio render thread. Fills `out` (must have
    /// `SpectrumMeter.bands` elements) with band levels in dB. All buffers are
    /// pre-allocated: no allocations on the real-time thread.
    func process(buffer pcm: AVAudioPCMBuffer, into out: inout [Float]) {
        guard let fft = fft, let data = pcm.floatChannelData else { return }
        let n = Self.fftSize
        let half = Self.bins
        guard Int(pcm.frameLength) >= n else { return }

        // Pack the windowed frame into the split-complex input layout the
        // real-input FFT expects: real = x(2i)·w(2i), imag = x(2i+1)·w(2i+1).
        vDSP_vmul(data[0], 2, windowEven, 1, &inputReal, 1, vDSP_Length(half))
        vDSP_vmul(data[0] + 1, 2, windowOdd, 1, &inputImag, 1, vDSP_Length(half))

        inputReal.withUnsafeMutableBufferPointer { reBuf in
            inputImag.withUnsafeMutableBufferPointer { imBuf in
                outputReal.withUnsafeMutableBufferPointer { outReBuf in
                    outputImag.withUnsafeMutableBufferPointer { outImBuf in
                        guard let re = reBuf.baseAddress, let im = imBuf.baseAddress,
                              let or = outReBuf.baseAddress, let oi = outImBuf.baseAddress else { return }
                        var input = DSPSplitComplex(realp: re, imagp: im)
                        var output = DSPSplitComplex(realp: or, imagp: oi)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }

        for (b, range) in bandRanges.enumerated() {
            var e: Float = 0
            var k = range.0
            while k < range.1 {
                let re = outputReal[k]
                let im = outputImag[k]
                e += re * re + im * im
                k += 1
            }
            let count = Float(max(1, range.1 - range.0))
            let avg = e / count
            out[b] = avg > 0 ? 10 * log10f(avg) : -100
        }
    }
}
