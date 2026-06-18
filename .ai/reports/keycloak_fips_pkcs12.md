# Keycloak FIPS PKCS12 / HmacPBESHA256 Research

Generated: 2026-06-18

## Current answer

Keycloak's `TruststoreBuilder` creates the merged system truststore as a Java `PKCS12` keystore, saves it as `keycloak-truststore.p12`, and sets `javax.net.ssl.trustStoreType=PKCS12`. While saving, it sets only:

```text
keystore.pkcs12.certProtectionAlgorithm=NONE
```

That disables certificate encryption in the PKCS12 file. It does not disable the PKCS12 integrity MAC. Because `setSystemTruststore()` passes the dummy password `keycloakchangeit`, the JDK PKCS12 implementation still emits `MacData`. In the OpenJDK 21 implementation used by the upstream Quay image, the default PKCS12 MAC algorithm is:

```text
keystore.pkcs12.macAlgorithm = HmacPBESHA256
```

So `HmacPBESHA256` is not selected by Keycloak directly. It is selected by the JDK PKCS12 keystore implementation when `KeyStore.store(output, nonNullPassword)` is called and no `keystore.pkcs12.macAlgorithm` override is present.

For the observed upstream `quay.io/keycloak/keycloak:26.6.2` image, this is not evidence of a supported strict FIPS configuration. The image run shows `PKCS12` from `SUN` and `HmacPBESHA256` from `SunJCE`, while Keycloak's FIPS docs require a FIPS-enabled host/JVM and state that strict mode defaults keystore/truststore type to BCFKS and that `jks` and `pkcs12` are not supported for strict-mode Keycloak keystore use.

The subtle point: PKCS12 as a file format is not itself the FIPS approval question. The question is which provider performs the cryptographic services for that file, whether those services are inside a validated approved-mode boundary, and whether Keycloak/JSSE relies on the PKCS12 MacData as an integrity service.

## How PKCS12 is constructed

PKCS12 is an ASN.1 `PFX` object. RFC 7292 defines the top-level structure as:

```text
PFX ::= SEQUENCE {
    version     INTEGER {v3(3)}(v3,...),
    authSafe    ContentInfo,
    macData     MacData OPTIONAL
}
```

The `authSafe` contains an `AuthenticatedSafe`, which is a sequence of `ContentInfo` values. Each inner `ContentInfo` can be plaintext `Data`, password-encrypted `EncryptedData`, or public-key `EnvelopedData`. The plaintext/encrypted payload is a `SafeContents`, which is a sequence of `SafeBag` values. Certificates are stored in `certBag` safe bags; private keys are normally `pkcs8ShroudedKeyBag`; secret keys can appear as `secretBag`.

`MacData` is optional and is stored at the top level of the PFX. It contains a `DigestInfo`, a salt, and an iteration count. The MAC covers the BER-encoded `AuthenticatedSafe` bytes. That means certificate bag encryption and file-level integrity are separate concerns.

Relevant RFC source:

* RFC 7292, PKCS #12 v1.1: https://www.rfc-editor.org/rfc/rfc7292
* The opened RFC text shows `PFX`, `MacData`, `AuthenticatedSafe`, `SafeContents`, and `SafeBag` definitions around lines 546-575 and 1228-1257.

## How OpenJDK writes PKCS12

The local OpenJDK 21 source has these hardcoded defaults in `sun.security.pkcs12.PKCS12KeyStore`:

```text
DEFAULT_CERT_PBE_ALGORITHM = PBEWithHmacSHA256AndAES_256
DEFAULT_KEY_PBE_ALGORITHM  = PBEWithHmacSHA256AndAES_256
DEFAULT_MAC_ALGORITHM      = HmacPBESHA256
DEFAULT_*_ITERATION_COUNT  = 10000
```

The `java.security` file documents the same defaults and the relevant override properties:

```text
keystore.pkcs12.certProtectionAlgorithm
keystore.pkcs12.certPbeIterationCount
keystore.pkcs12.keyProtectionAlgorithm
keystore.pkcs12.keyPbeIterationCount
keystore.pkcs12.macAlgorithm
keystore.pkcs12.macIterationCount
```

During `engineStore()` the JDK does this:

1. Writes `PFX` version 3.
2. Builds `AuthenticatedSafe`.
3. Stores private/secret keys, if any, as protected key data.
4. Stores certificates as `EncryptedData` only if `password != null` and `certProtectionAlgorithm != NONE`; otherwise it stores certificates as plaintext `Data`.
5. Wraps the `AuthenticatedSafe` in the outer `ContentInfo`.
6. If `password != null` and `macAlgorithm != NONE`, calculates and writes top-level `MacData`.

