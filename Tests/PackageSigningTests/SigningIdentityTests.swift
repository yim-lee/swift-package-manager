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
import PackageSigning
import SPMTestSupport

class SigningIdentityTests: XCTestCase {
    func testFindInKeychain() throws {
        #if os(macOS)
        #else
        throw XCTSkip("Skipping test on unsupported platform")
        #endif
        
        let name = "Apple Development"
        let provider = SigningIdentityProvider(observabilityScope: ObservabilitySystem.NOOP)
        let signingIdentity = try provider.findInKeychain(label: name)!
        
        let content: Data = "fluffy sheep".data(using: .utf8)!
        let signer = CMSProvider(observabilityScope: ObservabilitySystem.NOOP)
        let signature = try signer.sign(content, with: signingIdentity).get()
        print(signature.base64EncodedString())
    }
}
