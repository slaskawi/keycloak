package org.keycloak.authentication.authenticators.client;

import org.keycloak.authentication.ClientAuthenticationFlowContext;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.ClientModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.idm.CredentialRepresentation;
import org.keycloak.services.ServicesLogger;
import org.keycloak.services.x509.X509ClientCertificateLookup;

import java.security.GeneralSecurityException;
import java.security.cert.X509Certificate;
import java.util.*;

public class X509ClientAuthenticator extends AbstractClientAuthenticator {

    public static final String PROVIDER_ID = "client-x509";
    protected static ServicesLogger logger = ServicesLogger.LOGGER;

    public static final AuthenticationExecutionModel.Requirement[] REQUIREMENT_CHOICES = {
            AuthenticationExecutionModel.Requirement.ALTERNATIVE,
            AuthenticationExecutionModel.Requirement.DISABLED
    };

    @Override
    public void authenticateClient(ClientAuthenticationFlowContext context) {
        logger.debugv("DO YOU EVER COME HERE !!!!!!!!!!!!!1");
        X509ClientCertificateLookup provider = context.getSession().getProvider(X509ClientCertificateLookup.class);
        if (provider == null) {
            logger.errorv("\"{0}\" Spi is not available, did you forget to update the configuration?",
                    X509ClientCertificateLookup.class);
            return;
        }

        X509Certificate[] certs = new X509Certificate[0];
        try {
            certs = provider.getCertificateChain(context.getHttpRequest());
        } catch (GeneralSecurityException e) {
            logger.errorf("[X509ClientCertificateAuthenticator:authenticate] Exception: %s", e.getMessage());
            context.attempted();
        }

        if (certs == null || certs.length == 0) {
            // No x509 client cert, fall through and
            // continue processing the rest of the authentication flow
            logger.debug("[X509ClientCertificateAuthenticator:authenticate] x509 client certificate is not available for mutual SSL.");
            context.attempted();
            return;
        }

        context.success();
    }

    public String getDisplayType() {
        return "X509 cert";
    }

    @Override
    public boolean isConfigurable() {
        return false;
    }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return REQUIREMENT_CHOICES;
    }

    @Override
    public List<ProviderConfigProperty> getConfigPropertiesPerClient() {
        return Collections.emptyList();
    }

    @Override
    public Map<String, Object> getAdapterConfiguration(ClientModel client) {
        Map<String, Object> result = new HashMap<>();
        return result;
    }

    @Override
    public Set<String> getProtocolAuthenticatorMethods(String loginProtocol) {
        if (loginProtocol.equals(OIDCLoginProtocol.LOGIN_PROTOCOL)) {
            Set<String> results = new HashSet<>();
            return results;
        } else {
            return Collections.emptySet();
        }
    }

    @Override
    public String getHelpText() {
        return "Some x509 stuff";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return new LinkedList<>();
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }
}