This explains why Keycloak's `certProtectionAlgorithm=NONE` still results in `HmacPBESHA256`: Keycloak turned off certificate encryption, but left the top-level PKCS12 MAC enabled by using a non-null password and leaving `keystore.pkcs12.macAlgorithm` at the JDK default.

Local source evidence:

* JDK source: `/Users/sebastianlaskawiec/Library/Java/JavaVirtualMachines/ms-21.0.9/Contents/Home/lib/src.zip`
* `java.base/sun/security/pkcs12/PKCS12KeyStore.java`: defaults around lines 99-104.
* `PKCS12KeyStore.engineStore()`: certificate encryption decision and MAC decision around lines 1187-1274.
* `PKCS12KeyStore.calculateMac()`: uses `Mac.getInstance(macAlgorithm)` and encodes `MacData`, around lines 1492-1522.
* `java.base/com/sun/crypto/provider/HmacPKCS12PBECore.java`: describes the implementation as PKCS12 HMAC per RFC 7292 Appendix B.4, and includes `HmacPKCS12PBE_SHA256`.
* Local JDK `java.security`: `/Users/sebastianlaskawiec/Library/Java/JavaVirtualMachines/ms-21.0.9/Contents/Home/conf/security/java.security:1190-1280`.

## Keycloak construction path

`services/src/main/java/org/keycloak/truststore/TruststoreBuilder.java` does the following:

1. `setSystemTruststore(...)` calls `createMergedTruststore(...)`.
2. `createMergedTruststore(...)` calls `createPkcs12KeyStore()`.
3. `createPkcs12KeyStore()` calls `KeyStore.getInstance("PKCS12")` and loads an empty store.
4. Keycloak merges default truststore certificates, configured PKCS12 truststores, and PEM certificates into that in-memory store.
5. `setSystemTruststore(...)` calls `saveTruststore(truststore, dataDir, DUMMY_PASSWORD.toCharArray())`.
6. `saveTruststore(...)` temporarily sets `keystore.pkcs12.certProtectionAlgorithm=NONE` and calls `truststore.store(fos, password)`.
7. `setSystemTruststore(...)` sets system properties:

```text
javax.net.ssl.trustStore=<dataDir>/keycloak-truststore.p12
javax.net.ssl.trustStoreType=PKCS12
javax.net.ssl.trustStorePassword=keycloakchangeit
```

Important nuance: the unit test `TruststoreBuilderTest.testMergedTrustStore()` saves with `password=null`, and in that case the JDK will not generate MacData. The actual `setSystemTruststore()` path uses the dummy password, so it does generate MacData unless `keystore.pkcs12.macAlgorithm=NONE` is also set.

Local source evidence:

* `services/src/main/java/org/keycloak/truststore/TruststoreBuilder.java:49`: `PKCS12`.
* `TruststoreBuilder.java:56-67`: saves with dummy password and sets JSSE truststore properties.
* `TruststoreBuilder.java:99-113`: sets `keystore.pkcs12.certProtectionAlgorithm=NONE`, stores the keystore, restores the property.
* `TruststoreBuilder.java:118-155`: creates and populates the `PKCS12` keystore.
* `services/src/test/java/org/keycloak/truststore/TruststoreBuilderTest.java:47-53`: test uses `password=null`.

## Upstream Quay image check

Local image inspected:

```text
quay.io/keycloak/keycloak:26.6.2
```

Image version output:

```text
openjdk version "21.0.11" 2026-04-21 LTS
OpenJDK Runtime Environment (Red_Hat-21.0.11.0.10-1)
Keycloak 26.6.2
```

The image's JDK `java.security` has the same PKCS12 defaults:

```text
# no Mac is generated. The default value is "HmacPBESHA256".
#keystore.pkcs12.macAlgorithm = HmacPBESHA256
#keystore.pkcs12.certProtectionAlgorithm = PBEWithHmacSHA256AndAES_256
```

A `keytool` run inside the image with certificate protection set to `NONE`, matching Keycloak's truststore behavior, still resolved the PKCS12 keystore and MAC like this:

```text
Provider: SUN.putService(): SUN: KeyStore.PKCS12 -> sun.security.pkcs12.PKCS12KeyStore$DualFormatPKCS12
Provider: KeyStore.PKCS12 type from: SUN
keystore: Creating a new keystore in PKCS12 format
Certificate was added to keystore
Provider: SunJCE.putService(): SunJCE: Mac.HmacPBESHA256 -> com.sun.crypto.provider.HmacPKCS12PBECore$HmacPKCS12PBE_SHA256
Provider: Mac.HmacPBESHA256 algorithm from: SunJCE
Provider: KeyStore.PKCS12 type from: SUN
Provider: Mac.HmacPBESHA256 algorithm from: SunJCE
```

Command used:

