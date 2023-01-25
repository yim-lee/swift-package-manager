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
public struct SigningIdentity {
    let underlying: SecIdentity
}
#else
public struct SigningIdentity {
    let privateKey: Data
    let certificate: Data
}
#endif

public struct SigningIdentityProvider {
    private let observabilityScope: ObservabilityScope
    
    public init(observabilityScope: ObservabilityScope) {
        self.observabilityScope = observabilityScope
    }
    
    #if os(macOS)
    public func findInKeychain(label: String) throws -> SigningIdentity? {
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/certificates/storing_a_certificate_in_the_keychain
        // https://developer.apple.com/documentation/security/keychain_services/keychain_items/searching_for_keychain_items
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/storing_keys_in_the_keychain
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecAttrLabel as String: label, // Specifying only one of kSecAttrLabel or kSecMatchSubjectContains is too loose
                                    kSecMatchSubjectContains as String: label,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnRef as String: true]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            throw SigningIdentityProviderError.other("Failed to find signing identity labeled \"\(label)\" in keychain: status \(status)")
        }
        print(item)
        
        let identity: SecIdentity = item as! SecIdentity // FIXME: don't do as!
//        let certificate = item as! SecCertificate
//        
//        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/identities/creating_an_identity
//        var identity: SecIdentity?
//        let idStatus = SecIdentityCreateWithCertificate(nil, certificate, &identity)
//        guard idStatus == errSecSuccess else { return nil } // TODO: throw?
//        print(identity)
//        
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/identities/parsing_an_identity
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess else { return nil } // TODO: throw?
        print(privateKey)
        
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certStatus == errSecSuccess else { return nil } // TODO: throw?
        print(certificate)

        return SigningIdentity(underlying: identity)
    }
    #endif
}

public enum SigningIdentityProviderError: Error {
    case other(String)
}
