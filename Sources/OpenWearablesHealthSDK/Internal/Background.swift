import Foundation
import UIKit
import HealthKit
import BackgroundTasks

extension OpenWearablesHealthSDK {

    // MARK: - Background delivery
    internal func startBackgroundDelivery() {
        observerQueriesLock.lock()
        defer { observerQueriesLock.unlock() }
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()

        // Paused types get no observer and no background delivery; `resumeTypes`
        // registers them again.
        let paused = pausedHKIdentifiers()
        let observableTypes = getQueryableTypes().filter { !paused.contains($0.identifier) }

        for type in observableTypes {
            registerObserver(for: type)
        }
        logMessage("Background observers registered for \(observableTypes.count) types")
    }

    /// Callers hold `observerQueriesLock`.
    internal func registerObserver(for type: HKSampleType) {
        let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
            guard let self = self else {
                completionHandler()
                return
            }

            if let error = error {
                print("Observer error for \(type.identifier): \(error.localizedDescription)")
                completionHandler()
                return
            }

            self.triggerCombinedSync()
            completionHandler()
        }
        healthStore.execute(observer)
        activeObserverQueries.append(observer)
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    internal func stopBackgroundDelivery() {
        observerQueriesLock.lock()
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()
        observerQueriesLock.unlock()
        
        let observableTypes = getQueryableTypes()
        
        for t in observableTypes {
            healthStore.disableBackgroundDelivery(for: t) { _, _ in }
        }
        logMessage("Background observers stopped")
    }

    // MARK: - BGTaskScheduler
    internal func scheduleAppRefresh() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(req)
            logMessage("Scheduled app refresh task")
        }
        catch {
            logMessage("scheduleAppRefresh error: \(error.localizedDescription)")
        }
    }

    internal func scheduleProcessing() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGProcessingTaskRequest(identifier: processTaskId)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(req)
            logMessage("Scheduled processing task")
        }
        catch {
            logMessage("scheduleProcessing error: \(error.localizedDescription)")
        }
    }

    internal func cancelAllBGTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            logMessage("Cancelled all background tasks")
        }
    }

    @available(iOS 13.0, *)
    internal func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            let group = DispatchGroup()
            group.enter()
            
            self?.collectAllData(fullExport: false, isBackground: true) {
                group.leave()
            }
            
            let result = group.wait(timeout: .now() + 20)
            if result == .timedOut {
                self?.logMessage("BGAppRefresh sync timed out")
            }
        }

        task.expirationHandler = {
            self.logMessage("BGAppRefresh task expired - cancelling in-flight uploads")
            self.cancelInFlightSyncUploads(reason: "backgroundExpiration")
            op.cancel()
        }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }

    @available(iOS 13.0, *)
    internal func handleProcessing(task: BGProcessingTask) {
        scheduleProcessing()
        
        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            let group = DispatchGroup()
            group.enter()
            
            self?.retryOutboxIfPossible()
            self?.collectAllData(fullExport: false, isBackground: true) {
                group.leave()
            }
            
            let result = group.wait(timeout: .now() + 25)
            if result == .timedOut {
                self?.logMessage("BGProcessing sync timed out")
            }
        }

        task.expirationHandler = {
            self.logMessage("BGProcessing task expired - cancelling in-flight uploads")
            self.cancelInFlightSyncUploads(reason: "backgroundExpiration")
            op.cancel()
        }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }
}
