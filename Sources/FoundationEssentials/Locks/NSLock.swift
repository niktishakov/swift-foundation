//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if !hasFeature(Embedded)

#if !FOUNDATION_FRAMEWORK

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#endif

/// The elementary methods adopted by classes that define lock objects.
public protocol NSLocking {
    /// Attempts to acquire a lock, blocking a thread's execution until the lock can be acquired.
    func lock()

    /// Relinquishes a previously acquired lock.
    func unlock()
}

extension NSLocking {
    /// Acquires the lock, runs `body`, and releases the lock, even if `body` throws.
    @_alwaysEmitIntoClient
    @_disfavoredOverload
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        self.lock()
        defer {
            self.unlock()
        }

        return try body()
    }
}

#if os(Windows)
private typealias MutexPointer = UnsafeMutablePointer<SRWLOCK>
private typealias RecursiveMutexPointer = UnsafeMutablePointer<CRITICAL_SECTION>
private typealias ConditionVariablePointer = UnsafeMutablePointer<CONDITION_VARIABLE>
#elseif os(OpenBSD) || os(FreeBSD)
private typealias MutexPointer = UnsafeMutablePointer<pthread_mutex_t?>
private typealias RecursiveMutexPointer = UnsafeMutablePointer<pthread_mutex_t?>
private typealias ConditionVariablePointer = UnsafeMutablePointer<pthread_cond_t?>
#else
private typealias MutexPointer = UnsafeMutablePointer<pthread_mutex_t>
private typealias RecursiveMutexPointer = UnsafeMutablePointer<pthread_mutex_t>
private typealias ConditionVariablePointer = UnsafeMutablePointer<pthread_cond_t>
#endif

// `@unchecked Sendable`: the lock state is only touched through the platform lock functions, which are thread-safe. `name` is not synchronized, the same as on Darwin.

/// An object that coordinates the operation of multiple threads of execution within the same application.
open class NSLock: NSLocking, @unchecked Sendable {
    private let mutex = MutexPointer.allocate(capacity: 1)
#if canImport(Darwin) || os(Windows)
    private let timeoutCond = ConditionVariablePointer.allocate(capacity: 1)
    private let timeoutMutex = MutexPointer.allocate(capacity: 1)
#endif

    public init() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        InitializeSRWLock(mutex)
        InitializeConditionVariable(timeoutCond)
        InitializeSRWLock(timeoutMutex)
#else
        pthread_mutex_init(mutex, nil)
#if canImport(Darwin)
        pthread_cond_init(timeoutCond, nil)
        pthread_mutex_init(timeoutMutex, nil)
#endif
#endif
    }

    deinit {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        // SRWLocks do not need to be explicitly destroyed
#else
        pthread_mutex_destroy(mutex)
#endif
        mutex.deinitialize(count: 1)
        mutex.deallocate()
#if canImport(Darwin) || os(Windows)
        deallocateTimedLockData(cond: timeoutCond, mutex: timeoutMutex)
#endif
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        AcquireSRWLockExclusive(mutex)
#else
        pthread_mutex_lock(mutex)
#endif
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func unlock() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        ReleaseSRWLockExclusive(mutex)
        AcquireSRWLockExclusive(timeoutMutex)
        WakeAllConditionVariable(timeoutCond)
        ReleaseSRWLockExclusive(timeoutMutex)
#else
        pthread_mutex_unlock(mutex)
#if canImport(Darwin)
        // Wake up any threads waiting in lock(before:)
        pthread_mutex_lock(timeoutMutex)
        pthread_cond_broadcast(timeoutCond)
        pthread_mutex_unlock(timeoutMutex)
#endif
#endif
    }

    /// Attempts to acquire a lock and immediately returns a Boolean value that indicates whether the attempt was successful.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func `try`() -> Bool {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
        return true
#elseif os(Windows)
        return TryAcquireSRWLockExclusive(mutex) != 0
#else
        return pthread_mutex_trylock(mutex) == 0
#endif
    }

    /// Attempts to acquire a lock before a given time and returns a Boolean value that indicates whether the attempt was successful.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock(before limit: Date) -> Bool {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
        return true
