/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import struct Foundation.URL
import struct Foundation.URLComponents
import struct Foundation.URLQueryItem
import PackageLoading
import PackageModel
import TSCBasic
import TSCUtility

public enum RegistryError: Error {
    case registryNotConfigured(scope: PackageIdentity.Scope?)
    case invalidPackage(PackageIdentity)
    case invalidURL
    case invalidResponseStatus(expected: Int, actual: Int)
    case invalidContentVersion(expected: String, actual: String?)
    case invalidContentType(expected: String, actual: String?)
    case invalidResponse
    case missingSourceArchive
    case invalidSourceArchive
    case unsupportedHashAlgorithm(String)
    case failedToDetermineExpectedChecksum(Error)
    case checksumChanged(latest: String, previous: String)
    case invalidChecksum(expected: String, actual: String)
}

/// Package registry client.
/// API specification: https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md
public final class RegistryManager {
    private let apiVersion: APIVersion = .v1

    private let configuration: RegistryConfiguration
    private let identityResolver: IdentityResolver
    private let archiverProvider: (FileSystem) -> Archiver
    private let httpClient: HTTPClient
    private let authorizationProvider: HTTPClientAuthorizationProvider?
    let checksumStorage: ChecksumStorage

    public init(configuration: RegistryConfiguration,
                identityResolver: IdentityResolver,
                customArchiverProvider: ((FileSystem) -> Archiver)? = nil,
                customHTTPClient: HTTPClient? = nil,
                authorizationProvider: HTTPClientAuthorizationProvider? = nil,
                customChecksumStorage: ChecksumStorage? = nil)
    {
        self.configuration = configuration
        self.identityResolver = identityResolver
        self.archiverProvider = customArchiverProvider ?? { fileSystem in SourceArchiver(fileSystem: fileSystem) }
        self.httpClient = customHTTPClient ?? HTTPClient()
        self.authorizationProvider = authorizationProvider
        self.checksumStorage = customChecksumStorage ?? FileChecksumStorage()
    }

