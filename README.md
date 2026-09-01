# Apache Guacamole (Docker)

Apache Guacamole packaged as a single container: the Guacamole web application,
`guacd`, Tomcat and — optionally — an embedded MariaDB, all in one image.
Guacamole is a clientless remote desktop gateway supporting VNC, RDP and SSH
through the browser.

**Current version: Apache Guacamole 1.6.0**

This is a maintained fork of [jason-bean/docker-guacamole](https://github.com/jason-bean/docker-guacamole),
which is no longer being updated.

## Images

Images are built for `linux/amd64` and `linux/arm64` and published to the
GitHub Container Registry:

| Tag | Contents |
| --- | --- |
| `ghcr.io/simonloebert/docker-guacamole:latest` | Guacamole + guacd + embedded MariaDB |
| `ghcr.io/simonloebert/docker-guacamole:1.6.0` | Same, pinned to a Guacamole release |
| `ghcr.io/simonloebert/docker-guacamole:latest-nomariadb` | Guacamole + guacd, bring your own database |
| `ghcr.io/simonloebert/docker-guacamole:1.6.0-nomariadb` | Same, pinned to a Guacamole release |

Use the `-nomariadb` variant when the Guacamole database lives on an external
MySQL/MariaDB, PostgreSQL or SQL Server instance, or when authentication is
handled entirely by LDAP or an SSO provider.

## Running

Create a directory on the host for the configuration and (for the MariaDB
variant) the database, then map it to `/config`:

```
docker run -d \
  --name guacamole \
  -p 8080:8080 \
  -v /your-config-location:/config \
  -e OPT_MYSQL=Y \
  ghcr.io/simonloebert/docker-guacamole:latest
```

Browse to `http://your-host-ip:8080` and log in with user and password
`guacadmin`. **Change that password immediately after the first login.**

Everything that has to survive a container replacement lives under `/config`:
`guacamole.properties`, the installed extensions, the logs and — with
`OPT_MYSQL=Y` — the MariaDB data directory.

## Configuration

### General

| Variable | Default | Description |
| --- | --- | --- |
| `PUID` | `99` | User ID that owns `/config` and runs Tomcat, guacd and MariaDB |
| `PGID` | `100` | Group ID for the same |
| `TZ` | | Time zone, e.g. `Europe/Berlin` |
| `GUACD_LOG_LEVEL` | `info` | guacd log level (`trace`, `debug`, `info`, `warning`, `error`) |
| `LOGBACK_LEVEL` | `info` | Log level of the web application |

### Extensions

Every extension is opt-in: set the variable to `Y` to install it, leave it
unset (or set it to `N`) to remove it again. Extensions are installed into
`/config/guacamole/extensions` on start-up and are upgraded automatically when
the image ships a newer version, so an image update is all that is needed.

| Variable | Extension |
| --- | --- |
| `OPT_MYSQL` | MySQL/MariaDB authentication **and** the embedded MariaDB server |
| `OPT_MYSQL_EXTENSION` | MySQL/MariaDB authentication only, against an external server |
| `OPT_POSTGRES` | PostgreSQL authentication (external server) |
| `OPT_SQLSERVER` | SQL Server authentication (external server) |
| `OPT_LDAP` | LDAP authentication |
| `OPT_DUO` | Duo two-factor authentication |
| `OPT_TOTP` | TOTP two-factor authentication |
| `OPT_CAS` | CAS single sign-on |
| `OPT_OPENID` | OpenID Connect single sign-on |
| `OPT_SAML` | SAML single sign-on |
| `OPT_SSL` | SSL/TLS client certificate authentication |
| `OPT_HEADER` | Authentication via an HTTP header set by a reverse proxy |
| `OPT_JSON` | Encrypted JSON authentication |
| `OPT_QUICKCONNECT` | Quick Connect, for ad-hoc connections |
| `OPT_BAN` | Brute-force protection (temporary bans after failed logins) |
| `OPT_RESTRICT` | Additional per-user login restrictions (time and host based) |
| `OPT_HISTORY_RECORDING_STORAGE` | Session recording playback from the web interface |
| `OPT_DISPLAY_STATISTICS` | On-screen connection statistics |
| `OPT_VAULT_KSM` | Keeper Secrets Manager vault integration |

Extensions are configured in `/config/guacamole/guacamole.properties`; see the
[Guacamole manual](https://guacamole.apache.org/doc/gug/) for the properties
each one expects. Schema files for the database extensions are copied to
`/config/mysql-schema`, `/config/postgresql-schema` and
`/config/sqlserver-schema`; the LDAP schema is copied to `/config/ldap-schema`.

`OPT_MYSQL=Y` uses the embedded MariaDB and needs no further configuration —
the database, its user and a random password are created on first start. To use
an external database instead, set `OPT_MYSQL_EXTENSION=Y` (or `OPT_POSTGRES=Y`
/ `OPT_SQLSERVER=Y`), apply the schema from `/config/<type>-schema` yourself and
point the properties file at your server.

## Upgrading

Pull the new image and recreate the container. On start-up the extensions in
`/config/guacamole/extensions` are replaced with the versions from the new
image, and — with `OPT_MYSQL=Y` — any outstanding schema upgrades are applied to
the embedded database automatically.

Guacamole 1.6.0 changes the database schema, so **back up `/config` before
upgrading** from an older release of this image. If you run an external
database, apply `upgrade-pre-1.6.0.sql` from `/config/<type>-schema/upgrade`
yourself before starting the new image.

## Building

```
git clone https://github.com/SimonLoebert/docker-guacamole.git
cd docker-guacamole
./build.sh
```

`build.sh` builds both variants and reads the Guacamole version from the
Dockerfile. To build a single variant directly:

```
docker build --target nomariadb -t guacamole:nomariadb .
docker build --target mariadb   -t guacamole .
```

CI builds and publishes both variants for both architectures from
`.github/workflows/docker.yml`. It pushes to `ghcr.io` out of the box; to
publish to Docker Hub as well, add the repository secrets
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (and optionally the repository
variable `DOCKERHUB_REPOSITORY` to override the default `<username>/guacamole`).

### Version pinning

The versions the image is built from are declared as build arguments at the top
of the `Dockerfile`:

* `GUAC_VER` — the Apache Guacamole release. `guacd` and the web application are
  taken from the official `guacamole/guacd` and `guacamole/guacamole` images.
* `ALPINE_VER` — must match the Alpine release that `guacamole/guacd:${GUAC_VER}`
  is built on, because the guacd binaries copied out of that image are linked
  against its exact library versions. Bump it only when upstream does.
* `TOMCAT_VER` / `TOMCAT_SHA512` — Tomcat 9 is required: it is the last release
  line implementing the `javax.*` Servlet API that Guacamole is built against.
  The download is verified against the checksum, so both change together.

## Credits

Apache Guacamole is copyright The Apache Software Foundation and licensed under
the Apache License, Version 2.0.

This image is based on the work of Jason Bean, and before that on
aptalca/docker-containers, Zuhkov/docker-containers and hall/guacamole.
