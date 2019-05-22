package org.keycloak.social.openshift;

import org.junit.Assert;
import org.junit.Test;
import org.keycloak.models.IdentityProviderModel;

public class OpenshiftV4IdentityProviderConfigTest {

    @Test
    public void shouldSetProperEntriesInConfig() throws Exception {
        //given
        String baseUrl = "https://localhost:8443";
        String authorizationResource = "/authenticationResource";
        String tokenResource = "/tokenResource";
        String profileResource = "/profileResource";
        String defaultScope = "a:b";

        //when
        OpenshiftV4IdentityProviderConfig config = new OpenshiftV4IdentityProviderConfig(new IdentityProviderModel());

        config.setBaseUrl(baseUrl);
        config.setAuthorizationResource(authorizationResource);
        config.setTokenResource(tokenResource);
        config.setProfileResource(profileResource);
        config.setDefaultScope(defaultScope);

        //then
        Assert.assertEquals(baseUrl, config.getBaseUrl());
        Assert.assertEquals(baseUrl + authorizationResource, config.getAuthorizationUrl());
        Assert.assertEquals(baseUrl + profileResource, config.getProfileUrl());
        Assert.assertEquals(baseUrl + tokenResource, config.getTokenUrl());
        Assert.assertEquals(defaultScope, config.getDefaultScope());
    }

}