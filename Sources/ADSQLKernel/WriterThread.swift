import Dispatch
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A serial executor backed by ONE dedicated pthread running on a large,
/// controlled stack. It is a drop-in replacement for the `adsql.writer`
/// `DispatchQueue` and preserves that queue's exact contract:
///
///   * serial mutual exclusion — at most one job runs at a time;
///   * FIFO order — jobs run in enqueue order;
///   * `sync` blocks the caller until the job has run *on the writer thread*.
///
/// Why a dedicated thread instead of the Dispatch queue: write execution
/// re-enters itself recursively (row triggers fire `Writer.execute`, whose DML
/// fires more triggers). A Dispatch worker stack is only ~512 KiB, so deep
/// trigger chains overflow it. This thread owns a `stackSize`-byte stack, so
/// recursion depth is decoupled from the caller's stack and bounded only by a
/// measured, generous budget (see `TriggerEngine.maxDepth`).
///
/// Memory cost: exactly one extra thread. `stackSize` is a *virtual* address
/// reservation, lazily committed page-by-page; an idle writer thread (blocked
/// on its wakeup semaphore) costs a thread control block plus the one or two
/// stack pages it has actually touched — RSS tracks real recursion depth, not
/// `stackSize`.
@safe final class WriterThread: Sendable {
    /// Reserved stack for the writer thread. Virtual, lazily committed — costs
    /// nothing until trigger recursion actually grows into it. Worst-case
    /// per-level growth is ~33.7 KiB under ThreadSanitizer (measured; see
    /// `TriggerEngine.maxDepth`), so `maxDepth = 100` peaks at ~3.3 MiB ≈ 20% of
    /// this 16 MiB — a ~4.9× margin (well inside the ≥2.5× budget). SQLite-parity
    /// recursion (1000) is reachable by raising this single constant (~128 MiB
    /// virtual); it remains a knob. `pthread_attr_setstacksize` requires a
    /// page-aligned size ≥ `PTHREAD_STACK_MIN`; 16 MiB satisfies both.
    static let stackSize = 16 << 20

    /// One unit of serial work. `body` runs on the writer thread; `done`, when
    /// present (the `sync` path), is signalled after `body` returns so the blocked
    /// caller can resume. `@unchecked Sendable`: `body` is moved to the writer
    /// thread, but only under the hand-off discipline of `sync`/`async` (for
    /// `sync` the caller is parked on `done`, so `body` never runs concurrently
    /// with the caller; for `async` the caller already supplies `@Sendable`).
    /// Same justification as `Database.PendingWrite`.
    private struct Job: @unchecked Sendable {
        let body: () -> Void
        let done: DispatchSemaphore?
    }

    private struct State {
        var queue: [Job] = []
        var shuttingDown = false
    }

    private let state = Mutex(State())
    /// Counting semaphore: signalled exactly once per enqueue, waited exactly
    /// once per popped job. One-to-one signal/wait makes wakeups lost-wakeup-free
    /// regardless of enqueue/drain interleaving. (`DispatchSemaphore` is a thin
    /// futex wrapper — it runs no work on a Dispatch worker, so it does NOT
    /// reintroduce the small-stack problem this dedicated thread exists to avoid;
    /// that is why `import Dispatch` is kept.)
    private let wakeup = DispatchSemaphore(value: 0)
    /// The dedicated worker thread handle; set once in `init`, read once in
    /// `shutdown`. `pthread_t` is an opaque-pointer type and not `Sendable`, so
    /// it travels inside an `@unchecked Sendable` holder; access is serialized by
    /// the `didShutdown` exchange in `shutdown` (set happens-before any read).
    private let thread = Mutex<ThreadHandle>(ThreadHandle())
    private let didShutdown = Atomic<Bool>(false)

