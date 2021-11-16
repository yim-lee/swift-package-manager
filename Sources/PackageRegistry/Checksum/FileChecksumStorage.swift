/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import Foundation
import PackageModel
import TSCBasic
import TSCUtility

struct FileChecksumStorage: ChecksumStorage {
    let fileSystem: FileSystem
    let directory: AbsolutePath

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(customFileSystem: FileSystem? = nil, customDirectory: AbsolutePath? = nil) {
        self.fileSystem = customFileSystem ?? localFileSystem
        self.directory = customDirectory ?? self.fileSystem.dotSwiftPM.appending(component: "checksums")

        self.encoder = JSONEncoder.makeWithDefaults()
        self.decoder = JSONDecoder.makeWithDefaults()
    }

    func get(package: PackageIdentity,
             version: Version,
             observabilityScope: ObservabilityScope,
             callbackQueue: DispatchQueue,
             callback: @escaping (Result<String, Error>) -> Void)
    {
        let callback = makeAsync(callback, on: callbackQueue)

        do {
            let checksums = try self.withLock {
                try self.loadFromDisk(package: package)
            }

            guard let checksum = checksums[version] else {
                throw ChecksumStorageError.notFound
            }

            callback(.success(checksum))
        } catch {
            callback(.failure(error))
        }
    }

    func put(package: PackageIdentity,
             version: Version,
             checksum: String,
             observabilityScope: ObservabilityScope,
             callbackQueue: DispatchQueue,
             callback: @escaping (Result<Void, Error>) -> Void)
    {
        let callback = makeAsync(callback, on: callbackQueue)

        do {
            try self.withLock {
                var checksums = try self.loadFromDisk(package: package)

                if let existingChecksum = checksums[version] {
                    // Error if we try to write a different checksum
                    guard checksum == existingChecksum else {
                        throw ChecksumStorageError.conflict(given: checksum, existing: existingChecksum)
                    }
                    // Don't need to do anything if checksum is the same
                    return
                }

                checksums[version] = checksum
                try self.saveToDisk(package: package, checksums: checksums)
            }
            callback(.success(()))
        } catch {
            callback(.failure(error))
        }
    }

    private func loadFromDisk(package: PackageIdentity) throws -> [Version: String] {
        let path = self.directory.appending(component: package.checksumFilename)

        guard self.fileSystem.exists(path) else {
            return .init()
        }

        let buffer = try fileSystem.readFileContents(path).contents
        guard buffer.count > 0 else {
            return .init()
        }

        let container = try self.decoder.decode(StorageModel.Container.self, from: Data(buffer))
        return container.checksums
    }

    private func saveToDisk(package: PackageIdentity, checksums: [Version: String]) throws {
        if !self.fileSystem.exists(self.directory) {
            try self.fileSystem.createDirectory(self.directory, recursive: true)
        }

        let container = StorageModel.Container(checksums: checksums)
        let buffer = try encoder.encode(container)

        let path = self.directory.appending(component: package.checksumFilename)
        try self.fileSystem.writeFileContents(path, bytes: ByteString(buffer))
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        if !self.fileSystem.exists(self.directory) {
            try self.fileSystem.createDirectory(self.directory, recursive: true)
        }
        return try self.fileSystem.withLock(on: self.directory, type: .exclusive, body)
    }
}

private enum StorageModel {
    struct Container: Codable {
        let versionChecksums: [String: String]

        var checksums: [Version: String] {
            Dictionary(uniqueKeysWithValues: self.versionChecksums.map { version, checksum in
                (Version(stringLiteral: version), checksum)
            })
        }

        init(checksums: [Version: String]) {
            self.versionChecksums = Dictionary(uniqueKeysWithValues: checksums.map { version, checksum in
                (version.description, checksum)
            })
        }
    }
}

extension PackageIdentity {
    var checksumFilename: String {
        "\(self.description).json"
    }
}
