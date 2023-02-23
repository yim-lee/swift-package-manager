//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest

import Basics
@testable import PackageSigning
import SPMTestSupport
import TSCBasic
import X509

final class SigningTests: XCTestCase {
    #if swift(>=5.5.2)
    func testEndToEndWithIdentityFromKeychain() async throws {
        #if os(macOS)
        #if ENABLE_REAL_SIGNING_IDENTITY_TEST
        #else
        try XCTSkipIf(true)
        #endif
        #else
        throw XCTSkip("Skipping test on unsupported platform")
        #endif

        let label = ProcessInfo.processInfo.environment["REAL_SIGNING_IDENTITY_LABEL"] ?? "<USER ID>"
        let identityStore = SigningIdentityStore(observabilityScope: ObservabilitySystem.NOOP)
        let matches = try await identityStore.find(by: label)
        XCTAssertTrue(!matches.isEmpty)

        let certificate = try Certificate(secIdentity: matches[0] as! SecIdentity)
        XCTAssertNotNil(certificate.subject.commonName)
        XCTAssertNotNil(certificate.subject.organizationalUnitName)
        XCTAssertNotNil(certificate.subject.organizationName)

        let signatureProvider = SignatureProvider()
        let content = "per aspera ad astra".data(using: .utf8)!
        let signatureFormat = SignatureFormat.cms_1_0_0
        let signingIdentity = matches[0]

        // This call will trigger OS prompt(s) for key access
        let signature = try await signatureProvider.sign(
            content,
            with: signingIdentity,
            in: signatureFormat,
            observabilityScope: ObservabilitySystem.NOOP
        )

        var verifierConfiguration = VerifierConfiguration()
        verifierConfiguration.trustedRoots = try self.adpRoots()

        let status = try await signatureProvider.status(
            of: signature,
            for: content,
            in: signatureFormat,
            verifierConfiguration: verifierConfiguration,
            observabilityScope: ObservabilitySystem.NOOP
        )
        guard case .valid(let signingEntity) = status else {
            return XCTFail("Expected signature status to be .valid but got \(status)")
        }

        //        let signingEntity = try SigningEntity(of: signature, signatureFormat: signatureFormat)
        XCTAssertNotNil(signingEntity.name)
        XCTAssertNotNil(signingEntity.organizationalUnit)
        XCTAssertNotNil(signingEntity.organization)
    }
    #endif

    private func adpRoots() throws -> [Certificate] {
        var roots = [Certificate]()

        // TODO: use fixtures for this module, not Collections
        try fixture(name: "Collections", createGitRepo: false) { fixturePath in
            let intermediateCAPath = fixturePath.appending(components: "Signing", "AppleWWDRCAG3.cer")
            let intermediateCA =
                try Certificate(derEncoded: Array(localFileSystem.readFileContents(intermediateCAPath)))
            roots.append(intermediateCA)

//            let rootCAPath = fixturePath.appending(components: "Signing", "AppleIncRoot.cer")
//            let rootCA = try Certificate(derEncoded: Array(localFileSystem.readFileContents(rootCAPath)))
//            roots.append(rootCA)
        }

        return roots
    }
}
