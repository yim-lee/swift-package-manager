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

import Basics
import SwiftASN1
@_spi(CMS) import X509

public struct SignatureProvider {
    public init() {}

    public func sign(
        _ content: Data,
        with identity: SigningIdentity,
        in format: SignatureFormat,
        observabilityScope: ObservabilityScope
    ) async throws -> Data {
        let provider = format.provider
        return try await provider.sign(content, with: identity, observabilityScope: observabilityScope)
    }

    public func status(
        of signature: Data,
        for content: Data,
        in format: SignatureFormat,
        verifierConfiguration: VerifierConfiguration,
        observabilityScope: ObservabilityScope
    ) async throws -> SignatureStatus {
        let provider = format.provider
        return try await provider.status(
            of: signature,
            for: content,
            verifierConfiguration: verifierConfiguration,
            observabilityScope: observabilityScope
        )
    }
}

public struct VerifierConfiguration {
    public var trustedRoots: [Certificate]
    public var certificateExpiration: CertificateExpiration
    public var certificateRevocation: CertificateRevocation

    public init() {
        self.trustedRoots = []
        self.certificateExpiration = .disabled
        self.certificateRevocation = .disabled
    }

    public enum CertificateExpiration {
        case enabled
        case disabled
    }

    public enum CertificateRevocation {
        case strict
        case allowSoftFail
        case disabled
    }
}

public enum SignatureStatus: Equatable {
    case valid(SigningEntity)
    case doesNotConformToSignatureFormat(String)
    case certificateInvalid(String)
    case certificateNotTrusted
}

extension Certificate {
    public enum RevocationStatus {
        case valid
        case revoked
        case unknown
    }
}

public enum SigningError: Error {
    case encodeInitializationFailed(String)
    case decodeInitializationFailed(String)
    case signingFailed(String)
    case signatureInvalid(String)
}

protocol SignatureProviderProtocol {
    func sign(
        _ content: Data,
        with identity: SigningIdentity,
        observabilityScope: ObservabilityScope
    ) async throws -> Data

    func status(
        of signature: Data,
        for content: Data,
        verifierConfiguration: VerifierConfiguration,
        observabilityScope: ObservabilityScope
    ) async throws -> SignatureStatus

    func signingEntity(of signature: Data) throws -> SigningEntity
}

public enum SignatureFormat: String {
    case cms_1_0_0 = "cms-1.0.0"

    var provider: SignatureProviderProtocol {
        switch self {
        case .cms_1_0_0:
            return CMSSignatureProvider(format: self)
        }
    }
}

struct CMSSignatureProvider: SignatureProviderProtocol {
    let format: SignatureFormat

    init(format: SignatureFormat) {
        precondition(format.rawValue.hasPrefix("cms-"), "Unsupported signature format '\(format)'")
        self.format = format
    }

    func sign(
        _ content: Data,
        with identity: SigningIdentity,
        observabilityScope: ObservabilityScope
    ) async throws -> Data {
        try self.validate(identity: identity)

        #if os(macOS)
        if CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() {
            let secIdentity = identity as! SecIdentity // !-safe because we ensure type above

            var privateKey: SecKey?
            let keyStatus = SecIdentityCopyPrivateKey(secIdentity, &privateKey)
            guard keyStatus == errSecSuccess, let privateKey = privateKey else {
                throw SigningError.signingFailed("Unable to get private key from SecIdentity. Error: \(keyStatus)")
            }

            var error: Unmanaged<CFError>?
            // TODO: algorithm depends on signature format
            guard let signatureData = SecKeyCreateSignature(
                privateKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                // .ecdsaSignatureMessageX962SHA256,
                content as CFData,
                &error
            ) as Data? else {
                if let error = error?.takeRetainedValue() as Error? {
                    throw SigningError.signingFailed("\(error)")
                }
                throw SigningError.signingFailed("Failed to sign with SecIdentity")
            }

            let signature = try CMS.sign(
                signatureBytes: ASN1OctetString(contentBytes: ArraySlice(signatureData)),
                signatureAlgorithm: .sha256WithRSAEncryption,
                certificate: try Certificate(secIdentity: secIdentity)
            )
            return Data(signature)
        } else {
            fatalError("TO BE IMPLEMENTED")
        }
        #else
        fatalError("TO BE IMPLEMENTED")
        #endif
    }

    func status(
        of signature: Data,
        for content: Data,
        verifierConfiguration: VerifierConfiguration,
        observabilityScope: ObservabilityScope
    ) async throws -> SignatureStatus {
        let result = await CMS.isValidSignature(
            dataBytes: content,
            signatureBytes: signature,
            trustRoots: CertificateStore(verifierConfiguration.trustedRoots),
            policy: PolicySet(policies: [])
        )

        switch result {
        case .validSignature(let valid):
            let signingEntity = SigningEntity(certificate: valid.signer)
            return .valid(signingEntity)
        case .unableToValidateSigner(let failure):
            if failure.validationFailures.isEmpty {
                return .certificateNotTrusted
            } else {
                return .certificateInvalid("\(failure.validationFailures)") // TODO: format error message
            }
        case .invalidCMSBlock(let error):
            return .doesNotConformToSignatureFormat(error.reason)
        }
    }

    func signingEntity(of signature: Data) throws -> SigningEntity {
        #if os(macOS)
        var cmsDecoder: CMSDecoder?
        var status = CMSDecoderCreate(&cmsDecoder)
        guard status == errSecSuccess, let cmsDecoder = cmsDecoder else {
            throw SigningError.decodeInitializationFailed("Unable to create CMSDecoder. Error: \(status)")
        }

        status = CMSDecoderUpdateMessage(cmsDecoder, [UInt8](signature), signature.count)
        guard status == errSecSuccess else {
            throw SigningError
                .decodeInitializationFailed("Unable to update CMSDecoder with signature. Error: \(status)")
        }
        status = CMSDecoderFinalizeMessage(cmsDecoder)
        guard status == errSecSuccess else {
            throw SigningError.decodeInitializationFailed("Failed to set up CMSDecoder. Error: \(status)")
        }

        var certificate: SecCertificate?
        status = CMSDecoderCopySignerCert(cmsDecoder, 0, &certificate)
        guard status == errSecSuccess, let certificate = certificate else {
            throw SigningError.signatureInvalid("Unable to extract signing certificate. Error: \(status)")
        }

        return try SigningEntity(certificate: Certificate(secCertificate: certificate))
        #else
        fatalError("TO BE IMPLEMENTED")
        #endif
    }

    private func validate(identity: SigningIdentity) throws {
        switch self.format {
        case .cms_1_0_0:
            // TODO: key must be EC
            ()
        }
    }
}
