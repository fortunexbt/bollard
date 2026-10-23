import Carbon
import Foundation

/// A single global shortcut (⌃⌥B) that opens the panel from anywhere. Carbon hot keys need
/// no accessibility permission.
@MainActor final class Hotkey {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void
  static let description = "⌃⌥B"

  init(action: @escaping () -> Void) {
    self.action = action
  }
  func register() {
    guard reference == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in hotkey.action() }
        return noErr
      }, 1, &spec, pointer, &handler)
    let id = EventHotKeyID(signature: OSType(0x424C_4C44), id: 1)  // "BLLD"
    RegisterEventHotKey(
      UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0,
      &reference)
  }
  func unregister() {
    if let reference { UnregisterEventHotKey(reference) }
    reference = nil
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}
