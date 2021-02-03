/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Dispatch
import struct Foundation.Data
import struct Foundation.Date
import class Foundation.FileManager
import struct Foundation.URL

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Security
#else
@_implementationOnly import CCryptoBoringSSL
#endif

protocol CertificatePolicy {
    /// Validates the given certificate chain.
    ///
    /// - Parameters:
    ///   - certChainPaths: Paths to each certificate in the chain. The certificate being verified must be the first element of the array,
    ///                     with its issuer the next element and so on, and the root CA certificate is last.
    ///   - callback: The callback to invoke when the result is available.
    func validate(certChain: [Certificate], callback: @escaping (Result<Bool, Error>) -> Void)
}

extension CertificatePolicy {
    #if !(os(macOS) || os(iOS) || os(watchOS) || os(tvOS))
    typealias BoringSSLVerifyCallback = @convention(c) (CInt, UnsafeMutablePointer<X509_STORE_CTX>?) -> CInt
    #endif

    /// Verifies the certificate.
    ///
    /// - Parameters:
    ///   - certChain: The entire certificate chain. The certificate being verified must be the first element of the array.
    ///   - anchorCerts: Manually specify the certificates to trust (e.g., for testing)
    ///   - verifyDate: Overrides the timestamp used for checking certificate expiry (e.g., for testing). By default the current time is used.
    ///   - queue: The  `DispatchQueue` to use for async operations
    ///   - callback: The callback to invoke when the result is available.
    func verify(certChain: [Certificate],
                anchorCerts: [Certificate]? = nil,
                verifyDate: Date? = nil,
                queue: DispatchQueue,
                callback: @escaping (Result<Bool, Error>) -> Void) {
        guard !certChain.isEmpty else {
            return callback(.failure(CertificatePolicyError.emptyCertChain))
        }

        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        let policy = SecPolicyCreateBasicX509()
        let revocationPolicy = SecPolicyCreateRevocation(kSecRevocationOCSPMethod)

        var secTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certChain.map { $0.underlying } as CFArray,
                                             [policy, revocationPolicy] as CFArray,
                                             &secTrust) == errSecSuccess,
            let trust = secTrust else {
            return callback(.failure(CertificatePolicyError.certVerificationFailure))
        }

        if let anchorCerts = anchorCerts {
            SecTrustSetAnchorCertificates(trust, anchorCerts.map { $0.underlying } as CFArray)
        }
        if let verifyDate = verifyDate {
            SecTrustSetVerifyDate(trust, verifyDate as CFDate)
        }

        queue.async {
            // This automatically searches the user's keychain and system's store for any needed
            // certificates. Passing the entire cert chain is optional and is an optimization.
            SecTrustEvaluateAsyncWithError(trust, queue) { _, isTrusted, _ in
                callback(.success(isTrusted))
            }
        }
        #else
        // Cert chain
        let x509Stack = CCryptoBoringSSL_sk_X509_new_null()
        defer { CCryptoBoringSSL_sk_X509_free(x509Stack) }

        for i in 1 ..< certChain.count {
            guard CCryptoBoringSSL_sk_X509_push(x509Stack, certChain[i].underlying) > 0 else {
                return callback(.failure(CertificatePolicyError.certVerificationFailure))
            }
        }

        // Trusted certs
        let x509Store = CCryptoBoringSSL_X509_STORE_new()
        defer { CCryptoBoringSSL_X509_STORE_free(x509Store) }

        let x509StoreCtx = CCryptoBoringSSL_X509_STORE_CTX_new()
        defer { CCryptoBoringSSL_X509_STORE_CTX_free(x509StoreCtx) }

        guard CCryptoBoringSSL_X509_STORE_CTX_init(x509StoreCtx, x509Store, certChain.first!.underlying, x509Stack) == 1 else { // !-safe since certChain cannot be empty
            return callback(.failure(CertificatePolicyError.certVerificationFailure))
        }
        CCryptoBoringSSL_X509_STORE_CTX_set_purpose(x509StoreCtx, X509_PURPOSE_ANY)

        anchorCerts?.forEach {
            CCryptoBoringSSL_X509_STORE_add_cert(x509Store, $0.underlying)
        }

        var ctxFlags: CInt = 0
        if let verifyDate = verifyDate {
            CCryptoBoringSSL_X509_STORE_CTX_set_time(x509StoreCtx, 0, Int(verifyDate.timeIntervalSince1970))
            ctxFlags = ctxFlags | X509_V_FLAG_USE_CHECK_TIME
        }
        CCryptoBoringSSL_X509_STORE_CTX_set_flags(x509StoreCtx, UInt(ctxFlags))

