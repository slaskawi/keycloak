#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [image-tag]

Builds the local Keycloak Quarkus distribution without tests, builds a local
container image from that distribution, copies Bouncy Castle FIPS jars into a
derived image, runs it with JVM debug and crypto logging, and writes the
algorithm/cipher report to:

  .ai/reports/fips_algorithms_and_ciphers.txt

Environment:
  CONTAINER_RUNTIME      Container CLI to use. Default: docker
  FIPS_MODE              Keycloak FIPS mode: strict or non-strict. Default: strict
  STARTUP_TIMEOUT        Seconds to collect startup logs. Default: 180
  KEEP_CONTAINER         Keep the started container when set to true. Default: false
  KEEP_WORKDIR           Keep generated build context when set to true. Default: false
  SKIP_DIST_BUILD        Reuse existing quarkus/dist/target tarball when true. Default: false
  SKIP_IMAGE_BUILD       Reuse the requested image-tag when true. Default: false
  SKIP_PROTO_LOCK        Skip remote proto.lock compatibility checks. Default: true
  JAVA_SECURITY_DEBUG    java.security.debug value. Default: provider and crypto engines
  SSL_DEBUG              javax.net.debug value. Default: ssl,handshake,verbose
  EXTRA_JAVA_OPTS        Extra JVM options appended to JAVA_OPTS_APPEND
  EXTRA_KC_ARGS          Extra arguments appended to kc.sh start-dev

Examples:
  $0
  FIPS_MODE=non-strict STARTUP_TIMEOUT=240 $0 keycloak-fips:local
  SKIP_DIST_BUILD=true SKIP_IMAGE_BUILD=true $0 keycloak-fips:local
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONTAINER_DIR="${PROJECT_ROOT}/quarkus/container"
REPORT_DIR="${PROJECT_ROOT}/.ai/reports"
WORK_ROOT="${PROJECT_ROOT}/.ai/work/check_fips"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
FIPS_MODE="${FIPS_MODE:-strict}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"
KEEP_CONTAINER="${KEEP_CONTAINER:-false}"
KEEP_WORKDIR="${KEEP_WORKDIR:-false}"
SKIP_DIST_BUILD="${SKIP_DIST_BUILD:-false}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-false}"
SKIP_PROTO_LOCK="${SKIP_PROTO_LOCK:-true}"
JAVA_SECURITY_DEBUG="${JAVA_SECURITY_DEBUG:-properties,provider,engine=Cipher,engine=KeyAgreement,engine=KeyGenerator,engine=KeyPairGenerator,engine=KeyStore,engine=Mac,engine=MessageDigest,engine=SecureRandom,engine=Signature,engine=SSLContext}"
SSL_DEBUG="${SSL_DEBUG:-ssl,handshake,verbose}"
EXTRA_JAVA_OPTS="${EXTRA_JAVA_OPTS:-}"
EXTRA_KC_ARGS="${EXTRA_KC_ARGS:-}"
CLEANUP_CONTAINER_NAME=""
CLEANUP_RUN_DIR=""

log() {
  printf '[check-fips] %s\n' "$*"
}

die() {
  printf '[check-fips] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Required command not found: $1"
  fi
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_image_part() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^[._-]+//; s/[._-]+$//'
}

copy_bc_fips_jars() {
  local output_dir="$1"

  mkdir -p "$output_dir"
  log "Resolving Bouncy Castle FIPS jars into ${output_dir}"
  (
    cd "$PROJECT_ROOT"
    ./mvnw -q -f quarkus/tests/integration/pom.xml \
      -DincludeGroupIds=org.bouncycastle \
      -DincludeArtifactIds=bc-fips,bctls-fips,bcpkix-fips,bcutil-fips \
      -DexcludeTransitive=true \
      -DoutputDirectory="$output_dir" \
      dependency:copy-dependencies
  )

  local missing=()
  local artifact
  for artifact in bc-fips bctls-fips bcpkix-fips bcutil-fips; do
    if ! compgen -G "${output_dir}/${artifact}-*.jar" >/dev/null; then
      missing+=("$artifact")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    die "Missing Bouncy Castle FIPS jars after Maven resolution: ${missing[*]}"
  fi
}

