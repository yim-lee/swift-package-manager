/*
 This source file is part of the Swift.org open source project

 Copyright 2020-2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import ArgumentParser
import Basics
import Foundation
import PackageCollections
import PackageCollectionsModel
import PackageCollectionsSigning
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

        @Flag(name: .long, help: "Format output package collection using friendly indentation and line-breaks.")
        private var prettyPrinted: Bool = false
        
        typealias Model = PackageCollectionModel.V1

        func run(_ swiftTool: SwiftTool) throws {
            // Parse auth tokens
            let authTokens = self.authToken.reduce(into: [AuthTokenType: String]()) { authTokens, authToken in
                let parts = authToken.components(separatedBy: ":")
                guard parts.count == 3, let type = AuthTokenType.from(type: parts[0], host: parts[1]) else {
                    swiftTool.observabilityScope.emit(warning: "Ignoring invalid auth token '\(authToken)'")
                    return
                }
                authTokens[type] = parts[2]
            }
            if !self.authToken.isEmpty {
                swiftTool.observabilityScope.emit(info: "Using auth tokens: \(authTokens.keys)")
            }
            
            swiftTool.observabilityScope.emit(info: "Using input file located at \(self.inputPath)")

            // Get the list of packages to process
            let jsonDecoder = JSONDecoder.makeWithDefaults()
            let input = try jsonDecoder.decode(PackageCollectionGeneratorInput.self, from: Data(contentsOf: URL(fileURLWithPath: self.inputPath)))
            swiftTool.observabilityScope.emit(debug: "\(input)")
            
            let git = GitHelper(processSet: swiftTool.processSet)
            let metadataProvider = GitHubPackageMetadataProvider(
                configuration: .init(authTokens: { authTokens }),
                observabilityScope: swiftTool.observabilityScope
            )
            defer { try? metadataProvider.close() }
            
            // Generate metadata for each package
            let packages: [Model.Collection.Package] = input.packages.compactMap { package in
                do {
                    let packageMetadata = try self.generateMetadata(
                        for: package,
                        git: git,
                        metadataProvider: metadataProvider,
                        jsonDecoder: jsonDecoder,
                        swiftTool: swiftTool
                    )
                    swiftTool.observabilityScope.emit(debug: "\(packageMetadata)")

                    guard !packageMetadata.versions.isEmpty else {
                        swiftTool.observabilityScope.emit(warning: "Skipping package \(package.url) because it does not have any valid versions.")
                        return nil
                    }

                    return packageMetadata
                } catch {
                    swiftTool.observabilityScope.emit(error: "Failed to generate metadata for package \(package.url): \(error)")
                    return nil
                }
            }

            guard !packages.isEmpty else {
                swiftTool.observabilityScope.emit(error: "Failed to create package collection because it does not have any valid packages.")
                return
            }

            // Construct the package collection
            let packageCollection = Model.Collection(
                name: input.name,
                overview: input.overview,
                keywords: input.keywords,
                packages: packages,
                formatVersion: .v1_0,
                revision: self.revision,
                generatedAt: Date(),
                generatedBy: input.author
            )

            // Make sure the output directory exists
            let outputAbsolutePath = AbsolutePath(absoluteOrRelativePath: self.outputPath)
            let outputDirectory = outputAbsolutePath.parentDirectory
            try localFileSystem.createDirectory(outputDirectory, recursive: true)

            // Write the package collection
            let jsonEncoder = JSONEncoder.makeWithDefaults(sortKeys: true, prettyPrint: self.prettyPrinted, escapeSlashes: false)
            let jsonData = try jsonEncoder.encode(packageCollection)
            try jsonData.write(to: URL(fileURLWithPath: outputAbsolutePath.pathString))
            swiftTool.observabilityScope.emit(info: "Package collection saved to \(outputAbsolutePath)")
        }
        
        private func generateMetadata(for package: PackageCollectionGeneratorInput.Package,
                                      git: GitHelper,
                                      metadataProvider: PackageMetadataProvider,
                                      jsonDecoder: JSONDecoder,
                                      swiftTool: SwiftTool) throws -> Model.Collection.Package {
            swiftTool.observabilityScope.emit(info: "Processing package \(package.url)")

            // Try to locate the directory where the repository might have been cloned to previously
            if let workingDirectoryPath = self.workingDirectoryPath {
                let workingDirectoryAbsolutePath = AbsolutePath(absoluteOrRelativePath: workingDirectoryPath)

                // Extract directory name from repository URL
                if let repositoryName = package.url.repositoryName {
                    swiftTool.observabilityScope.emit(debug: "Extracted repository name from URL: \(repositoryName)")

                    let gitDirectoryPath = workingDirectoryAbsolutePath.appending(component: repositoryName)
                    if localFileSystem.exists(gitDirectoryPath) {
                        // If directory exists, assume it has been cloned previously
                        swiftTool.observabilityScope.emit(info: "\(gitDirectoryPath) exists")
                        try git.fetch(gitDirectory: gitDirectoryPath)
                    } else {
                        // Else clone it
                        swiftTool.observabilityScope.emit(info: "\(gitDirectoryPath) does not exist")
                        try git.clone(package.url, to: gitDirectoryPath)
                    }

                    return try self.generateMetadata(
                        for: package,
                        gitDirectory: gitDirectoryPath,
                        git: git,
                        metadataProvider: metadataProvider,
                        jsonDecoder: jsonDecoder,
                        swiftTool: swiftTool
                    )
                }
            }

            // Fallback to tmp directory if we cannot use the working directory for some reason or it's unspecified
            return try withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
                // Clone the package repository
                try git.clone(package.url, to: tmpDir)

                return try self.generateMetadata(
                    for: package,
                    gitDirectory: tmpDir,
                    git: git,
                    metadataProvider: metadataProvider,
                    jsonDecoder: jsonDecoder,
                    swiftTool: swiftTool
                )
            }
        }
        
        private func generateMetadata(for package: PackageCollectionGeneratorInput.Package,
                                      gitDirectory: AbsolutePath,
                                      git: GitHelper,
                                      metadataProvider: PackageMetadataProvider,
                                      jsonDecoder: JSONDecoder,
                                      swiftTool: SwiftTool) throws -> Model.Collection.Package {
            var additionalMetadata: PackageCollectionsModel.PackageBasicMetadata?
            do {
                additionalMetadata = try tsc_await { callback in
                    metadataProvider.get(identity: .init(url: package.url), location: package.url.absoluteString, callback: callback)
                }
            } catch {
                swiftTool.observabilityScope.emit(warning: "Failed to fetch additional metadata: \(error)")
            }
            if let additionalMetadata = additionalMetadata {
                swiftTool.observabilityScope.emit(debug: "Retrieved additional metadata: \(additionalMetadata)")
            }

            // Select versions if none specified
            var versions = try package.versions ?? self.defaultVersions(for: gitDirectory, git: git, observabilityScope: swiftTool.observabilityScope)

            // Remove excluded versions
            if let excludedVersions = package.excludedVersions {
                swiftTool.observabilityScope.emit(info: "Excluding: \(excludedVersions)")
                let excludedVersionsSet = Set(excludedVersions)
                versions = versions.filter { !excludedVersionsSet.contains($0) }
            }

            // Load the manifest for each version and extract metadata
            let packageVersions: [Model.Collection.Package.Version] = versions.compactMap { version in
                do {
                    let metadata = try self.generateMetadata(
                        for: version,
                        excludedProducts: package.excludedProducts.map { Set($0) } ?? [],
                        excludedTargets: package.excludedTargets.map { Set($0) } ?? [],
                        gitDirectory: gitDirectory,
                        git: git,
                        jsonDecoder: jsonDecoder,
                        swiftTool: swiftTool
                    )

                    guard metadata.manifests.values.first(where: { !$0.products.isEmpty }) != nil else {
                        swiftTool.observabilityScope.emit(warning: "Skipping version \(version) because it does not have any products.")
                        return nil
                    }
                    guard metadata.manifests.values.first(where: { !$0.targets.isEmpty }) != nil else {
                        swiftTool.observabilityScope.emit(warning: "Skipping version \(version) because it does not have any targets.")
                        return nil
                    }

                    return metadata
                } catch {
                    swiftTool.observabilityScope.emit(error: "Failed to load package manifest for \(package.url) version \(version): \(error)")
                    return nil
                }
            }
            
            return Model.Collection.Package(
                url: package.url,
                summary: package.summary ?? additionalMetadata?.summary,
                keywords: package.keywords ?? additionalMetadata?.keywords,
                versions: packageVersions,
                readmeURL: package.readmeURL ?? additionalMetadata?.readmeURL,
                license: additionalMetadata?.license.map { .init(name: $0.type.description, url: $0.url) }
            )
        }

        private func generateMetadata(for version: String,
                                      excludedProducts: Set<String>,
                                      excludedTargets: Set<String>,
                                      gitDirectory: AbsolutePath,
                                      git: GitHelper,
                                      jsonDecoder: JSONDecoder,
                                      swiftTool: SwiftTool) throws -> Model.Collection.Package.Version {
            // Check out the git tag
            swiftTool.observabilityScope.emit(info: "Checking out version \(version)")
            try git.checkout(version, at: gitDirectory)

            let tag = try git.readTag(version, for: gitDirectory)
            
            let defaultManifest = try self.defaultManifest(
                excludedProducts: excludedProducts,
                excludedTargets: excludedTargets,
                packagePath: gitDirectory,
                jsonDecoder: jsonDecoder,
                swiftTool: swiftTool
            )
            // TODO: Use `describe` to obtain all manifest-related data, including version-specific manifests
            let manifests = [defaultManifest.toolsVersion: defaultManifest]

            return Model.Collection.Package.Version(
                version: version,
                summary: tag?.message,
                manifests: manifests,
                defaultToolsVersion: defaultManifest.toolsVersion,
                verifiedCompatibility: nil,
                license: nil,
                createdAt: tag?.createdAt
            )
        }

        private func defaultManifest(excludedProducts: Set<String>,
                                     excludedTargets: Set<String>,
                                     packagePath: AbsolutePath,
                                     jsonDecoder: JSONDecoder,
                                     swiftTool: SwiftTool) throws -> Model.Collection.Package.Version.Manifest {
            let workspace = try swiftTool.getActiveWorkspace()
            let package = try tsc_await {
                workspace.loadRootPackage(
                    at: packagePath,
                    observabilityScope: swiftTool.observabilityScope.makeChildScope(description: "package describe"),
                    completion: $0
                )
            }
            let describedPackage = DescribedPackage(from: package)

            let products: [Model.Product] = describedPackage.products
                .filter { !excludedProducts.contains($0.name) }
                .map { product in
                    Model.Product(
                        name: product.name,
                        type: Model.ProductType(from: product.type),
                        targets: product.targets
                    )
                }
                .sorted { $0.name < $1.name }

            // Include only targets that are in at least one product.
            // Another approach is to use `target.product_memberships` but the way it is implemented produces a more concise list.
            let publicTargets = Set(products.map(\.targets).reduce(into: []) { result, targets in
                result.append(contentsOf: targets.filter { !excludedTargets.contains($0) })
            })

            let targets: [Model.Target] = describedPackage.targets
                .filter { publicTargets.contains($0.name) }
                .map { target in
                    Model.Target(
                        name: target.name,
                        moduleName: target.c99name
                    )
                }
                .sorted { $0.name < $1.name }

            let minimumPlatformVersions = describedPackage.platforms.map { Model.PlatformVersion(name: $0.name, version: $0.version) }

            return Model.Collection.Package.Version.Manifest(
                toolsVersion: describedPackage.toolsVersion,
                packageName: describedPackage.name,
                targets: targets,
                products: products,
                minimumPlatformVersions: minimumPlatformVersions
            )
        }

        private func defaultVersions(for gitDirectory: AbsolutePath,
                                     git: GitHelper,
                                     observabilityScope: ObservabilityScope) throws -> [String] {
            // List all the tags
            let tags = try git.listTags(for: gitDirectory)
            observabilityScope.emit(info: "Tags: \(tags)")

            // Sort tags in descending order (non-semver tags are excluded)
            // By default, we want:
            //  - At most 3 minor versions per major version
            //  - Maximum of 2 majors
            //  - Maximum of 6 versions total
            var allVersions: [(tag: String, version: Version)] = tags.compactMap { tag in
                // Remove common "v" prefix which is supported by SwiftPM
                Version(tag.hasPrefix("v") ? String(tag.dropFirst(1)) : tag).map { (tag: tag, version: $0) }
            }
            allVersions.sort { $0.version > $1.version }

            var versions = [String]()
            var currentMajor: Int?
            var majorCount = 0
            var minorCount = 0
            for tagVersion in allVersions {
                if tagVersion.version.major != currentMajor {
                    currentMajor = tagVersion.version.major
                    majorCount += 1
                    minorCount = 0
                }

                guard majorCount <= 2 else { break }
                guard minorCount < 3 else { continue }

                versions.append(tagVersion.tag)
                minorCount += 1
            }

            observabilityScope.emit(info: "Default versions: \(versions)")

            return versions
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
        
        typealias Model = PackageCollectionModel.V1

        func run(_ swiftTool: SwiftTool) throws {
            try self.run(swiftTool, customSigner: .none)
        }
        
        func run(_ swiftTool: SwiftTool, customSigner: PackageCollectionSigner?) throws {
            guard !self.certChainPaths.isEmpty else {
                swiftTool.observabilityScope.emit(error: "Certificate chain cannot be empty")
                throw PackageCollectionSigningError.emptyCertChain
            }

            swiftTool.observabilityScope.emit(info: "Signing package collection located at \(self.inputPath)")

            let jsonDecoder = JSONDecoder.makeWithDefaults()
            let collection = try jsonDecoder.decode(Model.Collection.self, from: Data(contentsOf: URL(fileURLWithPath: self.inputPath)))

            let privateKeyURL = Foundation.URL(fileURLWithPath: self.privateKeyPath)
            let certChainURLs = self.certChainPaths.map { AbsolutePath(absoluteOrRelativePath: $0).asURL }

            try withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
                // The last item in the array is the root certificate and we want to trust it, so here we
                // create a temp directory, copy the root certificate to it, and make it the trustedRootCertsDir.
                let rootCertPath = AbsolutePath(certChainURLs.last!.path) // !-safe since certChain cannot be empty at this point
                let rootCertFilename = rootCertPath.components.last!
                try localFileSystem.copy(from: rootCertPath, to: tmpDir.appending(component: rootCertFilename))

                // Sign the collection
                let signer = customSigner ?? PackageCollectionSigning(
                    trustedRootCertsDir: tmpDir.asURL,
                    observabilityScope: swiftTool.observabilityScope,
                    callbackQueue: .sharedConcurrent
                )
                let signedCollection = try tsc_await { callback in
                    signer.sign(collection: collection, certChainPaths: certChainURLs, certPrivateKeyPath: privateKeyURL, certPolicyKey: .default, callback: callback)
                }

                // Make sure the output directory exists
                let outputAbsolutePath = AbsolutePath(absoluteOrRelativePath: self.outputPath)
                let outputDirectory = outputAbsolutePath.parentDirectory
                try localFileSystem.createDirectory(outputDirectory, recursive: true)

                // Write the signed collection
                let jsonEncoder = JSONEncoder.makeWithDefaults(sortKeys: true, prettyPrint: false, escapeSlashes: false)
                let jsonData = try jsonEncoder.encode(signedCollection)
                try jsonData.write(to: URL(fileURLWithPath: outputAbsolutePath.pathString))
                swiftTool.observabilityScope.emit(info: "Signed package collection saved to \(outputAbsolutePath)")
            }
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
        
        typealias Model = PackageCollectionModel.V1

        func run(_ swiftTool: SwiftTool) throws {
            swiftTool.observabilityScope.emit(info: "Using input file located at \(self.inputPath)")

            let jsonDecoder = JSONDecoder.makeWithDefaults()
            let collection: Model.Collection
            do {
                collection = try jsonDecoder.decode(Model.Collection.self, from: Data(contentsOf: URL(fileURLWithPath: self.inputPath)))
            } catch {
                print("Failed to parse package collection: \(error)")
                throw error
            }

            let validator = Model.Validator()
            let validationMessages = validator.validate(collection: collection) ?? []

            if validationMessages.isEmpty {
                return print("The package collection is valid")
            }

            if self.warningsAsErrors {
                if let errors = validationMessages.errors(include: [.warning, .error]), !errors.isEmpty {
                    errors.forEach { print("error: \($0)") }
                    throw MultipleErrors(errors)
                }
            } else {
                validationMessages.filter { $0.level == .warning }.forEach { warning in
                    print("warning: \(warning.property.map { "\($0): " } ?? "")\(warning.message)")
                }
                
                if let errors = validationMessages.errors(include: [.error]), !errors.isEmpty {
                    errors.forEach { print("error: \($0)") }
                    throw MultipleErrors(errors)
                }
            }
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

// MARK: - Helpers

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

private extension AbsolutePath {
    init(absoluteOrRelativePath: String) {
        do {
            try self.init(validating: absoluteOrRelativePath)
        } catch {
            if let cwd = localFileSystem.currentWorkingDirectory {
                self.init(absoluteOrRelativePath, relativeTo: cwd)
            } else {
                self.init(absoluteOrRelativePath, relativeTo: AbsolutePath(FileManager.default.currentDirectoryPath))
            }
        }
    }
}

private extension Foundation.URL {
    var repositoryName: String? {
        let url = self.absoluteString
        do {
            let regex = try NSRegularExpression(pattern: #"([^/@]+)[:/]([^:/]+)/([^/.]+)(\.git)?$"#, options: .caseInsensitive)
            guard let match = regex.firstMatch(in: url, options: [], range: NSRange(location: 0, length: url.count)) else {
                return nil
            }
            guard let nameRange = Range(match.range(at: 3), in: url) else {
                return nil
            }
            return String(url[nameRange])
        } catch {
            return nil
        }
    }
}

private struct GitHelper {
    private let git: GitShellHelper
    
    init(processSet: ProcessSet) {
        self.git = GitShellHelper(processSet: processSet)
    }
    
    func clone(_ url: Foundation.URL, to path: AbsolutePath) throws {
        _ = try self.callGit("clone", url.absoluteString, path.pathString)
    }

    func fetch(gitDirectory: AbsolutePath) throws {
        _ = try self.callGit("-C", gitDirectory.pathString, "fetch")
    }

    func checkout(_ reference: String, at gitDirectory: AbsolutePath) throws {
        _ = try self.callGit("-C", gitDirectory.pathString, "checkout", reference)
    }

    func listTags(for gitDirectory: AbsolutePath) throws -> [String] {
        let output = try self.callGit("-C", gitDirectory.pathString, "tag")
        let tags = output.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return tags
    }

    func readTag(_ tag: String, for gitDirectory: AbsolutePath) throws -> Tag? {
        // If a tag is annotated (i.e., has a message), this command will return "tag", otherwise it will return "commit".
        let tagType = try self.callGit("-C", gitDirectory.pathString, "cat-file", "-t", tag)
        guard tagType == "tag" else {
            return nil
        }
        
        // The following commands only make sense for annotated tag. Otherwise, `contents` would be
        // the message of the commit that the tag points to, which isn't always appropriate, and
        // `taggerdate` would be empty
        let message = try self.callGit("-C", gitDirectory.pathString, "tag", "-l", "--format=%(contents:subject)", tag)
        // This shows the date when the tag was created. This would be empty if the tag was created on GitHub as part of a release.
        let createdAt = try self.callGit("-C", gitDirectory.pathString, "tag", "-l", "%(taggerdate:iso8601-strict)", tag)
        return Tag(message: message, createdAt: createdAt)
    }
    
    private func callGit(_ args: String...) throws -> String {
        try self.git.run(args)
    }
    
    struct Tag {
        let message: String
        let createdAt: Date?

        private static let dateFormatter: DateFormatter = {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            return dateFormatter
        }()

        init(message: String, createdAt: String) {
            self.message = message
            self.createdAt = Self.dateFormatter.date(from: createdAt)
        }
    }
}


// MARK: - Extensions to package collection models

private extension AuthTokenType {
    static func from(type: String, host: String) -> AuthTokenType? {
        switch type {
        case "github":
            return .github(host)
        default:
            return nil
        }
    }
}

private extension PackageCollectionModel.V1.ProductType {
    init(from: PackageModel.ProductType) {
        switch from {
        case .library(let libraryType):
            self = .library(.init(from: libraryType))
        case .executable:
            self = .executable
        case .plugin:
            self = .plugin
        case .snippet:
            self = .snippet
        case .test:
            self = .test
        }
    }
}

private extension PackageCollectionModel.V1.ProductType.LibraryType {
    init(from: PackageModel.ProductType.LibraryType) {
        switch from {
        case .static:
            self = .static
        case .dynamic:
            self = .dynamic
        case .automatic:
            self = .automatic
        }
    }
}
