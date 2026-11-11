import DiVoiceEngine
import Foundation

/// A bench clip: what is said, and the dictionary terms it contains.
struct Clip: Codable, Equatable {
  var id: String
  var text: String
  var terms: [String]
  /// Acceptable cleaned texts: what the user meant to write. Cleanup quality is measured
  /// against the closest one; empty means not measured.
  var expected: [String]
  /// macOS voice for synthetic clips (default: Alice for Italian, Samantha for English).
  var voice: String?
  /// Two-letter dictation language (default "it").
  var language: String?
  /// A recording to use instead of synthesizing `text`; set when loading a clips folder.
  var recording: URL?

  enum CodingKeys: String, CodingKey { case id, text, terms, expected, voice, language }

  init(id: String, text: String, terms: [String], expected: [String] = [], voice: String? = nil, language: String? = nil) {
    self.id = id
    self.text = text
    self.terms = terms
    self.expected = expected.isEmpty ? [text] : expected
    self.voice = voice
    self.language = language
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    terms = try container.decodeIfPresent([String].self, forKey: .terms) ?? []
    // A string or a list of strings.
    if let one = try? container.decodeIfPresent(String.self, forKey: .expected) {
      expected = [one]
    } else {
      expected = try container.decodeIfPresent([String].self, forKey: .expected) ?? []
    }
    voice = try container.decodeIfPresent(String.self, forKey: .voice)
    language = try container.decodeIfPresent(String.self, forKey: .language)
  }

  var dictationLanguage: String { language ?? "it" }
}

enum Clips {
  /// Synthetic dictations of 2 to 15 seconds with invented product names as dictionary terms:
  /// Italian (short sentences, a self-correction, a list, a long email, code), Italian mixed
  /// with English (jargon, a quoted sentence), and English. `expected` is the cleaned text,
  /// with the variants the rules allow (times as digits or words, an opening "Allora").
  static let builtIn: [Clip] = [
    Clip(
      id: "01-short", text: "Ci vediamo domani alle dieci.", terms: [],
      expected: ["Ci vediamo domani alle 10.", "Ci vediamo domani alle 10:00.", "Ci vediamo domani alle dieci."]),
    Clip(id: "02-term", text: "Ho appena mandato la proposta di Zentrix al cliente.", terms: ["Zentrix"]),
    Clip(
      id: "03-self-correction", text: "Ciao, ehm, ti confermo che la demo di Kestrel è giovedì alle quindici, anzi alle sedici.",
      terms: ["Kestrel"],
      expected: [
        "Ciao, ti confermo che la demo di Kestrel è giovedì alle 16.",
        "Ciao, ti confermo che la demo di Kestrel è giovedì alle 16:00.",
        "Ciao, ti confermo che la demo di Kestrel è giovedì alle sedici.",
      ]),
    Clip(
      id: "04-products",
      text: "Domani mattina facciamo il punto su Nimbly e Orbix con tutto il team commerciale, poi aggiorniamo la presentazione.",
      terms: ["Nimbly", "Orbix"]),
    Clip(
      id: "05-list",
      text:
        "Allora, per la call di lunedì volevo proporre tre cose: primo, rivedere i numeri di Kestrel; secondo, capire i tempi di Zentrix; terzo, definire chi segue Nimbly.",
      terms: ["Kestrel", "Zentrix", "Nimbly"],
      expected: [
        "Allora, per la call di lunedì volevo proporre tre cose: primo, rivedere i numeri di Kestrel; secondo, capire i tempi di Zentrix; terzo, definire chi segue Nimbly.",
        "Per la call di lunedì volevo proporre tre cose: primo, rivedere i numeri di Kestrel; secondo, capire i tempi di Zentrix; terzo, definire chi segue Nimbly.",
      ]),
    Clip(
      id: "06-long-email",
      text:
        "Buongiorno a tutti, vi scrivo per fare un riepilogo della riunione di oggi. Abbiamo deciso di lanciare la nuova versione di Orbix entro fine mese, mentre per Kestrel servono ancora due settimane di test. Vi chiedo di mandarmi i vostri commenti entro venerdì. Grazie, Ada.",
      terms: ["Orbix", "Kestrel"]),
    Clip(
      id: "07-english", text: "Quick update: the Zentrix pilot went well and the client wants to extend it to the whole sales team.",
      terms: ["Zentrix"], voice: "Samantha", language: "en"),
    Clip(id: "08-mixed", text: "Mandami il link del meeting e la recap della sessione di Nimbly, per favore.", terms: ["Nimbly"]),
    Clip(
      id: "09-code", text: "Apri il file index punto ts e aggiungi un log quando la sessione realtime va in timeout.", terms: [],
      expected: ["Apri il file index.ts e aggiungi un log quando la sessione realtime va in timeout."]),
    Clip(id: "10-short-term", text: "Ottimo lavoro su Orbix oggi.", terms: ["Orbix"]),
    Clip(
      id: "11-mixed-jargon",
      text: "Ho fatto il deploy in staging, ma il build è fallito per un timeout, quindi facciamo un rollback e ne parliamo nella daily.",
      terms: []),
    Clip(
      id: "12-mixed-quote",
      text: "Il cliente ha scritto testualmente: we need the final deck by Friday, quindi anticipiamo la review a giovedì.",
      terms: [],
      expected: [
        "Il cliente ha scritto testualmente: we need the final deck by Friday, quindi anticipiamo la review a giovedì.",
        "Il cliente ha scritto testualmente: \"We need the final deck by Friday\", quindi anticipiamo la review a giovedì.",
      ]),
    Clip(
      id: "13-mixed-correction", text: "Fissiamo il kickoff con il team di Orbix, ehm, martedì, anzi no, mercoledì alle undici.",
      terms: ["Orbix"],
      expected: [
        "Fissiamo il kickoff con il team di Orbix mercoledì alle 11.",
        "Fissiamo il kickoff con il team di Orbix mercoledì alle 11:00.",
        "Fissiamo il kickoff con il team di Orbix mercoledì alle undici.",
      ]),
    Clip(
      id: "14-english-correction",
      text:
        "So, um, I wanted to give you a quick recap of the Kestrel launch: we're on track for Tuesday, actually no, Wednesday, and the pricing page still needs a final review.",
      terms: ["Kestrel"],
      expected: [
        "So, I wanted to give you a quick recap of the Kestrel launch: we're on track for Wednesday, and the pricing page still needs a final review.",
        "I wanted to give you a quick recap of the Kestrel launch: we're on track for Wednesday, and the pricing page still needs a final review.",
      ],
      voice: "Samantha", language: "en"),
    Clip(id: "15-english-short", text: "Thanks, I'll send it over tonight.", terms: [], voice: "Samantha", language: "en"),
  ]