write_fips_containerfile() {
  local containerfile="$1"
  local base_image="$2"

  cat > "$containerfile" <<EOF
FROM ${base_image}
COPY --chown=1000:0 bcfips/*.jar /opt/keycloak/providers/
EOF
}

container_exists() {
  local name="$1"
  "$CONTAINER_RUNTIME" ps -a --format '{{.Names}}' | grep -Fxq "$name"
}

remove_container_if_exists() {
  local name="$1"
  if container_exists "$name"; then
    log "Removing previous container ${name}"
    "$CONTAINER_RUNTIME" rm -f "$name" >/dev/null
  fi
}

cleanup() {
  if [[ -n "${CLEANUP_CONTAINER_NAME:-}" ]] && ! is_true "$KEEP_CONTAINER"; then
    remove_container_if_exists "$CLEANUP_CONTAINER_NAME"
  fi
  if [[ -n "${CLEANUP_RUN_DIR:-}" ]] && ! is_true "$KEEP_WORKDIR"; then
    rm -rf "$CLEANUP_RUN_DIR"
  fi
}

collect_container_logs() {
  local container_name="$1"
  local raw_log="$2"
  local deadline=$((SECONDS + STARTUP_TIMEOUT))

  : > "$raw_log"
  log "Collecting container logs for up to ${STARTUP_TIMEOUT}s"

  while (( SECONDS < deadline )); do
    "$CONTAINER_RUNTIME" logs "$container_name" > "$raw_log" 2>&1 || true

    if grep -Eq 'Keycloak [0-9A-Za-z.+-]+ on JVM .* started' "$raw_log"; then
      break
    fi

    if grep -Eq 'ERROR:|Failed to start server|NoSuchMethodError|NoSuchAlgorithmException' "$raw_log"; then
      break
    fi

    if ! "$CONTAINER_RUNTIME" ps --format '{{.Names}}' | grep -Fxq "$container_name"; then
      break
    fi

    sleep 2
  done

  "$CONTAINER_RUNTIME" logs "$container_name" > "$raw_log" 2>&1 || true
}

dump_bcjsse_tls_probe() {
  local image="$1"
  local output_file="$2"

  log "Dumping enabled BCJSSE TLS cipher suites from ${image}"
  if ! "$CONTAINER_RUNTIME" run --rm -i --entrypoint /bin/bash "$image" -s "$FIPS_MODE" > "$output_file" 2>&1 <<'EOF'
set -euo pipefail
mode="$1"
cat > /tmp/DumpBcTls.java <<'JAVA'
import java.security.Provider;
import java.security.Security;
import java.util.Arrays;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider;
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider;

public class DumpBcTls {
  public static void main(String[] args) throws Exception {
    String mode = args.length == 0 ? "strict" : args[0];
    if ("strict".equals(mode)) {
      System.setProperty("org.bouncycastle.fips.approved_only", "true");
    }

    Security.insertProviderAt(new BouncyCastleFipsProvider(), 1);
    Security.insertProviderAt(new BouncyCastleJsseProvider("fips:BCFIPS"), 2);

    SSLContext context = SSLContext.getInstance("TLS");
    context.init(null, null, null);
    SSLEngine engine = context.createSSLEngine();

    System.out.println("FIPS mode: " + mode);
    System.out.println("BCFIPS approved-only property: " + System.getProperty("org.bouncycastle.fips.approved_only", "false"));
    System.out.println("SSLContext provider: " + context.getProvider().getName());
    System.out.println("Enabled protocols:");
    Arrays.stream(engine.getEnabledProtocols()).sorted().forEach(p -> System.out.println("  " + p));
    System.out.println("Enabled cipher suites:");
    Arrays.stream(engine.getEnabledCipherSuites()).sorted().forEach(c -> System.out.println("  " + c));
    System.out.println("Providers:");
    for (Provider provider : Security.getProviders()) {
      System.out.println("  " + provider.getName() + " - " + provider.getInfo());
    }
  }
}
JAVA
java -cp "/opt/keycloak/providers/*" /tmp/DumpBcTls.java "$mode"
EOF
  then
    die "Failed to dump BCJSSE TLS cipher suites; see ${output_file}"
  fi
}

dump_instantiable_crypto_probe() {
  local image="$1"
  local output_file="$2"

  log "Dumping instantiable crypto algorithms from ${image}"
  if ! "$CONTAINER_RUNTIME" run --rm -i --entrypoint /bin/bash "$image" -s "$FIPS_MODE" > "$output_file" 2>&1 <<'EOF'
set -euo pipefail
mode="$1"
cat > /tmp/DumpInstantiableCrypto.java <<'JAVA'
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.security.AlgorithmParameterGenerator;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.Provider;
import java.security.SecureRandom;
import java.security.Security;
import java.security.Signature;
import java.security.cert.CertPathBuilder;
import java.security.cert.CertPathValidator;
import java.security.cert.CertStore;
import java.security.cert.CollectionCertStoreParameters;
import java.security.cert.CertificateFactory;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import javax.crypto.SecretKeyFactory;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.TrustManagerFactory;
import org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider;
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider;

public class DumpInstantiableCrypto {
  private static final Set<String> CRYPTO_TYPES = new LinkedHashSet<>(Arrays.asList(
      "AlgorithmParameterGenerator",
      "AlgorithmParameters",
      "CertPathBuilder",
      "CertPathValidator",
      "CertStore",
      "CertificateFactory",
      "Cipher",
      "KeyAgreement",
      "KeyFactory",
      "KeyGenerator",
      "KeyManagerFactory",
      "KeyPairGenerator",
      "KeyStore",
      "Mac",
      "MessageDigest",
      "SSLContext",
      "SecretKeyFactory",
      "SecureRandom",
      "Signature",
      "TrustManagerFactory"));

  static final class Candidate implements Comparable<Candidate> {
    final String type;
    final Provider provider;
    final String algorithm;

    Candidate(String type, Provider provider, String algorithm) {
      this.type = type;
      this.provider = provider;
      this.algorithm = algorithm;
    }

    @Override
    public int compareTo(Candidate other) {
      int result = type.compareTo(other.type);
      if (result != 0) return result;
      result = provider.getName().compareTo(other.provider.getName());
      if (result != 0) return result;
      return algorithm.compareTo(other.algorithm);
    }
  }

  public static void main(String[] args) throws Exception {
    String mode = args.length == 0 ? "strict" : args[0];
    if ("strict".equals(mode)) {
      System.setProperty("org.bouncycastle.fips.approved_only", "true");
    }

    Object keycloakFipsProvider = installKeycloakFipsProvider();
    ensureBouncyCastleProviders();

    System.out.println("# Instantiable Crypto Inventory");
    System.out.println("FIPS mode: " + mode);
    System.out.println("BCFIPS approved-only property: " + System.getProperty("org.bouncycastle.fips.approved_only", "false"));
    System.out.println("Providers:");
    Provider[] providers = Security.getProviders();
    for (int i = 0; i < providers.length; i++) {
      Provider provider = providers[i];
      System.out.println("PROVIDER|" + (i + 1) + "|" + safe(provider.getName()) + "|" + safe(provider.getInfo()));
    }

    printKeycloakEncryptionAlgorithms(keycloakFipsProvider);
    printTlsInventory();

    TreeSet<Candidate> candidates = collectCandidates();
    int instantiated = 0;
    int notInstantiated = 0;
    for (Candidate candidate : candidates) {
      try {
        Object instance = instantiate(candidate.type, candidate.algorithm, candidate.provider);
        instantiated++;
        System.out.println("INSTANTIABLE|" + candidate.type + "|" + safe(candidate.provider.getName()) + "|" + safe(candidate.algorithm) + "|" + safe(instance.getClass().getName()));
      } catch (Throwable t) {
        notInstantiated++;
        System.out.println("NOT_INSTANTIABLE|" + candidate.type + "|" + safe(candidate.provider.getName()) + "|" + safe(candidate.algorithm) + "|" + safe(error(t)));
      }
    }
    System.out.println("SUMMARY|candidates|" + candidates.size());
    System.out.println("SUMMARY|instantiable|" + instantiated);
    System.out.println("SUMMARY|not_instantiable|" + notInstantiated);
  }

  static Object installKeycloakFipsProvider() {
    try {
      Class<?> providerClass = Class.forName("org.keycloak.crypto.fips.FIPS1402Provider");
      Object provider = providerClass.getConstructor().newInstance();
      System.out.println("KEYCLOAK_FIPS_PROVIDER|INSTALLED|" + safe(providerClass.getName()));
      return provider;
    } catch (Throwable t) {
      System.out.println("KEYCLOAK_FIPS_PROVIDER|ERROR|" + safe(error(t)));
      return null;
    }
  }

  static void ensureBouncyCastleProviders() {
    if (Security.getProvider("BCFIPS") == null) {
      Security.insertProviderAt(new BouncyCastleFipsProvider(), 1);
    }
    if (Security.getProvider("BCJSSE") == null) {
      Security.insertProviderAt(new BouncyCastleJsseProvider("fips:BCFIPS"), 2);
    }
  }

  static void printKeycloakEncryptionAlgorithms(Object keycloakFipsProvider) {
    if (keycloakFipsProvider == null) {
      return;
    }
    try {
      Field providersField = keycloakFipsProvider.getClass().getDeclaredField("providers");
      providersField.setAccessible(true);
      Object value = providersField.get(keycloakFipsProvider);
      if (value instanceof Map<?, ?> providers) {
        TreeMap<String, String> algorithms = new TreeMap<>();
        for (Map.Entry<?, ?> entry : providers.entrySet()) {
          algorithms.put(String.valueOf(entry.getKey()), entry.getValue().getClass().getName());
        }
        for (Map.Entry<String, String> entry : algorithms.entrySet()) {
          System.out.println("KEYCLOAK_ENCRYPTION|" + safe(entry.getKey()) + "|" + safe(entry.getValue()));
        }
      }
    } catch (Throwable t) {
      System.out.println("KEYCLOAK_ENCRYPTION_ERROR|" + safe(error(t)));
    }
  }

  static void printTlsInventory() {
    try {
      Provider jsseProvider = Security.getProvider("BCJSSE");
      SSLContext context = jsseProvider == null
          ? SSLContext.getInstance("TLS")
          : SSLContext.getInstance("TLS", jsseProvider);
      context.init(null, null, null);
      SSLEngine engine = context.createSSLEngine();
      String providerName = context.getProvider().getName();

      for (String protocol : sorted(engine.getSupportedProtocols())) {
        System.out.println("TLS_SUPPORTED_PROTOCOL|" + safe(providerName) + "|" + safe(protocol));
      }
      for (String protocol : sorted(engine.getEnabledProtocols())) {
        System.out.println("TLS_ENABLED_PROTOCOL|" + safe(providerName) + "|" + safe(protocol));
      }
      for (String suite : sorted(engine.getSupportedCipherSuites())) {
        System.out.println("TLS_SUPPORTED_CIPHER_SUITE|" + safe(providerName) + "|" + safe(suite));
        try {
          SSLEngine suiteEngine = context.createSSLEngine();
          suiteEngine.setEnabledCipherSuites(new String[] { suite });
          System.out.println("TLS_INSTANTIABLE_CIPHER_SUITE|" + safe(providerName) + "|" + safe(suite));
        } catch (Throwable t) {
          System.out.println("TLS_NOT_INSTANTIABLE_CIPHER_SUITE|" + safe(providerName) + "|" + safe(suite) + "|" + safe(error(t)));
        }
      }
      for (String suite : sorted(engine.getEnabledCipherSuites())) {
        System.out.println("TLS_ENABLED_CIPHER_SUITE|" + safe(providerName) + "|" + safe(suite));
      }
    } catch (Throwable t) {
      System.out.println("TLS_INVENTORY_ERROR|" + safe(error(t)));
    }
  }

  static TreeSet<Candidate> collectCandidates() {
    TreeSet<Candidate> candidates = new TreeSet<>();
    for (Provider provider : Security.getProviders()) {
      for (Provider.Service service : provider.getServices()) {
        String type = service.getType();
        if (CRYPTO_TYPES.contains(type)) {
          addCandidate(candidates, type, provider, service.getAlgorithm());
          if ("Cipher".equals(type)) {
            addCipherTransformations(candidates, provider, service);
          }
        }
      }

      for (String propertyName : provider.stringPropertyNames()) {
        for (String type : CRYPTO_TYPES) {
          String prefix = "Alg.Alias." + type + ".";
          if (propertyName.startsWith(prefix)) {
            addCandidate(candidates, type, provider, propertyName.substring(prefix.length()));
          }
        }
      }
    }
    return candidates;
  }

  static void addCipherTransformations(TreeSet<Candidate> candidates, Provider provider, Provider.Service service) {
    String algorithm = service.getAlgorithm();
    if (algorithm.contains("/")) {
      return;
    }
    Set<String> modes = parseProviderAttribute(service.getAttribute("SupportedModes"));
    Set<String> paddings = parseProviderAttribute(service.getAttribute("SupportedPaddings"));
    if (modes.isEmpty() || paddings.isEmpty()) {
      return;
    }
    for (String mode : modes) {
      for (String padding : paddings) {
        addCandidate(candidates, "Cipher", provider, algorithm + "/" + mode + "/" + padding);
      }
    }
  }

  static Set<String> parseProviderAttribute(String value) {
    TreeSet<String> values = new TreeSet<>();
    if (value == null || value.isBlank()) {
      return values;
    }
    for (String rawPart : value.replace("(?i)", "").split("\\|")) {
      String part = rawPart.trim();
      if (part.isEmpty() || part.matches(".*[\\[\\]*+?{}].*")) {
        continue;
      }
      part = part.replaceAll("[^A-Za-z0-9_-]", "");
      if (!part.isEmpty()) {
        values.add(part);
      }
    }
    return values;
  }

  static void addCandidate(TreeSet<Candidate> candidates, String type, Provider provider, String algorithm) {
    if (algorithm != null && !algorithm.isBlank()) {
      candidates.add(new Candidate(type, provider, algorithm));
    }
  }

  static Object instantiate(String type, String algorithm, Provider provider) throws Exception {
    return switch (type) {
      case "AlgorithmParameterGenerator" -> AlgorithmParameterGenerator.getInstance(algorithm, provider);
      case "AlgorithmParameters" -> AlgorithmParameters.getInstance(algorithm, provider);
      case "CertPathBuilder" -> CertPathBuilder.getInstance(algorithm, provider);
      case "CertPathValidator" -> CertPathValidator.getInstance(algorithm, provider);
      case "CertStore" -> CertStore.getInstance(algorithm, new CollectionCertStoreParameters(Collections.emptyList()), provider);
      case "CertificateFactory" -> CertificateFactory.getInstance(algorithm, provider);
      case "Cipher" -> Cipher.getInstance(algorithm, provider);
      case "KeyAgreement" -> KeyAgreement.getInstance(algorithm, provider);
      case "KeyFactory" -> KeyFactory.getInstance(algorithm, provider);
      case "KeyGenerator" -> KeyGenerator.getInstance(algorithm, provider);
      case "KeyManagerFactory" -> KeyManagerFactory.getInstance(algorithm, provider);
      case "KeyPairGenerator" -> KeyPairGenerator.getInstance(algorithm, provider);
      case "KeyStore" -> KeyStore.getInstance(algorithm, provider);
      case "Mac" -> Mac.getInstance(algorithm, provider);
      case "MessageDigest" -> MessageDigest.getInstance(algorithm, provider);
      case "SSLContext" -> SSLContext.getInstance(algorithm, provider);
      case "SecretKeyFactory" -> SecretKeyFactory.getInstance(algorithm, provider);
      case "SecureRandom" -> SecureRandom.getInstance(algorithm, provider);
      case "Signature" -> Signature.getInstance(algorithm, provider);
      case "TrustManagerFactory" -> TrustManagerFactory.getInstance(algorithm, provider);
      default -> throw new IllegalArgumentException("No instantiation probe for " + type);
    };
  }

  static String[] sorted(String[] input) {
    String[] copy = input.clone();
    Arrays.sort(copy);
    return copy;
  }

  static String safe(String input) {
    return input == null ? "" : input.replace('\n', ' ').replace('\r', ' ').replace('|', '/');
  }

  static String error(Throwable throwable) {
    Throwable current = throwable;
    if (current instanceof InvocationTargetException invocation && invocation.getCause() != null) {
      current = invocation.getCause();
    }
    return current.getClass().getName() + ":" + safe(current.getMessage());
  }
}
JAVA
java -Djava.util.logging.manager=org.jboss.logmanager.LogManager \
  -cp "/opt/keycloak/providers/*:/opt/keycloak/lib/lib/boot/*:/opt/keycloak/lib/lib/main/*:/opt/keycloak/bin/client/lib/*" \
  /tmp/DumpInstantiableCrypto.java "$mode"
EOF
  then
    die "Failed to dump instantiable crypto algorithms; see ${output_file}"
  fi
}

grep_or_true() {
  grep "$@" || true
}

write_report() {
  local raw_log="$1"
  local tls_probe_log="$2"
  local instantiable_crypto_log="$3"
  local report="$4"
  local version="$5"
  local base_image="$6"
  local fips_image="$7"
  local dist_tar="$8"
  local bc_dir="$9"

  local log_filter
  log_filter='FIPS1402Provider|Inserted security providers|BCFIPS|BCJSSE|BouncyCastle|Provider:|putService|Service\(|Cipher\.|Signature\.|MessageDigest\.|Mac\.|KeyAgreement\.|KeyGenerator\.|KeyPairGenerator\.|KeyFactory\.|SecretKeyFactory\.|AlgorithmParameters\.|AlgorithmParameterGenerator\.|KeyStore\.|SecureRandom\.|SSLContext\.|TrustManagerFactory\.|KeyManagerFactory\.|enabled cipher|Enabled cipher|cipher suites|Cipher Suites|TLS_[A-Z0-9_]+|SSL_[A-Z0-9_]+'

  {
    printf '# Keycloak FIPS Algorithms and Ciphers\n\n'
    printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Keycloak version: %s\n' "$version"
    printf 'Distribution: %s\n' "$dist_tar"
    printf 'Base image: %s\n' "$base_image"
    printf 'FIPS image: %s\n' "$fips_image"
    printf 'FIPS mode: %s\n' "$FIPS_MODE"
    printf 'java.security.debug: %s\n' "$JAVA_SECURITY_DEBUG"
    printf 'javax.net.debug: %s\n' "$SSL_DEBUG"
    printf 'Raw log: %s\n\n' "$raw_log"
    printf 'BCJSSE TLS probe log: %s\n\n' "$tls_probe_log"
    printf 'Instantiable crypto probe log: %s\n\n' "$instantiable_crypto_log"

    printf '## Bouncy Castle FIPS jars\n\n'
    if [[ -d "$bc_dir" ]]; then
      find "$bc_dir" -name '*.jar' -type f -print 2>/dev/null \
        | sed 's#^.*/##' \
        | sort
    else
      printf 'No Bouncy Castle FIPS jars were staged in this run; SKIP_IMAGE_BUILD=%s.\n' "$SKIP_IMAGE_BUILD"
    fi
    printf '\n'

    printf '## Provider confirmation log lines\n\n'
    grep_or_true -HnE 'FIPS1402Provider created|Inserted security providers|BCFIPS|BCJSSE|BouncyCastle|SSLContext provider' "$raw_log" "$tls_probe_log"
    printf '\n'

    printf '## BCJSSE TLS probe output\n\n'
    cat "$tls_probe_log"
    printf '\n'

    printf '## Keycloak encryption algorithm providers\n\n'
    awk -F'|' '/^KEYCLOAK_ENCRYPTION\|/ { printf "%s | %s\n", $2, $3 }' "$instantiable_crypto_log" | sort -u
    printf '\n'

    printf '## Instantiable Cipher algorithms\n\n'
    awk -F'|' '/^INSTANTIABLE\|Cipher\|/ { printf "%s | %s | %s\n", $3, $4, $5 }' "$instantiable_crypto_log" | sort -u
    printf '\n'

    printf '## Instantiable TLS cipher suites\n\n'
    awk -F'|' '/^TLS_INSTANTIABLE_CIPHER_SUITE\|/ { printf "%s | %s\n", $2, $3 }' "$instantiable_crypto_log" | sort -u
    printf '\n'

    printf '## Enabled TLS cipher suites\n\n'
    awk -F'|' '/^TLS_ENABLED_CIPHER_SUITE\|/ { printf "%s | %s\n", $2, $3 }' "$instantiable_crypto_log" | sort -u
    printf '\n'

    printf '## Instantiable encryption-related JCA algorithms\n\n'
    awk -F'|' '/^INSTANTIABLE\|/ && $2 != "Cipher" { printf "%s | %s | %s | %s\n", $2, $3, $4, $5 }' "$instantiable_crypto_log" | sort -u
    printf '\n'

    printf '## Unique JCA services observed in crypto debug logs\n\n'
    grep_or_true -Eo '(AlgorithmParameterGenerator|AlgorithmParameters|CertPathBuilder|CertPathValidator|CertStore|CertificateFactory|Cipher|Configuration|KeyAgreement|KeyFactory|KeyGenerator|KeyInfoFactory|KeyManagerFactory|KeyPairGenerator|KeyStore|Mac|MessageDigest|Policy|SSLContext|SecretKeyFactory|SecureRandom|Signature|TerminalFactory|TransformService|TrustManagerFactory|XMLSignatureFactory)\.[A-Za-z0-9_./+-]+' "$raw_log" \
      | sort -u
    printf '\n'

    printf '## Unique TLS cipher suite names observed in logs\n\n'
    grep_or_true -hEo '(TLS|SSL)_[A-Z0-9_]+(_[A-Z0-9_]+)*' "$raw_log" "$tls_probe_log" \
      | sort -u
    printf '\n'

    printf '## Relevant log lines\n\n'
    grep_or_true -HnEi "$log_filter" "$raw_log" "$tls_probe_log"
  } > "$report"
}

