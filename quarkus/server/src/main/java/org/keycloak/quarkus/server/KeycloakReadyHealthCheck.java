package org.keycloak.quarkus.server;

import io.agroal.api.AgroalDataSource;
import org.eclipse.microprofile.health.HealthCheck;
import org.eclipse.microprofile.health.HealthCheckResponse;
import org.eclipse.microprofile.health.Readiness;

import javax.enterprise.context.ApplicationScoped;
import javax.inject.Inject;

@Readiness
@ApplicationScoped
public class KeycloakReadyHealthCheck implements HealthCheck {

    @Inject
    private AgroalDataSource agroalDataSource;

    @Override
    public HealthCheckResponse call() {
        long creationCount = agroalDataSource.getMetrics().creationCount();
        if (creationCount < 1) {
            return HealthCheckResponse.down("No connections were created");
        }
        return HealthCheckResponse.up("Keycloak database is ready");
    }
}
