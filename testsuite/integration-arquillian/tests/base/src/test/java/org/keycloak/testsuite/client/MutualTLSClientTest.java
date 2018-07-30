package org.keycloak.testsuite.client;

import static org.junit.Assume.assumeTrue;

import java.io.IOException;
import java.util.function.Supplier;

import org.apache.http.impl.client.CloseableHttpClient;
import org.junit.Assert;
import org.junit.Assume;
import org.junit.BeforeClass;
import org.junit.Test;
import org.keycloak.representations.idm.RealmRepresentation;
import org.keycloak.testsuite.AbstractTestRealmKeycloakTest;
import org.keycloak.testsuite.util.MutualTLSUtils;
import org.keycloak.testsuite.util.OAuthClient;

/**
 * Mutual TLS Client tests.
 */
public class MutualTLSClientTest extends AbstractTestRealmKeycloakTest {

   private static final boolean sslRequired = Boolean.parseBoolean(System.getProperty("auth.server.ssl.required"));

   @Override
   public void configureTestRealm(RealmRepresentation testRealm) {
      //TODO: Configure Mutual TLS for the client here
   }

   @BeforeClass
   public static void sslRequired() {
      Assume.assumeTrue("\"auth.server.ssl.required\" is required for Mutual TLS tests", sslRequired);
   }

   @Test
   public void testSuccessfulClientInvocationWithProperCertificate() throws Exception {
      //given
      Supplier<CloseableHttpClient> clientWithProperCertificate = MutualTLSUtils::newCloseableHttpClientWithDefaultKeyStoreAndTrustStore;

      //when
      OAuthClient.AccessTokenResponse token = getTokenUsingTheClient(clientWithProperCertificate);

      //then
      Assert.assertEquals(200, token.getStatusCode());
      Assert.assertFalse(token.getAccessToken().isEmpty());
   }

   @Test
   public void testFailedClientInvocationWithWrongCertificate() throws Exception {
      //given
      Supplier<CloseableHttpClient> clientWithWrongCertificate = MutualTLSUtils::newCloseableHttpClientWithOtherKeyStoreAndTrustStore;

      //when
      OAuthClient.AccessTokenResponse token = getTokenUsingTheClient(clientWithWrongCertificate);

      //then
      Assert.assertEquals(401, token.getStatusCode());
      Assert.assertTrue(token.getAccessToken().isEmpty());
   }

   @Test
   public void testFailedClientInvocationWithoutCertificateCertificate() throws Exception {
      //given
      Supplier<CloseableHttpClient> clientWithoutCertificate = MutualTLSUtils::newCloseableHttpClientWithoutKeyStoreAndTrustStore;

      //when
      OAuthClient.AccessTokenResponse token = getTokenUsingTheClient(clientWithoutCertificate);

      //then
      Assert.assertEquals(401, token.getStatusCode());
      Assert.assertTrue(token.getAccessToken().isEmpty());
   }

   private OAuthClient.AccessTokenResponse getTokenUsingTheClient(Supplier<CloseableHttpClient> client) throws IOException{
      try (CloseableHttpClient closeableHttpClient = client.get()) {
         return oauth.doAccessTokenRequest(null, null, closeableHttpClient);
      }  catch (IOException ioe) {
         throw ioe;
      }
   }

}
