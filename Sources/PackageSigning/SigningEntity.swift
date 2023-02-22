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

import struct Foundation.Data

#if os(macOS)
import Security
#endif

import SwiftASN1
import X509

// MARK: - SigningEntity is the entity that generated the signature

public struct SigningEntity {
    public let type: SigningEntityType?
    public let name: String?
    public let organizationalUnit: String?
    public let organization: String?

    public var isRecognized: Bool {
        self.type != nil
    }

    public init(of signature: Data, signatureFormat: SignatureFormat) throws {
        let provider = signatureFormat.provider
        self = try provider.signingEntity(of: signature)
    }

    // TODO: shouldn't need this
    #if os(macOS)
    init(certificate: SecCertificate) throws {
        try self.init(certificate: Certificate(certificate))
    }
    #endif

    init(certificate: Certificate) {
        self.type = certificate.signingEntityType
        self.name = certificate.subject.commonName
        self.organizationalUnit = certificate.subject.organizationalUnitName
        self.organization = certificate.subject.organizationName
    }
}

// MARK: - Types of SigningEntity that SwiftPM recognizes

public enum SigningEntityType {
    case adp // Apple Developer Program
}

extension ASN1ObjectIdentifier.NameAttributes {
    static let adpSwiftPackageMarker: ASN1ObjectIdentifier = [1, 2, 840, 113_635, 100, 6, 1, 35]
}

extension Certificate {
    var signingEntityType: SigningEntityType? {
        // TODO: check that cert is chained to WWDR roots
        if self.hasExtension(oid: ASN1ObjectIdentifier.NameAttributes.adpSwiftPackageMarker) {
            return .adp
        }
        return nil
    }
}
