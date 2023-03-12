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

import PackageLoading
import XCTest

class ManifestSignatureParserTests: XCTestCase {
    func testHappyCase() {
        let manifest = """
        // swift-tools-version: 5.7
        
        
        // signature: cms-1.0.0;xxx
        
        """
        let components = ManifestSignatureParser.split(manifest)
        print("manifest: \(components.contentsBeforeSignatureComponents)")
        XCTAssertEqual(components.contentsBeforeSignatureComponents, """
        // swift-tools-version: 5.7
        
        
        """)
        XCTAssertEqual(components.signatureComponents?.signatureFormat, "cms-1.0.0")
        XCTAssertEqual(components.signatureComponents?.signatureBase64Encoded, "xxx")
    }
}
