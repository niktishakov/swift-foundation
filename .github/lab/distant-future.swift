// Waits on locks with Date.distantFuture while another thread holds them.
import Foundation

let which = CommandLine.arguments.dropFirst().first ?? "condition"
print("case:", which)
switch which {
case "condition":
    let condition = NSCondition()
    nonisolated(unsafe) var done = false
    condition.lock()
    Thread {
        Thread.sleep(forTimeInterval: 0.5)
        condition.lock(); done = true; condition.signal(); condition.unlock()
    }.start()
    while !done { _ = condition.wait(until: Date.distantFuture) }
    condition.unlock()
case "conditionLock":
    let lock = NSConditionLock(condition: 0)
    lock.lock()
    Thread {
        Thread.sleep(forTimeInterval: 0.5)
        lock.unlock()
    }.start()
    Thread.sleep(forTimeInterval: 0.1)
    lock.lock()  // contended: waits with Date.distantFuture
    lock.unlock()
default:
    break
}
print("finished:", which)