#else
#if os(Windows)
        if TryAcquireSRWLockExclusive(mutex) != 0 {
            return true
        }
#else
        if pthread_mutex_trylock(mutex) == 0 {
            return true
        }
#endif

#if canImport(Darwin) || os(Windows)
        return timedLock(mutex: mutex, endTime: limit, using: timeoutCond, with: timeoutMutex)
#else
        guard var endTime = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_mutex_timedlock(mutex, &endTime) == 0
#endif
#endif
    }

    /// The name associated with the lock.
    open var name: String?
}

#if _runtime(_multithreaded)
/// A lock that can be associated with specific, user-defined conditions.
open class NSConditionLock: NSLocking, @unchecked Sendable {
    // Protected by `cond`
    private let cond = NSCondition()
    private var value: Int
    private var isLocked = false

    public convenience init() {
        self.init(condition: 0)
    }

    /// Creates a condition lock and sets its condition to the given value.
    public init(condition: Int) {
        value = condition
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock() {
        let _ = lock(before: Date.distantFuture)
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func unlock() {
        cond.lock()
        isLocked = false
        cond.broadcast()
        cond.unlock()
    }

    /// The condition associated with the lock.
    open var condition: Int {
        return value
    }

    /// Acquires the lock when its condition is equal to the given value.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock(whenCondition condition: Int) {
        let _ = lock(whenCondition: condition, before: Date.distantFuture)
    }

    /// Attempts to acquire the lock and immediately returns a Boolean value that indicates whether the attempt was successful.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func `try`() -> Bool {
        return lock(before: Date.distantPast)
    }

    /// Attempts to acquire the lock when its condition is equal to the given value, and returns at once.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func tryLock(whenCondition condition: Int) -> Bool {
        return lock(whenCondition: condition, before: Date.distantPast)
    }

    /// Sets the condition and releases the lock.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func unlock(withCondition condition: Int) {
        cond.lock()
        isLocked = false
        value = condition
        cond.broadcast()
        cond.unlock()
    }

    /// Attempts to acquire the lock before the given time.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock(before limit: Date) -> Bool {
        cond.lock()
        while isLocked {
            if !cond.wait(until: limit) {
                cond.unlock()
                return false
            }
        }
        isLocked = true
        cond.unlock()
        return true
    }

    /// Attempts to acquire the lock before the given time, when its condition is equal to the given value.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock(whenCondition condition: Int, before limit: Date) -> Bool {
        cond.lock()
        while isLocked || value != condition {
            if !cond.wait(until: limit) {
                cond.unlock()
                return false
            }
        }
        isLocked = true
        cond.unlock()
        return true
    }

    /// The name associated with the lock.
    open var name: String?
}
#endif

/// A lock that the same thread can acquire more than once without causing a deadlock.
open class NSRecursiveLock: NSLocking, @unchecked Sendable {
    private let mutex = RecursiveMutexPointer.allocate(capacity: 1)
#if canImport(Darwin) || os(Windows)
    private let timeoutCond = ConditionVariablePointer.allocate(capacity: 1)
    private let timeoutMutex = MutexPointer.allocate(capacity: 1)
#endif