    public func fetchVersions(
        package: PackageIdentity,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<[Version], Error>) -> Void
    ) {
        let completion = makeAsync(completion, on: callbackQueue)

        guard case (let scope, let name)? = package.scopeAndName else {
            return completion(.failure(RegistryError.invalidPackage(package)))
        }

        guard let registry = configuration.registry(for: scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: scope)))
        }

        var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true)
        components?.appendPathComponents("\(scope)", "\(name)")

        guard let url = components?.url else {
            return completion(.failure(RegistryError.invalidURL))
        }

        var request = HTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .json),
            ]
        )
        request.options.timeout = timeout
        request.options.callbackQueue = callbackQueue
        request.options.authorizationProvider = authorizationProvider

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(result.tryMap { response in
                try self.checkResponseStatusAndHeaders(response, expectedStatusCode: 200, expectedContentType: .json)

                guard let data = response.body,
                      case .dictionary(let payload) = try? JSON(data: data),
                      case .dictionary(let releases) = payload["releases"]
                else {
                    throw RegistryError.invalidResponse
                }

                let versions = releases.filter { (try? $0.value.getJSON("problem")) == nil }
                    .compactMap { Version($0.key) }
                    .sorted(by: >)
                return versions
            })
        }
    }

    public func fetchManifest(
        package: PackageIdentity,
        version: Version,
        manifestLoader: ManifestLoaderProtocol,
        toolsVersion: ToolsVersion?,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Manifest, Error>) -> Void
    ) {
        let completion = makeAsync(completion, on: callbackQueue)

        guard case (let scope, let name)? = package.scopeAndName else {
            return completion(.failure(RegistryError.invalidPackage(package)))
        }

        guard let registry = configuration.registry(for: scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: scope)))
        }

        var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true)
        components?.appendPathComponents("\(scope)", "\(name)", "\(version)", "Package.swift")

        if let toolsVersion = toolsVersion {
            components?.queryItems = [
                URLQueryItem(name: "swift-version", value: toolsVersion.description),
            ]
        }

        guard let url = components?.url else {
            return completion(.failure(RegistryError.invalidURL))
        }

        var request = HTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .swift),
            ]
        )
        request.options.timeout = timeout
        request.options.callbackQueue = callbackQueue
        request.options.authorizationProvider = authorizationProvider

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            do {
                switch result {
                case .success(let response):
                    try self.checkResponseStatusAndHeaders(response, expectedStatusCode: 200, expectedContentType: .swift)

                    guard let data = response.body else {
                        throw RegistryError.invalidResponse
                    }

                    let fileSystem = InMemoryFileSystem()

                    let filename: String
                    if let toolsVersion = toolsVersion {
                        filename = Manifest.basename + "@swift-\(toolsVersion).swift"
                    } else {
                        filename = Manifest.basename + ".swift"
                    }

                    try fileSystem.writeFileContents(.root.appending(component: filename), bytes: ByteString(data))

                    // FIXME: this doesn't work for version-specific manifest
                    manifestLoader.load(
                        at: .root,
                        packageIdentity: package,
                        packageKind: .registry(package),
                        packageLocation: package.description, // FIXME: was originally PackageReference.locationString
                        version: version,
                        revision: nil,
                        toolsVersion: toolsVersion ?? .currentToolsVersion,
                        identityResolver: self.identityResolver,
                        fileSystem: fileSystem,
                        observabilityScope: observabilityScope,
                        on: callbackQueue,
                        completion: completion
                    )
                case .failure(let error):
                    throw error
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func fetchSourceArchiveChecksum(
        package: PackageIdentity,
        version: Version,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let completion = makeAsync(completion, on: callbackQueue)

        guard case (let scope, let name)? = package.scopeAndName else {
            return completion(.failure(RegistryError.invalidPackage(package)))
        }

        guard let registry = configuration.registry(for: scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: scope)))
        }

        var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true)
        components?.appendPathComponents("\(scope)", "\(name)", "\(version)")

        guard let url = components?.url else {
            return completion(.failure(RegistryError.invalidURL))
        }

        var request = HTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .json),
            ]
        )
        request.options.timeout = timeout
        request.options.callbackQueue = callbackQueue
        request.options.authorizationProvider = authorizationProvider

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            switch result {
            case .success(let response):
                do {
                    try self.checkResponseStatusAndHeaders(response, expectedStatusCode: 200, expectedContentType: .json)

                    guard let data = response.body,
                          case .dictionary(let payload) = try? JSON(data: data),
                          case .array(let resources) = payload["resources"]
                    else {
                        throw RegistryError.invalidResponse
                    }

                    guard let sourceArchive = resources.first(where: { (try? $0.get(String.self, forKey: "name")) == "source-archive" }) else {
                        throw RegistryError.missingSourceArchive
                    }

                    guard let checksum = try? sourceArchive.get(String.self, forKey: "checksum") else {
                        throw RegistryError.invalidSourceArchive
                    }

                    self.checksumStorage.put(package: package,
                                             version: version,
                                             checksum: checksum,
                                             observabilityScope: observabilityScope,
                                             callbackQueue: callbackQueue) { storageResult in
                        switch storageResult {
                        case .success:
                            completion(.success(checksum))
                        case .failure(let error):
                            if case ChecksumStorageError.conflict(_, let existingChecksum) = error {
                                return completion(.failure(RegistryError.checksumChanged(latest: checksum, previous: existingChecksum)))
                            }
                            completion(.failure(error))
                        }
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func downloadSourceArchive(
        package: PackageIdentity,
        version: Version,
        fileSystem: FileSystem,
        destinationPath: AbsolutePath,
        checksumAlgorithm: HashAlgorithm, // the same algorithm used by `package compute-checksum` tool
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let completion = makeAsync(completion, on: callbackQueue)

        guard case (let scope, let name)? = package.scopeAndName else {
            return completion(.failure(RegistryError.invalidPackage(package)))
        }

        guard let registry = configuration.registry(for: scope) else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: scope)))
        }

        // We either use a previously recorded checksum, or fetch it from the registry
        func withExpectedChecksum(body: @escaping (Result<String, Error>) -> Void) {
            self.checksumStorage.get(package: package,
                                     version: version,
                                     observabilityScope: observabilityScope,
                                     callbackQueue: callbackQueue) { result in
                switch result {
                case .success(let existingChecksum):
                    body(.success(existingChecksum))
                case .failure(let error):
                    if error as? ChecksumStorageError != .notFound {
                        observabilityScope.emit(error: "Failed to get checksum for \(package) \(version) from storage: \(error)")
                    }

                    self.fetchSourceArchiveChecksum(
                        package: package,
                        version: version,
                        observabilityScope: observabilityScope,
                        callbackQueue: callbackQueue,
                        completion: body
                    )
                }
            }
        }

        var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true)
        components?.appendPathComponents("\(scope)", "\(name)", "\(version).zip")

        guard let url = components?.url else {
            return completion(.failure(RegistryError.invalidURL))
        }

        var request = HTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .zip),
            ]
        )
        request.options.timeout = timeout
        request.options.callbackQueue = callbackQueue
        request.options.authorizationProvider = authorizationProvider

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            switch result {
            case .success(let response):
                do {
                    try self.checkResponseStatusAndHeaders(response, expectedStatusCode: 200, expectedContentType: .zip)
                } catch {
                    return completion(.failure(error))
                }

                guard let data = response.body else {
                    return completion(.failure(RegistryError.invalidResponse))
                }
                let contents = ByteString(data)

                withExpectedChecksum { result in
                    switch result {
                    case .success(let expectedChecksum):
                        let actualChecksum = checksumAlgorithm.hash(contents).hexadecimalRepresentation
                        guard expectedChecksum == actualChecksum else {
                            return completion(.failure(RegistryError.invalidChecksum(expected: expectedChecksum, actual: actualChecksum)))
                        }

                        do {
                            try fileSystem.createDirectory(destinationPath, recursive: true)

                            let archivePath = destinationPath.withExtension("zip")
                            try fileSystem.writeFileContents(archivePath, bytes: contents)

                            let archiver = self.archiverProvider(fileSystem)
                            // TODO: Bail if archive contains relative paths or overlapping files
                            archiver.extract(from: archivePath, to: destinationPath) { result in
                                completion(result)
                                try? fileSystem.removeFileTree(archivePath)
                            }
                        } catch {
                            try? fileSystem.removeFileTree(destinationPath)
                            completion(.failure(error))
                        }
                    case .failure(let error):
                        completion(.failure(RegistryError.failedToDetermineExpectedChecksum(error)))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func lookupIdentities(
        url: Foundation.URL,
        timeout: DispatchTimeInterval? = .none,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Set<PackageIdentity>, Error>) -> Void
    ) {
        let completion = makeAsync(completion, on: callbackQueue)

        guard let registry = configuration.defaultRegistry else {
            return completion(.failure(RegistryError.registryNotConfigured(scope: nil)))
        }

        var components = URLComponents(url: registry.url, resolvingAgainstBaseURL: true)
        components?.appendPathComponents("identifiers")

        components?.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
        ]

        guard let url = components?.url else {
            return completion(.failure(RegistryError.invalidURL))
        }

        var request = HTTPClient.Request(
            method: .get,
            url: url,
            headers: [
                "Accept": self.acceptHeader(mediaType: .json),
            ]
        )
        request.options.timeout = timeout
        request.options.callbackQueue = callbackQueue
        request.options.authorizationProvider = authorizationProvider

        self.httpClient.execute(request, observabilityScope: observabilityScope, progress: nil) { result in
            completion(result.tryMap { response in
                try self.checkResponseStatusAndHeaders(response, expectedStatusCode: 200, expectedContentType: .json)

                guard let data = response.body,
                      case .dictionary(let payload) = try? JSON(data: data),
                      case .array(let identifiers) = payload["identifiers"]
                else {
                    throw RegistryError.invalidResponse
                }

                let packageIdentities: [PackageIdentity] = identifiers.compactMap {
                    guard case .string(let string) = $0 else {
                        return nil
                    }
                    return PackageIdentity.plain(string)
                }

                return Set(packageIdentities)
            })
        }
    }
}