    init() {
        // Hand the freshly constructed instance to the C trampoline as a retained
        // Unmanaged reference: the trampoline takes that retain back (balancing it)
        // and runs `runLoop` for the life of the thread. The start arg references
        // `WriterThread`, never `Database`, so it forms no retain cycle with the
        // owner (see `Database.deinit`).
        let opaque = unsafe Unmanaged.passRetained(self).toOpaque()

        var attr = pthread_attr_t()
        guard unsafe pthread_attr_init(&attr) == 0 else {
            // Stack reservation failed; reclaim the retain we just handed out so the
            // instance is not leaked. The loop never started, so this is safe.
            unsafe Unmanaged<WriterThread>.fromOpaque(opaque).release()
            // A failed attribute init is a process-level resource exhaustion the DB
            // cannot recover from; trapping here keeps `init` non-throwing and the
            // invariant "a constructed WriterThread has a running loop" intact.
            fatalError("pthread_attr_init failed")
        }
        defer { unsafe pthread_attr_destroy(&attr) }
        guard unsafe pthread_attr_setstacksize(&attr, Self.stackSize) == 0 else {
            unsafe Unmanaged<WriterThread>.fromOpaque(opaque).release()
            fatalError("pthread_attr_setstacksize(\(Self.stackSize)) failed")
        }
        // Match the QoS the replaced `adsql.writer` DispatchQueue ran at
        // (`.userInitiated`). Without this the thread inherits a lower default QoS,
        // so the scheduler is slower to wake it on `sync` hand-off — measurably
        // inflating writeSync latency. Best-effort: ignore failure (QoS is an
        // optimization, not a correctness requirement). The QoS attribute is a
        // Darwin extension (`_np`); Glibc has no equivalent, so the thread simply
        // runs at the default scheduling class there — a latency knob, not a
        // correctness difference.
        #if canImport(Darwin)
            _ = unsafe pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0)
        #endif

        var tid: pthread_t?
        let rc = unsafe pthread_create(&tid, &attr, writerThreadMain, opaque)
        // `pthread_t` is an opaque-pointer (unsafe) type, so binding/storing the
        // handle is itself an unsafe expression even though we never dereference it.
        guard rc == 0, let tid = unsafe tid else {
            unsafe Unmanaged<WriterThread>.fromOpaque(opaque).release()
            fatalError("pthread_create failed (\(rc))")
        }
        thread.withLock { unsafe $0.tid = tid }
    }

    /// Enqueues `body` and BLOCKS the caller until it has run on the writer
    /// thread, then returns. Replaces `DispatchQueue.sync`.
    ///
    /// `body` is non-escaping, but it must cross a thread boundary to run on the
    /// writer thread, which requires `@escaping` + `Sendable`. This is sound:
    /// the caller `wait()`s on `done` and the writer `signal()`s it only after
    /// `body` returns, so `body` never runs concurrently with — nor outlives —
    /// this call. There is exactly one accessor at any instant (the writer while
    /// it runs `body`; the caller, parked, before and after). `withoutActuallyEscaping`
    /// bridges the non-escaping closure; `UncheckedSendableBox` moves it across
    /// the boundary under that same hand-off discipline. (Precedent: the group-
    /// commit `PendingWrite` is `@unchecked Sendable` for the identical reason.)
    func sync(_ body: () -> Void) {
        withoutActuallyEscaping(body) { escapingBody in
            let box = UncheckedSendableBox(escapingBody)
            let done = DispatchSemaphore(value: 0)
            let job = Job(body: { box.value() }, done: done)
            let accepted: Bool = state.withLock { s in
                // After shutdown the loop will not run new jobs; refuse rather than
                // park the caller forever. (Database owns this thread for its whole
                // lifetime, so in practice shutdown only happens at deinit when no
                // jobs are in flight; this guard is belt-and-suspenders.)
                guard !s.shuttingDown else { return false }
                s.queue.append(job)
                return true
            }
            guard accepted else { return }
            wakeup.signal()
            done.wait()
        }
    }

    /// Enqueues `body` without waiting. Replaces `DispatchQueue.async`.
    func async(_ body: @escaping @Sendable () -> Void) {
        let accepted: Bool = state.withLock { s in
            guard !s.shuttingDown else { return false }
            s.queue.append(Job(body: body, done: nil))
            return true
        }
        guard accepted else { return }
        wakeup.signal()
    }

    /// Stops the loop and joins the thread. Idempotent: the first call performs
    /// the shutdown, later calls are no-ops.
    func shutdown() {
        guard didShutdown.exchange(true, ordering: .acquiringAndReleasing) == false else { return }
        state.withLock { $0.shuttingDown = true }
        // Wake the loop so it observes the flag and (with an empty queue) returns.
        wakeup.signal()
        guard let tid = unsafe thread.withLock({ unsafe $0.tid }) else { return }
        // A group-commit drain captures `Database` strongly (`[self]`); when the
        // worker frees that closure (`runAndComplete`'s `body = nil`) it can drop
        // the LAST reference, so `Database.deinit` — hence this `shutdown()` — may
        // run ON the writer thread itself. Joining the calling thread is `EDEADLK`/
        // UB, so detect that case and `pthread_detach` instead: `shuttingDown` plus
        // the signal above guarantee `runLoop` returns, after which a detached
        // thread reclaims itself (no leak). Off the writer thread (the normal path)
        // we join, so teardown is synchronous.
        if unsafe pthread_equal(pthread_self(), tid) != 0 {
            unsafe pthread_detach(tid)
        } else {
            unsafe pthread_join(tid, nil)
        }
    }

    /// Single-consumer serial loop. Runs on the dedicated thread until shutdown
    /// is requested AND the queue has drained.
    fileprivate func runLoop() {
        while true {
            wakeup.wait()
            // Pop under the lock. The popped `Job` is moved straight into
            // `runAndComplete` without binding it to a surviving local, so the worker
            // holds no reference to the body once that call returns.
            let popped: Job? = state.withLock { s in
                if s.queue.isEmpty {
                    // Empty + shutting down ⇒ terminate. Empty + not shutting down means
                    // this signal was the shutdown wakeup racing an already-popped job;
                    // loop and wait again (the 1:1 signal/wait accounting holds).
                    return nil
                }
                return s.queue.removeFirst()
            }
            switch consume popped {
            case .none:
                if state.withLock({ $0.shuttingDown }) { return }
            case .some(let job):
                runAndComplete(job)
            }
        }
    }

    /// Runs one job, then signals its completion — having FIRST released the body.
    ///
    /// Ordering is load-bearing for the `sync` path: the blocked caller is parked
    /// inside `withoutActuallyEscaping`, which traps if any copy of the bridged
    /// closure is still alive when its block returns. So we run the body, set our
    /// only reference to it to `nil` (releasing the closure and its
    /// `UncheckedSendableBox`), and signal only after that. `signal`/`wait`
    /// establishes happens-before, so the resuming caller observes the body
    /// already released and the post-condition holds. `consuming` ensures no copy
    /// lingers in this frame. The release of `body` cannot move after
    /// `done.signal()`: both are opaque calls (an ARC release and a semaphore
    /// signal) the optimizer cannot prove are independent, so it may not reorder
    /// them; `@inline(never)` additionally preserves this ordering across any
    /// inlining into `runLoop`.
    @inline(never)
    private func runAndComplete(_ job: consuming Job) {
        let done = job.done
        var body: (() -> Void)? = job.body
        // End `job`'s lifetime now: from here only `body` retains the closure, so
        // nil-ing it below is the single, final release before the signal.
        _ = consume job
        body?()
        body = nil
        done?.signal()
    }
}

