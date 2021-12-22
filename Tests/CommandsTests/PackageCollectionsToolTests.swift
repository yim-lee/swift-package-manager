/*
 This source file is part of the Swift.org open source project

 Copyright 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
@testable import Commands
import PackageCollectionsModel
import SPMTestSupport
import TSCBasic
import TSCUtility
import XCTest

final class PackageCollectionsToolTests: XCTestCase {
    typealias Model = PackageCollectionModel.V1

    func testGenerate() throws {
        fixture(name: "Collections") { fixtureDir in
            try withTemporaryDirectory(removeTreeOnDeinit: false) { tmpDir in
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
                    Model.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoOne.git")!,
                        summary: "Package Foo",
                        keywords: nil,
                        versions: [
                            Model.Collection.Package.Version(
                                version: "0.1.0",
                                summary: nil,
                                manifests: [
                                    "5.2": Model.Collection.Package.Version.Manifest(
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
                    Model.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoTwo.git")!,
                        summary: "Package Foo & Bar",
                        keywords: nil,
                        versions: [
                            Model.Collection.Package.Version(
                                version: "0.2.0",
                                summary: nil,
                                manifests: [
                                    "5.2": Model.Collection.Package.Version.Manifest(
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
                            Model.Collection.Package.Version(
                                version: "0.1.0",
                                summary: nil,
                                manifests: [
                                    "5.2": Model.Collection.Package.Version.Manifest(
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
                    Model.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoThree.git")!,
                        summary: "Package Baz",
                        keywords: nil,
                        versions: [
                            Model.Collection.Package.Version(
                                version: "1.0.0",
                                summary: nil,
                                manifests: [
                                    "5.2": Model.Collection.Package.Version.Manifest(
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
                    let packageCollection = try jsonDecoder.decode(Model.Collection.self, from: Data(collectionData))
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
        fixture(name: "Collections") { fixtureDir in
            try withTemporaryDirectory(removeTreeOnDeinit: false) { tmpDir in
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
                    Model.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoOne.git")!,
                        summary: "Package Foo",
                        keywords: nil,
                        versions: [
                            Model.Collection.Package.Version(
                                version: "0.1.0",
                                summary: nil,
                                manifests: [
                                    "5.2": Model.Collection.Package.Version.Manifest(
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
                    Model.Collection.Package(
                        url: URL(string: "https://package-collection-tests.com/repos/TestRepoTwo.git")!,
                        summary: "Package Foo & Bar",
                        keywords: nil,
                        versions: [
                            Model.Collection.Package.Version(
                                version: "0.2.0",
                                summary: nil,
                                manifests: [
                                    "5.2": Model.Collection.Package.Version.Manifest(
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
                let packageCollection = try jsonDecoder.decode(Model.Collection.self, from: Data(collectionData))
                XCTAssertEqual(input.name, packageCollection.name)
                XCTAssertEqual(input.overview, packageCollection.overview)
                XCTAssertEqual(input.keywords, packageCollection.keywords)
                XCTAssertEqual(expectedPackages, packageCollection.packages)
            }
        }
    }
}
