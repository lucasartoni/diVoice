@preconcurrency import AVFoundation
import DiVoiceEngine

/// A short spoken sentence for the Verify button, synthesized on this Mac.
/// No recorded audio ships with the app.
enum SpeechSample {
  static func sentence(language: String) -> String {
    switch language {
    case "it": "Questa è una prova di dettatura: domani alle dieci presento il progetto al cliente."
    case "es": "Esta es una prueba de dictado: mañana a las diez presento el proyecto al cliente."
    case "fr": "Ceci est un test de dictée : demain à dix heures je présente le projet au client."
    case "de": "Das ist ein Diktiertest: Morgen um zehn stelle ich dem Kunden das Projekt vor."
    case "pt": "Este é um teste de ditado: amanhã às dez apresento o projeto ao cliente."
    default: "This is a dictation test: tomorrow at ten I will present the project to the client."
    }
  }

  private static let voices = ["it": "it-IT", "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "pt": "pt-PT"]

  /// The sentence as mono PCM s16le at `sampleRate`.
  @MainActor
  static func pcm(language: String, sampleRate: Int) async throws -> Data {
    let lang = voices[language] == nil ? "en" : language
    let utterance = AVSpeechUtterance(string: sentence(language: lang))
    utterance.voice = AVSpeechSynthesisVoice(language: voices[lang])
    let synthesizer = AVSpeechSynthesizer()
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!

    let buffers: [AVAudioPCMBuffer] = try await withCheckedThrowingContinuation { continuation in
      var collected: [AVAudioPCMBuffer] = []
      var finished = false
      synthesizer.write(utterance) { buffer in
        guard !finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
          finished = true
          if collected.isEmpty {
            continuation.resume(throwing: EngineError("speech synthesis produced no audio"))
          } else {
            continuation.resume(returning: collected)
          }
          return
        }
        collected.append(pcm)
      }
    }
    _ = synthesizer

    var out = Data()
    guard let source = buffers.first?.format, let converter = AVAudioConverter(from: source, to: target) else {
      throw EngineError("unsupported speech format")
    }
    for (index, buffer) in buffers.enumerated() {
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Double(sampleRate) / source.sampleRate + 64)
      guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
      var supplied = false
      var error: NSError?
      _ = converter.convert(to: converted, error: &error) { _, status in
        if supplied {
          status.pointee = index == buffers.count - 1 ? .endOfStream : .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
      }
      if let samples = converted.int16ChannelData, converted.frameLength > 0 {
        out.append(Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
      }
    }
    // Half a second of silence before and after, like a real dictation.
    let pad = Data(count: sampleRate)
    return pad + out + pad
  }
}