/// Moves a value across an isolation boundary when correctness is guaranteed by
/// an external hand-off protocol (here: the `sync` semaphore round-trip) rather
/// than by the type system. Mirrors the `@unchecked Sendable` discipline of
/// `Database.PendingWrite`.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Holds the opaque `pthread_t` so it can live in a `Mutex` under strict
/// memory safety. `@unchecked Sendable`: the handle is written once (end of
/// `init`) and read once (`shutdown`), with the `didShutdown` exchange ordering
/// the read after the write; it is never used concurrently. `@safe`: the
/// opaque-pointer storage is owned by this type and only ever handed to
/// `pthread_join` (mirrors `ReaderTable`'s `@safe` over its mapped pointer).
@safe private struct ThreadHandle: @unchecked Sendable {
    var tid: pthread_t?
}

/// C trampoline for `pthread_create`. Reclaims the retain handed out in
/// `WriterThread.init` and enters the serial loop. Returns `nil` per the
/// `@convention(c)` start-routine signature when the loop ends (at shutdown).
/// The argument type differs by platform: Darwin imports the start routine's
/// `void *` as a non-optional `UnsafeMutableRawPointer`, whereas Glibc imports
/// it as an optional. Both receive the exact same non-nil `opaque` pointer
/// `pthread_create` was handed, so the Linux branch force-unwraps it.
#if canImport(Darwin)
    private func writerThreadMain(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        let instance = unsafe Unmanaged<WriterThread>.fromOpaque(arg).takeRetainedValue()
        instance.runLoop()
        return nil
    }
#elseif canImport(Glibc)
    private func writerThreadMain(_ arg: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        let instance = unsafe Unmanaged<WriterThread>.fromOpaque(arg!).takeRetainedValue()
        instance.runLoop()
        return nil
    }
#endif