  /// `clips.json` in `folder`, with `<id>.wav` recordings where present (otherwise the text is synthesized).
  static func load(folder: URL) throws -> [Clip] {
    let data = try Data(contentsOf: folder.appendingPathComponent("clips.json"))
    return try JSONDecoder().decode([Clip].self, from: data).map { clip in
      var clip = clip
      let wav = folder.appendingPathComponent("\(clip.id).wav")
      if FileManager.default.fileExists(atPath: wav.path) { clip.recording = wav }
      return clip
    }
  }

  static let leadingSilenceMs = 300

  /// The clip as mono PCM s16le at `sampleRate`, with 300 ms of silence before the voice
  /// (a dictation starts at the key press). Converted files are cached in `cache`.
  static func pcm(_ clip: Clip, sampleRate: Int, cache: URL) throws -> Data {
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let voice = clip.voice ?? (clip.dictationLanguage == "en" ? "Samantha" : "Alice")
    let source: URL
    let tag: String
    if let recording = clip.recording {
      source = recording
      tag = fingerprint(recording.path + "\(fileSize(recording))")
    } else {
      guard !clip.text.isEmpty else { throw EngineError("\(clip.id): no recording and no text to synthesize") }
      tag = fingerprint(voice + "|" + clip.text)
      source = cache.appendingPathComponent("\(clip.id)-\(tag).aiff")
      if !FileManager.default.fileExists(atPath: source.path) {
        try run("/usr/bin/say", ["-v", voice, "-r", "185", "-o", source.path, clip.text])
      }
    }
    let wav = cache.appendingPathComponent("\(clip.id)-\(tag)-\(sampleRate).wav")
    if !FileManager.default.fileExists(atPath: wav.path) {
      try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@\(sampleRate)", "-c", "1", source.path, wav.path])
    }
    let silence = Data(count: sampleRate * 2 * leadingSilenceMs / 1000)
    return silence + (try pcmData(wav: Data(contentsOf: wav)))
  }

  /// The `data` chunk of a RIFF/WAVE file.
  static func pcmData(wav: Data) throws -> Data {
    let bytes = [UInt8](wav)
    guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
      String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE"
    else { throw EngineError("not a WAV file") }
    var offset = 12
    while offset + 8 <= bytes.count {
      let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
      let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
      let start = offset + 8
      if id == "data" { return Data(bytes[start..<min(start + size, bytes.count)]) }
      offset = start + size + (size & 1)
    }
    throw EngineError("WAV file without audio data")
  }

  private static func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw EngineError("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))")
    }
  }

  private static func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
  }

  /// FNV-1a, stable across runs (unlike `hashValue`): names cached files after their content.
  static func fingerprint(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}
