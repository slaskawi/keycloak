package org.keycloak.social.openshift;

import com.fasterxml.jackson.databind.JsonNode;
import org.keycloak.broker.oidc.AbstractOAuth2IdentityProvider;
import org.keycloak.broker.oidc.mappers.AbstractJsonUserAttributeMapper;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdentityBrokerException;
import org.keycloak.broker.provider.util.SimpleHttp;
import org.keycloak.broker.social.SocialIdentityProvider;
import org.keycloak.events.EventBuilder;
import org.keycloak.models.KeycloakSession;

import java.io.IOException;
import java.util.Optional;

/**
 * Identity provider for Openshift V4.
 *
 */
public class OpenshiftV4IdentityProvider extends AbstractOAuth2IdentityProvider<OpenshiftV4IdentityProviderConfig> implements SocialIdentityProvider<OpenshiftV4IdentityProviderConfig> {


    public OpenshiftV4IdentityProvider(KeycloakSession session, OpenshiftV4IdentityProviderConfig config) {
        super(session, config);
        config.setAuthorizationUrl(config.getAuthorizationUrl());
        config.setTokenUrl(config.getTokenUrl());
        config.setUserInfoUrl(config.getUserInfoUrl());
    }

    @Override
    protected String getDefaultScopes() {
        return getConfig().getDefaultScope();
    }

    @Override
    protected BrokeredIdentityContext doGetFederatedIdentity(String accessToken) {
        try {
            final JsonNode profile = fetchProfile(accessToken);
            final BrokeredIdentityContext user = extractUserContext(profile);
            AbstractJsonUserAttributeMapper.storeUserProfileForMapper(user, profile, getConfig().getAlias());
            return user;
        } catch (Exception e) {
            throw new IdentityBrokerException("Could not obtain user profile from Openshift.", e);
        }
    }

    private BrokeredIdentityContext extractUserContext(JsonNode profile) {
        JsonNode metadata = profile.get("metadata");

        final BrokeredIdentityContext user = new BrokeredIdentityContext(getJsonProperty(metadata, "uid"));
        user.setUsername(getJsonProperty(metadata, "name"));
        user.setName(getJsonProperty(profile, "fullName"));
        user.setIdpConfig(getConfig());
        user.setIdp(this);
        return user;
    }

    private JsonNode fetchProfile(String accessToken) throws IOException {
        return SimpleHttp.doGet(getConfig().getUserInfoUrl(), this.session)
                             .header("Authorization", "Bearer " + accessToken)
                             .asJson();
    }

    @Override
    protected boolean supportsExternalExchange() {
        return true;
    }

    @Override
    protected String getProfileEndpointForValidation(EventBuilder event) {
        return getConfig().getUserInfoUrl();
    }

    @Override
    protected BrokeredIdentityContext extractIdentityFromProfile(EventBuilder event, JsonNode profile) {
        final BrokeredIdentityContext user = extractUserContext(profile.get("metadata"));
        AbstractJsonUserAttributeMapper.storeUserProfileForMapper(user, profile, getConfig().getAlias());
        return user;
    }

}