```bash
docker run --rm --entrypoint /bin/bash quay.io/keycloak/keycloak:26.6.2 -lc 'set -euo pipefail; keytool -genkeypair -alias src -keyalg RSA -keysize 2048 -keystore /tmp/src.p12 -storetype PKCS12 -storepass changeit -keypass changeit -dname CN=test -validity 1 >/dev/null 2>&1; keytool -exportcert -rfc -alias src -keystore /tmp/src.p12 -storepass changeit -file /tmp/cert.pem >/dev/null 2>&1; keytool -J-Djava.security.debug=provider,engine=KeyStore,engine=Mac -J-Dkeystore.pkcs12.certProtectionAlgorithm=NONE -importcert -noprompt -alias trusted -file /tmp/cert.pem -keystore /tmp/trust.p12 -storetype PKCS12 -storepass keycloakchangeit 2>&1 | grep -E "KeyStore.PKCS12|Mac.HmacPBE|Provider: Mac|Creating a new keystore|Certificate was added"'
```

This directly explains why the upstream Quay image produces a PKCS12 file associated with `HmacPBESHA256`: the image's Red Hat OpenJDK PKCS12 defaults select it, and the provider path in this non-FIPS-host run is `SUN` + `SunJCE`.

## Prior upstream Keycloak runtime logs

Existing captured upstream logs in `.ai/reports/logs/upstream/0.log.20260611-222321` agree with the direct image test:

```text
FIPS1402Provider created: KC(BCFIPS version 2.0102 Approved Mode, FIPS-JVM: unknown)
Inserted security providers: [BCFIPS, BCJSSE]
Using the crypto provider: org.keycloak.crypto.fips.Fips1402StrictCryptoProvider
File truststore provider initialized: /opt/keycloak/bin/../data/keycloak-truststore.p12, Truststore type: PKCS12
Java security providers: BCFIPS, BCJSSE, SUN, SunRsaSign, SunEC, SunJSSE, SunJCE, ...
Default keystore type: pkcs12
javax.net.ssl.trustStoreType: PKCS12
javax.net.ssl.trustStore: /opt/keycloak/bin/../data/keycloak-truststore.p12
Found string system property [javax.net.ssl.trustStoreType]: PKCS12
Initializing default trust store from path: /opt/keycloak/bin/../data/keycloak-truststore.p12
```

The same log also says Keycloak could not detect host FIPS mode:

```text
Could not detect if FIPS is enabled from the host
NoSuchFileException: /proc/sys/crypto/fips_enabled
FIPS-JVM: unknown
```

That makes the captured upstream run a useful reproduction of provider behavior, but not a proof of a supported FIPS deployment.

## Prior local FIPS inventory

The prior reports and runtime inventory already captured the provider-boundary issue:

```text
.ai/reports/fips_instantiable_crypto.log:3: FIPS mode: strict
.ai/reports/fips_instantiable_crypto.log:4: BCFIPS approved-only property: true
.ai/reports/fips_instantiable_crypto.log:6: PROVIDER|1|BCFIPS
.ai/reports/fips_instantiable_crypto.log:7: PROVIDER|2|BCJSSE
.ai/reports/fips_instantiable_crypto.log:8: PROVIDER|3|SUN|... PKCS12, JKS & DKS keystores ...
.ai/reports/fips_instantiable_crypto.log:12: PROVIDER|7|SunJCE|...
.ai/reports/fips_instantiable_crypto.log:1754: INSTANTIABLE|KeyStore|SUN|PKCS12
.ai/reports/fips_instantiable_crypto.log:1756: INSTANTIABLE|KeyStore|SunJSSE|PKCS12
.ai/reports/fips_instantiable_crypto.log:1905: INSTANTIABLE|Mac|SunJCE|HmacPBESHA256
```

JCA debug evidence:

```text
.ai/reports/fips_crypto_debug_raw.log:6506: Provider: KeyStore.BCFKS type from: BCFIPS
.ai/reports/fips_crypto_debug_raw.log:6507: Provider: KeyStore.PKCS12 type from: SUN
.ai/reports/fips_crypto_debug_raw.log:964:  SunJCE: Mac.HmacPBESHA256 -> com.sun.crypto.provider.HmacPKCS12PBECore$HmacPKCS12PBE_SHA256
```

The existing `.ai/reports/chainguard_fips.adoc` reaches the same direction: `HmacPBESHA256` is a Java provider spelling observed from SunJCE, not a NIST algorithm name, and strict-mode Keycloak evidence points to BCFKS rather than PKCS12.

## FIPS support assessment

### What is approved in principle

HMAC with SHA-256 can be an approved primitive when implemented by a validated module in approved mode and used with sufficient key strength. Prior reports already cite:

