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

class ECKeySigningTests: XCTestCase {
    func test_signAndValidate_happyCase() throws {
        fixture(name: "Collections") { directoryPath in
            let privateKeyPath = directoryPath.appending(components: "Signing", "ec_private.pem")
            let privateKey = try ECPrivateKey(pem: readPEM(path: privateKeyPath))

            let publicKeyPath = directoryPath.appending(components: "Signing", "ec_public.pem")
            let publicKey = try ECPublicKey(pem: readPEM(path: publicKeyPath))

            let message = try JSONEncoder().encode(["foo": "bar"])
            let signature = try privateKey.sign(message: message)
            XCTAssertTrue(try publicKey.isValidSignature(signature, for: message))
        }
    }

    func test_signAndValidate_mismatch() throws {
        fixture(name: "Collections") { directoryPath in
            let privateKeyPath = directoryPath.appending(components: "Signing", "ec_private.pem")
            let privateKey = try ECPrivateKey(pem: readPEM(path: privateKeyPath))

            let publicKeyPath = directoryPath.appending(components: "Signing", "ec_public.pem")
            let publicKey = try ECPublicKey(pem: readPEM(path: publicKeyPath))

            let jsonEncoder = JSONEncoder()
            let message = try jsonEncoder.encode(["foo": "bar"])
            let otherMessage = try jsonEncoder.encode(["foo": "baz"])
            let signature = try privateKey.sign(message: message)
            XCTAssertFalse(try publicKey.isValidSignature(signature, for: otherMessage))
        }
    }
}
