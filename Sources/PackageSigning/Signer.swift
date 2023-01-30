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
            return .failure(.encoderInitializationError)
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
    
    public func validate(signature: Data, signs content: Data) -> Result<Void, SigningError> {
        var cmsDecoder: CMSDecoder!
        var status = CMSDecoderCreate(&cmsDecoder)
        guard status == errSecSuccess else {
            return .failure(.decoderInitializationError)
        }

        CMSDecoderSetDetachedContent(cmsDecoder, content as CFData)
        
        status = CMSDecoderUpdateMessage(cmsDecoder, [UInt8](signature), signature.count)
        guard status == errSecSuccess else {
            return .failure(.decoderInitializationError)
        }
        status = CMSDecoderFinalizeMessage(cmsDecoder)
        guard status == errSecSuccess else {
            return .failure(.decoderInitializationError)
        }
        
        var signerStatus = CMSSignerStatus.needsDetachedContent
        var trust: SecTrust?
        var certificateVerifyResult: OSStatus = errSecSuccess

        let basicPolicy = SecPolicyCreateBasicX509()
        let revocationPolicy = SecPolicyCreateRevocation(kSecRevocationOCSPMethod)
        CMSDecoderCopySignerStatus(cmsDecoder, 0, [basicPolicy, revocationPolicy] as CFArray, true, &signerStatus, &trust, &certificateVerifyResult)
        
        guard signerStatus == .valid else {
            return .failure(.invalidSignature)
        }
        guard certificateVerifyResult == errSecSuccess else {
            return .failure(.invalidCertificate)
        }
        guard let trust = trust else {
            return .failure(.untrustedCertificate)
        }

        SecTrustSetNetworkFetchAllowed(trust, true)
        // TODO: Custom trusted roots
//        SecTrustSetAnchorCertificates(trust, trustedCAs as CFArray)
//        SecTrustSetAnchorCertificatesOnly(trust, true)
        
        guard SecTrustEvaluateWithError(trust, nil) else {
            return .failure(.untrustedCertificate)
        }

        if let trustResult = SecTrustCopyResult(trust) as? [String: Any],
           let trustRevocationChecked = trustResult[kSecTrustRevocationChecked as String] as? Bool {
            if !trustRevocationChecked {
                self.observabilityScope.emit(warning: "Certificate has been revoked")
            } else {
                self.observabilityScope.emit(debug: "Certificate is valid")
            }
        } else {
            self.observabilityScope.emit(warning: "Certificate revocation status unknown")
        }
        
        return .success(())
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
    case encoderInitializationError
    case decoderInitializationError
    case invalidSignature
    case invalidCertificate
    case untrustedCertificate
    case other(String)
}