* FIPS 140-2 Annex A for HMAC and SHS.
* FIPS 198-1 for HMAC using an approved hash function.
* SP 800-131A Rev. 2 for 112-bit minimum MAC key strength.
* SP 800-132 for password-based key derivation for storage applications.

### What is not proven by `HmacPBESHA256`

`HmacPBESHA256` is a Java provider algorithm name for the PKCS12 PBE MAC implementation. It is not by itself a FIPS approval statement. In the observed upstream Quay image, it resolves from `SunJCE`, not `BCFIPS` or an NSS-backed FIPS provider. Therefore this observed path is not acceptable as strict FIPS evidence.

### Keycloak strict mode

Current Keycloak docs say:

* Keycloak should run on a FIPS-enabled system/JVM.
* For containers, the host must be in FIPS mode and the container inherits that state.
* PKCS12 works well in BCFIPS non-approved mode.
* In strict mode, the default keystore/truststore type is BCFKS.
* `jks` and `pkcs12` are not supported in Keycloak when using strict mode for strict-mode Keycloak keystore use cases.

Source:

* Keycloak FIPS guide, current nightly 26.6.3 page: https://www.keycloak.org/server/fips

Local tests agree:

* `crypto/fips1402/src/test/java/org/keycloak/crypto/fips/test/FIPS1402KeystoreTypesTest.java:43-49`: BCFIPS approved mode supports only BCFKS in Keycloak's active crypto provider test.
* `crypto/fips1402/src/test/java/org/keycloak/crypto/fips/test/FIPS1402SslTest.java:55-78`: PKCS12 SSL keystore tests require non-approved mode.

### Red Hat OpenJDK FIPS configuration

Red Hat's OpenJDK 21 FIPS documentation says that when system FIPS policy is enabled, Red Hat OpenJDK performs automatic configuration including:

* Installing a restricted list of security providers containing the FIPS-certified NSS software token for cryptographic operations.
* Enforcing the RHEL FIPS crypto policy for Java.
* `fips.keystore.type` defaults to `PKCS12`, with supported values `PKCS12` and `PKCS11`.

Source:

* Red Hat OpenJDK 21 FIPS settings: https://docs.redhat.com/en/documentation/red_hat_build_of_openjdk/21/html/configuring_red_hat_build_of_openjdk_21_on_rhel_with_fips/fips_settings

This means the exact supported answer depends on the actual runtime provider configuration:

* On the observed upstream Quay image running outside a FIPS-enabled host/JVM, `PKCS12` and `HmacPBESHA256` are handled by `SUN`/`SunJCE`. Not strict FIPS evidence.
* On a correctly FIPS-enabled RHEL/OpenJDK runtime, provider exposure and algorithm availability may be different. That target must be tested directly.
* Keycloak's own strict-mode guidance still points operators to BCFKS for strict-mode Keycloak keystore/truststore handling.

## Preliminary conclusion

The answer to "how did HmacPBESHA256 get there?" is: the JDK inserted it as the default PKCS12 `MacData` algorithm because Keycloak saved a `PKCS12` truststore with a non-null password and only disabled certificate encryption.

The answer to "is this the supported FIPS configuration?" for the observed upstream Quay image is: no, not as observed. The reproduction shows `PKCS12` from `SUN` and `HmacPBESHA256` from `SunJCE`, while the startup log says `FIPS-JVM: unknown` and host FIPS was not detected. This is a non-FIPS or incomplete-FIPS provider path.

The harder follow-up is whether Keycloak should generate the system-wide merged truststore as BCFKS in strict mode, or at least suppress PKCS12 MacData in a way that is explicitly documented as "no security claim" for a public-certificate truststore. Suppressing MacData with `keystore.pkcs12.macAlgorithm=NONE` would remove `HmacPBESHA256`, but it would also remove PKCS12 file-integrity protection; that is not automatically a compliance fix.

## Recommended next tests

1. Run the same certificate-only PKCS12 creation test on a real RHEL FIPS-enabled host with Red Hat OpenJDK 21 and record whether `Mac.HmacPBESHA256` is available, blocked, or routed through an NSS/FIPS provider.
2. Run Keycloak strict mode on that host/container setup and capture:
   * `FIPS-JVM: enabled`
   * provider order
   * `KeyStore.getInstance("PKCS12").getProvider()`
   * `Mac.getInstance("HmacPBESHA256").getProvider()` or the expected failure
   * generated `keycloak-truststore.p12` metadata.
3. Decide whether `TruststoreBuilder` should respect strict FIPS mode and produce BCFKS, or whether the PKCS12 system truststore is intentionally outside the approved cryptographic service boundary because it contains public certificates only.
4. Add a focused regression test for strict mode that asserts the provider path used by the generated system truststore.
