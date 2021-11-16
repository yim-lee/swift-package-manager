/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import PackageModel
@testable import PackageRegistry
import TSCBasic
import XCTest

final class FileChecksumStorageTests: XCTestCase {
    func testHappyCase() throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FileChecksumStorage(customFileSystem: mockFileSystem)

        // Add checksums for mona.LinkedList
        let package = PackageIdentity.plain("mona.LinkedList")
        try tsc_await { callback in storage.put(package: package, version: Version("1.0.0"), checksum: "checksum-1.0.0",
                                                observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent, callback: callback) }
        try tsc_await { callback in storage.put(package: package, version: Version("1.1.0"), checksum: "checksum-1.1.0",
                                                observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent, callback: callback) }
        // Checksum for another package
        let otherPackage = PackageIdentity.plain("other.LinkedList")
        try tsc_await { callback in storage.put(package: otherPackage, version: Version("1.0.0"), checksum: "other-checksum-1.0.0",
                                                observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent, callback: callback) }

        // A checksum file should have been created for each package
        XCTAssertTrue(mockFileSystem.exists(storage.directory.appending(component: package.checksumFilename)))
        XCTAssertTrue(mockFileSystem.exists(storage.directory.appending(component: otherPackage.checksumFilename)))

        // Checksums should be saved
        XCTAssertEqual("checksum-1.0.0", try tsc_await { callback in storage.get(package: package, version: Version("1.0.0"),
                                                                                 observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent,
                                                                                 callback: callback) })
        XCTAssertEqual("checksum-1.1.0", try tsc_await { callback in storage.get(package: package, version: Version("1.1.0"),
                                                                                 observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent,
                                                                                 callback: callback) })
        XCTAssertEqual("other-checksum-1.0.0", try tsc_await { callback in storage.get(package: otherPackage, version: Version("1.0.0"),
                                                                                       observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent,
                                                                                       callback: callback) })
    }

    func testChecksumNotFound() throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FileChecksumStorage(customFileSystem: mockFileSystem)

        let package = PackageIdentity.plain("mona.LinkedList")
        XCTAssertThrowsError(try tsc_await { callback in storage.get(package: package, version: Version("1.0.0"),
                                                                     observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent, callback: callback) }) { error in
            guard case ChecksumStorageError.notFound = error else {
                return XCTFail("Expected ChecksumStorageError.notFound, got \(error)")
            }
        }
    }

    func testVersionChecksumAlreadyExists() throws {
        let mockFileSystem = InMemoryFileSystem()
        let storage = FileChecksumStorage(customFileSystem: mockFileSystem)

        let package = PackageIdentity.plain("mona.LinkedList")
        // Write checksum for v1.0.0
        try tsc_await { callback in storage.put(package: package, version: Version("1.0.0"), checksum: "checksum-1.0.0",
                                                observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent, callback: callback) }

        // Writing for the same version again should fail
        XCTAssertThrowsError(try tsc_await { callback in storage.put(package: package, version: Version("1.0.0"), checksum: "checksum-1.0.0-2",
                                                                     observabilityScope: ObservabilitySystem.NOOP, callbackQueue: .sharedConcurrent, callback: callback) }) { error in
            guard case ChecksumStorageError.conflict = error else {
                return XCTFail("Expected ChecksumStorageError.conflict, got \(error)")
            }
        }
    }
}
