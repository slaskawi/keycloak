package org.keycloak.testsuite.dballocator.client;

import org.apache.commons.io.IOUtils;
import org.junit.Assert;
import org.junit.Test;
import org.keycloak.testsuite.dballocator.client.data.AllocationResult;
import org.keycloak.testsuite.dballocator.client.exceptions.DBAllocatorException;
import org.keycloak.testsuite.dballocator.client.exceptions.DBAllocatorUnavailableException;
import org.keycloak.testsuite.dballocator.client.retry.IncrementalBackoffRetryPolicy;

import javax.ws.rs.core.Response;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.Charset;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

import static org.mockito.Mockito.any;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.spy;


public class DBAllocatorServiceClientTest {

    @Test
    public void testSuccessfulAllocation() throws Exception {
        //given
        URI mockURI = URI.create("http://localhost:8080/test");

        Response successfulResponse = null;
        String testProperties = null;
        try(InputStream is = DBAllocatorServiceClientTest.class.getResourceAsStream("/db-allocator-response.properties")) {
            testProperties = IOUtils.toString(is, Charset.defaultCharset());
            successfulResponse = Response.ok(testProperties).build();
        }
        successfulResponse = spy(successfulResponse);
        doReturn(testProperties).when(successfulResponse).readEntity(String.class);

        BackoffRetryPolicy retryPolicyMock = mock(BackoffRetryPolicy.class);
        doReturn(successfulResponse).when(retryPolicyMock).retryTillHttpOk(any(Callable.class));

        DBAllocatorServiceClient client = new DBAllocatorServiceClient(mockURI, retryPolicyMock);

        //when
        AllocationResult allocationResult = client.allocate("user", "mariadb_galera_101", 1440, TimeUnit.SECONDS, "geo_RDU");

        //then
        Assert.assertEquals("d328bb0e-3dcc-42da-8ce1-83738a8dfede", allocationResult.getUUID());
        Assert.assertEquals("org.mariadb.jdbc.Driver", allocationResult.getDriver());
        Assert.assertEquals("dbname", allocationResult.getDatabase());
        Assert.assertEquals("username", allocationResult.getUser());
        Assert.assertEquals("password", allocationResult.getPassword());
        Assert.assertEquals("jdbc:mariadb://mariadb-101-galera.keycloak.org:3306", allocationResult.getURL());
    }

    @Test
    public void testFailureAllocation() throws Exception {
        //given
        URI mockURI = URI.create("http://localhost:8080/test");

        Response serverErrorResponse = Response.serverError().build();
        BackoffRetryPolicy retryPolicyMock = mock(BackoffRetryPolicy.class);
        doThrow(new DBAllocatorUnavailableException(serverErrorResponse)).when(retryPolicyMock).retryTillHttpOk(any(Callable.class));

        DBAllocatorServiceClient client = new DBAllocatorServiceClient(mockURI, retryPolicyMock);

        //when
        try {
            client.allocate("user", "mariadb_galera_101", 1440, TimeUnit.SECONDS, "geo_RDU");
            Assert.fail();
        } catch (DBAllocatorException e) {
            Assert.assertEquals(500, e.getErrorResponse().getStatus());
        }
    }
}