    public init() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        InitializeCriticalSection(mutex)
        InitializeConditionVariable(timeoutCond)
        InitializeSRWLock(timeoutMutex)
#else
#if os(OpenBSD) || os(FreeBSD)
        var attrib: pthread_mutexattr_t? = nil
#else
        var attrib = pthread_mutexattr_t()
#endif
        withUnsafeMutablePointer(to: &attrib) { attrs in
            pthread_mutexattr_init(attrs)
#if os(OpenBSD) || os(FreeBSD)
            let type = Int32(PTHREAD_MUTEX_RECURSIVE.rawValue)
#else
            let type = Int32(PTHREAD_MUTEX_RECURSIVE)
#endif
            pthread_mutexattr_settype(attrs, type)
            pthread_mutex_init(mutex, attrs)
            pthread_mutexattr_destroy(attrs)
        }
#if canImport(Darwin)
        pthread_cond_init(timeoutCond, nil)
        pthread_mutex_init(timeoutMutex, nil)
#endif
#endif
    }

    deinit {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        DeleteCriticalSection(mutex)
#else
        pthread_mutex_destroy(mutex)
#endif
        mutex.deinitialize(count: 1)
        mutex.deallocate()
#if canImport(Darwin) || os(Windows)
        deallocateTimedLockData(cond: timeoutCond, mutex: timeoutMutex)
#endif
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        EnterCriticalSection(mutex)
#else
        pthread_mutex_lock(mutex)
#endif
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func unlock() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        LeaveCriticalSection(mutex)
        AcquireSRWLockExclusive(timeoutMutex)
        WakeAllConditionVariable(timeoutCond)
        ReleaseSRWLockExclusive(timeoutMutex)
#else
        pthread_mutex_unlock(mutex)
#if canImport(Darwin)
        // Wake up any threads waiting in lock(before:)
        pthread_mutex_lock(timeoutMutex)
        pthread_cond_broadcast(timeoutCond)
        pthread_mutex_unlock(timeoutMutex)
#endif
#endif
    }

    /// Attempts to acquire a lock, and immediately returns a Boolean value that indicates whether the attempt was successful.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func `try`() -> Bool {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
        return true
#elseif os(Windows)
        return TryEnterCriticalSection(mutex)
#else
        return pthread_mutex_trylock(mutex) == 0
#endif
    }

    /// Attempts to acquire a lock before a given time and returns a Boolean value that indicates whether the attempt was successful.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock(before limit: Date) -> Bool {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
        return true
#else
#if os(Windows)
        if TryEnterCriticalSection(mutex) {
            return true
        }
#else
        if pthread_mutex_trylock(mutex) == 0 {
            return true
        }
#endif

#if canImport(Darwin) || os(Windows)
        return timedLock(mutex: mutex, endTime: limit, using: timeoutCond, with: timeoutMutex)
#else
        guard var endTime = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_mutex_timedlock(mutex, &endTime) == 0
#endif
#endif
    }

    /// The name associated with the lock.
    open var name: String?
}

/// A condition variable whose semantics follow those used for POSIX-style conditions.
open class NSCondition: NSLocking, @unchecked Sendable {
    private let mutex = MutexPointer.allocate(capacity: 1)
    private let cond = ConditionVariablePointer.allocate(capacity: 1)

    public init() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        InitializeSRWLock(mutex)
        InitializeConditionVariable(cond)
#else
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(cond, nil)
#endif
    }

    deinit {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        // SRWLocks do not need to be explicitly destroyed
#else
        pthread_mutex_destroy(mutex)
        pthread_cond_destroy(cond)
#endif
        mutex.deinitialize(count: 1)
        cond.deinitialize(count: 1)
        mutex.deallocate()
        cond.deallocate()
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func lock() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        AcquireSRWLockExclusive(mutex)
#else
        pthread_mutex_lock(mutex)
#endif
    }

    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func unlock() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        ReleaseSRWLockExclusive(mutex)
#else
        pthread_mutex_unlock(mutex)
#endif
    }

    /// Blocks the current thread until the condition is signaled.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func wait() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        SleepConditionVariableSRW(cond, mutex, WinSDK.INFINITE, 0)
#else
        pthread_cond_wait(cond, mutex)
#endif
    }

    /// Blocks the current thread until the condition is signaled or the specified time limit is reached.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func wait(until limit: Date) -> Bool {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
        return true
#elseif os(Windows)
        return SleepConditionVariableSRW(cond, mutex, timeoutFrom(date: limit), 0)
#else
        guard var timeout = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_cond_timedwait(cond, mutex, &timeout) == 0
#endif
    }

    /// Signals the condition, waking up one thread waiting on it.
    @available(*, noasync, message: "Use async-safe scoped locking instead")
    open func signal() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        WakeConditionVariable(cond)
#else
        pthread_cond_signal(cond)
