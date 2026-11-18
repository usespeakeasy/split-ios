//
//  HashedImpressionStorage.swift
//  Split
//
//  Created by Javier Avrudsky on 22/05/2024.
//  Copyright © 2024 Split. All rights reserved.
//

import Foundation

protocol HashedImpressionsStorage {
    func loadFromDb()
    func set(_ time: Int64, for hash: UInt32)
    func get(for hash: UInt32) -> Int64?
    func clear()
    func save()
}

class DefaultHashedImpressionsStorage: HashedImpressionsStorage, @unchecked Sendable {

    private let cache: LRUCache<UInt32, Int64>
    private let persistentStorage: PersistentHashedImpressionsStorage
    private let lock = NSLock()
    private var pendingTimes = [UInt32: Int64]()
    private var pendingCount = 0
    private let queueSize = ServiceConstants.maxHashedImpressionsQueueSize

    init(cache: LRUCache<UInt32, Int64>,
         persistentStorage: PersistentHashedImpressionsStorage) {

        self.cache = cache
        self.persistentStorage = persistentStorage
    }

    func loadFromDb() {
        let items = persistentStorage.getAll()
        var toDelete = [HashedImpression]()
        items.forEach { hashed in
            if !isExpired(hashed) {
                cache.set(hashed.time, for: hashed.impressionHash)
            } else {
                toDelete.append(hashed)
            }
        }
        persistentStorage.delete(toDelete)
    }

    func set(_ time: Int64, for hash: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        cache.set(time, for: hash)
        pendingTimes[hash] = time
        pendingCount += 1
        if pendingCount >= queueSize {
            savePendingTimes()
        }
    }

    func get(for hash: UInt32) -> Int64? {
        return cache.element(for: hash)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        cache.clear()
        pendingTimes.removeAll()
        pendingCount = 0
    }

    func save() {
        lock.lock()
        defer { lock.unlock() }
        savePendingTimes()
    }

    // Hold the lock through enqueueing so concurrent flushes reach Core Data in order.
    private func savePendingTimes() {
        guard !pendingTimes.isEmpty else {
            return
        }
        persistentStorage.update(pendingTimes.map { HashedImpression(impressionHash: $0.key,
                                                                      time: $0.value,
                                                                      createdAt: $0.value) })
        pendingTimes.removeAll(keepingCapacity: true)
        pendingCount = 0
        Logger.v("Hashed impressions persisted")
    }

    private func isExpired(_ impression: HashedImpression) -> Bool {
        return ((Date.nowMillis() - ServiceConstants.hashedImpressionsExpirationMs) > impression.createdAt)
    }
}
