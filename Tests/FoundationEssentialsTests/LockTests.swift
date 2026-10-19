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

import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

@Suite("Locks")
private struct LockTests {
    @Test func name() {
        let lock = NSLock()
        #expect(lock.name == nil)
        lock.name = "lock"
        #expect(lock.name == "lock")

        let recursiveLock = NSRecursiveLock()
        recursiveLock.name = "recursiveLock"
        #expect(recursiveLock.name == "recursiveLock")

        let condition = NSCondition()
        condition.name = "condition"
        #expect(condition.name == "condition")
    }

    @Test func withLockReturnsValue() throws {
        struct TestError: Error {}
        let lock = NSLock()
        #expect(lock.withLock { 42 } == 42)
        #expect(throws: TestError.self) {
            try lock.withLock { throw TestError() }
        }
        // The lock must be free again after `body` throws
        #expect(lock.try())
        lock.unlock()
    }

#if _runtime(_multithreaded)
    @Test func tryFailsWhileLocked() {
        let lock = NSLock()
        lock.lock()
        let thread = TestThread {
            #expect(!lock.try())
        }
        thread.join()
        lock.unlock()
        #expect(lock.try())
        lock.unlock()
    }

    @Test func recursiveLockTryFromOwningThread() {
        let lock = NSRecursiveLock()
        lock.lock()
        #expect(lock.try())
        let thread = TestThread {
            #expect(!lock.try())
        }
        thread.join()
        lock.unlock()
        lock.unlock()
    }

    @Test(arguments: [false, true])
    func lockBefore(recursive: Bool) {
        let holdTime = 4.0
        let condition = NSCondition()
        let lock: any TimedLock = recursive ? NSRecursiveLock() : NSLock()

        func tryLock(waitTime: Double) -> Bool {
            let locked = lock.lock(before: Date(timeIntervalSinceNow: waitTime))
            if locked {
                lock.unlock()
            }
            return locked
        }

        // Protected by condition
        nonisolated(unsafe) var isLockTaken = false
        let thread = TestThread {
            lock.lock()

            // Wake up the main thread so it can try to take the lock that this thread holds
            condition.lock()
            isLockTaken = true
            condition.signal()
            condition.unlock()

            sleep(seconds: holdTime)
            lock.unlock()
        }
        condition.lock()
        while !isLockTaken {
            condition.wait()
        }
        condition.unlock()

        #expect(!tryLock(waitTime: 0))
        #expect(!tryLock(waitTime: -1))
        #expect(!tryLock(waitTime: 1))
        #expect(tryLock(waitTime: holdTime * 2))
        #expect(tryLock(waitTime: -1))
        thread.join()
    }

    @Test func threadsAndLocks() {
        let condition = NSCondition()
        let lock = NSLock()
        let threadCount = 10
        let endTime = Date(timeIntervalSinceNow: 2)
        // Protected by arrayLock
        nonisolated(unsafe) var threadsStarted = Array(repeating: false, count: threadCount)
        let arrayLock = NSLock()

        var threads: [TestThread] = []
        for index in 0..<threadCount {
            threads.append(TestThread {
                condition.lock()
                arrayLock.lock()
                threadsStarted[index] = true
                arrayLock.unlock()

                condition.wait()
                condition.unlock()
                for _ in 1...50 {
                    sleep(seconds: Double.random(in: 0...0.02))
                    if lock.lock(before: endTime) {
                        lock.unlock()
                    }
                }
                arrayLock.lock()
                threadsStarted[index] = false
                arrayLock.unlock()
            })
        }

        var startedCount = 0
        repeat {
            // Hold `condition` so that no thread can miss the broadcast between setting its flag and waiting
            condition.lock()
            arrayLock.lock()
            startedCount = threadsStarted.filter { $0 }.count
            arrayLock.unlock()
            if startedCount == threadCount {
                condition.broadcast()
            }
            condition.unlock()
        } while startedCount < threadCount

        for thread in threads {
            thread.join()
        }
        arrayLock.lock()
        #expect(threadsStarted.allSatisfy { !$0 })
        arrayLock.unlock()

        #expect(lock.try())
        lock.unlock()
    }

    @Test func recursiveLock() {
        // 10 threads together reduce the countdown value to zero in less than 30 seconds
        let threadCount = 10
        let countdownPerThread = 1000
        let endTime = Date(timeIntervalSinceNow: 30)

        // Protected by threadCompletedCondition
        nonisolated(unsafe) var completedThreadCount = 0
        // Protected by countdownValueLock
        nonisolated(unsafe) var countdownValue = threadCount * countdownPerThread

        let threadCompletedCondition = NSCondition()
        let countdownValueLock = NSRecursiveLock()

        var threads: [TestThread] = []
        for _ in 0..<threadCount {
            threads.append(TestThread {
                // The additions and subtractions decrease the countdown by exactly `countdownPerThread`
                for _ in 0..<countdownPerThread {
                    countdownValueLock.lock()
                    countdownValue -= 3
                    countdownValueLock.lock()
                    countdownValue += 4
                    countdownValueLock.unlock()
                    countdownValueLock.unlock()

                    countdownValueLock.lock()
                    countdownValue += 2
                    countdownValueLock.lock()
                    countdownValue -= 1
                    countdownValueLock.unlock()
                    countdownValue -= 3
                    countdownValueLock.unlock()

                    countdownValueLock.lock()
                    countdownValue += 1
                    countdownValueLock.unlock()

                    countdownValueLock.lock()
                    countdownValue -= 1
                    countdownValueLock.unlock()
                }

                threadCompletedCondition.lock()
                completedThreadCount += 1
                threadCompletedCondition.broadcast()
                threadCompletedCondition.unlock()
            })
        }

        threadCompletedCondition.lock()
        var isTimedOut = false
        while !isTimedOut && completedThreadCount < threadCount {
            isTimedOut = !threadCompletedCondition.wait(until: endTime)
        }
        #expect(completedThreadCount == threadCount, "Some threads did not finish")
        threadCompletedCondition.unlock()

        countdownValueLock.lock()
        #expect(countdownValue == 0, "Wrong countdown value means the lock did not protect it")
        countdownValueLock.unlock()

        for thread in threads {
            thread.join()
        }
    }

    @Test func withLock() {
        let lock = NSLock()
        // Protected by lock
        nonisolated(unsafe) var counter = 0
        let incrementsPerThread = 10_000
        let threadCount = 10

        let threads = (0..<threadCount).map { _ in
            TestThread {
                for _ in 0..<incrementsPerThread {
                    lock.withLock {
                        counter += 1
                    }
                }
            }
        }
        for thread in threads {
            thread.join()
        }

        #expect(counter == incrementsPerThread * threadCount)
    }

    @Test func conditionWaitTimesOut() {
        let condition = NSCondition()
        condition.lock()
        #expect(!condition.wait(until: Date(timeIntervalSinceNow: 0.1)))
        #expect(!condition.wait(until: Date(timeIntervalSinceNow: -1)))
        condition.unlock()
    }

    @Test func conditionWaitUntilDistantFuture() {
        let condition = NSCondition()
        // Protected by condition
        nonisolated(unsafe) var isSignaled = false
        condition.lock()
        let thread = TestThread {
            condition.lock()
            isSignaled = true
            condition.signal()
            condition.unlock()
        }
        while !isSignaled {
            #expect(condition.wait(until: Date.distantFuture))
        }
        condition.unlock()
        thread.join()
    }

    @Test func conditionLockRelocksOnSameThread() {
        let lock = NSConditionLock()
        for _ in 0..<3 {
            #expect(lock.lock(before: Date(timeIntervalSinceNow: 1)))
            lock.unlock()
        }
        #expect(lock.try())
        #expect(!lock.try())
        lock.unlock()
    }

    @Test func conditionLockCondition() {
        let lock = NSConditionLock(condition: 1)
        #expect(lock.condition == 1)
        #expect(!lock.tryLock(whenCondition: 2))
        #expect(!lock.lock(whenCondition: 2, before: Date(timeIntervalSinceNow: 0.1)))
        #expect(lock.tryLock(whenCondition: 1))
        lock.unlock(withCondition: 2)
        #expect(lock.condition == 2)
        #expect(lock.tryLock(whenCondition: 2))
        lock.unlock()
        #expect(lock.condition == 2)
    }

    @Test func conditionLockProducerConsumer() {
        let empty = 0
        let full = 1
        let itemCount = 100
        let lock = NSConditionLock(condition: empty)
        // Protected by lock
        nonisolated(unsafe) var buffer: Int? = nil
        nonisolated(unsafe) var received: [Int] = []

        let consumer = TestThread {
            for _ in 0..<itemCount {
                lock.lock(whenCondition: full)
                if let item = buffer {
                    received.append(item)
                }
                buffer = nil
                lock.unlock(withCondition: empty)
            }
        }
        for item in 0..<itemCount {
            lock.lock(whenCondition: empty)
            buffer = item
            lock.unlock(withCondition: full)
        }
        consumer.join()

        #expect(received == Array(0..<itemCount))
        #expect(lock.condition == empty)
    }
