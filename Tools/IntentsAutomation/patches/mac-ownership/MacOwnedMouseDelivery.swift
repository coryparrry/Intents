// Recipient-scoped submission, never global HID. Actual UI delivery requires independent observation.
import AgentDeviceMacOSInput
import AppKit
import CoreGraphics
import Foundation

struct MacOwnedMouseEvent: Equatable {
  let type: CGEventType
  let point: CGPoint
  let clickState: Int
}

struct MacOwnedMouseReceipt: Encodable {
  let applicationTarget: MacApplicationTarget
  let x: Double
  let y: Double
  let disposition = "submittedUnconfirmed"
  let releaseSubmitted: Bool
  let clicks: Int
  let doubleClick: Bool
  let holdMs: Int
}

struct MacOwnedMouseDelivery<Event> {
  let prepare: (MacOwnedMouseEvent) throws -> Event
  let submit: (Event, MacApplicationTarget) throws -> Void
  let verifyTarget: (MacApplicationTarget) throws -> Void
  // Release checks process identity but may run after the user changes the frontmost app.
  let verifyReleaseTarget: (MacApplicationTarget) throws -> Void
  let cancelled: () -> Bool
  let wait: (Int) -> Void

  func press(_ request: MouseClickRequest, target: MacApplicationTarget) throws -> MacOwnedMouseReceipt {
    guard request.x.isFinite, request.y.isFinite, abs(request.x) <= 1_000_000, abs(request.y) <= 1_000_000,
      (0...5000).contains(request.holdMs), (1...8).contains(request.clicks), (0...1000).contains(request.intervalMs),
      mouseClickScheduleMs(holdMs: request.holdMs, clicks: request.clicks, doubleClick: request.doubleClick, intervalMs: request.intervalMs) <= 60_000
    else { throw HelperError.invalidArgs("exact-process press exceeds finite operation bounds") }
    try target.validate()
    func check() throws {
      guard !cancelled() else { throw HelperError.commandFailed("exact-process press cancelled before submission") }
      try verifyTarget(target)
    }
    func delay(_ milliseconds: Int) throws {
      var remaining = milliseconds
      while remaining > 0 {
        guard !cancelled() else { throw HelperError.commandFailed("exact-process press cancelled") }
        let step = min(remaining, 10)
        wait(step); remaining -= step
      }
      guard !cancelled() else { throw HelperError.commandFailed("exact-process press cancelled") }
    }
    try check()
    let point = CGPoint(x: request.x, y: request.y)
    let schedule = mouseClickPresses(clicks: request.clicks, doubleClick: request.doubleClick, intervalMs: request.intervalMs)
    // Build every down and up before dispatch. Event-creation failure cannot leave a button held.
    let move = try prepare(.init(type: .mouseMoved, point: point, clickState: 0))
    let events = try schedule.map { press in
      (try prepare(.init(type: .leftMouseDown, point: point, clickState: press.clickState)),
       try prepare(.init(type: .leftMouseUp, point: point, clickState: press.clickState)))
    }
    var heldRelease: Event?
    var submitted = false
    var releaseSubmitted = false
    var releaseAttempted = false
    do {
      try check()
      submitted = true // The backend may throw after submission; treat that conservatively.
      try submit(move, target)
      for (index, press) in schedule.enumerated() {
        try delay(press.delayBeforeMs)
        try check()
        heldRelease = events[index].1
        releaseSubmitted = false
        releaseAttempted = false
        try submit(events[index].0, target)
        try delay(mouseClickHoldMs(requestedMs: request.holdMs))
        try verifyReleaseTarget(target)
        releaseAttempted = true
        try submit(events[index].1, target)
        releaseSubmitted = true
        heldRelease = nil
        try check()
      }
    } catch {
      if let release = heldRelease, !releaseAttempted {
        do {
          try verifyReleaseTarget(target) // Refuse a reused/disappeared PID, even for cleanup.
          releaseAttempted = true
          try submit(release, target)
          releaseSubmitted = true
        } catch { releaseSubmitted = false }
      }
      if submitted {
        throw HelperError.commandFailed("exact-process mouse delivery is unknown", details: [
          "deliveryUnknown": "true", "mayHaveCommitted": "true", "releaseSubmitted": String(releaseSubmitted),
          "releaseUncertain": String(releaseAttempted && !releaseSubmitted),
          "reason": String(describing: error)])
      }
      throw error
    }
    return .init(applicationTarget: target, x: request.x, y: request.y, releaseSubmitted: releaseSubmitted,
      clicks: request.clicks, doubleClick: request.doubleClick, holdMs: mouseClickHoldMs(requestedMs: request.holdMs))
  }
}

// Signal callbacks run on an ordinary dispatch queue. No CoreGraphics, locks or allocation
// occur in a POSIX signal handler; cleanup stays in the operation's structured error path.
private final class MacMouseCancellation {
  private let lock = NSLock()
  private var value = false
  private var sources: [DispatchSourceSignal] = []
  init() {
    for number in [SIGTERM, SIGINT, SIGHUP] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
      source.setEventHandler { [weak self] in
        guard let self else { return }
        self.lock.lock(); self.value = true; self.lock.unlock()
      }
      source.activate(); sources.append(source)
    }
  }
  var cancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return value
  }
  deinit { for source in sources { source.cancel() } }
}

func postMacOwnedMouseClick(_ request: MouseClickRequest, target: MacApplicationTarget) throws -> MacOwnedMouseReceipt {
  let cancellation = MacMouseCancellation()
  let delivery = MacOwnedMouseDelivery<CGEvent>(prepare: { specification in
    guard let event = CGEvent(mouseEventSource: nil, mouseType: specification.type,
      mouseCursorPosition: specification.point, mouseButton: .left) else {
      throw HelperError.commandFailed("exact-process mouse event creation failed")
    }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(specification.clickState))
    return event
  }, submit: { event, target in
    // The public API takes a PID, not a process generation; this narrow race remains unqualified.
    _ = try target.application()
    event.postToPid(target.pid)
  }, verifyTarget: { target in
    _ = try target.application()
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
      throw HelperError.commandFailed("selected Mac app is not frontmost")
    }
  }, verifyReleaseTarget: { _ = try $0.application() }, cancelled: { cancellation.cancelled },
    wait: { usleep(UInt32($0) * 1000) })
  return try delivery.press(request, target: target)
}
