//
//  DB.swift
//  StatsKit
//
//  ZTAT-PATCH: Replaced upstream LevelDB (libleveldb.a + lldb.m + 60s fsync timer)
//  with a pure-Swift debounced JSON cache in ZtatBrand.statsCacheDirectory/stats-cache.json.
//  Flushes on a 15-second debounce and synchronously on flush()/terminate().
//

import Foundation
import ZtatCore

public struct HistoryStatistic: Codable {
    public var average: Double
    public var minimum: Double
    public var maximum: Double
    public var count: Int
    public var duration: TimeInterval

    public init(average: Double, minimum: Double, maximum: Double, count: Int, duration: TimeInterval) {
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
        self.count = count
        self.duration = duration
    }

    var isValid: Bool {
        self.average.isFinite && self.minimum.isFinite && self.maximum.isFinite && self.minimum <= self.maximum &&
        self.count >= 1 && self.duration.isFinite && self.duration > 0
    }

    mutating func merge(_ value: HistoryStatistic) {
        let duration = self.duration + value.duration
        self.average = self.average * (self.duration / duration) + value.average * (value.duration / duration)
        self.minimum = min(self.minimum, value.minimum)
        self.maximum = max(self.maximum, value.maximum)
        self.count += value.count
        self.duration = duration
    }
}

public struct HistoryBucket: Codable {
    public let timestamp: Date
    public var recordedAt: Date
    public var snapshot: Data
    public var values: [String: HistoryStatistic]

    public init(timestamp: Date, recordedAt: Date, snapshot: Data, values: [String: HistoryStatistic]) {
        self.timestamp = timestamp
        self.recordedAt = recordedAt
        self.snapshot = snapshot
        self.values = values
    }

    var isValid: Bool {
        self.timestamp.timeIntervalSince1970.isFinite && self.recordedAt.timeIntervalSince1970.isFinite &&
        !self.snapshot.isEmpty && self.values.values.allSatisfy { $0.isValid }
    }

    mutating func merge(_ bucket: HistoryBucket) {
        for (path, value) in bucket.values {
            if self.values[path] != nil {
                self.values[path]?.merge(value)
            } else {
                self.values[path] = value
            }
        }
        if bucket.recordedAt.timeIntervalSinceReferenceDate >= self.recordedAt.timeIntervalSinceReferenceDate {
            self.recordedAt = bucket.recordedAt
            self.snapshot = bucket.snapshot
        }
    }
}

public class DB {
    public static let shared = DB()

    private let queue = DispatchQueue(label: "dev.ztat.stats.db", qos: .utility)
    private let historyQueue = DispatchQueue(label: "dev.ztat.stats.db.history", qos: .utility)
    private let cacheFileURL: URL
    private let historyFileURL: URL
    private let debounceInterval: TimeInterval = 15
    private let historyDebounceInterval: TimeInterval = 60
    private let historyRetention: TimeInterval = 24 * 60 * 60

    private var serializedValues: [String: String] = [:]
    private var isDirty: Bool = false
    private var pendingSaveWorkItem: DispatchWorkItem? = nil

    private var historyBuckets: [String: [Date: HistoryBucket]] = [:]
    private var isHistoryDirty: Bool = false
    private var pendingHistorySaveWorkItem: DispatchWorkItem? = nil
    private var lastHistoryCleanup: Date? = nil

    public var _writeTS: [String: Date] = [:]
    public var writeTS: [String: Date] {
        get { self.queue.sync { self._writeTS } }
        set { self.queue.sync { self._writeTS = newValue } }
    }

    private var _values: [String: Codable] = [:]
    public var values: [String: Codable] {
        get { self.queue.sync { self._values } }
        set { self.queue.sync { self._values = newValue } }
    }

    init() {
        self.cacheFileURL = ZtatBrand.statsCacheDirectory.appendingPathComponent("stats-cache.json")
        self.historyFileURL = ZtatBrand.statsCacheDirectory.appendingPathComponent("stats-history.json")
        self.loadFromDisk()
        self.loadHistoryFromDisk()
    }

    deinit {
        self.pendingSaveWorkItem?.cancel()
        self.pendingHistorySaveWorkItem?.cancel()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: self.cacheFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        self.serializedValues = dict
    }

