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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
typealias Certificate = CoreCertificate
#else
typealias Certificate = BoringSSLCertificate
#endif

// MARK: - Certificate implementation using the Security framework

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
struct CoreCertificate {
    let underlying: SecCertificate

    init(derEncoded data: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CertificateError.initializationFailure
        }
        self.underlying = certificate
    }

    func subject() throws -> CertificateName {
        try self.extractName(kSecOIDX509V1SubjectName)
    }

    func issuer() throws -> CertificateName {
        try self.extractName(kSecOIDX509V1IssuerName)
    }

    private func extractName(_ name: CFString) throws -> CertificateName {
        guard let dict = SecCertificateCopyValues(self.underlying, [name] as CFArray, nil) as? [CFString: Any] else {
            throw CertificateError.nameExtractionFailure
        }

        guard let nameDict = dict[name] as? [CFString: Any],
            let propValueList = nameDict[kSecPropertyKeyValue] as? [[String: Any]] else {
            throw CertificateError.nameExtractionFailure
        }

        let props = propValueList.reduce(into: [String: String]()) { result, item in
            if let label = item["label"] as? String, let value = item["value"] as? String {
                result[label] = value
            }
        }

        return CertificateName(
            userID: props["0.9.2342.19200300.100.1.1"], // FIXME: don't hardcode
            commonName: props[kSecOIDCommonName as String],
            organization: props[kSecOIDOrganizationName as String],
            organizationalUnit: props[kSecOIDOrganizationalUnitName as String]
        )
    }
}

// MARK: - Certificate implementation using BoringSSL

#else
final class BoringSSLCertificate {
    let underlying: UnsafeMutablePointer<X509>

    deinit {
        CCryptoBoringSSL_X509_free(self.underlying)
    }

    init(derEncoded data: Data) throws {
        let bytes = data.copyBytes()
        let x509 = try bytes.withUnsafeBufferPointer { (ptr: UnsafeBufferPointer<UInt8>) throws -> UnsafeMutablePointer<X509> in
            var pointer = ptr.baseAddress
            guard let x509 = CCryptoBoringSSL_d2i_X509(nil, &pointer, bytes.count) else {
                throw CertificateError.initializationFailure
            }
            return x509
        }
        self.underlying = x509
    }

    func subject() throws -> CertificateName {
        guard let subject = CCryptoBoringSSL_X509_get_subject_name(self.underlying) else {
            throw CertificateError.nameExtractionFailure
        }
        return CertificateName(x509Name: subject)
    }

    func issuer() throws -> CertificateName {
        guard let issuer = CCryptoBoringSSL_X509_get_issuer_name(self.underlying) else {
            throw CertificateError.nameExtractionFailure
        }
        return CertificateName(x509Name: issuer)
    }
}

private extension CertificateName {
    init(x509Name: UnsafeMutablePointer<X509_NAME>) {
        self.userID = x509Name.getStringValue(of: NID_userId)
        self.commonName = x509Name.getStringValue(of: NID_commonName)
        self.organization = x509Name.getStringValue(of: NID_organizationName)
        self.organizationalUnit = x509Name.getStringValue(of: NID_organizationalUnitName)
    }
}

private extension UnsafeMutablePointer where Pointee == X509_NAME {
    func getStringValue(of nid: CInt) -> String? {
        let index = CCryptoBoringSSL_X509_NAME_get_index_by_NID(self, nid, -1)
        guard index >= 0 else {
            return nil
        }

        let entry = CCryptoBoringSSL_X509_NAME_get_entry(self, index)
        guard let data = CCryptoBoringSSL_X509_NAME_ENTRY_get_data(entry) else {
            return nil
        }

        var value: UnsafeMutablePointer<CUnsignedChar>?
        defer { CCryptoBoringSSL_OPENSSL_free(value) }

        guard CCryptoBoringSSL_ASN1_STRING_to_UTF8(&value, data) >= 0 else {
            return nil
        }

        return value.map { String(validatingUTF8: $0) } ?? nil
    }
}

private extension String {
    init?(validatingUTF8 cString: UnsafePointer<UInt8>) {
        guard let (s, _) = String.decodeCString(cString, as: UTF8.self, repairingInvalidCodeUnits: false) else {
            return nil
        }
        self = s
    }
}
#endif

struct CertificateName {
    let userID: String?
    let commonName: String?
    let organization: String?
    let organizationalUnit: String?
}

enum CertificateError: Error {
    case initializationFailure
    case nameExtractionFailure
}
