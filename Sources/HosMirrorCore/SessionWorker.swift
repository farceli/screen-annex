import Foundation

/// 一次连接的取消凭据；主线程取消后，工作线程和所有旧回调都会看到同一状态。
public final class ConnectionAttempt: @unchecked Sendable { // 全部可变状态由 NSLock 保护，可安全跨队列传递。
    private let lock = NSLock() // 保护跨线程读取的取消标记。
    private var cancelled = false // 新连接默认有效。

    public init() {}

    public var isCancelled: Bool {
        lock.lock() // 与 cancel() 配对，避免读取到过期状态。
        defer { lock.unlock() } // 所有返回路径都释放锁。
        return cancelled // 对调用者只暴露线程安全的快照。
    }

    public func cancel() {
        lock.lock() // 取消可从任意线程发起。
        cancelled = true // 重复取消仍然安全。
        lock.unlock() // 不在锁内执行外部代码。
    }

    public func checkCancellation() throws {
        if isCancelled { throw CancellationError() } // 用标准取消错误中止启动流程。
    }
}

/// 工作队列拥有会话的资源释放权，便于用假会话验证取消与重连顺序。
public protocol SessionResource: AnyObject {
    func stop() // 实现必须允许重复调用。
}

/// 每台设备独占一个串行队列；清理、启动和输入不能相互穿插。
public final class SessionWorker<Resource: SessionResource> {
    private let queue = DispatchQueue(label: "hosmirror.session.worker") // 网络和 hdc 均离开主线程。
    private var current: (ConnectionAttempt, Resource)? // 只允许工作队列访问当前资源。

    public init() {}

    deinit {
        guard let current else { return } // 已停止的工作队列没有待释放资源。
        current.0.cancel() // 先使回调失效。
        let resource = current.1 // 释放操作不能捕获正在析构的 self。
        queue.async { resource.stop() } // 最后一次释放同样不阻塞拥有者的线程。
    }

    public func start(
        attempt: ConnectionAttempt,
        create: @escaping () throws -> Resource,
        completion: @escaping (Result<Resource, Error>) -> Void
    ) {
        queue.async { // 串行执行，保证旧设备守护进程先结束再启动新进程。
            self.releaseCurrent() // 新连接接管设备前，先完整释放上一次会话。
            do {
                try attempt.checkCancellation() // 排队期间已取消则不访问设备。
                let resource = try create() // 创建函数负责处理自身的部分初始化失败。
                if attempt.isCancelled { // 启动期间取消时，不能把资源交给界面。
                    resource.stop() // 仍在同一队列内清理，避免误杀后续新会话。
                    throw CancellationError() // 通知调用方这次结果已失效。
                }
                self.current = (attempt, resource) // 接管成功创建的资源。
                completion(.success(resource)) // 调用方负责切换回自己的 UI 执行器。
            } catch {
                completion(.failure(error)) // 取消与失败统一通过结果返回。
            }
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async { self.releaseCurrent(); completion?() } // 退出应用时等到底层资源释放完成，普通关窗仍不阻塞。
    }

    public func perform(attempt: ConnectionAttempt, _ action: @escaping (Resource) -> Void) {
        queue.async { // 保持触控、按键和关闭的先后顺序。
            guard !attempt.isCancelled, let current = self.current,
                  current.0 === attempt else { return } // 旧连接排队的输入不可落到新设备会话。
            action(current.1) // 阻塞 I/O 仅影响这台设备自己的工作队列。
        }
    }

    private func releaseCurrent() {
        guard let current else { return } // 空闲状态无需清理。
        self.current = nil // 先移除所有权，避免重复关闭同一资源。
        current.0.cancel() // 先使已投递的旧回调失效。
        current.1.stop() // 再同步完成底层资源释放。
    }
}
