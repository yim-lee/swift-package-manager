/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation
import XCTest

@testable import PackageCollectionsSigning
import SPMTestSupport
import TSCBasic

class CertificatePolicyTests: XCTestCase {
    func test_RSA_validate_happyCase() throws {
        fixture(name: "Collections") { directoryPath in
            let certPath = directoryPath.appending(components: "Signing", "Test_rsa.cer")
            let certificate = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(certPath).contents))

            let intermediateCAPath = directoryPath.appending(components: "Signing", "TestIntermediateCA_rsa.cer")
            let intermediateCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(intermediateCAPath).contents))

            let rootCAPath = directoryPath.appending(components: "Signing", "TestRootCA_rsa.cer")
            let rootCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(rootCAPath).contents))

            let certChain = [certificate, intermediateCA, rootCA]

            let policy = TestCertificatePolicy(anchorCerts: [rootCA])
            XCTAssertTrue(try tsc_await { callback in policy.validate(certChain: certChain, callback: callback) })
        }
    }

    func test_EC_validate_happyCase() throws {
        fixture(name: "Collections") { directoryPath in
            let certPath = directoryPath.appending(components: "Signing", "Test_ec.cer")
            let certificate = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(certPath).contents))

            let intermediateCAPath = directoryPath.appending(components: "Signing", "TestIntermediateCA_ec.cer")
            let intermediateCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(intermediateCAPath).contents))

            let rootCAPath = directoryPath.appending(components: "Signing", "TestRootCA_rsa.cer")
            let rootCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(rootCAPath).contents))

            let certChain = [certificate, intermediateCA, rootCA]

            let policy = TestCertificatePolicy(anchorCerts: [rootCA])
            XCTAssertTrue(try tsc_await { callback in policy.validate(certChain: certChain, callback: callback) })
        }
    }

    func test_validate_untrustedRoot() throws {
        fixture(name: "Collections") { directoryPath in
            let certPath = directoryPath.appending(components: "Signing", "Test_rsa.cer")
            let certificate = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(certPath).contents))

            let intermediateCAPath = directoryPath.appending(components: "Signing", "TestIntermediateCA_rsa.cer")
            let intermediateCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(intermediateCAPath).contents))

            let rootCAPath = directoryPath.appending(components: "Signing", "TestRootCA_rsa.cer")
            let rootCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(rootCAPath).contents))

            let certChain = [certificate, intermediateCA, rootCA]

            // Self-signed root is not trusted
            let policy = TestCertificatePolicy(anchorCerts: [])
            XCTAssertFalse(try tsc_await { callback in policy.validate(certChain: certChain, callback: callback) })
        }
    }

    func test_validate_expiredCert() throws {
        fixture(name: "Collections") { directoryPath in
            let certPath = directoryPath.appending(components: "Signing", "Test_rsa.cer")
            let certificate = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(certPath).contents))

            let intermediateCAPath = directoryPath.appending(components: "Signing", "TestIntermediateCA_rsa.cer")
            let intermediateCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(intermediateCAPath).contents))

            let rootCAPath = directoryPath.appending(components: "Signing", "TestRootCA_rsa.cer")
            let rootCA = try Certificate(derEncoded: Data(try localFileSystem.readFileContents(rootCAPath).contents))

            let certChain = [certificate, intermediateCA, rootCA]

            // Use verify date outside of cert's validity period
            let policy = TestCertificatePolicy(anchorCerts: [rootCA], verifyDate: TestCertificatePolicy.testCertInvalidDate)
            XCTAssertFalse(try tsc_await { callback in policy.validate(certChain: certChain, callback: callback) })
        }
    }
}