main() {
  require_command date
  require_command find
  require_command grep
  require_command sed
  require_command sort
  require_command tr
  require_command "$CONTAINER_RUNTIME"

  [[ "$FIPS_MODE" == "strict" || "$FIPS_MODE" == "non-strict" ]] \
    || die "FIPS_MODE must be strict or non-strict"

  cd "$PROJECT_ROOT"
  mkdir -p "$REPORT_DIR" "$WORK_ROOT"

  local version
  version="$(./get-version.sh)"
  local safe_version
  safe_version="$(sanitize_image_part "$version")"
  local timestamp
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  local run_dir="${WORK_ROOT}/${timestamp}"
  local context_dir="${run_dir}/container-context"
  local bc_dir="${context_dir}/bcfips"
  local raw_log="${REPORT_DIR}/fips_crypto_debug_raw.log"
  local tls_probe_log="${REPORT_DIR}/fips_bcjsse_tls_probe.log"
  local instantiable_crypto_log="${REPORT_DIR}/fips_instantiable_crypto.log"
  local report="${REPORT_DIR}/fips_algorithms_and_ciphers.txt"
  local base_image="keycloak-fips-base:${safe_version}-${timestamp}"
  local fips_image="${1:-keycloak-fips:${safe_version}-${timestamp}}"
  local dist_tar="${PROJECT_ROOT}/quarkus/dist/target/keycloak-${version}.tar.gz"
  local staged_dist_name="keycloak-${safe_version}-${timestamp}.tar.gz"
  local container_name="keycloak-fips-check-${timestamp}"

  CLEANUP_CONTAINER_NAME="$container_name"
  CLEANUP_RUN_DIR="$run_dir"
  trap cleanup EXIT

  if ! is_true "$SKIP_DIST_BUILD"; then
    log "Building Keycloak server distribution (${version}) without tests"
    local maven_build_args=(-pl quarkus/deployment,quarkus/dist -am -DskipTests clean install)
    if is_true "$SKIP_PROTO_LOCK"; then
      maven_build_args+=(-DskipProtoLock=true)
    fi
    ./mvnw "${maven_build_args[@]}"
  else
    log "Skipping distribution build because SKIP_DIST_BUILD=${SKIP_DIST_BUILD}"
  fi

  [[ -f "$dist_tar" ]] || die "Distribution archive not found: $dist_tar"

  if ! is_true "$SKIP_IMAGE_BUILD"; then
    mkdir -p "$context_dir"
    cp "${CONTAINER_DIR}/Dockerfile" "${context_dir}/Dockerfile"
    cp "${CONTAINER_DIR}/ubi-null.sh" "${context_dir}/ubi-null.sh"
    cp "$dist_tar" "${context_dir}/${staged_dist_name}"
    copy_bc_fips_jars "$bc_dir"
    write_fips_containerfile "${context_dir}/Containerfile.fips" "$base_image"

    log "Building base image ${base_image}"
    "$CONTAINER_RUNTIME" build \
      --build-arg "KEYCLOAK_VERSION=${version}" \
      --build-arg "KEYCLOAK_DIST=${staged_dist_name}" \
      -t "$base_image" \
      "$context_dir"

    log "Building FIPS image ${fips_image}"
    "$CONTAINER_RUNTIME" build \
      -f "${context_dir}/Containerfile.fips" \
      -t "$fips_image" \
      "$context_dir"
  else
    log "Skipping image build because SKIP_IMAGE_BUILD=${SKIP_IMAGE_BUILD}; using ${fips_image}"
    base_image="not rebuilt (SKIP_IMAGE_BUILD=${SKIP_IMAGE_BUILD})"
  fi

  remove_container_if_exists "$container_name"

  local java_opts
  java_opts="-Djava.security.debug=${JAVA_SECURITY_DEBUG} -Djavax.net.debug=${SSL_DEBUG}"
  if [[ -n "$EXTRA_JAVA_OPTS" ]]; then
    java_opts="${java_opts} ${EXTRA_JAVA_OPTS}"
  fi

  log "Starting ${container_name} from ${fips_image}"
  "$CONTAINER_RUNTIME" run -d \
    --name "$container_name" \
    -e DEBUG_SUSPEND=n \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
    -e KC_BOOTSTRAP_ADMIN_PASSWORD=adminadminadmin \
    -e KC_LOG_LEVEL=INFO,org.keycloak.common.crypto:TRACE,org.keycloak.crypto:TRACE \
    -e JAVA_OPTS_APPEND="$java_opts" \
    "$fips_image" \
    --debug start-dev \
    --features=fips \
    --fips-mode="$FIPS_MODE" \
    --http-enabled=true \
    --hostname-strict=false \
    ${EXTRA_KC_ARGS} >/dev/null

  collect_container_logs "$container_name" "$raw_log"
  dump_bcjsse_tls_probe "$fips_image" "$tls_probe_log"
  dump_instantiable_crypto_probe "$fips_image" "$instantiable_crypto_log"
  write_report "$raw_log" "$tls_probe_log" "$instantiable_crypto_log" "$report" "$version" "$base_image" "$fips_image" "$dist_tar" "$bc_dir"

  log "Raw log written to ${raw_log}"
  log "BCJSSE TLS probe written to ${tls_probe_log}"
  log "Instantiable crypto probe written to ${instantiable_crypto_log}"
  log "Report written to ${report}"

  if grep -Eq 'ERROR:|Failed to start server|NoSuchMethodError|NoSuchAlgorithmException' "$raw_log"; then
    log "Potential startup errors were found in the raw log; inspect the report and raw log."
  fi
}

main "$@"
