import Foundation

/// 协调器拥有的加载请求；同一方向与令牌的独立请求仍具有不同身份。
public struct ContinuousLoadTicket: Sendable, Equatable {
    public let id: UUID
    public let direction: PageTurnDirection
    public let token: ContinuousUpdateToken

    /// - Parameters: direction: 加载方向；token: 请求依据的窗口版本。
    internal init(direction: PageTurnDirection, token: ContinuousUpdateToken) {
        id = UUID()
        self.direction = direction
        self.token = token
    }
}

/// 加载请求的唯一终态；安装成功携带安装后的窗口版本。
public enum ContinuousLoadOutcome: Sendable, Equatable {
    case installed(ContinuousUpdateToken)
    case superseded
    case cancelled
    case invalidated
    case rejected(PageTurnError)
}

/// 等待容器安装的完整窗口及其可选锚点。
internal struct ContinuousPreparedUpdate {
    let ticket: ContinuousLoadTicket
    let window: ContinuousWindow
    let anchor: ContinuousAnchor?
}

/// 在主线程管理加载所有权、完整窗口覆盖及同步回调重入。
@MainActor
internal final class ContinuousLoadCoordinator {
    private struct Request {
        let ticket: ContinuousLoadTicket
        let target: ContinuousLoadTarget
        let cancel: () -> Void
        let completion: (ContinuousLoadOutcome) -> Void
        var accepted = false
    }

    private var requests: [PageTurnDirection: Request] = [:]
    private var isInvalidated = false
    private var isDeliveringCallbacks = false
    private var installingRequest: Request?
    internal var isInTerminalCallback: Bool { isDeliveringCallbacks }

    internal private(set) var preparedUpdate: ContinuousPreparedUpdate?
    internal var activeCount: Int { requests.count + (installingRequest == nil ? 0 : 1) }

    /// - Parameter direction: 加载方向。
    /// - Returns: 已登记或正在原子安装时为 true，避免新需求抢占未结束所有权。
    internal func hasRequest(in direction: PageTurnDirection) -> Bool {
        requests[direction] != nil || installingRequest?.ticket.direction == direction
    }

    /// 相同窗口内的占位目标跨方向去重；前后窗口外读取仍可分别并发。
    /// - Parameters: target: 准备读取的内容；token: 安装前置版本。
    /// - Returns: 同一占位已有实际任务或正在安装时为 true。
    internal func hasRequest(for target: ContinuousLoadTarget, token: ContinuousUpdateToken) -> Bool {
        guard case .item = target else { return false }
        if let installingRequest, installingRequest.target == target, installingRequest.ticket.token == token { return true }
        return requests.values.contains { $0.target == target && $0.ticket.token == token }
    }

    /// 创建尚未失效且没有活动请求的协调器。
    internal init() {}

    /// 同方向同版本请求去重，跨版本请求先结束旧任务。
    /// - Parameters: direction: 加载方向；token: 前置窗口版本；target: 窗口边缘或占位目标；cancel: 非安装终态的取消回调；completion: 唯一终态回调。
    /// - Returns: 协调器接管的新请求凭据。
    /// - Throws: 已失效或正在回调、重复请求时的状态错误。
    internal func begin(direction: PageTurnDirection, token: ContinuousUpdateToken, target: ContinuousLoadTarget = .edge,
                        cancel: @escaping () -> Void,
                        completion: @escaping (ContinuousLoadOutcome) -> Void) throws -> ContinuousLoadTicket {
        try validateAdmission()
        guard !hasRequest(for: target, token: token) else { throw PageTurnError.interactionInProgress }
        if let previous = requests[direction] {
            guard previous.ticket.token != token else { throw PageTurnError.interactionInProgress }
            finish(previous.ticket, outcome: .superseded)
            try validateAdmission()
        }
        let ticket = ContinuousLoadTicket(direction: direction, token: token)
        requests[direction] = Request(ticket: ticket, target: target, cancel: cancel, completion: completion)
        return ticket
    }

