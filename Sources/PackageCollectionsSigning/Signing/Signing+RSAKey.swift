/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import struct Foundation.Data

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Security
#else
@_implementationOnly import CCryptoBoringSSL
#endif

// MARK: - MessageSigner and MessageValidator conformance using the Security framework

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
extension CoreRSAPrivateKey {
    func sign(message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(self.underlying,
                                                    .rsaSignatureMessagePKCS1v15SHA256,
                                                    message as CFData,
                                                    &error) as Data? else {
            throw error.map { $0.takeRetainedValue() as Error } ?? SigningError.signFailure
        }
        return signature
    }
}

extension CoreRSAPublicKey {
    func isValidSignature(_ signature: Data, for message: Data) throws -> Bool {
        SecKeyVerifySignature(
            self.underlying,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            signature as CFData,
            nil // no-match is considered an error as well so we would rather not trap it
        )
    }
}

// MARK: - MessageSigner and MessageValidator conformance using BoringSSL

#else
// Reference: https://github.com/vapor/jwt-kit/blob/master/Sources/JWTKit/RSA/RSASigner.swift

extension BoringSSLRSAPrivateKey: BoringSSLSigning {
    func sign(message: Data) throws -> Data {
        guard let algorithm = CCryptoBoringSSL_EVP_sha256() else {
            throw SigningError.algorithmFailure
        }

        let digest = try self.digest(message, algorithm: algorithm)

        var signatureLength: UInt32 = 0
        var signature = [UInt8](
            repeating: 0,
            count: Int(CCryptoBoringSSL_RSA_size(self.underlying))
        )

        guard CCryptoBoringSSL_RSA_sign(
            CCryptoBoringSSL_EVP_MD_type(algorithm),
            digest,
            numericCast(digest.count),
            &signature,
            &signatureLength,
            self.underlying
        ) == 1 else {
            throw SigningError.signFailure
        }

        return Data(signature[0 ..< numericCast(signatureLength)])
    }
}

extension BoringSSLRSAPublicKey: BoringSSLSigning {
    func isValidSignature(_ signature: Data, for message: Data) throws -> Bool {
        guard let algorithm = CCryptoBoringSSL_EVP_sha256() else {
            throw SigningError.algorithmFailure
        }

        let digest = try self.digest(message, algorithm: algorithm)
        let signature = signature.copyBytes()

        return CCryptoBoringSSL_RSA_verify(
            CCryptoBoringSSL_EVP_MD_type(algorithm),
            digest,
            numericCast(digest.count),
            signature,
            numericCast(signature.count),
            self.underlying
        ) == 1
    }
}
#endif
