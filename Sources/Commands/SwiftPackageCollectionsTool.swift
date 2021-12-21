/*
 This source file is part of the Swift.org open source project

 Copyright 2020-2022 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import ArgumentParser
import Basics
import Foundation
import PackageCollections
import PackageModel
import TSCBasic
import TSCUtility

private enum CollectionsError: Swift.Error {
    case invalidArgument(String)
    case invalidVersionString(String)
    case unsigned
    case cannotVerifySignature
    case invalidSignature
    case missingSignature
}

// FIXME: add links to docs in error messages
extension CollectionsError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidArgument(let argumentName):
            return "Invalid argument '\(argumentName)'"
        case .invalidVersionString(let versionString):
            return "Invalid version string '\(versionString)'"
        case .unsigned:
            return "The collection is not signed. If you would still like to add it please rerun 'add' with '--trust-unsigned'."
        case .cannotVerifySignature:
            return "The collection's signature cannot be verified due to missing configuration. Please refer to documentations on how to set up trusted root certificates or rerun 'add' with '--skip-signature-check'."
        case .invalidSignature:
            return "The collection's signature is invalid. If you would still like to add it please rerun 'add' with '--skip-signature-check'."
        case .missingSignature:
            return "The collection is missing required signature, which means it might have been compromised. Please contact the collection's authors and alert them of the issue."
        }
    }
}

struct JSONOptions: ParsableArguments {
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
}

public struct SwiftPackageCollectionsTool: ParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "package-collection",
        _superCommandName: "swift",
        abstract: "Interact with package collections",
        discussion: "SEE ALSO: swift build, swift package, swift run, swift test",
        version: SwiftVersion.currentVersion.completeDisplayString,
        subcommands: [
            Add.self,
            Describe.self,
            Diff.self,
            Generate.self,
            List.self,
            Refresh.self,
            Remove.self,
            Search.self,
            Sign.self,
            Validate.self
        ],
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)]
    )

    public init() {}

    // MARK: - Collections

    struct List: SwiftCommand {
        static let configuration = CommandConfiguration(abstract: "List configured collections")

        @OptionGroup
        var jsonOptions: JSONOptions

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            let collections = try with(swiftTool.observabilityScope) { collections in
                try tsc_await { collections.listCollections(identifiers: nil, callback: $0) }
            }

            if self.jsonOptions.json {
                try JSONEncoder.makeWithDefaults().print(collections)
            } else {
                collections.forEach {
                    print("\($0.name) - \($0.source.url)")
                }
            }
        }
    }

    struct Refresh: SwiftCommand {
        static let configuration = CommandConfiguration(abstract: "Refresh configured collections")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            let collections = try with(swiftTool.observabilityScope) { collections in
                try tsc_await { collections.refreshCollections(callback: $0) }
            }
            print("Refreshed \(collections.count) configured package collection\(collections.count == 1 ? "" : "s").")
        }
    }

    struct Add: SwiftCommand {
        static let configuration = CommandConfiguration(abstract: "Add a new collection")

        @Argument(help: "URL of the collection to add")
        var collectionURL: String

        @Option(name: .long, help: "Sort order for the added collection")
        var order: Int?

        @Flag(name: .long, help: "Trust the collection even if it is unsigned")
        var trustUnsigned: Bool = false

        @Flag(name: .long, help: "Skip signature check if the collection is signed")
        var skipSignatureCheck: Bool = false

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            let collectionURL = try url(self.collectionURL)

            let source = PackageCollectionsModel.CollectionSource(type: .json, url: collectionURL, skipSignatureCheck: self.skipSignatureCheck)
            let collection: PackageCollectionsModel.Collection = try with(swiftTool.observabilityScope) { collections in
                do {
                    let userTrusted = self.trustUnsigned
                    return try tsc_await {
                        collections.addCollection(
                            source,
                            order: order,
                            trustConfirmationProvider: { _, callback in callback(userTrusted) },
                            callback: $0
                        )
                    }
                } catch PackageCollectionError.trustConfirmationRequired, PackageCollectionError.untrusted {
                    throw CollectionsError.unsigned
                } catch PackageCollectionError.cannotVerifySignature {
                    throw CollectionsError.cannotVerifySignature
                } catch PackageCollectionError.invalidSignature {
                    throw CollectionsError.invalidSignature
                } catch PackageCollectionError.missingSignature {
                    throw CollectionsError.missingSignature
                }
            }

            print("Added \"\(collection.name)\" to your package collections.")
        }
    }

    struct Remove: SwiftCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a configured collection")

        @Argument(help: "URL of the collection to remove")
        var collectionURL: String

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            let collectionURL = try url(self.collectionURL)

            let source = PackageCollectionsModel.CollectionSource(type: .json, url: collectionURL)
            try with(swiftTool.observabilityScope) { collections in
                let collection = try tsc_await { collections.getCollection(source, callback: $0) }
                _ = try tsc_await { collections.removeCollection(source, callback: $0) }
                print("Removed \"\(collection.name)\" from your package collections.")
            }
        }
    }

    // MARK: - Search

    enum SearchMethod: String, EnumerableFlag {
        case keywords
        case module
    }

    struct Search: SwiftCommand {
        static var configuration = CommandConfiguration(abstract: "Search for packages by keywords or module names")

        @OptionGroup
        var jsonOptions: JSONOptions

        @Flag(help: "Pick the method for searching")
        var searchMethod: SearchMethod

        @Argument(help: "Search query")
        var searchQuery: String

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        func run(_ swiftTool: SwiftTool) throws {
            try with(swiftTool.observabilityScope) { collections in
                switch searchMethod {
                case .keywords:
                    let results = try tsc_await { collections.findPackages(searchQuery, collections: nil, callback: $0) }

                    if jsonOptions.json {
                        try JSONEncoder.makeWithDefaults().print(results.items)
                    } else {
                        results.items.forEach {
                            print("\($0.package.identity): \($0.package.summary ?? "")")
                        }
                    }

                case .module:
                    let results = try tsc_await { collections.findTargets(searchQuery, searchType: .exactMatch, collections: nil, callback: $0) }

                    let packages = Set(results.items.flatMap { $0.packages })
                    if jsonOptions.json {
                        try JSONEncoder.makeWithDefaults().print(packages)
                    } else {
                        packages.forEach {
                            print("\($0.identity): \($0.summary ?? "")")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Describe

    struct Describe: SwiftCommand {
        static var configuration = CommandConfiguration(abstract: "Get metadata for a collection or a package included in an imported collection")

        @OptionGroup
        var jsonOptions: JSONOptions

        @Argument(help: "URL of the package or collection to get information for")
        var packageURL: String

        @Option(name: .long, help: "Version of the package to get information for")
        var version: String?

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions

        private func printVersion(_ version: PackageCollectionsModel.Package.Version?) -> String? {
            guard let version = version else {
                return nil
            }
            guard let defaultManifest = version.defaultManifest else {
                return nil
            }

            let manifests = version.manifests.values.filter { $0.toolsVersion != version.defaultToolsVersion }.map { printManifest($0) }.joined(separator: "\n")
            let compatibility = optionalRow(
                "Verified Compatibility (Platform, Swift Version)",
                version.verifiedCompatibility?.map { "(\($0.platform.name), \($0.swiftVersion.rawValue))" }.joined(separator: ", ")
            )
            let license = optionalRow("License", version.license?.type.description)

            return """
            \(version.version)
            \(self.printManifest(defaultManifest))\(manifests)\(compatibility)\(license)
            """
        }

        private func printManifest(_ manifest: PackageCollectionsModel.Package.Version.Manifest) -> String {
            let modules = manifest.targets.compactMap { $0.moduleName }.joined(separator: ", ")
            let products = optionalRow("Products", manifest.products.isEmpty ? nil : manifest.products.compactMap { $0.name }.joined(separator: ", "), indentationLevel: 3)

            return """
                    Tools Version: \(manifest.toolsVersion.description)
                        Package Name: \(manifest.packageName)
                        Modules: \(modules)\(products)
            """
        }

        func run(_ swiftTool: SwiftTool) throws {
            try with(swiftTool.observabilityScope) { collections in
                let identity = PackageIdentity(urlString: self.packageURL)

                do { // assume URL is for a package in an imported collection
                    let result = try tsc_await { collections.getPackageMetadata(identity: identity, location: self.packageURL, callback: $0) }

                    if let versionString = version {
                        guard let version = TSCUtility.Version(versionString), let result = result.package.versions.first(where: { $0.version == version }), let printedResult = printVersion(result) else {
                            throw CollectionsError.invalidVersionString(versionString)
                        }

                        if jsonOptions.json {
                            try JSONEncoder.makeWithDefaults().print(result)
                        } else {
                            print("\(indent())Version: \(printedResult)")
                        }
                    } else {
                        let description = optionalRow("Description", result.package.summary)
                        let versions = result.package.versions.map { "\($0.version)" }.joined(separator: ", ")
                        let stars = optionalRow("Stars", result.package.watchersCount?.description)
                        let readme = optionalRow("Readme", result.package.readmeURL?.absoluteString)
                        let authors = optionalRow("Authors", result.package.authors?.map { $0.username }.joined(separator: ", "))
                        let license =  optionalRow("License", result.package.license.map { "\($0.type) (\($0.url))" })
                        let languages = optionalRow("Languages", result.package.languages?.joined(separator: ", "))
                        let latestVersion = optionalRow("\(String(repeating: "-", count: 60))\n\(indent())Latest Version", printVersion(result.package.latestVersion))

                        if jsonOptions.json {
                            try JSONEncoder.makeWithDefaults().print(result.package)
                        } else {
                            print("""
                                \(description)
                                Available Versions: \(versions)\(readme)\(license)\(authors)\(stars)\(languages)\(latestVersion)
                            """)
                        }
                    }
                } catch { // assume URL is for a collection
                    // If a version argument was given, we do not perform the fallback.
                    if version != nil {
                        throw error
                    }

                    let collectionURL = try url(self.packageURL)

                    do {
                        let source = PackageCollectionsModel.CollectionSource(type: .json, url: collectionURL)
                        let collection = try tsc_await { collections.getCollection(source, callback: $0) }

                        let description = optionalRow("Description", collection.overview)
                        let keywords = optionalRow("Keywords", collection.keywords?.joined(separator: ", "))
                        let createdAt = optionalRow("Created At", DateFormatter().string(from: collection.createdAt))
                        let packages = collection.packages.map { "\($0.identity)" }.joined(separator: "\n\(indent(levels: 2))")

                        if jsonOptions.json {
                            try JSONEncoder.makeWithDefaults().print(collection)
                        } else {
                            let signature = optionalRow("Signed By", collection.signature.map { "\($0.certificate.subject.commonName ?? "Unspecified") (\($0.isVerified ? "" : "not ")verified)" })

                            print("""
                                Name: \(collection.name)
                                Source: \(collection.source.url)\(description)\(keywords)\(createdAt)
                                Packages:
                                    \(packages)\(signature)
                            """)
                        }
                    } catch {
                        print("Failed to get metadata. The given URL either belongs to a collection that is invalid or unavailable, or a package that is not found in any of the imported collections.")
                    }
                }
            }
        }
    }
    
    // MARK: - Commands for authoring package collection
    
    struct Generate: SwiftCommand {
        static var configuration = CommandConfiguration(abstract: "Generate a package collection")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(help: "The path to the JSON document containing the list of packages to be processed")
        private var inputPath: String

        @Argument(help: "The path to write the generated package collection to")
        private var outputPath: String

        @Option(help:
            """
            The path to the working directory where package repositories may have been cloned previously. \
            A package repository that already exists in the directory will be updated rather than cloned again.\n\n\
            Be warned that the tool does not distinguish these directories by their corresponding git repository URL--\
            different repositories with the same name will end up in the same directory.\n\n\
            Temporary directories will be used instead if this argument is not specified.
            """
        )
        private var workingDirectoryPath: String?

        @Option(help: "The revision number of the generated package collection")
        private var revision: Int?

        @Option(parsing: .upToNextOption, help:
            """
            Auth tokens each in the format of type:host:token for retrieving additional package metadata via source
            hosting platform APIs. Currently only GitHub APIs are supported. An example token would be github:github.com:<TOKEN>.
            """)
        private var authToken: [String] = []

        @Flag(name: .long, help: "Format output using friendly indentation and line-breaks.")
        private var prettyPrinted: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            print("generate")
        }
    }
    
    struct Sign: SwiftCommand {
        static var configuration = CommandConfiguration(abstract: "Sign a package collection")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(help: "The path to the package collection file to be signed")
        var inputPath: String

        @Argument(help: "The path to write the signed package collection to")
        var outputPath: String

        @Argument(help: "The path to certificate's private key (PEM encoded)")
        var privateKeyPath: String

        @Argument(help: "Paths to all certificates (DER encoded) in the chain. The certificate used for signing must be first and the root certificate last.")
        var certChainPaths: [String]

        func run(_ swiftTool: SwiftTool) throws {
            print("sign")
        }
    }
    
    struct Validate: SwiftCommand {
        static var configuration = CommandConfiguration(abstract: "Validate a package collection")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(help: "The path to the JSON document containing the package collection to be validated")
        private var inputPath: String

        @Flag(name: .long, help: "Warnings will fail validation in addition to errors")
        private var warningsAsErrors: Bool = false

        func run(_ swiftTool: SwiftTool) throws {
            print("validate")
        }
    }
    
    struct Diff: SwiftCommand {
        static var configuration = CommandConfiguration(abstract: "Compare two package collections to determine if their contents are the same")

        @OptionGroup(_hiddenFromHelp: true)
        var swiftOptions: SwiftToolOptions
        
        @Argument(help: "The path to the JSON document containing package collection #1")
        private var collectionOnePath: String

        @Argument(help: "The path to the JSON document containing package collection #2")
        private var collectionTwoPath: String

        func run(_ swiftTool: SwiftTool) throws {
            print("diff")
        }
    }
}

private func indent(levels: Int = 1) -> String {
    return String(repeating: "    ", count: levels)
}

private func optionalRow(_ title: String, _ contents: String?, indentationLevel: Int = 1) -> String {
    if let contents = contents, !contents.isEmpty {
        return "\n\(indent(levels: indentationLevel))\(title): \(contents)"
    } else {
        return ""
    }
}

private extension JSONEncoder {
    func print<T>(_ value: T) throws where T: Encodable {
        let jsonData = try self.encode(value)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        Swift.print(jsonString)
    }
}

private extension ParsableCommand {
    func with<T>(_ observabilityScope: ObservabilityScope, handler: (_ collections: PackageCollectionsProtocol) throws -> T) throws -> T {
        let collections = PackageCollections(observabilityScope: observabilityScope)
        defer {
            do {
                try collections.shutdown()
            } catch {
                Self.exit(withError: error)
            }
        }

        return try handler(collections)
    }

    func url(_ urlString: String) throws -> Foundation.URL {
        guard let url = URL(string: urlString) else {
            let filePrefix = "file://"
            guard urlString.hasPrefix(filePrefix) else {
                throw CollectionsError.invalidArgument("collectionURL")
            }
            // URL(fileURLWithPath:) can handle whitespaces in path
            return URL(fileURLWithPath: String(urlString.dropFirst(filePrefix.count)))
        }
        return url
    }
}