    /// 接收完整窗口；只保留最近一个准备安装的结果。
    /// - Parameters: ticket: 当前拥有且尚未提交结果的请求；window: 完整窗口；anchor: 安装时恢复的锚点。
    /// - Throws: 已失效、正在回调或请求不存在／已经提交时的状态错误。
    internal func accept(_ ticket: ContinuousLoadTicket, window: ContinuousWindow,
                         anchor: ContinuousAnchor?) throws {
        try validateAdmission()
        guard let request = requests[ticket.direction], request.ticket == ticket, !request.accepted else {
            throw PageTurnError.staleWindow
        }
        if let previous = preparedUpdate {
            finish(previous.ticket, outcome: .superseded)
            try validateAdmission()
        }
        // 旧任务回调可以取消当前任务，必须重新确认所有权。
        guard var current = requests[ticket.direction], current.ticket == ticket else {
            throw PageTurnError.staleWindow
        }
        current.accepted = true
        requests[ticket.direction] = current
        preparedUpdate = ContinuousPreparedUpdate(ticket: ticket, window: window, anchor: anchor)
    }

    /// 在窗口提交点冻结请求所有权；此后普通取消不能改写已提交安装的终态。
    /// - Parameter ticket: 当前已就绪的完整窗口请求。
    /// - Throws: 无效、重入或非当前准备请求。
    internal func lockForInstallation(_ ticket: ContinuousLoadTicket) throws {
        try validateAdmission()
        guard preparedUpdate?.ticket == ticket, let request = remove(ticket) else { throw PageTurnError.staleWindow }
        installingRequest = request
    }

    /// 真实视图安装后交付冻结的成功结果；invalidate 已终止的请求不会再次回调。
    /// - Parameter token: 安装后的窗口版本。
    internal func confirmInstallation(token: ContinuousUpdateToken) {
        guard let request = installingRequest else { return }
        installingRequest = nil
        deliver([request], outcome: .installed(token))
    }

    /// 先移除请求及准备结果，再交付一次终态；未知请求不产生副作用。
    /// - Parameters: ticket: 要结束的请求；outcome: 请求终态，安装成功时不调用取消回调。
    internal func finish(_ ticket: ContinuousLoadTicket, outcome: ContinuousLoadOutcome) {
        guard let request = remove(ticket) else { return }
        deliver([request], outcome: outcome)
    }

    /// 批量清除过期请求后再执行回调，避免回调观察到部分清理状态。
    /// - Parameter token: 唯一允许保留的前置窗口版本。
    internal func discard(except token: ContinuousUpdateToken) {
        let discarded = requests.values.filter { $0.ticket.token != token }
        for request in discarded {
            _ = remove(request.ticket)
        }
        deliver(discarded, outcome: .superseded)
    }

    /// 永久失效；先清空全部状态再回调，重复调用不产生副作用。
    internal func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        var invalidated = Array(requests.values)
        if let installingRequest { invalidated.append(installingRequest) }
        installingRequest = nil
        requests.removeAll()
        preparedUpdate = nil
        deliver(invalidated, outcome: .invalidated)
    }

    // MARK: - 所有权与回调

    /// 校验是否允许接收请求或结果。
    /// - Throws: 永久失效或正在交付终态时的状态错误。
    private func validateAdmission() throws {
        guard !isInvalidated else { throw PageTurnError.inactive }
        guard !isDeliveringCallbacks, installingRequest == nil else { throw PageTurnError.interactionInProgress }
    }

    /// - Parameter ticket: 需要移除的请求凭据。
    /// - Returns: 原请求；所有权不匹配时返回 nil。
    private func remove(_ ticket: ContinuousLoadTicket) -> Request? {
        guard let request = requests[ticket.direction], request.ticket == ticket else { return nil }
        requests.removeValue(forKey: ticket.direction)
        if preparedUpdate?.ticket == ticket {
            preparedUpdate = nil
        }
        return request
    }

    /// 在重入保护下交付已移除请求的终态，嵌套清理不解除外层保护。
    /// - Parameters: completed: 已移除所有权的请求快照；outcome: 这些请求的终态。
    private func deliver(_ completed: [Request], outcome: ContinuousLoadOutcome) {
        let wasDeliveringCallbacks = isDeliveringCallbacks
        isDeliveringCallbacks = true
        defer { isDeliveringCallbacks = wasDeliveringCallbacks }
        for request in completed {
            if case .installed = outcome {
                request.completion(outcome)
            } else {
                request.cancel()
                request.completion(outcome)
            }
        }
    }
}
