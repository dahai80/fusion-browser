import Foundation

// FR-13 scheduling guards + watchdog rebuild policy (NFR-R).
// Idempotency classification: navigate/scroll/screenshot replays safe; click/type/evaluate NOT replayed.

public enum FBSessionState: String, Codable {
    case created
    case running
    case crashed
    case rebuilding
    case closed
    case permanentFail = "permanent_fail"
}

public enum FBSchedulingDecision: Equatable {
    case accept
    case rejectMaxActions(FBError)
    case rejectTimeout(FBError)
    case rejectReplayLimit(FBError)
    case rejectRepeatBreak(FBError)
}

public final class FBScheduler {
    private let guards: FBSchedulingGuards
    private let queue = DispatchQueue(label: "fusion-browser.scheduler")
    private var actionCount: Int = 0
    private var lastActionKey: String? = nil
    private var lastActionRepeat: Int = 0
    private var rebuildDepth: Int = 0
    private var taskStartTs: Double = 0
    private let log = FBLogger.shared

    public init(guards: FBSchedulingGuards) {
        self.guards = guards
    }

    public func reset() {
        queue.sync {
            actionCount = 0
            lastActionKey = nil
            lastActionRepeat = 0
            rebuildDepth = 0
            taskStartTs = Date().timeIntervalSince1970
        }
    }

    // L-5: a visual-grounding click bypasses the __fbMap fingerprint path and clicks at
    // bare coordinates, so the scheduler's lastActionKey (set by the preceding admit to
    // "click:@eN:") no longer reflects what actually ran. A second visual fallback on the
    // same target would trip repeat-break on that stale key. Call this after a visual
    // click so the key advances and the repeat counter reflects the visual path. The
    // visual click still counts against maxActions (already admitted).
    public func noteVisualClick(target: String?) {
        queue.sync {
            lastActionKey = "click:visual:\(target ?? "")"
            lastActionRepeat = 0
        }
    }

    // FR-13: max_actions + task_timeout + repeat detection.
    public func admit(action: ActionType, target: String?, payload: String?) -> FBSchedulingDecision {
        return queue.sync {
            actionCount += 1
            if actionCount > guards.maxActions {
                log.warn("Sched", "max_actions exceeded (\(guards.maxActions))")
                return .rejectMaxActions(.quotaExceeded)
            }
            let now = Date().timeIntervalSince1970
            if taskStartTs == 0 { taskStartTs = now }
            let elapsedMs = Int((now - taskStartTs) * 1000)
            if elapsedMs > guards.taskTimeoutMs {
                log.warn("Sched", "task_timeout exceeded (\(guards.taskTimeoutMs)ms)")
                return .rejectTimeout(.timeout)
            }
            let key = "\(action.rawValue):\(target ?? ""):\(payload ?? "")"
            if key == lastActionKey {
                lastActionRepeat += 1
                // PRD FR-13: "连续 N 次相同 action 中断". occurrence N triggers break.
                // lastActionRepeat counts consecutive repeats after first; break when count reaches cap.
                if lastActionRepeat + 1 >= guards.repeatActionBreak {
                    log.warn("Sched", "repeat action break (\(guards.repeatActionBreak))")
                    return .rejectRepeatBreak(.replayLimit)
                }
            } else {
                lastActionKey = key
                lastActionRepeat = 0
            }
            return .accept
        }
    }

    public func canRebuild() -> Bool {
        return queue.sync {
            rebuildDepth += 1
            if rebuildDepth > guards.rebuildDepthCap {
                log.warn("Sched", "rebuild depth cap (\(guards.rebuildDepthCap))")
                return false
            }
            return true
        }
    }

    // Idempotency: which actions may be replayed after watchdog crash recovery.
    // L-1: .navigate is NOT idempotent — navigating to a POST/PUT URL or a page with an
    // onLoad side effect re-fires that effect on replay (duplicate submit). Only scroll and
    // screenshot are safe to replay (pure view ops). This keeps crash-recovery honest: a
    // timed-out navigate fails directly rather than silently re-loading the URL.
    public static func isIdempotent(_ action: ActionType) -> Bool {
        switch action {
        case .scroll, .screenshot: return true
        case .navigate, .click, .typeText, .evaluate, .close: return false
        }
    }
}
