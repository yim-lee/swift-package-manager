/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import struct Foundation.Date
import struct Foundation.URL

import PackageModel
import TSCBasic
import TSCUtility

/// `PackageBasicMetadata` provider
public protocol PackageMetadataProvider: Closable {
    /// The name of the provider
    var name: String { get }

    /// Retrieves metadata for a package at the given repository address.
    ///
    /// - Parameters:
    ///   - identity: The package's identity
    ///   - location: The package's location
    ///   - callback: The closure to invoke when result becomes available
    func get(identity: PackageIdentity, location: String, callback: @escaping (Result<PackageCollectionsModel.PackageBasicMetadata, Error>) -> Void)

    /// Returns `AuthTokenType` for a package.
    ///
    /// - Parameters:
    ///   - location: The package's location
    func getAuthTokenType(for location: String) -> AuthTokenType?
}

public extension PackageCollectionsModel {
    struct PackageBasicMetadata: Equatable, Codable {
        public let summary: String?
        public let keywords: [String]?
        public let versions: [PackageBasicVersionMetadata]
        public let watchersCount: Int?
        public let readmeURL: Foundation.URL?
        public let license: PackageCollectionsModel.License?
        public let authors: [PackageCollectionsModel.Package.Author]?
        public let languages: Set<String>?
        public let processedAt: Date
    }

    struct PackageBasicVersionMetadata: Equatable, Codable {
        public let version: TSCUtility.Version
        public let title: String?
        public let summary: String?
        public let createdAt: Date
        public let publishedAt: Date?
    }
}

public struct PackageMetadataProviderContext: Equatable {
    public let authTokenType: AuthTokenType?
    public let isAuthTokenConfigured: Bool
    public internal(set) var error: PackageMetadataProviderError?

    init(authTokenType: AuthTokenType?, isAuthTokenConfigured: Bool, error: PackageMetadataProviderError? = nil) {
        self.authTokenType = authTokenType
        self.isAuthTokenConfigured = isAuthTokenConfigured
        self.error = error
    }
}

public enum PackageMetadataProviderError: Error, Equatable {
    case invalidResponse(errorMessage: String)
    case permissionDenied
    case invalidAuthToken
    case apiLimitsExceeded
}
