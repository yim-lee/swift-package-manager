/*
 This source file is part of the Swift.org open source project

 Copyright 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
@testable import Commands
import struct Foundation.Data
import struct Foundation.URL
import PackageCollectionsModel
import PackageCollectionsSigning
import SPMTestSupport
import TSCBasic
import TSCUtility
import XCTest

private typealias GeneratorModel = PackageCollectionModel.V1

final class PackageCollectionsToolTests: XCTestCase {
    @discardableResult
    private func execute(
        _ args: [String],
        env: EnvironmentVariables? = nil
    ) throws -> (exitStatus: ProcessResult.ExitStatus, stdout: String, stderr: String) {
        let result = try SwiftPMProduct.SwiftPackageCollection.executeProcess(args, packagePath: nil, env: env)
        return try (result.exitStatus, result.utf8Output(), result.utf8stderrOutput())
    }
    
    // MARK: - Generate

    func testGenerate() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            try withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
                let archiver = ZipArchiver()
                // Prepare test package repositories
                try tsc_await { callback in archiver.extract(from: fixtureDir.appending(components: "Generator", "TestRepoOne.zip"), to: tmpDir, completion: callback) }
                try tsc_await { callback in archiver.extract(from: fixtureDir.appending(components: "Generator", "TestRepoTwo.zip"), to: tmpDir, completion: callback) }
                try tsc_await { callback in archiver.extract(from: fixtureDir.appending(components: "Generator", "TestRepoThree.zip"), to: tmpDir, completion: callback) }

                // Prepare input.json
                let input = PackageCollectionGeneratorInput(
                    name: "Test Package Collection",
                    overview: "A few test packages",
                    keywords: ["swift packages"],
                    packages: [
                        PackageCollectionGeneratorInput.Package(
                            url: URL(string: "https://package-collection-tests.com/repos/TestRepoOne.git")!,
                            summary: "Package Foo"
                        ),
                        PackageCollectionGeneratorInput.Package(
                            url: URL(string: "https://package-collection-tests.com/repos/TestRepoTwo.git")!,
                            summary: "Package Foo & Bar"
                        ),
                        PackageCollectionGeneratorInput.Package(
                            url: URL(string: "https://package-collection-tests.com/repos/TestRepoThree.git")!,
                            summary: "Package Baz",
                            versions: ["1.0.0"]
                        ),
                    ]
                )
                let jsonEncoder = JSONEncoder.makeWithDefaults()
                let inputData = try jsonEncoder.encode(input)
                let inputFilePath = tmpDir.appending(component: "input.json")
                try localFileSystem.writeFileContents(inputFilePath, bytes: ByteString(inputData))

                let expectedPackages = [
                    GeneratorModel.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoOne.git")!,
                        summary: "Package Foo",
                        keywords: nil,
                        versions: [
                            GeneratorModel.Collection.Package.Version(
                                version: "0.1.0",
                                summary: nil,
                                manifests: [
                                    "5.2": GeneratorModel.Collection.Package.Version.Manifest(
                                        toolsVersion: "5.2",
                                        packageName: "TestPackageOne",
                                        targets: [.init(name: "Foo", moduleName: "Foo")],
                                        products: [.init(name: "Foo", type: .library(.automatic), targets: ["Foo"])],
                                        minimumPlatformVersions: [.init(name: "macos", version: "10.15")]
                                    ),
                                ],
                                defaultToolsVersion: "5.2",
                                verifiedCompatibility: nil,
                                license: nil,
                                createdAt: nil
                            ),
                        ],
                        readmeURL: nil,
                        license: nil
                    ),
                    GeneratorModel.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoTwo.git")!,
                        summary: "Package Foo & Bar",
                        keywords: nil,
                        versions: [
                            GeneratorModel.Collection.Package.Version(
                                version: "0.2.0",
                                summary: nil,
                                manifests: [
                                    "5.2": GeneratorModel.Collection.Package.Version.Manifest(
                                        toolsVersion: "5.2",
                                        packageName: "TestPackageTwo",
                                        targets: [
                                            .init(name: "Bar", moduleName: "Bar"),
                                            .init(name: "Foo", moduleName: "Foo"),
                                        ],
                                        products: [
                                            .init(name: "Bar", type: .library(.automatic), targets: ["Bar"]),
                                            .init(name: "Foo", type: .library(.automatic), targets: ["Foo"]),
                                        ],
                                        minimumPlatformVersions: []
                                    ),
                                ],
                                defaultToolsVersion: "5.2",
                                verifiedCompatibility: nil,
                                license: nil,
                                createdAt: nil
                            ),
                            GeneratorModel.Collection.Package.Version(
                                version: "0.1.0",
                                summary: nil,
                                manifests: [
                                    "5.2": GeneratorModel.Collection.Package.Version.Manifest(
                                        toolsVersion: "5.2",
                                        packageName: "TestPackageTwo",
                                        targets: [.init(name: "Bar", moduleName: "Bar")],
                                        products: [.init(name: "Bar", type: .library(.automatic), targets: ["Bar"])],
                                        minimumPlatformVersions: []
                                    ),
                                ],
                                defaultToolsVersion: "5.2",
                                verifiedCompatibility: nil,
                                license: nil,
                                createdAt: nil
                            ),
                        ],
                        readmeURL: nil,
                        license: nil
                    ),
                    GeneratorModel.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoThree.git")!,
                        summary: "Package Baz",
                        keywords: nil,
                        versions: [
                            GeneratorModel.Collection.Package.Version(
                                version: "1.0.0",
                                summary: nil,
                                manifests: [
                                    "5.2": GeneratorModel.Collection.Package.Version.Manifest(
                                        toolsVersion: "5.2",
                                        packageName: "TestPackageThree",
                                        targets: [.init(name: "Baz", moduleName: "Baz")],
                                        products: [.init(name: "Baz", type: .library(.automatic), targets: ["Baz"])],
                                        minimumPlatformVersions: []
                                    ),
                                ],
                                defaultToolsVersion: "5.2",
                                verifiedCompatibility: nil,
                                license: nil,
                                createdAt: nil
                            ),
                        ],
                        readmeURL: nil,
                        license: nil
                    ),
                ]

                // Run command with both pretty-printed enabled and disabled (which is the default, with no flag).
                for prettyFlag in ["--pretty-printed", nil] {
                    // Where to write the generated collection
                    let outputFilePath = tmpDir.appending(component: "package-collection\(prettyFlag ?? "").json")
                    // `tmpDir` is where we extract the repos so use it as the working directory so we don't actually do any cloning
                    let workingDirectoryPath = tmpDir

                    let flags = [
                        "--verbose",
                        prettyFlag,
                        inputFilePath.pathString,
                        outputFilePath.pathString,
                        "--working-directory-path",
                        workingDirectoryPath.pathString,
                    ].compactMap { $0 }
                    let cmd = try SwiftPackageCollectionsTool.Generate.parse(flags)
                    try cmd.run()

                    let jsonDecoder = JSONDecoder.makeWithDefaults()

                    // Assert the generated package collection
                    let collectionData = try localFileSystem.readFileContents(outputFilePath).contents
                    let packageCollection = try jsonDecoder.decode(GeneratorModel.Collection.self, from: Data(collectionData))
                    XCTAssertEqual(input.name, packageCollection.name)
                    XCTAssertEqual(input.overview, packageCollection.overview)
                    XCTAssertEqual(input.keywords, packageCollection.keywords)
                    XCTAssertEqual(expectedPackages, packageCollection.packages)

                    #if os(macOS) // XCTAttachment is available in Xcode only
                    add(XCTAttachment(contentsOfFile: outputFilePath.asURL))
                    #endif
                }
            }
        }
    }

    func testGenerateWithExcludedVersions() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            try withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
                let archiver = ZipArchiver()
                // Prepare test package repositories
                try tsc_await { callback in archiver.extract(from: fixtureDir.appending(components: "Generator", "TestRepoOne.zip"), to: tmpDir, completion: callback) }
                try tsc_await { callback in archiver.extract(from: fixtureDir.appending(components: "Generator", "TestRepoTwo.zip"), to: tmpDir, completion: callback) }

                // Prepare input.json
                let input = PackageCollectionGeneratorInput(
                    name: "Test Package Collection",
                    overview: "A few test packages",
                    keywords: ["swift packages"],
                    packages: [
                        PackageCollectionGeneratorInput.Package(
                            url: URL(string: "https://package-collection-tests.com/repos/TestRepoOne.git")!,
                            summary: "Package Foo"
                        ),
                        PackageCollectionGeneratorInput.Package(
                            url: URL(string: "https://package-collection-tests.com/repos/TestRepoTwo.git")!,
                            summary: "Package Foo & Bar",
                            excludedVersions: ["0.1.0"]
                        ),
                    ]
                )
                let jsonEncoder = JSONEncoder.makeWithDefaults()
                let inputData = try jsonEncoder.encode(input)
                let inputFilePath = tmpDir.appending(component: "input.json")
                try localFileSystem.writeFileContents(inputFilePath, bytes: ByteString(inputData))

                // Where to write the generated collection
                let outputFilePath = tmpDir.appending(component: "package-collection.json")
                // `tmpDir` is where we extract the repos so use it as the working directory so we don't actually do any cloning
                let workingDirectoryPath = tmpDir

                let cmd = try SwiftPackageCollectionsTool.Generate.parse([
                    "--verbose",
                    inputFilePath.pathString,
                    outputFilePath.pathString,
                    "--working-directory-path",
                    workingDirectoryPath.pathString,
                ])
                try cmd.run()

                let expectedPackages = [
                    GeneratorModel.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoOne.git")!,
                        summary: "Package Foo",
                        keywords: nil,
                        versions: [
                            GeneratorModel.Collection.Package.Version(
                                version: "0.1.0",
                                summary: nil,
                                manifests: [
                                    "5.2": GeneratorModel.Collection.Package.Version.Manifest(
                                        toolsVersion: "5.2",
                                        packageName: "TestPackageOne",
                                        targets: [.init(name: "Foo", moduleName: "Foo")],
                                        products: [.init(name: "Foo", type: .library(.automatic), targets: ["Foo"])],
                                        minimumPlatformVersions: [.init(name: "macos", version: "10.15")]
                                    ),
                                ],
                                defaultToolsVersion: "5.2",
                                verifiedCompatibility: nil,
                                license: nil,
                                createdAt: nil
                            ),
                        ],
                        readmeURL: nil,
                        license: nil
                    ),
                    GeneratorModel.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoTwo.git")!,
                        summary: "Package Foo & Bar",
                        keywords: nil,
                        versions: [
                            GeneratorModel.Collection.Package.Version(
                                version: "0.2.0",
                                summary: nil,
                                manifests: [
                                    "5.2": GeneratorModel.Collection.Package.Version.Manifest(
                                        toolsVersion: "5.2",
                                        packageName: "TestPackageTwo",
                                        targets: [
                                            .init(name: "Bar", moduleName: "Bar"),
                                            .init(name: "Foo", moduleName: "Foo"),
                                        ],
                                        products: [
                                            .init(name: "Bar", type: .library(.automatic), targets: ["Bar"]),
                                            .init(name: "Foo", type: .library(.automatic), targets: ["Foo"]),
                                        ],
                                        minimumPlatformVersions: []
                                    ),
                                ],
                                defaultToolsVersion: "5.2",
                                verifiedCompatibility: nil,
                                license: nil,
                                createdAt: nil
                            ),
                        ],
                        readmeURL: nil,
                        license: nil
                    ),
                ]

                let jsonDecoder = JSONDecoder.makeWithDefaults()

                // Assert the generated package collection
                let collectionData = try localFileSystem.readFileContents(outputFilePath).contents
                let packageCollection = try jsonDecoder.decode(GeneratorModel.Collection.self, from: Data(collectionData))
                XCTAssertEqual(input.name, packageCollection.name)
                XCTAssertEqual(input.overview, packageCollection.overview)
                XCTAssertEqual(input.keywords, packageCollection.keywords)
                XCTAssertEqual(expectedPackages, packageCollection.packages)
            }
        }
    }
    
    // MARK: - Sign
    
    func testSign() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            try withTemporaryDirectory(removeTreeOnDeinit: true) { tmpDir in
                let inputPath = fixtureDir.appending(components: "Generator", "valid.json")
                let outputPath = tmpDir.appending(component: "test_collection_signed.json")
                // These are not actually used since we are using MockPackageCollectionSigner
                let privateKeyPath = fixtureDir.appending(components: "Signing", "Test_ec_key.pem")
                let certPath = fixtureDir.appending(components: "Signing", "Test_ec.cer")

                let cmd = try SwiftPackageCollectionsTool.Sign.parse([
                    inputPath.pathString,
                    outputPath.pathString,
                    privateKeyPath.pathString,
                    certPath.pathString,
                ])

                let swiftTool = try SwiftTool(options: cmd.swiftOptions)
                // We don't have real certs so we have to use a mock signer
                let signer = MockPackageCollectionSigner()
                try cmd.run(swiftTool, customSigner: signer)

                let jsonDecoder = JSONDecoder.makeWithDefaults()

                // Assert the generated package collection
                let bytes = try localFileSystem.readFileContents(outputPath).contents
                let signedCollection = try jsonDecoder.decode(GeneratorModel.SignedCollection.self, from: Data(bytes))
                XCTAssertEqual("test signature", signedCollection.signature.signature)
            }
        }
    }
    
    // MARK: - Validate
    
    func testValidateGood() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPath = fixtureDir.appending(components: "Generator", "valid.json")
            let result = try self.execute([
                "validate",
                inputPath.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 0))
            XCTAssert(result.stdout.contains("package collection is valid"), "got stdout:\n" + result.stdout)
        }
    }

    func testValidateBadJSON() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPath = fixtureDir.appending(components: "Generator", "bad.json")
            let result = try self.execute([
                "validate",
                inputPath.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 1))
            XCTAssert(result.stdout.contains("Failed to parse package collection"), "got stdout:\n" + result.stdout)
        }
    }

    func testValidateCollectionWithErrors() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPath = fixtureDir.appending(components: "Generator", "error-no-packages.json")
            let result = try self.execute([
                "validate",
                inputPath.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 1))
            XCTAssert(result.stdout.contains("must contain at least one package"), "got stdout:\n" + result.stdout)
        }
    }

    func testValidateCollectionWithWarnings() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPath = fixtureDir.appending(components: "Generator", "warning-too-many-versions.json")
            let result = try self.execute([
                "validate",
                inputPath.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 0))
            XCTAssert(result.stdout.contains("includes too many major versions"), "got stdout:\n" + result.stdout)
        }
    }

    func testValidateWarningsAsErrors() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPath = fixtureDir.appending(components: "Generator", "warning-too-many-versions.json")
            let result = try self.execute([
                "validate",
                "--warnings-as-errors",
                inputPath.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 1))
            XCTAssert(result.stdout.contains("includes too many major versions"), "got stdout:\n" + result.stdout)
        }
    }
    
    // MARK: - Diff
    
    func testDiffSameCollections() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPath = fixtureDir.appending(components: "Generator", "diff.json")
            let result = try self.execute([
                "diff",
                inputPath.pathString,
                inputPath.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 0))
            XCTAssert(result.stdout.contains("package collections are the same"), "got stdout:\n" + result.stdout)
        }
    }

    func testDiffCollectionsWithDifferentGeneratedAt() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPathOne = fixtureDir.appending(components: "Generator", "diff.json")
            let inputPathTwo = fixtureDir.appending(components: "Generator", "diff_generated_at.json")
            let result = try self.execute([
                "diff",
                inputPathOne.pathString,
                inputPathTwo.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 0))
            XCTAssert(result.stdout.contains("package collections are the same"), "got stdout:\n" + result.stdout)
        }
    }

    func testDiffCollectionsWithDifferentPackages() throws {
        fixture(name: "Collections", createGitRepo: false) { fixtureDir in
            let inputPathOne = fixtureDir.appending(components: "Generator", "diff.json")
            let inputPathTwo = fixtureDir.appending(components: "Generator", "diff_packages.json")
            let result = try self.execute([
                "diff",
                inputPathOne.pathString,
                inputPathTwo.pathString
            ])
            XCTAssertEqual(result.exitStatus, .terminated(code: 0))
            XCTAssert(result.stdout.contains("package collections are different"), "got stdout:\n" + result.stdout)
        }
    }
}

private struct MockPackageCollectionSigner: PackageCollectionSigner {
    func sign(collection: GeneratorModel.Collection,
              certChainPaths: [Foundation.URL],
              privateKeyPEM: Data,
              certPolicyKey: CertificatePolicyKey,
              callback: @escaping (Result<GeneratorModel.SignedCollection, Error>) -> Void)
    {
        let signature = GeneratorModel.Signature(
            signature: "test signature",
            certificate: GeneratorModel.Signature.Certificate(
                subject: GeneratorModel.Signature.Certificate.Name(
                    userID: "test user id",
                    commonName: "test subject",
                    organizationalUnit: "test unit",
                    organization: "test org"
                ),
                issuer: GeneratorModel.Signature.Certificate.Name(
                    userID: nil,
                    commonName: "test issuer",
                    organizationalUnit: "test unit",
                    organization: "test org"
                )
            )
        )
        callback(.success(GeneratorModel.SignedCollection(collection: collection, signature: signature)))
    }
}
