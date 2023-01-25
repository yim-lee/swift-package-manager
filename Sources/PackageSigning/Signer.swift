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

import Basics

#if os(macOS)
import Security
#endif

#if os(macOS)
public struct CMSProvider {
    private let observabilityScope: ObservabilityScope
    
    public init(observabilityScope: ObservabilityScope) {
        self.observabilityScope = observabilityScope
    }
    
    public func sign(_ content: Data, with signingIdentity: SigningIdentity) -> Result<Data, SigningError> {
        // TODO: This code triggers system password/authorization prompt
        var cmsEncoder: CMSEncoder!
        var status = CMSEncoderCreate(&cmsEncoder)
        guard status == errSecSuccess else {
            return .failure(SigningError.initializationError)
        }

        CMSEncoderAddSigners(cmsEncoder, signingIdentity.underlying)
        CMSEncoderSetHasDetachedContent(cmsEncoder, true)

        CMSEncoderSetSignerAlgorithm(cmsEncoder, kCMSEncoderDigestAlgorithmSHA256)
        CMSEncoderAddSignedAttributes(cmsEncoder, CMSSignedAttributes.attrSigningTime)
        CMSEncoderSetCertificateChainMode(cmsEncoder, .chainWithRoot)

        var contentArray = Array(content)
        CMSEncoderUpdateContent(cmsEncoder, &contentArray, content.count)

        var signature: CFData!
        status = CMSEncoderCopyEncodedContent(cmsEncoder, &signature)
        guard status == errSecSuccess else {
            return .failure(SigningError.other("Signing failed with error \(status)"))
        }

        return .success(signature as Data)
    }
}
#else
public struct CMSProvider {
    public func sign(_ content: Data, with signingIdentity: SigningIdentity) -> Result<Data, SigningError> {
        fatalError("TO BE IMPLEMENTED")
    }
}
#endif

public enum SigningError: Error {
    case initializationError
    case other(String)
}