#endif
}

#if _runtime(_multithreaded)
private protocol TimedLock: NSLocking, Sendable {
    func lock(before limit: Date) -> Bool
}

extension NSLock: TimedLock {}
extension NSRecursiveLock: TimedLock {}

private func sleep(seconds: Double) {
#if os(Windows)
    Sleep(DWORD(seconds * 1000))
#else
    usleep(useconds_t(seconds * 1_000_000))
#endif
}

/// A thread that starts at once and runs `body`.
private final class TestThread {
    private final class Context {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }
    }

    private static func run(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<Context>.fromOpaque(context).takeRetainedValue().body()
    }

#if os(Windows)
    private let handle: HANDLE?
#elseif canImport(Darwin)
    private let thread: pthread_t?
#else
    private let thread: pthread_t
#endif

    init(_ body: @escaping @Sendable () -> Void) {
        let context = Unmanaged.passRetained(Context(body)).toOpaque()
#if os(Windows)
        handle = CreateThread(nil, 0, { context in
            TestThread.run(context)
            return 0
        }, context, 0, nil)
        precondition(handle != nil, "Could not create a thread")
#else
#if canImport(Darwin)
        var thread: pthread_t? = nil
#else
        var thread = pthread_t()
#endif
        let result = pthread_create(&thread, nil, { context in
            TestThread.run(context)
            return nil
        }, context)
        precondition(result == 0, "Could not create a thread")
        self.thread = thread
#endif
    }

    func join() {
#if os(Windows)
        WaitForSingleObject(handle, INFINITE)
        CloseHandle(handle)
#elseif canImport(Darwin)
        guard let thread else { return }
        pthread_join(thread, nil)
#else
        pthread_join(thread, nil)
#endif
    }
}
#endif
