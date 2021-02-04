/*
 * Copyright 2000-2019 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the OpenSSL license (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

#ifndef C_COLLECTION_SIGNING_HEADER_OCSP_H
#define C_COLLECTION_SIGNING_HEADER_OCSP_H

#include <CCryptoBoringSSL_stack.h>
#include <CCryptoBoringSSL_base.h>
#include <CCryptoBoringSSL_x509.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define NID_id_pkix_OCSP_basic          365

typedef struct ocsp_cert_id_st OCSP_CERTID;

DEFINE_STACK_OF(OCSP_CERTID)

typedef struct ocsp_one_request_st OCSP_ONEREQ;

DEFINE_STACK_OF(OCSP_ONEREQ)

typedef struct ocsp_req_info_st OCSP_REQINFO;
typedef struct ocsp_signature_st OCSP_SIGNATURE;
typedef struct ocsp_request_st OCSP_REQUEST;

typedef struct ocsp_resp_bytes_st OCSP_RESPBYTES;

#define OCSP_RESPONSE_STATUS_SUCCESSFUL           0
#define OCSP_RESPONSE_STATUS_MALFORMEDREQUEST     1
#define OCSP_RESPONSE_STATUS_INTERNALERROR        2
#define OCSP_RESPONSE_STATUS_TRYLATER             3
#define OCSP_RESPONSE_STATUS_SIGREQUIRED          5
#define OCSP_RESPONSE_STATUS_UNAUTHORIZED         6

typedef struct ocsp_response_st OCSP_RESPONSE;

#define V_OCSP_RESPID_NAME 0
#define V_OCSP_RESPID_KEY  1

typedef struct ocsp_responder_id_st OCSP_RESPID;

DEFINE_STACK_OF(OCSP_RESPID)

typedef struct ocsp_revoked_info_st OCSP_REVOKEDINFO;

#define V_OCSP_CERTSTATUS_GOOD    0
#define V_OCSP_CERTSTATUS_REVOKED 1
#define V_OCSP_CERTSTATUS_UNKNOWN 2

typedef struct ocsp_cert_status_st OCSP_CERTSTATUS;
typedef struct ocsp_single_response_st OCSP_SINGLERESP;

DEFINE_STACK_OF(OCSP_SINGLERESP)

typedef struct ocsp_response_data_st OCSP_RESPDATA;

typedef struct ocsp_basic_response_st OCSP_BASICRESP;

OCSP_CERTID *OCSP_cert_to_id(const EVP_MD *dgst, const X509 *subject,
                             const X509 *issuer);

OCSP_CERTID *OCSP_cert_id_new(const EVP_MD *dgst,
                              const X509_NAME *issuerName,
                              const ASN1_BIT_STRING *issuerKey,
                              const ASN1_INTEGER *serialNumber);

OCSP_ONEREQ *OCSP_request_add0_id(OCSP_REQUEST *req, OCSP_CERTID *cid);

DECLARE_ASN1_FUNCTIONS(OCSP_CERTID)
DECLARE_ASN1_FUNCTIONS(OCSP_ONEREQ)
DECLARE_ASN1_FUNCTIONS(OCSP_REQINFO)
DECLARE_ASN1_FUNCTIONS(OCSP_SIGNATURE)
DECLARE_ASN1_FUNCTIONS(OCSP_REQUEST)
DECLARE_ASN1_FUNCTIONS(OCSP_RESPBYTES)
DECLARE_ASN1_FUNCTIONS(OCSP_RESPONSE)
DECLARE_ASN1_FUNCTIONS(OCSP_RESPID)
DECLARE_ASN1_FUNCTIONS(OCSP_REVOKEDINFO)
DECLARE_ASN1_FUNCTIONS(OCSP_CERTSTATUS)
DECLARE_ASN1_FUNCTIONS(OCSP_SINGLERESP)
DECLARE_ASN1_FUNCTIONS(OCSP_RESPDATA)
DECLARE_ASN1_FUNCTIONS(OCSP_BASICRESP)

int i2d_OCSP_REQUEST_bio(BIO *out, OCSP_REQUEST *req);
OCSP_RESPONSE *d2i_OCSP_RESPONSE_bio(BIO *in, OCSP_RESPONSE **res);

int OCSP_response_status(OCSP_RESPONSE *resp);
OCSP_BASICRESP *OCSP_response_get1_basic(OCSP_RESPONSE *resp);

#if defined(__cplusplus)
}  // extern C
#endif

#endif