        let verifyCallback: BoringSSLVerifyCallback = { result, ctx in
            // Success
            if result == 1 { return result }

            // Custom error handling
            let errorCode = CCryptoBoringSSL_X509_STORE_CTX_get_error(ctx)
            // Certs could have unknown critical extensions and cause them to be rejected.
            // Instead of disabling all critical extension checks with X509_V_FLAG_IGNORE_CRITICAL
            // we will just ignore this specific error.
            if errorCode == X509_V_ERR_UNHANDLED_CRITICAL_EXTENSION {
                return 1
            }
            return result
        }
        CCryptoBoringSSL_X509_STORE_CTX_set_verify_cb(x509StoreCtx, verifyCallback)

        guard CCryptoBoringSSL_X509_verify_cert(x509StoreCtx) == 1 else {
//            let error = CCryptoBoringSSL_X509_verify_cert_error_string(Int(CCryptoBoringSSL_X509_STORE_CTX_get_error(x509StoreCtx)))
            return callback(.success(false))
        }

        // TODO: OCSP
//        if certChain.count >= 1 {
//            // Whether cert chain can be trusted depends on OCSP result
//            self.BoringSSL_OCSP_isGood(certificate: certChain[0], issuer: certChain[1], callback: callback)
//        } else {
//            callback(.success(true))
//        }
        callback(.success(true))
        #endif
    }
}

// MARK: - Supporting methods and types

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
private let infoAccessMethodOCSP = "1.3.6.1.5.5.7.48.1"
#endif

extension CertificatePolicy {
    func hasExtension(oid: String, in certificate: Certificate) throws -> Bool {
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        guard let dict = SecCertificateCopyValues(certificate.underlying, [oid as CFString] as CFArray, nil) as? [CFString: Any] else {
            throw CertificatePolicyError.extensionFailure
        }
        return !dict.isEmpty
        #else
        let nid = CCryptoBoringSSL_OBJ_create(oid, "ObjectShortName", "ObjectLongName")
        let index = CCryptoBoringSSL_X509_get_ext_by_NID(certificate.underlying, nid, -1)
        return index >= 0
        #endif
    }

    func hasExtendedKeyUsage(_ usage: CertificateExtendedKeyUsage, in certificate: Certificate) throws -> Bool {
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        guard let dict = SecCertificateCopyValues(certificate.underlying, [kSecOIDExtendedKeyUsage] as CFArray, nil) as? [CFString: Any] else {
            throw CertificatePolicyError.extensionFailure
        }
        guard let usageDict = dict[kSecOIDExtendedKeyUsage] as? [CFString: Any],
            let usages = usageDict[kSecPropertyKeyValue] as? [Data] else {
            return false
        }
        return usages.first(where: { $0 == usage.data }) != nil
        #else
        let eku = CCryptoBoringSSL_X509_get_extended_key_usage(certificate.underlying)
        return eku & UInt32(usage.flag) > 0
        #endif
    }

    /// Checks that the certificate supports OCSP. This **must** be done before calling `verify` to ensure
    /// the necessary properties are in place to trigger revocation check.
    func supportsOCSP(certificate: Certificate) throws -> Bool {
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        // Check that certificate has "Certificate Authority Information Access" extension and includes OCSP as access method.
        // The actual revocation check will be done by the Security framework in `verify`.
        guard let dict = SecCertificateCopyValues(certificate.underlying, [kSecOIDAuthorityInfoAccess] as CFArray, nil) as? [CFString: Any] else { // ignore error
            throw CertificatePolicyError.extensionFailure
        }
        guard let infoAccessDict = dict[kSecOIDAuthorityInfoAccess] as? [CFString: Any],
            let infoAccessValue = infoAccessDict[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return false
        }
        return infoAccessValue.first(where: { valueDict in valueDict[kSecPropertyKeyValue] as? String == infoAccessMethodOCSP }) != nil
        #else
        // Check that there is at least one OCSP responder URL, in which case OCSP check will take place in `verify`.
        let ocspURLs = CCryptoBoringSSL_X509_get1_ocsp(certificate.underlying)
        defer { CCryptoBoringSSL_sk_OPENSSL_STRING_free(ocspURLs) }

        return CCryptoBoringSSL_sk_OPENSSL_STRING_num(ocspURLs) > 0
        #endif
    }
}

enum CertificateExtendedKeyUsage {
    case codeSigning

    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    var data: Data {
        switch self {
        case .codeSigning:
            // https://stackoverflow.com/questions/49489591/how-to-extract-or-compare-ksecpropertykeyvalue-from-seccertificate
            // https://github.com/google/der-ascii/blob/cd91cb85bb0d71e4611856e4f76f5110609d7e42/cmd/der2ascii/oid_names.go#L100
            return Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])
        }
    }

    #else
    var flag: CInt {
        switch self {
        case .codeSigning:
            // https://www.openssl.org/docs/man1.1.0/man3/X509_get_extension_flags.html
            return XKU_CODE_SIGN
        }
    }
    #endif
}

