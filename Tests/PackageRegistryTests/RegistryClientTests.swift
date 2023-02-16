//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageFingerprint
import PackageLoading
import PackageModel
@testable import PackageRegistry
import SPMTestSupport
import TSCBasic
import XCTest

import struct TSCUtility.Version

final class RegistryClientTests: XCTestCase {
    func testGetPackageMetadata() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let releasesURL = URL(string: "\(registryURL)/\(scope)/\(name)")!

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, releasesURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "releases": {
                        "1.1.1": {
                            "url": "https://packages.example.com/mona/LinkedList/1.1.1"
                        },
                        "1.1.0": {
                            "url": "https://packages.example.com/mona/LinkedList/1.1.0",
                            "problem": {
                                "status": 410,
                                "title": "Gone",
                                "detail": "this release was removed from the registry"
                            }
                        },
                        "1.0.0": {
                            "url": "https://packages.example.com/mona/LinkedList/1.0.0"
                        }
                    }
                }
                """#.data(using: .utf8)!

                let links = """
                <https://github.com/mona/LinkedList>; rel="canonical",
                <ssh://git@github.com:mona/LinkedList.git>; rel="alternate",
                <git@github.com:mona/LinkedList.git>; rel="alternate",
                <https://gitlab.com/mona/LinkedList>; rel="alternate"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let metadata = try registryClient.getPackageMetadata(package: identity)
        XCTAssertEqual(metadata.versions, ["1.1.1", "1.0.0"])
        XCTAssertEqual(metadata.alternateLocations!, [
            URL(string: "https://github.com/mona/LinkedList"),
            URL(string: "ssh://git@github.com:mona/LinkedList.git"),
            URL(string: "git@github.com:mona/LinkedList.git"),
            URL(string: "https://gitlab.com/mona/LinkedList"),
        ])
    }

    func testGetPackageMetadata_ServerError() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let releasesURL = URL(string: "\(registryURL)/\(scope)/\(name)")!

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: releasesURL,
            errorCode: Int.random(in: 400 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        XCTAssertThrowsError(try registryClient.getPackageMetadata(package: identity)) { error in
            guard case RegistryError
                .failedRetrievingReleases(
                    RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testAvailableManifests() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let manifestURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)/Package.swift")!

        let defaultManifest = """
        // swift-tools-version:5.5
        import PackageDescription

        let package = Package(
            name: "LinkedList",
            products: [
                .library(name: "LinkedList", targets: ["LinkedList"])
            ],
            targets: [
                .target(name: "LinkedList"),
                .testTarget(name: "LinkedListTests", dependencies: ["LinkedList"]),
            ],
            swiftLanguageVersions: [.v4, .v5]
        )
        """

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let defaultManifestData = defaultManifest.data(using: .utf8)!

                let links = """
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4>; rel="alternate"; filename="Package@swift-4.swift"; swift-tools-version="4.0",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=4.2>; rel="alternate"; filename="Package@swift-4.2.swift"; swift-tools-version="4.2",
                <http://packages.example.com/mona/LinkedList/1.1.1/Package.swift?swift-version=5.3>; rel="alternate"; filename="Package@swift-5.3.swift"; swift-tools-version="5.3"
                """

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(defaultManifestData.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Link", value: links),
                    ]),
                    body: defaultManifestData
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let availableManifests = try registryClient.getAvailableManifests(
            package: identity,
            version: version
        )

        XCTAssertEqual(availableManifests["Package.swift"]?.toolsVersion, .v5_5)
        XCTAssertEqual(availableManifests["Package.swift"]?.content, defaultManifest)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.toolsVersion, .v4)
        XCTAssertEqual(availableManifests["Package@swift-4.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.toolsVersion, .v4_2)
        XCTAssertEqual(availableManifests["Package@swift-4.2.swift"]?.content, .none)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.toolsVersion, .v5_3)
        XCTAssertEqual(availableManifests["Package@swift-5.3.swift"]?.content, .none)
    }

    func testAvailableManifests_ServerError() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let manifestURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)/Package.swift")!

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: manifestURL,
            errorCode: Int.random(in: 400 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        XCTAssertThrowsError(try registryClient.getAvailableManifests(package: identity, version: version)) { error in
            guard case RegistryError
                .failedRetrievingManifest(
                    RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testGetManifestContent() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let manifestURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)/Package.swift")!

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = """
                // swift-tools-version:\(toolsVersion)

                import PackageDescription

                let package = Package()
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)

        do {
            let manifest = try registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .current)
        }

        do {
            let manifest = try registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v5_3)
        }

        do {
            let manifest = try registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v4
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v4)
        }
    }
    
    func testGetManifestContent_optionalContentVersion() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let manifestURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)/Package.swift")!

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            let toolsVersion = components.queryItems?.first { $0.name == "swift-version" }
                .flatMap { ToolsVersion(string: $0.value!) } ?? ToolsVersion.current
            // remove query
            components.query = nil
            let urlWithoutQuery = components.url
            switch (request.method, urlWithoutQuery) {
            case (.get, manifestURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+swift")

                let data = """
                // swift-tools-version:\(toolsVersion)

                import PackageDescription

                let package = Package()
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "text/x-swift"),
                        // Omit `Content-Version` header
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)

        do {
            let manifest = try registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: nil
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .current)
        }

        do {
            let manifest = try registryClient.getManifestContent(
                package: identity,
                version: version,
                customToolsVersion: .v5_3
            )
            let parsedToolsVersion = try ToolsVersionParser.parse(utf8String: manifest)
            XCTAssertEqual(parsedToolsVersion, .v5_3)
        }
    }

    func testGetManifestContent_ServerError() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let manifestURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)/Package.swift")!

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: manifestURL,
            errorCode: Int.random(in: 400 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        XCTAssertThrowsError(
            try registryClient
                .getManifestContent(package: identity, version: version, customToolsVersion: nil)
        ) { error in
            guard case RegistryError
                .failedRetrievingManifest(
                    RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testFetchSourceArchiveChecksum() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let metadataURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                    "id": "mona.LinkedList",
                    "version": "1.1.1",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "description": "One thing links to another."
                    }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage()
        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage
        )

        let checksumResponse = try registryClient.fetchSourceArchiveChecksum(package: identity, version: version)
        XCTAssertEqual(checksum, checksumResponse)

        // Checksum should have been saved to storage
        let fingerprint = try tsc_await { callback in
            fingerprintStorage.get(
                package: identity,
                version: version,
                kind: .registry,
                observabilityScope: ObservabilitySystem
                    .NOOP,
                callbackQueue: .sharedConcurrent,
                callback: callback
            )
        }
        XCTAssertEqual(registryURL, fingerprint.origin.url?.absoluteString)
        XCTAssertEqual(checksum, fingerprint.value)
    }

    func testFetchSourceArchiveChecksum_storageConflict() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let metadataURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                    "id": "mona.LinkedList",
                    "version": "1.1.1",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "description": "One thing links to another."
                    }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [.registry: Fingerprint(
                    origin: .registry(URL(string: registryURL)!),
                    value: "non-matching checksum"
                )],
            ],
        ])
        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict
        ) // intended for this test; don't change

        XCTAssertThrowsError(
            try registryClient
                .fetchSourceArchiveChecksum(package: identity, version: version)
        ) { error in
            guard case RegistryError.checksumChanged = error else {
                return XCTFail("Expected RegistryError.checksumChanged, got \(error)")
            }
        }
    }

    func testFetchSourceArchiveChecksum_storageConflict_fingerprintChecking_warn() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let metadataURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!
        let checksum = "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                    "id": "mona.LinkedList",
                    "version": "1.1.1",
                    "resources": [
                        {
                            "name": "source-archive",
                            "type": "application/zip",
                            "checksum": "\(checksum)"
                        }
                    ],
                    "metadata": {
                        "description": "One thing links to another."
                    }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let storedChecksum = "non-matching checksum"
        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [.registry: Fingerprint(origin: .registry(URL(string: registryURL)!), value: storedChecksum)],
            ],
        ])
        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .warn
        ) // intended for this test; don't change

        let observability = ObservabilitySystem.makeForTesting()

        // The checksum differs from that in storage, but error is not thrown
        // because fingerprintCheckingMode=.warn
        let checksumResponse = try registryClient.fetchSourceArchiveChecksum(
            package: identity,
            version: version,
            observabilityScope: observability.topScope
        )
        XCTAssertEqual(checksum, checksumResponse)

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("does not match previously recorded value"), severity: .warning)
        }

        // Storage should NOT be updated
        let fingerprint = try tsc_await { callback in
            fingerprintStorage.get(
                package: identity,
                version: version,
                kind: .registry,
                observabilityScope: ObservabilitySystem
                    .NOOP,
                callbackQueue: .sharedConcurrent,
                callback: callback
            )
        }
        XCTAssertEqual(registryURL, fingerprint.origin.url?.absoluteString)
        XCTAssertEqual(storedChecksum, fingerprint.value)
    }

    func testFetchSourceArchiveChecksum_ServerError() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let metadataURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: metadataURL,
            errorCode: Int.random(in: 400 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage()
        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            fingerprintStorage: fingerprintStorage
        )

        XCTAssertThrowsError(
            try registryClient
                .fetchSourceArchiveChecksum(package: identity, version: version)
        ) { error in
            guard case RegistryError
                .failedRetrievingReleaseChecksum(
                    RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testDownloadSourceArchive_matchingChecksumInStorage() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let downloadURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version).zip")!

        let checksumAlgorithm: HashAlgorithm = SHA256()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [.registry: Fingerprint(origin: .registry(URL(string: registryURL)!), value: checksum)],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            }
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath(path: "/LinkedList-1.1.1")

        try registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path,
            checksumAlgorithm: checksumAlgorithm
        )

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents, ["Package.swift"])
    }

    func testDownloadSourceArchive_nonMatchingChecksumInStorage() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let downloadURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version).zip")!

        let checksumAlgorithm: HashAlgorithm = SHA256()

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [.registry: Fingerprint(
                    origin: .registry(URL(string: registryURL)!),
                    value: "non-matching checksum"
                )],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict, // intended for this test; don't change
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            }
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath(path: "/LinkedList-1.1.1")

        XCTAssertThrowsError(
            try registryClient.downloadSourceArchive(
                package: identity,
                version: version,
                fileSystem: fileSystem,
                destinationPath: path,
                checksumAlgorithm: checksumAlgorithm
            )
        ) { error in
            guard case RegistryError.invalidChecksum = error else {
                return XCTFail("Expected RegistryError.invalidChecksum, got \(error)")
            }
        }

        // download did not succeed so directory does not exist
        XCTAssertFalse(fileSystem.exists(path))
    }

    func testDownloadSourceArchive_nonMatchingChecksumInStorage_fingerprintChecking_warn() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let downloadURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version).zip")!

        let checksumAlgorithm: HashAlgorithm = SHA256()

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [.registry: Fingerprint(
                    origin: .registry(URL(string: registryURL)!),
                    value: "non-matching checksum"
                )],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .warn, // intended for this test; don't change
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            }
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath(path: "/LinkedList-1.1.1")
        let observability = ObservabilitySystem.makeForTesting()

        // The checksum differs from that in storage, but error is not thrown
        // because fingerprintCheckingMode=.warn
        try registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path,
            checksumAlgorithm: checksumAlgorithm,
            observabilityScope: observability.topScope
        )

        // But there should be a warning
        testDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: .contains("does not match previously recorded value"), severity: .warning)
        }

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents, ["Package.swift"])
    }

    func testDownloadSourceArchive_checksumNotInStorage() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let downloadURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version).zip")!
        let metadataURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!

        let checksumAlgorithm: HashAlgorithm = SHA256()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        .init(name: "Content-Version", value: "1"),
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            // `downloadSourceArchive` calls this API to fetch checksum
            case (.generic, .get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                  "id": "mona.LinkedList",
                  "version": "1.1.1",
                  "resources": [
                    {
                      "name": "source-archive",
                      "type": "application/zip",
                      "checksum": "\(checksum)"
                    }
                  ],
                  "metadata": {
                    "description": "One thing links to another."
                  }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage()
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            }
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath(path: "/LinkedList-1.1.1")

        try registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path,
            checksumAlgorithm: checksumAlgorithm
        )

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents, ["Package.swift"])

        // Expected checksum is not found in storage so the metadata API will be called
        let fingerprint = try tsc_await { callback in
            fingerprintStorage.get(
                package: identity,
                version: version,
                kind: .registry,
                observabilityScope: ObservabilitySystem
                    .NOOP,
                callbackQueue: .sharedConcurrent,
                callback: callback
            )
        }
        XCTAssertEqual(registryURL, fingerprint.origin.url?.absoluteString)
        XCTAssertEqual(checksum, fingerprint.value)
    }
    
    func testDownloadSourceArchive_optionalContentVersion() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let downloadURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version).zip")!
        let metadataURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!

        let checksumAlgorithm: HashAlgorithm = SHA256()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.kind, request.method, request.url) {
            case (.download(let fileSystem, let path), .get, downloadURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+zip")

                let data = Data(emptyZipFile.contents)
                try! fileSystem.writeFileContents(path, data: data)

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/zip"),
                        // Omit `Content-Version` header
                        .init(name: "Content-Disposition", value: #"attachment; filename="LinkedList-1.1.1.zip""#),
                        .init(
                            name: "Digest",
                            value: "sha-256=bc6c9a5d2f2226cfa1ef4fad8344b10e1cc2e82960f468f70d9ed696d26b3283"
                        ),
                    ]),
                    body: nil
                )))
            // `downloadSourceArchive` calls this API to fetch checksum
            case (.generic, .get, metadataURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = """
                {
                  "id": "mona.LinkedList",
                  "version": "1.1.1",
                  "resources": [
                    {
                      "name": "source-archive",
                      "type": "application/zip",
                      "checksum": "\(checksum)"
                    }
                  ],
                  "metadata": {
                    "description": "One thing links to another."
                  }
                }
                """.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage()
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            }
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath(path: "/LinkedList-1.1.1")

        try registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path,
            checksumAlgorithm: checksumAlgorithm
        )

        let contents = try fileSystem.getDirectoryContents(path)
        XCTAssertEqual(contents, ["Package.swift"])
    }

    func testDownloadSourceArchive_ServerError() throws {
        let registryURL = "https://packages.example.com"
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let downloadURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version).zip")!

        let checksumAlgorithm: HashAlgorithm = SHA256()
        let checksum = checksumAlgorithm.hash(emptyZipFile).hexadecimalRepresentation

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: downloadURL,
            errorCode: Int.random(in: 400 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let fingerprintStorage = MockPackageFingerprintStorage([
            identity: [
                version: [.registry: Fingerprint(origin: .registry(URL(string: registryURL)!), value: checksum)],
            ],
        ])
        let registryClient = RegistryClient(
            configuration: configuration,
            fingerprintStorage: fingerprintStorage,
            fingerprintCheckingMode: .strict,
            customHTTPClient: httpClient,
            customArchiverProvider: { fileSystem in
                MockArchiver(handler: { _, from, to, callback in
                    let data = try fileSystem.readFileContents(from)
                    XCTAssertEqual(data, emptyZipFile)

                    let packagePath = to.appending(component: "package")
                    try fileSystem.createDirectory(packagePath, recursive: true)
                    try fileSystem.writeFileContents(packagePath.appending(component: "Package.swift"), string: "")
                    callback(.success(()))
                })
            }
        )

        let fileSystem = InMemoryFileSystem()
        let path = AbsolutePath(path: "/LinkedList-1.1.1")

        XCTAssertThrowsError(try registryClient.downloadSourceArchive(
            package: identity,
            version: version,
            fileSystem: fileSystem,
            destinationPath: path,
            checksumAlgorithm: checksumAlgorithm
        )) { error in
            guard case RegistryError
                .failedDownloadingSourceArchive(
                    RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testLookupIdentities() throws {
        let registryURL = "https://packages.example.com"
        let packageURL = URL(string: "https://example.com/mona/LinkedList")!
        let identifiersURL = URL(string: "\(registryURL)/identifiers?url=\(packageURL.absoluteString)")!

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "identifiers": [
                      "mona.LinkedList"
                    ]
                }
                """#.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let identities = try registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([PackageIdentity.plain("mona.LinkedList")], identities)
    }

    func testLookupIdentities404() throws {
        let registryURL = "https://packages.example.com"
        let packageURL = URL(string: "https://example.com/mona/LinkedList")!
        let identifiersURL = URL(string: "\(registryURL)/identifiers?url=\(packageURL.absoluteString)")!

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")
                completion(.success(.notFound()))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        let identities = try registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([], identities)
    }

    func testLookupIdentities_ServerError() throws {
        let registryURL = "https://packages.example.com"
        let packageURL = URL(string: "https://example.com/mona/LinkedList")!
        let identifiersURL = URL(string: "\(registryURL)/identifiers?url=\(packageURL.absoluteString)")!

        let serverErrorHandler = ServerErrorHandler(
            method: .get,
            url: identifiersURL,
            errorCode: Int.random(in: 405 ..< 500),
            errorDescription: UUID().uuidString
        )

        let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: URL(string: registryURL)!)

        let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
        XCTAssertThrowsError(try registryClient.lookupIdentities(scmURL: packageURL)) { error in
            guard case RegistryError
                .failedIdentityLookup(
                    RegistryError
                        .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                ) = error
            else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRequestAuthorization_token() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let packageURL = URL(string: "https://example.com/mona/LinkedList")!
        let identifiersURL = URL(string: "\(registryURL)/identifiers?url=\(packageURL.absoluteString)")!

        let token = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(request.headers.get("Authorization").first, "Bearer \(token)")
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "identifiers": [
                      "mona.LinkedList"
                    ]
                }
                """#.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .token)

        let authorizationProvider = TestProvider(map: [registryURL.host!: ("token", token)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        let identities = try registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([PackageIdentity.plain("mona.LinkedList")], identities)
    }

    func testRequestAuthorization_basic() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let packageURL = URL(string: "https://example.com/mona/LinkedList")!
        let identifiersURL = URL(string: "\(registryURL)/identifiers?url=\(packageURL.absoluteString)")!

        let user = "jappleseed"
        let password = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.get, identifiersURL):
                XCTAssertEqual(
                    request.headers.get("Authorization").first,
                    "Basic \("\(user):\(password)".data(using: .utf8)!.base64EncodedString())"
                )
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                let data = #"""
                {
                    "identifiers": [
                      "mona.LinkedList"
                    ]
                }
                """#.data(using: .utf8)!

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Length", value: "\(data.count)"),
                        .init(name: "Content-Type", value: "application/json"),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: data
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .basic)

        let authorizationProvider = TestProvider(map: [registryURL.host!: (user, password)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        let identities = try registryClient.lookupIdentities(scmURL: packageURL)
        XCTAssertEqual([PackageIdentity.plain("mona.LinkedList")], identities)
    }

    func testLogin() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let loginURL = URL(string: "\(registryURL)/login")!

        let token = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.post, loginURL):
                XCTAssertEqual(request.headers.get("Authorization").first, "Bearer \(token)")

                completion(.success(.init(
                    statusCode: 200,
                    headers: .init([
                        .init(name: "Content-Version", value: "1"),
                    ])
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .token)

        let authorizationProvider = TestProvider(map: [registryURL.host!: ("token", token)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        XCTAssertNoThrow(try registryClient.login(url: loginURL))
    }

    func testLogin_missingCredentials() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let loginURL = URL(string: "\(registryURL)/login")!

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.post, loginURL):
                XCTAssertNil(request.headers.get("Authorization").first)

                completion(.success(.init(
                    statusCode: 401,
                    headers: .init([
                        .init(name: "Content-Version", value: "1"),
                    ])
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL)

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient
        )

        XCTAssertThrowsError(try registryClient.login(url: loginURL)) { error in
            guard case RegistryError.unauthorized = error else {
                return XCTFail("Expected RegistryError.unauthorized, got \(error)")
            }
        }
    }

    func testLogin_authenticationMethodNotSupported() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let loginURL = URL(string: "\(registryURL)/login")!

        let token = "top-sekret"

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.post, loginURL):
                XCTAssertNotNil(request.headers.get("Authorization").first)

                completion(.success(.init(
                    statusCode: 501,
                    headers: .init([
                        .init(name: "Content-Version", value: "1"),
                    ])
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        let httpClient = LegacyHTTPClient(handler: handler)
        httpClient.configuration.circuitBreakerStrategy = .none
        httpClient.configuration.retryStrategy = .none

        var configuration = RegistryConfiguration()
        configuration.defaultRegistry = Registry(url: registryURL)
        configuration.registryAuthentication[registryURL.host!] = .init(type: .token)

        let authorizationProvider = TestProvider(map: [registryURL.host!: ("token", token)])

        let registryClient = makeRegistryClient(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )

        XCTAssertThrowsError(try registryClient.login(url: loginURL)) { error in
            guard case RegistryError.authenticationMethodNotSupported = error else {
                return XCTFail("Expected RegistryError.authenticationMethodNotSupported, got \(error)")
            }
        }
    }

    func testGetRegistryPublishSync() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let publishURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!

        let expectedLocation = URL(string: "https://\(registryURL)/packages\(scope)/\(name)/\(version)")!

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.put, publishURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                // TODO: implement multipart form parsing
                let body = String(data: request.body!, encoding: .utf8)
                XCTAssertMatch(body, .contains(Data(archiveContent.utf8).base64EncodedString()))
                XCTAssertMatch(body, .contains(metadataContent))

                completion(.success(.init(
                    statusCode: 201,
                    headers: .init([
                        .init(name: "Location", value: expectedLocation.absoluteString),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: .none
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        try withTemporaryDirectory() { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            let result = try registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                fileSystem: localFileSystem
            )

            XCTAssertEqual(result, .published(expectedLocation))
        }
    }

    func testGetRegistryPublishAsync() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let publishURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!

        let expectedLocation = URL(string: "https://\(registryURL)/status\(scope)/\(name)/\(version)")!
        let expectedRetry = Int.random(in: 10 ..< 100)

        let archiveContent = UUID().uuidString
        let metadataContent = UUID().uuidString

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            switch (request.method, request.url) {
            case (.put, publishURL):
                XCTAssertEqual(request.headers.get("Accept").first, "application/vnd.swift.registry.v1+json")

                // TODO: implement multipart form parsing
                let body = String(data: request.body!, encoding: .utf8)
                XCTAssertMatch(body, .contains(Data(archiveContent.utf8).base64EncodedString()))
                XCTAssertMatch(body, .contains(metadataContent))

                completion(.success(.init(
                    statusCode: 202,
                    headers: .init([
                        .init(name: "Location", value: expectedLocation.absoluteString),
                        .init(name: "Retry-After", value: expectedRetry.description),
                        .init(name: "Content-Version", value: "1"),
                    ]),
                    body: .none
                )))
            default:
                completion(.failure(StringError("method and url should match")))
            }
        }

        try withTemporaryDirectory() { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, string: archiveContent)

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, string: metadataContent)

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            let result = try registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                fileSystem: localFileSystem
            )

            XCTAssertEqual(result, .processing(statusURL: expectedLocation, retryAfter: expectedRetry))
        }
    }

    func testGetRegistryPublish_ServerError() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let identity = PackageIdentity.plain("mona.LinkedList")
        let (scope, name) = identity.scopeAndName!
        let version = Version("1.1.1")
        let publishURL = URL(string: "\(registryURL)/\(scope)/\(name)/\(version)")!

        let serverErrorHandler = ServerErrorHandler(
            method: .put,
            url: publishURL,
            errorCode: Int.random(in: 400 ..< 500),
            errorDescription: UUID().uuidString
        )

        try withTemporaryDirectory() { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, bytes: [])

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")
            try localFileSystem.writeFileContents(metadataPath, bytes: [])

            let httpClient = LegacyHTTPClient(handler: serverErrorHandler.handle)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            XCTAssertThrowsError(try registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError
                    .failedPublishing(
                        RegistryError
                            .serverError(code: serverErrorHandler.errorCode, details: serverErrorHandler.errorDescription)
                    ) = error
                else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testGetRegistryPublish_InvalidArchive() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory() { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            //try localFileSystem.writeFileContents(archivePath, bytes: [])

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            XCTAssertThrowsError(try registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.failedLoadingPackageArchive(archivePath) = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testGetRegistryPublish_InvalidMetadata() throws {
        let registryURL = URL(string: "https://packages.example.com")!
        let identity = PackageIdentity.plain("mona.LinkedList")
        let version = Version("1.1.1")

        let handler: LegacyHTTPClient.Handler = { request, _, completion in
            completion(.failure(StringError("should not be called")))
        }

        try withTemporaryDirectory() { temporaryDirectory in
            let archivePath = temporaryDirectory.appending(component: "\(identity)-\(version).zip")
            try localFileSystem.writeFileContents(archivePath, bytes: [])

            let metadataPath = temporaryDirectory.appending(component: "\(identity)-\(version)-metadata.json")

            let httpClient = LegacyHTTPClient(handler: handler)
            httpClient.configuration.circuitBreakerStrategy = .none
            httpClient.configuration.retryStrategy = .none

            var configuration = RegistryConfiguration()
            configuration.defaultRegistry = Registry(url: registryURL)

            let registryClient = makeRegistryClient(configuration: configuration, httpClient: httpClient)
            XCTAssertThrowsError(try registryClient.publish(
                registryURL: registryURL,
                packageIdentity: identity,
                packageVersion: version,
                packageArchive: archivePath,
                packageMetadata: metadataPath,
                signature: .none,
                fileSystem: localFileSystem
            )) { error in
                guard case RegistryError.failedLoadingPackageMetadata(metadataPath) = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }
}

// MARK: - Sugar

extension RegistryClient {
    fileprivate func getPackageMetadata(package: PackageIdentity) throws -> RegistryClient.PackageMetadata {
        try tsc_await {
            self.getPackageMetadata(
                package: package,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    fileprivate func getAvailableManifests(
        package: PackageIdentity,
        version: Version
    ) throws -> [String: (toolsVersion: ToolsVersion, content: String?)] {
        try tsc_await {
            self.getAvailableManifests(
                package: package,
                version: version,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    fileprivate func getManifestContent(
        package: PackageIdentity,
        version: Version,
        customToolsVersion: ToolsVersion?
    ) throws -> String {
        try tsc_await {
            self.getManifestContent(
                package: package,
                version: version,
                customToolsVersion: customToolsVersion,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    fileprivate func fetchSourceArchiveChecksum(
        package: PackageIdentity,
        version: Version,
        observabilityScope: ObservabilityScope = ObservabilitySystem.NOOP
    ) throws -> String {
        try tsc_await {
            self.fetchSourceArchiveChecksum(
                package: package,
                version: version,
                observabilityScope: observabilityScope,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    fileprivate func downloadSourceArchive(
        package: PackageIdentity,
        version: Version,
        fileSystem: FileSystem,
        destinationPath: AbsolutePath,
        checksumAlgorithm: HashAlgorithm,
        observabilityScope: ObservabilityScope = ObservabilitySystem.NOOP
    ) throws {
        try tsc_await {
            self.downloadSourceArchive(
                package: package,
                version: version,
                fileSystem: fileSystem,
                destinationPath: destinationPath,
                checksumAlgorithm: checksumAlgorithm,
                progressHandler: .none,
                observabilityScope: observabilityScope,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    fileprivate func lookupIdentities(scmURL: URL) throws -> Set<PackageIdentity> {
        try tsc_await {
            self.lookupIdentities(
                scmURL: scmURL,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    fileprivate func login(url: URL) throws {
        try tsc_await {
            self.login(
                url: url,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }

    func publish(
        registryURL: URL,
        packageIdentity: PackageIdentity,
        packageVersion: Version,
        packageArchive: AbsolutePath,
        packageMetadata: AbsolutePath?,
        signature: Data?,
        fileSystem: FileSystem
    ) throws -> RegistryClient.PublishResult {
        try tsc_await {
            self.publish(
                registryURL: registryURL,
                packageIdentity: packageIdentity,
                packageVersion: packageVersion,
                packageArchive: packageArchive,
                packageMetadata: packageMetadata,
                signature: signature,
                fileSystem: fileSystem,
                observabilityScope: ObservabilitySystem.NOOP,
                callbackQueue: .sharedConcurrent,
                completion: $0
            )
        }
    }
}

private func makeRegistryClient(
    configuration: RegistryConfiguration,
    httpClient: LegacyHTTPClient,
    authorizationProvider: AuthorizationProvider? = .none,
    fingerprintStorage: PackageFingerprintStorage = MockPackageFingerprintStorage(),
    fingerprintCheckingMode: FingerprintCheckingMode = .strict
) -> RegistryClient {
    RegistryClient(
        configuration: configuration,
        fingerprintStorage: fingerprintStorage,
        fingerprintCheckingMode: fingerprintCheckingMode,
        authorizationProvider: authorizationProvider,
        customHTTPClient: httpClient,
        customArchiverProvider: { _ in MockArchiver() }
    )
}

private struct TestProvider: AuthorizationProvider {
    let map: [String: (user: String, password: String)]

    func authentication(for url: URL) -> (user: String, password: String)? {
        self.map[url.host!]
    }
}

struct ServerErrorHandler {
    let method: HTTPMethod
    let url: URL
    let errorCode: Int
    let errorDescription: String

    init(
        method: HTTPMethod,
        url: URL,
        errorCode: Int,
        errorDescription: String
    ) {
        self.method = method
        self.url = url
        self.errorCode = errorCode
        self.errorDescription = errorDescription
    }

    func handle(
        request: LegacyHTTPClient.Request,
        progress: LegacyHTTPClient.ProgressHandler?,
        completion: @escaping ((Result<LegacyHTTPClient.Response, Error>) -> Void)
    ) {
        let data = """
        {
            "detail": "\(self.errorDescription)"
        }
        """.data(using: .utf8)!

        completion(.success(.init(
            statusCode: self.errorCode,
            headers: .init([
                .init(name: "Content-Length", value: "\(data.count)"),
                .init(name: "Content-Type", value: "application/problem+json"),
                .init(name: "Content-Version", value: "1"),
            ]),
            body: data
        )))
    }
}