    private func loadHistoryFromDisk() {
        guard let data = try? Data(contentsOf: self.historyFileURL),
              let decoded = try? JSONDecoder().decode([String: [HistoryBucket]].self, from: data) else {
            return
        }
        let cutoff = self.historyMinute(Date().addingTimeInterval(-self.historyRetention))
        var loaded: [String: [Date: HistoryBucket]] = [:]
        for (key, list) in decoded {
            var map: [Date: HistoryBucket] = [:]
            for bucket in list where bucket.isValid && bucket.timestamp >= cutoff {
                map[bucket.timestamp] = bucket
            }
            if !map.isEmpty {
                loaded[key] = map
            }
        }
        self.historyBuckets = loaded
    }

    private func scheduleDebouncedHistoryPersistLocked() {
        self.isHistoryDirty = true
        self.pendingHistorySaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistHistoryLocked()
        }
        self.pendingHistorySaveWorkItem = item
        self.historyQueue.asyncAfter(deadline: .now() + self.historyDebounceInterval, execute: item)
    }

    private func persistHistoryLocked() {
        self.pendingHistorySaveWorkItem?.cancel()
        self.pendingHistorySaveWorkItem = nil
        guard self.isHistoryDirty else { return }
        self.isHistoryDirty = false

        let cutoff = self.historyMinute(Date().addingTimeInterval(-self.historyRetention))
        var payload: [String: [HistoryBucket]] = [:]
        for (key, map) in self.historyBuckets {
            let valid = map.values.filter { $0.isValid && $0.timestamp >= cutoff }
            if !valid.isEmpty {
                payload[key] = valid
            }
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: self.historyFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: self.historyFileURL, options: .atomic)
    }

    private func scheduleDebouncedPersistLocked() {
        self.isDirty = true
        self.pendingSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistLocked()
        }
        self.pendingSaveWorkItem = item
        self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
    }

    private func persistLocked() {
        self.pendingSaveWorkItem?.cancel()
        self.pendingSaveWorkItem = nil
        guard self.isDirty else { return }
        self.isDirty = false

        let snapshot = self.serializedValues
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: self.cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: self.cacheFileURL, options: .atomic)
    }

    public func setup<T: Codable>(_ type: T.Type, _ key: String) {
        self.queue.sync {
            guard let raw = self.serializedValues[key],
                  let data = raw.data(using: .utf8),
                  let value = try? JSONDecoder().decode(type, from: data) else {
                return
            }
            self._values[key] = value
        }
    }

    public func insert(key: String, value: Codable, force: Bool = false) {
        self.queue.async {
            self._values[key] = value
            let now = Date()
            if !force, let ts = self._writeTS[key], (now.timeIntervalSince1970 - ts.timeIntervalSince1970) < 30 {
                return
            }
            guard let blobData = try? JSONEncoder().encode(value),
                  let str = String(data: blobData, encoding: .utf8) else {
                return
            }
            self._writeTS[key] = now
            self.serializedValues[key] = str
            self.scheduleDebouncedPersistLocked()
        }
    }

    public func findOne<T: Decodable>(_ dynamicType: T.Type, key: String) -> T? {
        return self.queue.sync {
            if let existing = self._values[key] as? T {
                return existing
            }
            guard let raw = self.serializedValues[key],
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(dynamicType, from: data) else {
                return nil
            }
            return decoded
        }
    }

    public func delete(key: String) {
        self.queue.async {
            self._values.removeValue(forKey: key)
            self._writeTS.removeValue(forKey: key)
            if self.serializedValues.removeValue(forKey: key) != nil {
                self.scheduleDebouncedPersistLocked()
            }
        }
    }

    public func recordHistory<T: Encodable>(key: String, value: T, at: Date = Date(), duration: TimeInterval = 1) {
        guard !key.isEmpty, at.timeIntervalSince1970.isFinite, duration.isFinite, duration > 0 else { return }
        guard at.addingTimeInterval(60) > at else { return }
        guard let snapshot = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: snapshot, options: .fragmentsAllowed) else { return }
        var values: [String: Double] = [:]
        self.historyValues(object, path: "", values: &values)

        self.historyQueue.async {
            let cutoff = Date().addingTimeInterval(-self.historyRetention)
            var start = max(at.addingTimeInterval(-min(duration, self.historyRetention)), cutoff)
            guard start < at else { return }

            while start < at {
                let timestamp = self.historyMinute(start)
                let end = min(timestamp.addingTimeInterval(60), at)
                let sliceDuration = end.timeIntervalSince(start)

                let statistics = values.mapValues {
                    HistoryStatistic(average: $0, minimum: $0, maximum: $0, count: 1, duration: sliceDuration)
                }
                let bucket = HistoryBucket(timestamp: timestamp, recordedAt: at, snapshot: snapshot, values: statistics)
                if self.historyBuckets[key]?[timestamp] != nil {
                    self.historyBuckets[key]?[timestamp]?.merge(bucket)
                } else {
                    self.historyBuckets[key, default: [:]][timestamp] = bucket
                }
                start = end
            }

            self.cleanupHistoryIfNeeded()
            self.scheduleDebouncedHistoryPersistLocked()
        }
    }

    public func loadHistory(key: String, from: Date, to: Date, completion: @escaping ([HistoryBucket]) -> Void) {
        self.historyQueue.async {
            guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, from < to else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let start = self.historyMinute(max(from, Date().addingTimeInterval(-self.historyRetention)))
            let end = self.historyMinute(to).addingTimeInterval(to == self.historyMinute(to) ? 0 : 60)
            guard start < end else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let buckets = (self.historyBuckets[key] ?? [:])
                .values
                .filter {
                    $0.timestamp.timeIntervalSinceReferenceDate >= start.timeIntervalSinceReferenceDate &&
                    $0.timestamp < end
                }
                .sorted { $0.timestamp < $1.timestamp }
            DispatchQueue.main.async { completion(buckets) }
        }
    }

    public func flush() {
        self.queue.sync {
            self.persistLocked()
        }
        self.historyQueue.sync {
            self.persistHistoryLocked()
        }
    }

    public func terminate() {
        self.flush()
    }

    private func historyMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private func cleanupHistoryIfNeeded() {
        let now = Date()
        if let lastCleanup = self.lastHistoryCleanup, now.timeIntervalSince(lastCleanup) < 15 * 60 {
            return
        }
        self.lastHistoryCleanup = now
        let cutoff = self.historyMinute(now.addingTimeInterval(-self.historyRetention))
        for key in Array(self.historyBuckets.keys) {
            self.historyBuckets[key] = self.historyBuckets[key]?.filter {
                $0.key.timeIntervalSinceReferenceDate >= cutoff.timeIntervalSinceReferenceDate
            }
            if self.historyBuckets[key]?.isEmpty == true {
                self.historyBuckets.removeValue(forKey: key)
            }
        }
    }

    private func historyValues(_ object: Any, path: String, values: inout [String: Double]) {
        if let number = object as? NSNumber {
            if CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                values[path] = number.doubleValue
            }
        } else if let object = object as? [String: Any] {
            for (key, value) in object {
                self.historyValues(value, path: "\(path)/field:\(self.historyPath(key))", values: &values)
            }
        } else if let array = object as? [Any] {
            let identifiers = array.map { ($0 as? [String: Any]).flatMap { self.historyIdentity($0) } }
            var counts: [String: Int] = [:]
            identifiers.compactMap { $0 }.forEach { counts[$0, default: 0] += 1 }

            for (index, value) in array.enumerated() {
                if value is [String: Any] {
                    guard let identifier = identifiers[index], counts[identifier] == 1 else { continue }
                    self.historyValues(value, path: "\(path)/item:\(self.historyPath(identifier))", values: &values)
                } else {
                    self.historyValues(value, path: "\(path)/index:\(index)", values: &values)
                }
            }
        }
    }

    private func historyPath(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private func historyIdentity(_ object: [String: Any]) -> String? {
        for key in ["id", "uuid", "BSDName"] {
            if let value = object[key] as? String, !value.isEmpty {
                return "\(key):\(value)"
            }
        }
        if let ioClass = object["IOClass"] as? String, let model = object["model"] as? String, !ioClass.isEmpty, !model.isEmpty {
            return "IOClass:\(ioClass.utf8.count):\(ioClass)\(model)"
        }
        return nil
    }
}
