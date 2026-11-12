import Foundation

/// Represents a job managed by ``ExactCronScheduler``.
public struct ExactCronJob: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let expression: String
    public let schedule: CronSchedule
    public var isEnabled: Bool
    public var lastRunDate: Date?
    public var nextRunDate: Date?
    public var runCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        name: String,
        expression: String,
        schedule: CronSchedule,
        isEnabled: Bool = true,
        lastRunDate: Date? = nil,
        nextRunDate: Date? = nil,
        runCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.expression = expression
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.lastRunDate = lastRunDate
        self.nextRunDate = nextRunDate
        self.runCount = runCount
        self.lastError = lastError
    }
}

/// Exact cron scheduling engine that guarantees scheduled jobs fire at their exact defined time.
public actor ExactCronScheduler {
    public static let shared = ExactCronScheduler()

    public typealias JobAction = @Sendable () async throws -> Void

    private var jobs: [UUID: ExactCronJob] = [:]
    private var actions: [UUID: JobAction] = [:]
    private var lastFiredMinute: [UUID: Int] = [:]
    private var isRunning: Bool = false
    private var runnerTask: Task<Void, Never>?

    public init() {}

    deinit {
        runnerTask?.cancel()
    }

    /// Registers a new exact cron job.
    @discardableResult
    public func register(
        id: UUID = UUID(),
        name: String,
        expression: String,
        action: @escaping JobAction
    ) throws -> UUID {
        let schedule = try CronSchedule(expression: expression)
        let now = Date()
        let nextDate = schedule.nextDate(after: now)

        let job = ExactCronJob(
            id: id,
            name: name,
            expression: expression,
            schedule: schedule,
            isEnabled: true,
            lastRunDate: nil,
            nextRunDate: nextDate,
            runCount: 0,
            lastError: nil
        )

        jobs[id] = job
        actions[id] = action
        AppLog.info(.routine, "ExactCronScheduler: Registered job '\(name)' [\(id)] with cron '\(expression)', next run at \(nextDate?.description ?? "none")")

        if isRunning {
            restartRunnerLoop()
        }
        return id
    }

    /// Unregisters an existing cron job.
    public func unregister(id: UUID) {
        if let job = jobs.removeValue(forKey: id) {
            actions.removeValue(forKey: id)
            lastFiredMinute.removeValue(forKey: id)
            AppLog.info(.routine, "ExactCronScheduler: Unregistered job '\(job.name)' [\(id)]")
            if isRunning {
                restartRunnerLoop()
            }
        }
    }

    /// Enables or disables a registered job.
    public func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var job = jobs[id] else { return }
        job.isEnabled = enabled
        if enabled {
            job.nextRunDate = job.schedule.nextDate(after: Date())
        } else {
            job.nextRunDate = nil
        }
        jobs[id] = job
        if isRunning {
            restartRunnerLoop()
        }
    }

    /// Returns a snapshot of a job by ID.
    public func job(id: UUID) -> ExactCronJob? {
        jobs[id]
    }

    /// Returns snapshots of all registered jobs.
    public func allJobs() -> [ExactCronJob] {
        Array(jobs.values).sorted { $0.name < $1.name }
    }

    /// Computes the earliest next scheduled fire date across all enabled jobs.
    public func nextScheduledDate() -> Date? {
        jobs.values
            .filter { $0.isEnabled }
            .compactMap { $0.nextRunDate }
            .min()
    }

    /// Starts the scheduler background runner.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        AppLog.info(.routine, "ExactCronScheduler: Started exact cron runner.")
        restartRunnerLoop()
    }

    /// Stops the scheduler background runner.
    public func stop() {
        isRunning = false
        runnerTask?.cancel()
        runnerTask = nil
        AppLog.info(.routine, "ExactCronScheduler: Stopped exact cron runner.")
    }

    /// Manually fires a job immediately, updating its run count and last run date.
    @discardableResult
    public func triggerNow(id: UUID) async throws -> Date {
        guard var job = jobs[id], let action = actions[id] else {
            throw NSError(domain: "ExactCronScheduler", code: 404, userInfo: [NSLocalizedDescriptionKey: "Job \(id) not found"])
        }
        let firedAt = Date()
        do {
            try await action()
            job.lastError = nil
        } catch {
            job.lastError = error.localizedDescription
            AppLog.error(.routine, "ExactCronScheduler: Job '\(job.name)' execution error: \(error)")
        }
        job.lastRunDate = firedAt
        job.runCount += 1
        job.nextRunDate = job.schedule.nextDate(after: firedAt)
        jobs[id] = job
        return firedAt
    }

    /// Evaluates due jobs at the specified timestamp. Returns the number of jobs executed.
    @discardableResult
    public func evaluateDueJobs(at targetDate: Date = Date()) async -> Int {
        let currentMinute = Int(targetDate.timeIntervalSince1970) / 60
        var executedCount = 0

        for (id, var job) in jobs where job.isEnabled {
            let alreadyFiredThisMinute = (lastFiredMinute[id] == currentMinute)
            let isDue = job.schedule.matches(date: targetDate) || (job.nextRunDate != nil && targetDate >= job.nextRunDate!)

            if isDue && !alreadyFiredThisMinute {
                lastFiredMinute[id] = currentMinute
                if let action = actions[id] {
                    AppLog.info(.routine, "ExactCronScheduler: Executing '\(job.name)' at exact time \(targetDate)")
                    do {
                        try await action()
                        job.lastError = nil
                    } catch {
                        job.lastError = error.localizedDescription
                        AppLog.error(.routine, "ExactCronScheduler: Error executing '\(job.name)': \(error)")
                    }
                }
                job.lastRunDate = targetDate
                job.runCount += 1
                job.nextRunDate = job.schedule.nextDate(after: targetDate)
                jobs[id] = job
                executedCount += 1
            } else if job.nextRunDate != nil && targetDate > job.nextRunDate! {
                // If it passed without matching, advance nextRunDate to upcoming window
                job.nextRunDate = job.schedule.nextDate(after: targetDate)
                jobs[id] = job
            }
        }

        return executedCount
    }

    private func restartRunnerLoop() {
        runnerTask?.cancel()
        runnerTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                guard await self.isRunning else { break }
                guard let nextDate = await self.nextScheduledDate() else {
                    // No jobs scheduled or enabled; wait before re-checking
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }

                let now = Date()
                let delay = nextDate.timeIntervalSince(now)

                if delay > 0 {
                    let nanos = UInt64(delay * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: nanos)
                    } catch {
                        break // Cancelled
                    }
                }

                if !Task.isCancelled {
                    _ = await self.evaluateDueJobs(at: Date())
                }
            }
        }
    }
}
