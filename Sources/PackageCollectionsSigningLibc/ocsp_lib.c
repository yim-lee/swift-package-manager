/*
 * Copyright 2000-2020 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

#include <CCryptoBoringSSL_base.h>
#include <CCryptoBoringSSL_digest.h>
#include <CCryptoBoringSSL_obj.h>
#include "CCollectionSigning_asn1.h"
#include "CCollectionSigning_ocsp.h"
#include "CCollectionSigning_ocsp_local.h"

/* Convert a certificate and its issuer to an OCSP_CERTID */

OCSP_CERTID *OCSP_cert_to_id(const EVP_MD *dgst, const X509 *subject,
                             const X509 *issuer)
{
    X509_NAME *iname;
    const ASN1_INTEGER *serial;
    ASN1_BIT_STRING *ikey;
    if (!dgst)
        dgst = EVP_sha1();
    if (subject) {
        iname = X509_get_issuer_name(subject);
        serial = X509_get0_serialNumber(subject);
    } else {
        iname = X509_get_subject_name(issuer);
        serial = NULL;
    }
    ikey = X509_get0_pubkey_bitstr(issuer);
    return OCSP_cert_id_new(dgst, iname, ikey, serial);
}

OCSP_CERTID *OCSP_cert_id_new(const EVP_MD *dgst,
                              const X509_NAME *issuerName,
                              const ASN1_BIT_STRING *issuerKey,
                              const ASN1_INTEGER *serialNumber)
{
    int nid;
    unsigned int i;
    X509_ALGOR *alg;
    OCSP_CERTID *cid = NULL;
    unsigned char md[EVP_MAX_MD_SIZE];

    if ((cid = OCSP_CERTID_new()) == NULL)
        goto err;

    alg = cid->hashAlgorithm;
    ASN1_OBJECT_free(alg->algorithm);
    if ((nid = EVP_MD_type(dgst)) == NID_undef) {
        goto err;
    }
    if ((alg->algorithm = (ASN1_OBJECT *)OBJ_nid2obj(nid)) == NULL)
        goto err;
    if ((alg->parameter = ASN1_TYPE_new()) == NULL)
        goto err;
    alg->parameter->type = V_ASN1_NULL;

    if (!X509_NAME_digest(issuerName, dgst, md, &i))
        goto err;
    if (!(ASN1_OCTET_STRING_set(cid->issuerNameHash, md, i)))
        goto err;

    /* Calculate the issuerKey hash, excluding tag and length */
    if (!EVP_Digest(issuerKey->data, issuerKey->length, md, &i, dgst, NULL))
        goto err;

    if (!(ASN1_OCTET_STRING_set(cid->issuerKeyHash, md, i)))
        goto err;

    if (serialNumber) {
        if (ASN1_STRING_copy(cid->serialNumber, serialNumber) == 0)
            goto err;
    }
    return cid;
 err:
    OCSP_CERTID_free(cid);
    return NULL;
}

int i2d_OCSP_REQUEST_bio(BIO *out, OCSP_REQUEST *req)
{
    return ASN1_i2d_bio_of(OCSP_REQUEST, i2d_OCSP_REQUEST, out, req);
}

OCSP_RESPONSE *d2i_OCSP_RESPONSE_bio(BIO *in, OCSP_RESPONSE **res)
{
    return (OCSP_RESPONSE *)ASN1_d2i_bio_of(OCSP_RESPONSE, OCSP_RESPONSE_new, d2i_OCSP_RESPONSE, in, res);
}
