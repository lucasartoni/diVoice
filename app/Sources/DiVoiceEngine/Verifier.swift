import Foundation

/// The result of the Verify button for one model.
public struct VerifyReport: Sendable, Equatable, Identifiable {
  public enum Step: String, Sendable {
    case streaming, batch, cleanup, scribe
  }

  public var step: Step
  public var model: String
  public var ok: Bool
  /// What the model answered (transcript or text), or the error.
  public var detail: String
  public var connectMs: Double?
  public var firstTokenMs: Double?
  public var totalMs: Double?
  /// False when the model refused predicted outputs (then they are turned off).
  public var predictionAccepted: Bool?

  public var id: String { "\(step.rawValue)-\(model)" }

  public init(
    step: Step, model: String, ok: Bool, detail: String, connectMs: Double? = nil, firstTokenMs: Double? = nil,
    totalMs: Double? = nil, predictionAccepted: Bool? = nil
  ) {
    self.step = step
    self.model = model
    self.ok = ok
    self.detail = detail
    self.connectMs = connectMs
    self.firstTokenMs = firstTokenMs
    self.totalMs = totalMs
    self.predictionAccepted = predictionAccepted
  }
}

/// Checks key and model with a real request and measures how long it takes.
public enum Verifier {
  /// Transcribes `pcm` with the streaming model (unless the mode is batch) and with the batch model.
  /// The streaming check sends the audio at speaking pace (`pace` 1 = real time), so its time
  /// is the one a dictation sees after the key is released.
  public static func transcription(
    _ settings: TranscriptionSettings, service: TranscriptionService, pcm: Data, language: String?, vocabulary: [String],
    pace: Double = 1, includeBatch: Bool = true, now: @escaping EngineClock = EngineClocks.monotonic
  ) async -> [VerifyReport] {
    var reports: [VerifyReport] = []
    if settings.mode != .batch || !includeBatch {
      var streaming = settings
      streaming.mode = .realtime
      reports.append(
        await transcribe(
          streaming, step: .streaming, model: settings.realtimeModel, service: service, pcm: pcm, language: language,
          vocabulary: vocabulary, pace: pace, now: now))
    }
    // Through an organization's server, one session: the server chooses streaming or batch.
    guard includeBatch else { return reports }
    var batch = settings
    batch.mode = .batch
    reports.append(
      await transcribe(
        batch, step: .batch, model: settings.batchModel, service: service, pcm: pcm, language: language, vocabulary: vocabulary,
        pace: 0, now: now))
    return reports
  }

  private static func transcribe(
    _ settings: TranscriptionSettings, step: VerifyReport.Step, model: String, service: TranscriptionService, pcm: Data,
    language: String?, vocabulary: [String], pace: Double, now: EngineClock
  ) async -> VerifyReport {
    let sampleRate = settings.provider.sampleRate
    let run = TranscriptionRun(service: service, settings: settings, language: language, vocabulary: vocabulary, sampleRate: sampleRate)
    await run.start()
    do {
      let frame = sampleRate / 10 * 2
      var offset = 0
      while offset < pcm.count {
        try await run.append(pcm.subdata(in: offset..<min(pcm.count, offset + frame)))
        offset += frame
        if pace > 0 { try await Task.sleep(nanoseconds: UInt64(100_000_000 / pace)) }
      }
      let started = now()
      let outcome = try await run.finish()
      let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return VerifyReport(
        step: step, model: model, ok: !text.isEmpty, detail: text.isEmpty ? "empty transcript" : text,
        connectMs: await run.upstreamConnectMs, totalMs: now() - started)
    } catch {
      await run.abort()
      return VerifyReport(step: step, model: model, ok: false, detail: errorMessage(error))
    }
  }

  /// A short cleanup (or Scribe) request. If the model refuses predicted outputs, tries again without.
  public static func chat(
    _ settings: ChatSettings, step: VerifyReport.Step, chat: ChatService, now: @escaping EngineClock = EngineClocks.monotonic
  ) async -> VerifyReport {
    let raw = "ehm questa è una prova di verifica"
    let caps = ModelCatalog.chatCapabilities(settings.provider, settings.model)
    let wantsPrediction = step == .cleanup && settings.prediction && caps.prediction
    func call(prediction: Bool) -> ChatCall {
      if step == .scribe {
        // The same request as a real Scribe draft, just short.
        let input = Prompts.ScribeInput(
          userName: "", organization: nil, appName: nil, windowTitle: nil, category: .other, style: Categories.style(for: .other),
          dictionary: "", instruction: "scrivi una frase di prova di una riga", selectedText: nil, history: [])
        return Scribe.call(input, settings: settings, maxTokens: 120)
      }
      return ChatCall(
        model: settings.model,
        messages: Prompts.cleanup(dictionary: "", raw: raw, appName: nil, category: .other, style: Categories.style(for: .other), insertion: .start),
        temperature: 0, maxTokens: 64, reasoning: settings.reasoning ?? WantedReasoning.cleanup, prediction: prediction ? raw : nil, fastTier: settings.fastTier)
    }
    func report(_ result: ChatStreamResult, prediction: Bool?) -> VerifyReport {
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return VerifyReport(
        step: step, model: settings.model, ok: !text.isEmpty, detail: text.isEmpty ? "empty answer" : text,
        firstTokenMs: result.ttftMs, totalMs: result.totalMs, predictionAccepted: prediction)
    }
    do {
      return report(try await chat.stream(call(prediction: wantsPrediction), timeout: 30, onDelta: nil), prediction: wantsPrediction ? true : nil)
    } catch let error as HTTPStatusError where wantsPrediction && (400..<500).contains(error.status) && error.status != 401 {
      do {
        return report(try await chat.stream(call(prediction: false), timeout: 30, onDelta: nil), prediction: false)
      } catch {
        return VerifyReport(step: step, model: settings.model, ok: false, detail: errorMessage(error))
      }
    } catch {
      return VerifyReport(step: step, model: settings.model, ok: false, detail: errorMessage(error))
    }
  }
}