private extension RegistryManager {
    enum APIVersion: String {
        case v1 = "1"
    }
}

private extension RegistryManager {
    enum MediaType: String {
        case json
        case swift
        case zip
    }

    enum ContentType: String {
        case json = "application/json"
        case swift = "text/x-swift"
        case zip = "application/zip"
    }

    func acceptHeader(mediaType: MediaType) -> String {
        "application/vnd.swift.registry.v\(self.apiVersion.rawValue)+\(mediaType)"
    }

    func checkResponseStatusAndHeaders(_ response: HTTPClient.Response, expectedStatusCode: Int, expectedContentType: ContentType) throws {
        guard response.statusCode == expectedStatusCode else {
            throw RegistryError.invalidResponseStatus(expected: expectedStatusCode, actual: response.statusCode)
        }

        let contentVersion = response.headers.get("Content-Version").first
        guard contentVersion == self.apiVersion.rawValue else {
            throw RegistryError.invalidContentVersion(expected: self.apiVersion.rawValue, actual: contentVersion)
        }

        let contentType = response.headers.get("Content-Type").first
        guard contentType?.hasPrefix(expectedContentType.rawValue) == true else {
            throw RegistryError.invalidContentType(expected: expectedContentType.rawValue, actual: contentType)
        }
    }
}

// MARK: - Utilities

private extension String {
    /// Drops the given suffix from the string, if present.
    func spm_dropPrefix(_ prefix: String) -> String {
        if hasPrefix(prefix) {
            return String(dropFirst(prefix.count))
        }
        return self
    }
}

private extension AbsolutePath {
    func withExtension(_ extension: String) -> AbsolutePath {
        guard !self.isRoot else { return self }
        let `extension` = `extension`.spm_dropPrefix(".")
        return AbsolutePath(self, RelativePath("..")).appending(component: "\(basename).\(`extension`)")
    }
}

private extension URLComponents {
    mutating func appendPathComponents(_ components: String...) {
        path += (path.last == "/" ? "" : "/") + components.joined(separator: "/")
    }
}
