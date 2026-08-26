package com.bench.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;
import java.net.URI;

/**
 * Builds the DataSource for the benchmark contract without an ORM.
 *
 * <p>The testbed passes a libpq-style {@code DATABASE_URL} such as
 * {@code postgres://bench:test@127.0.0.1:5432/bench} plus an exact
 * {@code DB_POOL_SIZE}. Spring's JDBC layer wants a
 * {@code jdbc:postgresql://host:port/db} URL and separate username/password,
 * so here we parse the libpq URL and translate it. If a
 * {@code SPRING_DATASOURCE_URL} (+ {@code _USERNAME}/{@code _PASSWORD}) is set
 * it wins -- that is the escape hatch for an operator who already has a JDBC
 * URL and does not want the translation.
 *
 * <p>The pool is sized to exactly {@code DB_POOL_SIZE}: maximumPoolSize ==
 * minimumIdle so the pool opens and holds the contracted number of
 * connections rather than idling below it and growing on demand. This matches
 * the Go and Rust references, both of which pin MinConns to MaxConns.
 */
@Configuration
public class DatabaseConfig {

    @Bean
    public DataSource dataSource() {
        String jdbcUrl = firstNonBlank(System.getenv("SPRING_DATASOURCE_URL"), "");
        String username = firstNonBlank(System.getenv("SPRING_DATASOURCE_USERNAME"), "");
        String password = firstNonBlank(System.getenv("SPRING_DATASOURCE_PASSWORD"), "");

        if (jdbcUrl.isBlank()) {
            String libpq = System.getenv("DATABASE_URL");
            if (libpq == null || libpq.isBlank()) {
                throw new IllegalStateException("DATABASE_URL must be set (or SPRING_DATASOURCE_URL)");
            }
            ParsedDb parsed = parseLibpq(libpq);
            jdbcUrl = parsed.jdbcUrl;
            username = parsed.username;
            password = parsed.password;
        }

        int poolSize = parsePoolSize(System.getenv("DB_POOL_SIZE"));

        HikariConfig hc = new HikariConfig();
        hc.setJdbcUrl(jdbcUrl);
        hc.setUsername(username);
        hc.setPassword(password);
        hc.setPoolName("bench-spring");
        hc.setMaximumPoolSize(poolSize);
        hc.setMinimumIdle(poolSize);
        hc.setConnectionTimeout(10_000);
        hc.setValidationTimeout(5_000);
        hc.setIdleTimeout(300_000);
        hc.setMaxLifetime(1_800_000);

        return new HikariDataSource(hc);
    }

    private static int parsePoolSize(String raw) {
        if (raw == null || raw.isBlank()) {
            raw = "32";
        }
        int n = Integer.parseInt(raw.trim());
        if (n <= 0) {
            throw new IllegalStateException("DB_POOL_SIZE must be > 0");
        }
        return n;
    }

    private static String firstNonBlank(String a, String b) {
        return (a != null && !a.isBlank()) ? a : b;
    }

    private static ParsedDb parseLibpq(String url) {
        URI u = URI.create(url);
        String userInfo = u.getUserInfo();
        String user = "";
        String pass = "";
        if (userInfo != null) {
            int colon = userInfo.indexOf(':');
            if (colon >= 0) {
                user = userInfo.substring(0, colon);
                pass = userInfo.substring(colon + 1);
            } else {
                user = userInfo;
            }
        }
        String host = (u.getHost() != null) ? u.getHost() : "localhost";
        int port = (u.getPort() > 0) ? u.getPort() : 5432;
        String path = u.getPath();
        String db = (path != null && path.length() > 1) ? path.substring(1) : "bench";
        String jdbc = "jdbc:postgresql://" + host + ":" + port + "/" + db;
        return new ParsedDb(jdbc, user, pass);
    }

    private record ParsedDb(String jdbcUrl, String username, String password) {}
}