#endif
    }

    /// Signals the condition, waking up all threads waiting on it.
    open func broadcast() {
#if !_runtime(_multithreaded)
        // No-op on platforms without threads
#elseif os(Windows)
        WakeAllConditionVariable(cond)
#else
        pthread_cond_broadcast(cond)
#endif
    }

    /// The name associated with the condition.
    open var name: String?
}

#if os(Windows)
private func timeoutFrom(date: Date) -> DWORD {
    guard date.timeIntervalSinceNow > 0 else { return 0 }
    return DWORD(date.timeIntervalSinceNow * 1000)
}
#else
private func timeSpecFrom(date: Date) -> timespec? {
    guard date.timeIntervalSinceNow > 0 else {
        return nil
    }
    let interval = date.timeIntervalSince1970
    let seconds = interval.rounded(.down)
    // Dates such as `Date.distantFuture` do not fit in `time_t` as nanoseconds, or on some platforms even as seconds
    guard seconds < Double(time_t.max) else {
        return timespec(tv_sec: time_t.max, tv_nsec: 0)
    }
    return timespec(tv_sec: time_t(seconds), tv_nsec: Int((interval - seconds) * 1_000_000_000))
}
#endif

// Darwin has no `pthread_mutex_timedlock`, and Windows locks have no timed variant, so `lock(before:)` waits on a condition variable that `unlock()` broadcasts.
#if canImport(Darwin) || os(Windows)
private func deallocateTimedLockData(cond: ConditionVariablePointer, mutex: MutexPointer) {
#if !os(Windows)
    // Windows condition variables and SRWLocks do not need to be explicitly destroyed
    pthread_cond_destroy(cond)
    pthread_mutex_destroy(mutex)
#endif
    cond.deinitialize(count: 1)
    cond.deallocate()
    mutex.deinitialize(count: 1)
    mutex.deallocate()
}

#if os(Windows)
private func timedLock(mutex: MutexPointer, endTime: Date, using timeoutCond: ConditionVariablePointer, with timeoutMutex: MutexPointer) -> Bool {
    repeat {
        AcquireSRWLockExclusive(timeoutMutex)
        SleepConditionVariableSRW(timeoutCond, timeoutMutex, timeoutFrom(date: endTime), 0)
        ReleaseSRWLockExclusive(timeoutMutex)
        if TryAcquireSRWLockExclusive(mutex) != 0 {
            return true
        }
    } while timeoutFrom(date: endTime) != 0
    return false
}

private func timedLock(mutex: RecursiveMutexPointer, endTime: Date, using timeoutCond: ConditionVariablePointer, with timeoutMutex: MutexPointer) -> Bool {
    repeat {
        AcquireSRWLockExclusive(timeoutMutex)
        SleepConditionVariableSRW(timeoutCond, timeoutMutex, timeoutFrom(date: endTime), 0)
        ReleaseSRWLockExclusive(timeoutMutex)
        if TryEnterCriticalSection(mutex) {
            return true
        }
    } while timeoutFrom(date: endTime) != 0
    return false
}
#else
private func timedLock(mutex: MutexPointer, endTime: Date, using timeoutCond: ConditionVariablePointer, with timeoutMutex: MutexPointer) -> Bool {
    var timeSpec = timeSpecFrom(date: endTime)
    while var ts = timeSpec {
        let lockResult = pthread_mutex_lock(timeoutMutex)
        precondition(lockResult == 0)
        let waitResult = pthread_cond_timedwait(timeoutCond, timeoutMutex, &ts)
        precondition(waitResult == 0 || waitResult == ETIMEDOUT)
        let unlockResult = pthread_mutex_unlock(timeoutMutex)
        precondition(unlockResult == 0)

        if waitResult == ETIMEDOUT {
            return false
        }
        let tryResult = pthread_mutex_trylock(mutex)
        precondition(tryResult == 0 || tryResult == EBUSY)
        if tryResult == 0 {
            return true
        }
        // The wait did not time out, so wait some more
        timeSpec = timeSpecFrom(date: endTime)
    }
    return false
}
#endif
#endif

#endif // !FOUNDATION_FRAMEWORK

#endif // !hasFeature(Embedded)
