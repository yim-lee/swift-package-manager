/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation
import XCTest

@testable import PackageCollections
import PackageModel
import SourceControl
import TSCBasic
import TSCUtility

final class PackageCollectionsTests: XCTestCase {
    func testBasicRegistration() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        try mockCollections.forEach { collection in
            _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
        }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list, mockCollections, "list count should match")
        }
    }

    func testAddDuplicates() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollection = makeMockCollections(count: 1).first!

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider([mockCollection])]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        _ = try tsc_await { callback in packageCollections.addCollection(mockCollection.source, order: nil, callback: callback) }
        _ = try tsc_await { callback in packageCollections.addCollection(mockCollection.source, order: nil, callback: callback) }
        _ = try tsc_await { callback in packageCollections.addCollection(mockCollection.source, order: nil, callback: callback) }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 1, "list count should match")
        }
    }

    func testAddUnsigned() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 3, signed: false)

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        // User trusted
        _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[0].source, order: nil, trustConfirmationProvider: { _, cb in cb(true) }, callback: callback) }
        // User untrusted
        XCTAssertThrowsError(
            try tsc_await { callback in
                packageCollections.addCollection(mockCollections[1].source, order: nil, trustConfirmationProvider: { _, cb in cb(false) }, callback: callback)
            }) { error in
            guard case PackageCollectionError.untrusted = error else {
                return XCTFail("Expected PackageCollectionError.untrusted")
            }
        }
        // User preference unknown
        XCTAssertThrowsError(
            try tsc_await { callback in packageCollections.addCollection(mockCollections[1].source, order: nil, trustConfirmationProvider: nil, callback: callback) }) { error in
            guard case PackageCollectionError.trustConfirmationRequired = error else {
                return XCTFail("Expected PackageCollectionError.trustConfirmationRequired")
            }
        }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 1, "list count should match")
        }
    }

    func testInvalidCollectionNotAdded() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollection = makeMockCollections(count: 1).first!

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider([])]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")

            let sources = try tsc_await { callback in storage.sources.list(callback: callback) }
            XCTAssertEqual(sources.count, 0, "sources should be empty")
        }

        // add fails because collection is not found
        guard case .failure = tsc_await({ callback in packageCollections.addCollection(mockCollection.source, order: nil, callback: callback) }) else {
            return XCTFail("expected error")
        }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list count should match")

            let sources = try tsc_await { callback in storage.sources.list(callback: callback) }
            XCTAssertEqual(sources.count, 0, "sources should be empty")
        }
    }

    func testCollectionPendingTrustConfirmIsKeptOnAdd() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollection = makeMockCollections(count: 1, signed: false).first!

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider([mockCollection])]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")

            let sources = try tsc_await { callback in storage.sources.list(callback: callback) }
            XCTAssertEqual(sources.count, 0, "sources should be empty")
        }

        guard case .failure = tsc_await({ callback in packageCollections.addCollection(mockCollection.source, order: nil, callback: callback) }) else {
            return XCTFail("expected error")
        }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list count should match")

            let sources = try tsc_await { callback in storage.sources.list(callback: callback) }
            XCTAssertEqual(sources.count, 1, "sources should match")
        }
    }

    func testDelete() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 10)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
            }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list, mockCollections, "list count should match")
        }

        do {
            _ = try tsc_await { callback in packageCollections.removeCollection(mockCollections.first!.source, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count - 1, "list count should match")
        }

        do {
            _ = try tsc_await { callback in packageCollections.removeCollection(mockCollections.first!.source, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count - 1, "list count should match")
        }

        do {
            _ = try tsc_await { callback in packageCollections.removeCollection(mockCollections[mockCollections.count - 1].source, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count - 2, "list count should match")
        }

        do {
            let unknownSource = makeMockSources(count: 1).first!
            _ = try tsc_await { callback in packageCollections.removeCollection(unknownSource, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count - 2, "list should be empty")
        }
    }

    func testDeleteFromBothStorages() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollection = makeMockCollections(count: 1).first!

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider([mockCollection])]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        _ = try tsc_await { callback in packageCollections.addCollection(mockCollection.source, order: nil, callback: callback) }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 1, "list count should match")
        }

        do {
            _ = try tsc_await { callback in packageCollections.removeCollection(mockCollection.source, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list count should match")

            // check if exists in storage
            XCTAssertThrowsError(try tsc_await { callback in storage.collections.get(identifier: mockCollection.identifier, callback: callback) }, "expected error")
        }
    }

    func testOrdering() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 10)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[0].source, order: 0, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[1].source, order: 1, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[2].source, order: 2, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[3].source, order: Int.min, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[4].source, order: Int.max, callback: callback) }

            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 5, "list count should match")

            let expectedOrder = [
                mockCollections[0].identifier: 0,
                mockCollections[1].identifier: 1,
                mockCollections[2].identifier: 2,
                mockCollections[3].identifier: 3,
                mockCollections[4].identifier: 4,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }

        // bump the order

        do {
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[5].source, order: 2, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[6].source, order: 2, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[7].source, order: 0, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[8].source, order: -1, callback: callback) }

            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 9, "list count should match")

            let expectedOrder = [
                mockCollections[0].identifier: 1,
                mockCollections[1].identifier: 2,
                mockCollections[2].identifier: 5,
                mockCollections[3].identifier: 6,
                mockCollections[4].identifier: 7,
                mockCollections[5].identifier: 4,
                mockCollections[6].identifier: 3,
                mockCollections[7].identifier: 0,
                mockCollections[8].identifier: 8,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }
    }

    func testReorder() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 3)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[0].source, order: 0, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[1].source, order: 1, callback: callback) }
            _ = try tsc_await { callback in packageCollections.addCollection(mockCollections[2].source, order: 2, callback: callback) }

            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 3, "list count should match")

            let expectedOrder = [
                mockCollections[0].identifier: 0,
                mockCollections[1].identifier: 1,
                mockCollections[2].identifier: 2,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }

        do {
            _ = try tsc_await { callback in packageCollections.moveCollection(mockCollections[2].source, to: -1, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }

            let expectedOrder = [
                mockCollections[0].identifier: 0,
                mockCollections[1].identifier: 1,
                mockCollections[2].identifier: 2,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }

        do {
            _ = try tsc_await { callback in packageCollections.moveCollection(mockCollections[2].source, to: Int.max, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }

            let expectedOrder = [
                mockCollections[0].identifier: 0,
                mockCollections[1].identifier: 1,
                mockCollections[2].identifier: 2,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }

        do {
            _ = try tsc_await { callback in packageCollections.moveCollection(mockCollections[2].source, to: 0, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }

            let expectedOrder = [
                mockCollections[0].identifier: 1,
                mockCollections[1].identifier: 2,
                mockCollections[2].identifier: 0,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }

        do {
            _ = try tsc_await { callback in packageCollections.moveCollection(mockCollections[2].source, to: 1, callback: callback) }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }

            let expectedOrder = [
                mockCollections[0].identifier: 0,
                mockCollections[1].identifier: 2,
                mockCollections[2].identifier: 1,
            ]

            list.enumerated().forEach { index, collection in
                let expectedOrder = expectedOrder[collection.identifier]!
                XCTAssertEqual(index, expectedOrder, "order should match")
            }
        }
    }

    func testUpdateTrust() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 1, signed: false)

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        // User preference unknown - collection not saved to storage
        _ = try? tsc_await { callback in packageCollections.addCollection(mockCollections.first!.source, order: nil, trustConfirmationProvider: nil, callback: callback) }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        var source = mockCollections.first!.source

        // Update to trust the source. It will trigger a collection refresh which will save collection to storage.
        source.isTrusted = true
        _ = try tsc_await { callback in packageCollections.updateCollection(source, callback: callback) }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 1, "list count should match")
        }

        // Update to untrust the source. It will trigger a collection refresh which will remove collection from storage.
        source.isTrusted = false
        XCTAssertThrowsError(try tsc_await { callback in packageCollections.updateCollection(source, callback: callback) }) { error in
            guard case PackageCollectionError.untrusted = error else {
                return XCTFail("Expected PackageCollectionError.untrusted")
            }
        }

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }
    }

    func testListPerformance() throws {
        #if ENABLE_COLLECTION_PERF_TESTS
        #else
        try XCTSkipIf(true)
        #endif

        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 1000)
        let mockPackage = mockCollections.last!.packages.last!
        let mockMetadata = makeMockPackageBasicMetadata()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([mockPackage.reference: mockMetadata])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        let sync = DispatchGroup()
        mockCollections.forEach { collection in
            sync.enter()
            packageCollections.addCollection(collection.source, order: nil) { _ in
                sync.leave()
            }
        }
        sync.wait()

        let start = Date()
        let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
        XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        let delta = Date().timeIntervalSince(start)
        XCTAssert(delta < 1.0, "should list quickly, took \(delta)")
    }

    func testPackageSearch() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        var mockCollections = makeMockCollections()

        let mockTargets = [UUID().uuidString, UUID().uuidString].map {
            PackageCollectionsModel.Target(name: $0, moduleName: $0)
        }

        let mockProducts = [PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: [mockTargets.first!]),
                            PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: mockTargets)]

        let mockVersion = PackageCollectionsModel.Package.Version(version: TSCUtility.Version(1, 0, 0),
                                                                  packageName: UUID().uuidString,
                                                                  targets: mockTargets,
                                                                  products: mockProducts,
                                                                  toolsVersion: .currentToolsVersion,
                                                                  minimumPlatformVersions: nil,
                                                                  verifiedCompatibility: nil,
                                                                  license: nil)

        let mockPackage = PackageCollectionsModel.Package(repository: .init(url: "https://packages.mock/\(UUID().uuidString)"),
                                                          summary: UUID().uuidString,
                                                          keywords: [UUID().uuidString, UUID().uuidString],
                                                          versions: [mockVersion],
                                                          watchersCount: nil,
                                                          readmeURL: nil,
                                                          license: nil,
                                                          authors: nil)

        let mockCollection = PackageCollectionsModel.Collection(source: .init(type: .json, url: URL(string: "https://feed.mock/\(UUID().uuidString)")!),
                                                                name: UUID().uuidString,
                                                                overview: UUID().uuidString,
                                                                keywords: [UUID().uuidString, UUID().uuidString],
                                                                packages: [mockPackage],
                                                                createdAt: Date(),
                                                                createdBy: nil,
                                                                isSigned: true)

        let mockCollection2 = PackageCollectionsModel.Collection(source: .init(type: .json, url: URL(string: "https://feed.mock/\(UUID().uuidString)")!),
                                                                 name: UUID().uuidString,
                                                                 overview: UUID().uuidString,
                                                                 keywords: [UUID().uuidString, UUID().uuidString],
                                                                 packages: [mockPackage],
                                                                 createdAt: Date(),
                                                                 createdBy: nil,
                                                                 isSigned: true)

        let expectedCollections = [mockCollection, mockCollection2]
        let expectedCollectionsIdentifiers = expectedCollections.map { $0.identifier }.sorted()

        mockCollections.append(contentsOf: expectedCollections)

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        try mockCollections.forEach { collection in
            _ = try tsc_await { callback in packageCollections.addCollection(collection.source, callback: callback) }
        }

        do {
            // search by package name
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockVersion.packageName, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "list count should match")
        }

        do {
            // search by package description/summary
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockPackage.summary!, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "list count should match")
        }

        do {
            // search by package keywords
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockPackage.keywords!.first!, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "list count should match")
        }

        do {
            // search by package repository url
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockPackage.repository.url, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // search by package repository url base name
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockPackage.repository.basename, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // search by product name
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockProducts.first!.name, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "list count should match")
        }

        do {
            // search by target name
            let searchResult = try tsc_await { callback in packageCollections.findPackages(mockTargets.first!.name, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.collections.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // empty search
            let searchResult = try tsc_await { callback in packageCollections.findPackages(UUID().uuidString, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 0, "list count should match")
        }
    }

    func testPackageSearchPerformance() throws {
        #if ENABLE_COLLECTION_PERF_TESTS
        #else
        try XCTSkipIf(true)
        #endif

        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 1000, maxPackages: 20)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        let sync = DispatchGroup()
        mockCollections.forEach { collection in
            sync.enter()
            packageCollections.addCollection(collection.source, order: nil) { _ in
                sync.leave()
            }
        }
        sync.wait()

        // search by package name
        let start = Date()
        let repoName = mockCollections.last!.packages.last!.repository.basename
        let searchResult = try tsc_await { callback in packageCollections.findPackages(repoName, callback: callback) }
        XCTAssert(searchResult.items.count > 0, "should get results")
        let delta = Date().timeIntervalSince(start)
        XCTAssert(delta < 1.0, "should search quickly, took \(delta)")
    }

    func testTargetsSearch() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        var mockCollections = makeMockCollections()

        let mockTargets = [UUID().uuidString, UUID().uuidString].map {
            PackageCollectionsModel.Target(name: $0, moduleName: $0)
        }

        let mockProducts = [PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: [mockTargets.first!]),
                            PackageCollectionsModel.Product(name: UUID().uuidString, type: .executable, targets: mockTargets)]

        let mockVersion = PackageCollectionsModel.Package.Version(version: TSCUtility.Version(1, 0, 0),
                                                                  packageName: UUID().uuidString,
                                                                  targets: mockTargets,
                                                                  products: mockProducts,
                                                                  toolsVersion: .currentToolsVersion,
                                                                  minimumPlatformVersions: nil,
                                                                  verifiedCompatibility: nil,
                                                                  license: nil)

        let mockPackage = PackageCollectionsModel.Package(repository: RepositorySpecifier(url: "https://packages.mock/\(UUID().uuidString)"),
                                                          summary: UUID().uuidString,
                                                          keywords: [UUID().uuidString, UUID().uuidString],
                                                          versions: [mockVersion],
                                                          watchersCount: nil,
                                                          readmeURL: nil,
                                                          license: nil,
                                                          authors: nil)

        let mockCollection = PackageCollectionsModel.Collection(source: .init(type: .json, url: URL(string: "https://feed.mock/\(UUID().uuidString)")!),
                                                                name: UUID().uuidString,
                                                                overview: UUID().uuidString,
                                                                keywords: [UUID().uuidString, UUID().uuidString],
                                                                packages: [mockPackage],
                                                                createdAt: Date(),
                                                                createdBy: nil,
                                                                isSigned: true)

        let mockCollection2 = PackageCollectionsModel.Collection(source: .init(type: .json, url: URL(string: "https://feed.mock/\(UUID().uuidString)")!),
                                                                 name: UUID().uuidString,
                                                                 overview: UUID().uuidString,
                                                                 keywords: [UUID().uuidString, UUID().uuidString],
                                                                 packages: [mockPackage],
                                                                 createdAt: Date(),
                                                                 createdBy: nil,
                                                                 isSigned: true)

        let expectedCollections = [mockCollection, mockCollection2]
        let expectedCollectionsIdentifiers = expectedCollections.map { $0.identifier }.sorted()

        mockCollections.append(contentsOf: expectedCollections)

        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        try mockCollections.forEach { collection in
            _ = try tsc_await { callback in packageCollections.addCollection(collection.source, callback: callback) }
        }

        do {
            // search by exact target name
            let searchResult = try tsc_await { callback in packageCollections.findTargets(mockTargets.first!.name, searchType: .exactMatch, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.packages.map { $0.repository }, [mockPackage.repository], "packages should match")
            XCTAssertEqual(searchResult.items.first?.packages.flatMap { $0.collections }.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // search by prefix target name
            let searchResult = try tsc_await { callback in packageCollections.findTargets(String(mockTargets.first!.name.prefix(mockTargets.first!.name.count - 1)), searchType: .prefix, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 1, "list count should match")
            XCTAssertEqual(searchResult.items.first?.packages.map { $0.repository }, [mockPackage.repository], "packages should match")
            XCTAssertEqual(searchResult.items.first?.packages.flatMap { $0.collections }.sorted(), expectedCollectionsIdentifiers, "collections should match")
        }

        do {
            // empty search
            let searchResult = try tsc_await { callback in packageCollections.findTargets(UUID().uuidString, searchType: .exactMatch, callback: callback) }
            XCTAssertEqual(searchResult.items.count, 0, "list count should match")
        }
    }

    func testTargetsSearchPerformance() throws {
        #if ENABLE_COLLECTION_PERF_TESTS
        #else
//        try XCTSkipIf(true)
        #endif

        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 1000)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        let sync = DispatchGroup()
        mockCollections.forEach { collection in
            sync.enter()
            packageCollections.addCollection(collection.source, order: nil) { _ in
                sync.leave()
            }
        }
        sync.wait()

        // search by target name
        let start = Date()
        let targetName = mockCollections.last!.packages.last!.versions.last!.targets.last!.name
        let searchResult = try tsc_await { callback in packageCollections.findTargets(targetName, searchType: .exactMatch, callback: callback) }
        XCTAssert(searchResult.items.count > 0, "should get results")
        let delta = Date().timeIntervalSince(start)
print("\(delta)")
        XCTAssert(delta < 1.0, "should search quickly, took \(delta)")
    }

    func testHappyRefresh() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        try mockCollections.forEach { collection in
            // save directly to storage to circumvent refresh on add
            _ = try tsc_await { callback in storage.sources.add(source: collection.source, order: nil, callback: callback) }
        }
        _ = try tsc_await { callback in packageCollections.refreshCollections(callback: callback) }

        let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
        XCTAssertEqual(list.count, mockCollections.count, "list count should match")
    }

    func testBrokenRefresh() throws {
        struct BrokenProvider: PackageCollectionProvider {
            let brokenSources: [PackageCollectionsModel.CollectionSource]
            let error: Error

            init(brokenSources: [PackageCollectionsModel.CollectionSource], error: Error) {
                self.brokenSources = brokenSources
                self.error = error
            }

            func get(_ source: PackageCollectionsModel.CollectionSource, callback: @escaping (Result<PackageCollectionsModel.Collection, Error>) -> Void) {
                if self.brokenSources.contains(source) {
                    callback(.failure(self.error))
                } else {
                    callback(.success(PackageCollectionsModel.Collection(source: source, name: "", overview: nil, keywords: nil, packages: [], createdAt: Date(), createdBy: nil, isSigned: true)))
                }
            }
        }

        struct MyError: Error, Equatable {}

        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let expectedError = MyError()
        let goodSources = [PackageCollectionsModel.CollectionSource(type: .json, url: URL(string: "https://feed-\(UUID().uuidString)")!),
                           PackageCollectionsModel.CollectionSource(type: .json, url: URL(string: "https://feed-\(UUID().uuidString)")!)]
        let brokenSources = [PackageCollectionsModel.CollectionSource(type: .json, url: URL(string: "https://feed-\(UUID().uuidString)")!),
                             PackageCollectionsModel.CollectionSource(type: .json, url: URL(string: "https://feed-\(UUID().uuidString)")!)]
        let provider = BrokenProvider(brokenSources: brokenSources, error: expectedError)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: provider]

        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        XCTAssertThrowsError(try tsc_await { callback in packageCollections.addCollection(brokenSources.first!, order: nil, callback: callback) }, "expected error", { error in
            XCTAssertEqual(error as? MyError, expectedError, "expected error to match")
        })

        // save directly to storage to circumvent refresh on add
        try goodSources.forEach { source in
            _ = try tsc_await { callback in storage.sources.add(source: source, order: nil, callback: callback) }
        }
        try brokenSources.forEach { source in
            _ = try tsc_await { callback in storage.sources.add(source: source, order: nil, callback: callback) }
        }
        _ = try tsc_await { callback in storage.sources.add(source: .init(type: .json, url: URL(string: "https://feed-\(UUID().uuidString)")!), order: nil, callback: callback) }

        XCTAssertThrowsError(try tsc_await { callback in packageCollections.refreshCollections(callback: callback) }, "expected error", { error in
            if let error = error as? MultipleErrors {
                XCTAssertEqual(error.errors.count, brokenSources.count, "expected error to match")
                error.errors.forEach { error in
                    XCTAssertEqual(error as? MyError, expectedError, "expected error to match")
                }
            } else {
                XCTFail("expected error to match")
            }
        })

        // test isolation - broken feeds does not impact good ones
        let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
        XCTAssertEqual(list.count, goodSources.count + 1, "list count should match")
    }

    func testRefreshOne() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 1)
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        try mockCollections.forEach { collection in
            // save directly to storage to circumvent refresh on add
            _ = try tsc_await { callback in storage.sources.add(source: collection.source, order: nil, callback: callback) }
        }
        _ = try tsc_await { callback in packageCollections.refreshCollection(mockCollections.first!.source, callback: callback) }

        let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
        XCTAssertEqual(list.count, mockCollections.count, "list count should match")
    }

    func testListTargets() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
            }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }

        let targetsList = try tsc_await { callback in packageCollections.listTargets(callback: callback) }
        let expectedTargets = Set(mockCollections.flatMap { $0.packages.flatMap { $0.versions.flatMap { $0.targets.map { $0.name } } } })
        XCTAssertEqual(Set(targetsList.map { $0.target.name }), expectedTargets, "targets should match")

        let targetsPackagesList = Set(targetsList.flatMap { $0.packages })
        let expectedPackages = Set(mockCollections.flatMap { $0.packages.filter { !$0.versions.filter { !expectedTargets.isDisjoint(with: $0.targets.map { $0.name }) }.isEmpty } }.map { $0.reference })
        XCTAssertEqual(targetsPackagesList.count, expectedPackages.count, "pacakges should match")

        let targetsCollectionsList = Set(targetsList.flatMap { $0.packages.flatMap { $0.collections } })
        let expectedCollections = Set(mockCollections.filter { !$0.packages.filter { expectedPackages.contains($0.reference) }.isEmpty }.map { $0.identifier })
        XCTAssertEqual(targetsCollectionsList, expectedCollections, "collections should match")
    }

    func testFetchMetadataHappy() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections()
        let mockPackage = mockCollections.last!.packages.last!
        let mockMetadata = makeMockPackageBasicMetadata()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([mockPackage.reference: mockMetadata])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
            }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }

        let metadata = try tsc_await { callback in packageCollections.getPackageMetadata(mockPackage.reference, callback: callback) }

        let expectedCollections = Set(mockCollections.filter { $0.packages.map { $0.reference }.contains(mockPackage.reference) }.map { $0.identifier })
        XCTAssertEqual(Set(metadata.collections), expectedCollections, "collections should match")

        let expectedMetadata = PackageCollections.mergedPackageMetadata(package: mockPackage, basicMetadata: mockMetadata)
        XCTAssertEqual(metadata.package, expectedMetadata, "package should match")
    }

    func testFetchMetadataInOrder() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 2)
        let mockPackage = mockCollections.last!.packages.first!
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
            }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }

        let metadata = try tsc_await { callback in packageCollections.getPackageMetadata(mockPackage.reference, callback: callback) }

        let expectedCollections = Set(mockCollections.filter { $0.packages.map { $0.reference }.contains(mockPackage.reference) }.map { $0.identifier })
        XCTAssertEqual(Set(metadata.collections), expectedCollections, "collections should match")

        let expectedMetadata = PackageCollections.mergedPackageMetadata(package: mockPackage, basicMetadata: nil)
        XCTAssertEqual(metadata.package, expectedMetadata, "package should match")
    }

    func testMergedPackageMetadata() {
        let packageId = UUID().uuidString

        let targets = (0 ..< Int.random(in: 1 ... 5)).map {
            PackageCollectionsModel.Target(name: "target-\($0)", moduleName: "target-\($0)")
        }
        let products = (0 ..< Int.random(in: 1 ... 3)).map {
            PackageCollectionsModel.Product(name: "product-\($0)", type: .executable, targets: targets)
        }

        let versions = (0 ... 3).map {
            PackageCollectionsModel.Package.Version(version: TSCUtility.Version($0, 0, 0),
                                                    packageName: "package-\(packageId)",
                                                    targets: targets,
                                                    products: products,
                                                    toolsVersion: .currentToolsVersion,
                                                    minimumPlatformVersions: [.init(platform: .macOS, version: .init("10.15"))],
                                                    verifiedCompatibility: [
                                                        .init(platform: .iOS, swiftVersion: SwiftLanguageVersion.knownSwiftLanguageVersions.randomElement()!),
                                                        .init(platform: .linux, swiftVersion: SwiftLanguageVersion.knownSwiftLanguageVersions.randomElement()!),
                                                    ],
                                                    license: PackageCollectionsModel.License(type: .Apache2_0, url: URL(string: "http://apache.license")!))
        }

        let mockPackage = PackageCollectionsModel.Package(repository: RepositorySpecifier(url: "https://package-\(packageId)"),
                                                          summary: "package \(packageId) description",
                                                          keywords: [UUID().uuidString],
                                                          versions: versions,
                                                          watchersCount: Int.random(in: 0 ... 50),
                                                          readmeURL: URL(string: "https://package-\(packageId)-readme")!,
                                                          license: PackageCollectionsModel.License(type: .Apache2_0, url: URL(string: "http://apache.license")!),
                                                          authors: (0 ..< Int.random(in: 1 ... 10)).map { .init(username: "\($0)", url: nil, service: nil) })

        let mockMetadata = PackageCollectionsModel.PackageBasicMetadata(summary: "\(mockPackage.summary!) 2",
                                                                        keywords: mockPackage.keywords.flatMap { $0.map { "\($0)-2" } },
                                                                        versions: mockPackage.versions.map { TSCUtility.Version($0.version.major, 1, 0) },
                                                                        watchersCount: mockPackage.watchersCount! + 1,
                                                                        readmeURL: URL(string: "\(mockPackage.readmeURL!.absoluteString)-2")!,
                                                                        license: PackageCollectionsModel.License(type: .Apache2_0, url: URL(string: "\(mockPackage.license!.url.absoluteString)-2")!),
                                                                        authors: mockPackage.authors.flatMap { $0.map { .init(username: "\($0.username + "2")", url: nil, service: nil) } },
                                                                        processedAt: Date())

        let metadata = PackageCollections.mergedPackageMetadata(package: mockPackage, basicMetadata: mockMetadata)

        XCTAssertEqual(metadata.reference, mockPackage.reference, "reference should match")
        XCTAssertEqual(metadata.repository, mockPackage.repository, "repository should match")
        XCTAssertEqual(metadata.summary, mockMetadata.summary, "summary should match")
        XCTAssertEqual(metadata.keywords, mockMetadata.keywords, "keywords should match")
        mockPackage.versions.forEach { version in
            let metadataVersion = metadata.versions.first(where: { $0.version == version.version })
            XCTAssertNotNil(metadataVersion)

            XCTAssertEqual(version.packageName, metadataVersion?.packageName, "packageName should match")
            XCTAssertEqual(version.targets, metadataVersion?.targets, "targets should match")
            XCTAssertEqual(version.products, metadataVersion?.products, "products should match")
            XCTAssertEqual(version.toolsVersion, metadataVersion?.toolsVersion, "toolsVersion should match")
            XCTAssertEqual(version.minimumPlatformVersions, metadataVersion?.minimumPlatformVersions, "minimumPlatformVersions should match")
            XCTAssertEqual(version.verifiedCompatibility, metadataVersion?.verifiedCompatibility, "verifiedCompatibility should match")
            XCTAssertEqual(version.license, metadataVersion?.license, "license should match")
        }
        XCTAssertEqual(metadata.latestVersion, metadata.versions.first, "versions should be sorted")
        XCTAssertEqual(metadata.latestVersion?.version, versions.last?.version, "latestVersion should match")
        XCTAssertEqual(metadata.watchersCount, mockMetadata.watchersCount, "watchersCount should match")
        XCTAssertEqual(metadata.readmeURL, mockMetadata.readmeURL, "readmeURL should match")
        XCTAssertEqual(metadata.license, mockMetadata.license, "license should match")
        XCTAssertEqual(metadata.authors, mockMetadata.authors, "authors should match")
    }

    func testFetchMetadataNotFoundInCollections() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockPackage = makeMockCollections().first!.packages.first!
        let mockMetadata = makeMockPackageBasicMetadata()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider([])]
        let metadataProvider = MockMetadataProvider([mockPackage.reference: mockMetadata])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        XCTAssertThrowsError(try tsc_await { callback in packageCollections.getPackageMetadata(mockPackage.reference, callback: callback) }, "expected error") { error in
            XCTAssert(error is NotFoundError)
        }
    }

    func testFetchMetadataNotFoundByProvider() throws {
        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections()
        let mockPackage = mockCollections.last!.packages.last!
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([:])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
            }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }

        let metadata = try tsc_await { callback in packageCollections.getPackageMetadata(mockPackage.reference, callback: callback) }

        let expectedCollections = Set(mockCollections.filter { $0.packages.map { $0.reference }.contains(mockPackage.reference) }.map { $0.identifier })
        XCTAssertEqual(Set(metadata.collections), expectedCollections, "collections should match")

        let expectedMetadata = PackageCollections.mergedPackageMetadata(package: mockPackage, basicMetadata: nil)
        XCTAssertEqual(metadata.package, expectedMetadata, "package should match")
    }

    func testFetchMetadataProviderError() throws {
        struct BrokenMetadataProvider: PackageMetadataProvider {
            var name: String = "BrokenMetadataProvider"

            func get(_ reference: PackageReference, callback: @escaping (Result<PackageCollectionsModel.PackageBasicMetadata, Error>) -> Void) {
                callback(.failure(TerribleThing()))
            }

            struct TerribleThing: Error {}
        }

        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections()
        let mockPackage = mockCollections.last!.packages.last!
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = BrokenMetadataProvider()
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        do {
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, 0, "list should be empty")
        }

        do {
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in packageCollections.addCollection(collection.source, order: nil, callback: callback) }
            }
            let list = try tsc_await { callback in packageCollections.listCollections(callback: callback) }
            XCTAssertEqual(list.count, mockCollections.count, "list count should match")
        }

        XCTAssertThrowsError(try tsc_await { callback in packageCollections.getPackageMetadata(mockPackage.reference, callback: callback) }, "expected error") { error in
            XCTAssert(error is BrokenMetadataProvider.TerribleThing)
        }
    }

    func testFetchMetadataPerformance() throws {
        #if ENABLE_COLLECTION_PERF_TESTS
        #else
        try XCTSkipIf(true)
        #endif

        let configuration = PackageCollections.Configuration()
        let storage = makeMockStorage()
        defer { XCTAssertNoThrow(try storage.close()) }

        let mockCollections = makeMockCollections(count: 1000)
        let mockPackage = mockCollections.last!.packages.last!
        let mockMetadata = makeMockPackageBasicMetadata()
        let collectionProviders = [PackageCollectionsModel.CollectionSourceType.json: MockCollectionsProvider(mockCollections)]
        let metadataProvider = MockMetadataProvider([mockPackage.reference: mockMetadata])
        let packageCollections = PackageCollections(configuration: configuration, storage: storage, collectionProviders: collectionProviders, metadataProvider: metadataProvider)

        let sync = DispatchGroup()
        mockCollections.forEach { collection in
            sync.enter()
            packageCollections.addCollection(collection.source, order: nil) { _ in
                sync.leave()
            }
        }
        sync.wait()

        let start = Date()
        let metadata = try tsc_await { callback in packageCollections.getPackageMetadata(mockPackage.reference, callback: callback) }
        XCTAssertNotNil(metadata)
        let delta = Date().timeIntervalSince(start)
        XCTAssert(delta < 1.0, "should fetch quickly, took \(delta)")
    }
}
