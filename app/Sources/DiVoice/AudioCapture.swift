import AVFoundation
import CoreAudio
import DiVoiceCore

struct AudioInputDevice: Identifiable, Hashable {
  let id: AudioDeviceID
  let uid: String
  let name: String
}

/// Lists the microphones through Core Audio.
enum AudioDevices {
  static func inputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      guard inputChannels(id) > 0,
            let uid = string(id, kAudioDevicePropertyDeviceUID),
            let name = string(id, kAudioObjectPropertyName)
      else { return nil }
      return AudioInputDevice(id: id, uid: uid, name: name)
    }
  }

  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    inputDevices().first { $0.uid == uid }?.id
  }

  private static func inputChannels(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}

/// Captures from the microphone and converts to mono PCM s16le at the provider's sample rate
/// (16 kHz Mistral, 24 kHz OpenAI), in 100 ms chunks.
final class AudioCapture {
  enum CaptureError: LocalizedError {
    case noInput
    case converter

    var errorDescription: String? {
      switch self {
      case .noInput: return String(localized: "no microphone available")
      case .converter: return String(localized: "unsupported audio format")
      }
    }
  }

  /// Called on the audio queue.
  var onFrame: ((Data) -> Void)?
  var onLevel: ((Float) -> Void)?
  /// First buffer from the microphone after start: audio is captured from here on.
  var onFirstBuffer: ((UInt64) -> Void)?

  private var engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var framer = PCMFramer()
  private let queue = DispatchQueue(label: "app.wibo.divoice.audio", qos: .userInteractive)
  private var outputFormat = AudioCapture.format(PCM.sampleRate)
  private(set) var sampleRate = PCM.sampleRate
  private var engineNeedsRebuild = false
  private var configuredDeviceUID: String?
  private var observer: NSObjectProtocol?
  private var prepared = false
  private var firstBufferPending = false
  private(set) var isRunning = false

  init() {
    observeConfigurationChanges()
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func observeConfigurationChanges() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    // Device or format change: the engine is recreated at the next recording.
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in self?.engineNeedsRebuild = true }
  }

  /// Prepares engine, device and converter ahead of time, so that on key press only the
  /// hardware start remains. Does not turn the microphone on.
  func prepare(deviceUID: String, sampleRate: Int) {
    guard !isRunning else { return }
    if prepared && !engineNeedsRebuild && configuredDeviceUID == deviceUID && self.sampleRate == sampleRate { return }
    self.sampleRate = sampleRate
    outputFormat = Self.format(sampleRate)
    if prepared { engine.inputNode.removeTap(onBus: 0) }
    prepared = false
    engine = AVAudioEngine()
    observeConfigurationChanges()
    engineNeedsRebuild = false

    let input = engine.inputNode
    if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
      var device = id
      AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &device, UInt32(MemoryLayout<AudioDeviceID>.size)
      )
    }
    configuredDeviceUID = deviceUID

    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
          let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { return }
    self.converter = converter
    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      self?.process(buffer)
    }
    engine.prepare()
    prepared = true
  }

  func start(deviceUID: String, sampleRate: Int) throws {
    if isRunning { _ = stop() }
    prepare(deviceUID: deviceUID, sampleRate: sampleRate)
    guard prepared, let converter else { throw CaptureError.noInput }
    converter.reset()
    let frameBytes = PCM.frameBytes(sampleRate: sampleRate)
    queue.sync { framer = PCMFramer(frameBytes: frameBytes) }
    firstBufferPending = true
    do {
      try engine.start()
    } catch {
      engineNeedsRebuild = true
      throw error
    }
    isRunning = true
  }

  private static func format(_ sampleRate: Int) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
  }

  /// Stops capturing and returns the remaining audio (less than 100 ms).
  func stop() -> Data? {
    guard isRunning else { return nil }
    engine.stop()
    isRunning = false
    // After the chunks already queued, the rest.
    let rest = queue.sync { framer.flush() }
    // Ready for the next dictation.
    if !engineNeedsRebuild { engine.prepare() }
    return rest
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    if firstBufferPending {
      firstBufferPending = false
      onFirstBuffer?(MonotonicClock.nowNs())
    }
    if let channels = buffer.floatChannelData {
      let level = PCM.level(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
      onLevel?(level)
    }
    guard let converter else { return }
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        // noDataNow (not endOfStream) keeps the resampler state between buffers.
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return }
    let data = Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    queue.async { [weak self] in
      guard let self else { return }
      for frame in self.framer.append(data) { self.onFrame?(frame) }
    }
  }
}