extension CertificatePolicy {
    static func loadCerts(at directory: URL) -> [Certificate] {
        var certs = [Certificate]()
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                do {
                    certs.append(try Certificate(derEncoded: Data(contentsOf: fileURL)))
                } catch {
                    // ignore
                }
            }
        }
        return certs
    }
}

enum CertificatePolicyError: Error {
    case emptyCertChain
    case certVerificationFailure
    case extensionFailure
//    case ocspFailure
}

// TODO: actual cert policies to be implemented later
struct NoopCertificatePolicy: CertificatePolicy {
    func validate(certChain: [Certificate], callback: @escaping (Result<Bool, Error>) -> Void) {
        callback(.success(true))
    }
}

// MARK: - Certificate policies

struct AppleDeveloperCertificatePolicy: CertificatePolicy {
    private static let expectedCertChainLength = 3
    private static let appleDistributionIOSMarker = "1.2.840.113635.100.6.1.4"
    private static let appleDistributionMacOSMarker = "1.2.840.113635.100.6.1.7"
    private static let appleIntermediateMarker = "1.2.840.113635.100.6.2.1"

    let trustedRoots: [Certificate]?
    let expectedSubjectUserID: String?

    let queue: DispatchQueue

    init(trustedRootCertsDir: URL? = nil, expectedSubjectUserID: String? = nil, queue: DispatchQueue = DispatchQueue.global()) throws {
        self.trustedRoots = trustedRootCertsDir.map { Self.loadCerts(at: $0) }
        self.expectedSubjectUserID = expectedSubjectUserID
        self.queue = queue
    }

    func validate(certChain: [Certificate], callback: @escaping (Result<Bool, Error>) -> Void) {
        guard !certChain.isEmpty else {
            return callback(.failure(CertificatePolicyError.emptyCertChain))
        }
        // developer.apple.com cert chain is always 3-long
        guard certChain.count == Self.expectedCertChainLength else {
            return callback(.success(false))
        }

        do {
            // Check if subject user ID matches
            if let expectedSubjectUserID = self.expectedSubjectUserID {
                guard try certChain[0].subject().userID == expectedSubjectUserID else {
                    return callback(.success(false))
                }
            }

            // Check marker extensions (certificates issued post WWDC 2019 have both extensions but earlier ones have just one depending on platform)
            guard try (self.hasExtension(oid: Self.appleDistributionIOSMarker, in: certChain[0]) || self.hasExtension(oid: Self.appleDistributionMacOSMarker, in: certChain[0])) else {
                return callback(.success(false))
            }
            guard try self.hasExtension(oid: Self.appleIntermediateMarker, in: certChain[1]) else {
                return callback(.success(false))
            }
            // Must be a code signing certificate
            guard try self.hasExtendedKeyUsage(.codeSigning, in: certChain[0]) else {
                return callback(.success(false))
            }
            // Must support OCSP
            guard try self.supportsOCSP(certificate: certChain[0]) else {
                return callback(.success(false))
            }

            // Verify the cert chain - if it is trusted then cert chain is valid
            self.verify(certChain: certChain, anchorCerts: self.trustedRoots, queue: self.queue, callback: callback)
        } catch {
            return callback(.failure(error))
        }
    }
}

struct BasicCertificatePolicy: CertificatePolicy {
    let trustedRoots: [Certificate]?
    let expectedSubjectUserID: String?

    let queue: DispatchQueue

    init(trustedRootCertsDir: URL? = nil, expectedSubjectUserID: String? = nil, queue: DispatchQueue = DispatchQueue.global()) throws {
        self.trustedRoots = trustedRootCertsDir.map { Self.loadCerts(at: $0) }
        self.expectedSubjectUserID = expectedSubjectUserID
        self.queue = queue
    }

    func validate(certChain: [Certificate], callback: @escaping (Result<Bool, Error>) -> Void) {
        guard !certChain.isEmpty else {
            return callback(.failure(CertificatePolicyError.emptyCertChain))
        }

        do {
            // Check if subject user ID matches
            if let expectedSubjectUserID = self.expectedSubjectUserID {
                guard try certChain[0].subject().userID == expectedSubjectUserID else {
                    return callback(.success(false))
                }
            }

            // Must be a code signing certificate
            guard try self.hasExtendedKeyUsage(.codeSigning, in: certChain[0]) else {
                return callback(.success(false))
            }
            // Must support OCSP
            guard try self.supportsOCSP(certificate: certChain[0]) else {
                return callback(.success(false))
            }

            // Verify the cert chain - if it is trusted then cert chain is valid
            self.verify(certChain: certChain, anchorCerts: self.trustedRoots, queue: self.queue, callback: callback)
        } catch {
            return callback(.failure(error))
        }
    }
}
