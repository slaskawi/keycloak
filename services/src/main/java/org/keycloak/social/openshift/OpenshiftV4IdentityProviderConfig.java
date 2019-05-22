package org.keycloak.social.openshift;

import org.keycloak.broker.oidc.OAuth2IdentityProviderConfig;
import org.keycloak.models.IdentityProviderModel;

import java.util.Map;
import java.util.Optional;

public class OpenshiftV4IdentityProviderConfig extends OAuth2IdentityProviderConfig {

    enum ConfigurationValue {
        BASE_URL("baseUrl", "https://api.preview.openshift.com") {
            @Override
            public void setValue(Map<String, String> config, String value) {
                super.setValue(config, trimTrailingSlash(value));
            }
        },
        AUTHORIZATION_RESOURCE("authorizationResource", "/oauth/authorize"),
        TOKEN_RESOURCE("tokenResource", "/oauth/token"),
        PROFILE_RESOURCE("profileResource", "/oapi/v1/users/~"),
        DEFAULT_SCOPE("defaultScope", "user:info");

        private final String defaultValue;
        private final String configPropertyName;

        ConfigurationValue(String configPropertyName, String defaultValue) {
            this.defaultValue = defaultValue;
            this.configPropertyName = configPropertyName;
        }

        void setValue(Map<String, String> config, String value) {
            config.put(configPropertyName, value);
        }

        String getValue(Map<String, String> config) {
            return Optional.ofNullable(config.get(configPropertyName)).orElse(defaultValue);
        }

        static String trimTrailingSlash(String baseUrl) {
            if (baseUrl != null && baseUrl.endsWith("/")) {
                baseUrl = baseUrl.substring(0, baseUrl.length() - 1);
            }
            return baseUrl;
        }
    }

    public OpenshiftV4IdentityProviderConfig(IdentityProviderModel identityProviderModel) {
        super(identityProviderModel);
    }

    @Override
    public void setAuthorizationUrl(String authorizationUrl) {
        ConfigurationValue.AUTHORIZATION_RESOURCE.setValue(getConfig(), authorizationUrl);
    }

    @Override
    public String getAuthorizationUrl() {
        return ConfigurationValue.BASE_URL.getValue(getConfig()) + ConfigurationValue.AUTHORIZATION_RESOURCE.getValue(getConfig());
    }

    @Override
    public String getTokenUrl() {
        return ConfigurationValue.BASE_URL.getValue(getConfig()) + ConfigurationValue.TOKEN_RESOURCE.getValue(getConfig());
    }

    @Override
    public void setTokenUrl(String tokenUrl) {
        throw new UnsupportedOperationException("Setting Token URL is only supported through " + ConfigurationValue.BASE_URL.name());
    }

    @Override
    public String getDefaultScope() {
        return ConfigurationValue.DEFAULT_SCOPE.getValue(getConfig());
    }

    @Override
    public void setDefaultScope(String defaultScope) {
        ConfigurationValue.DEFAULT_SCOPE.setValue(getConfig(), defaultScope);
    }

    public String getProfileUrl() {
        return ConfigurationValue.BASE_URL.getValue(getConfig()) + ConfigurationValue.PROFILE_RESOURCE.getValue(getConfig());
    }

    public void setProfileResource(String profileResource) {
        ConfigurationValue.PROFILE_RESOURCE.setValue(getConfig(), profileResource);
    }

    public void setTokenResource(String tokenResource) {
        ConfigurationValue.TOKEN_RESOURCE.setValue(getConfig(), tokenResource);
    }

    public void setAuthorizationResource(String authorizationResource) {
        ConfigurationValue.AUTHORIZATION_RESOURCE.setValue(getConfig(), authorizationResource);
    }

    public void setBaseUrl(String baseUrl) {
        ConfigurationValue.BASE_URL.setValue(getConfig(), baseUrl);
    }

    public String getBaseUrl() {
        return ConfigurationValue.BASE_URL.getValue(getConfig());
    }
}
