# syntax=docker/dockerfile:1

### Dockerfile for Apache Guacamole
### Bundles guacd, the Guacamole web application, Tomcat and (optionally)
### MariaDB into a single container.

ARG GUAC_VER=1.6.0

### The Alpine release MUST match the one guacamole/guacd:${GUAC_VER} is built
### on. This image copies the compiled guacd binaries out of that image, and
### they are linked against the exact library versions of that release --
### notably libssl1.1/libcrypto1.1, which no longer exist after Alpine 3.18.
### Bump this only together with a Guacamole release that moves guacd forward.
ARG ALPINE_VER=3.18

### Tomcat 9 is the last release line implementing the javax.* Servlet API that
### the Guacamole web application is built against. Tomcat 10+ moved to
### jakarta.* and cannot run guacamole.war.
ARG TOMCAT_VER=9.0.121
ARG TOMCAT_SHA512=16494dd4745f808d3c506807b5275521fd71044d976f441d18eeeab0f5a38bc1b5344ca395292f6f26eb7612cd8c8e746d01ccdfb29893d394052d9f4b1f4c11

########################
### Get Guacamole Server
FROM guacamole/guacd:${GUAC_VER} AS server

########################
### Get Guacamole Client
FROM guacamole/guacamole:${GUAC_VER} AS client


####################
### Build Main Image

###############################
### Build image without MariaDB
FROM alpine:${ALPINE_VER} AS nomariadb
ARG GUAC_VER
ARG TOMCAT_VER
ARG TOMCAT_SHA512

ARG PREFIX_DIR=/opt/guacamole

LABEL version=$GUAC_VER
LABEL org.opencontainers.image.title="Apache Guacamole"
LABEL org.opencontainers.image.description="Apache Guacamole $GUAC_VER with embedded guacd, Tomcat and optional MariaDB"
LABEL org.opencontainers.image.version=$GUAC_VER
LABEL org.opencontainers.image.source="https://github.com/SimonLoebert/docker-guacamole"
LABEL org.opencontainers.image.licenses="MIT"

### Set correct environment variables.
ENV HOME=/config
ENV LC_ALL=C.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LD_LIBRARY_PATH=${PREFIX_DIR}/lib
ENV GUACD_LOG_LEVEL=info
ENV LOGBACK_LEVEL=info
ENV GUACAMOLE_HOME=/config/guacamole
### Consumed by /etc/firstrun/mariadb.sh to decide which schema upgrades apply
ENV GUAC_VER=${GUAC_VER}

### Copy build artifacts into this stage
COPY --from=server ${PREFIX_DIR} ${PREFIX_DIR}
COPY --from=client ${PREFIX_DIR} ${PREFIX_DIR}

ARG RUNTIME_DEPENDENCIES="  \
    ca-certificates         \
    ghostscript             \
    netcat-openbsd          \
    shadow                  \
    terminus-font           \
    ttf-dejavu              \
    ttf-liberation          \
    util-linux-login        \
    openjdk17-jre-headless  \
    supervisor              \
    pwgen                   \
    tzdata                  \
    procps                  \
    logrotate               \
    unzip                   \
    wget                    \
    bash                    \
    tini"

COPY image /

### Install packages and clean up in one command to reduce build size

RUN apk add --no-cache ${RUNTIME_DEPENDENCIES}                                                                                                                                      && \
    xargs apk add --no-cache < ${PREFIX_DIR}/DEPENDENCIES                                                                                                                           && \
    adduser -h /config -s /bin/nologin -u 99 -D abc                                                                                                                                 && \
    adduser -h /opt/tomcat -s /bin/false -D tomcat                                                                                                                                  && \
    mkdir -p /opt/tomcat                                                                                                                                                            && \
    for MIRROR in https://dlcdn.apache.org/tomcat https://archive.apache.org/dist/tomcat; do                                                                                            \
        wget -O /tmp/tomcat.tar.gz "${MIRROR}/tomcat-9/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz" && break;                                                                 \
    done                                                                                                                                                                            && \
    echo "${TOMCAT_SHA512}  /tmp/tomcat.tar.gz" | sha512sum -c -                                                                                                                     && \
    tar -xf /tmp/tomcat.tar.gz -C /opt/tomcat --strip-components=1                                                                                                                   && \
    rm /tmp/tomcat.tar.gz                                                                                                                                                           && \
    rm -rf /opt/tomcat/webapps.dist /opt/tomcat/webapps/*                                                                                                                            && \
    rm -f /opt/tomcat/bin/*.bat                                                                                                                                                     && \
    find /opt/tomcat -type d -print0 | xargs -0 chmod 700                                                                                                                           && \
    chmod +x /opt/tomcat/bin/*.sh                                                                                                                                                   && \
    mkdir -p /var/lib/tomcat/webapps /var/log/tomcat                                                                                                                                && \
    ln -s ${PREFIX_DIR}/webapp/guacamole.war /var/lib/tomcat/webapps/ROOT.war                                                                                                       && \
    chmod +x /etc/firstrun/*.sh                                                                                                                                                     && \
    mkdir -p /config/guacamole /config/log/tomcat /var/lib/tomcat/temp /var/run/tomcat                                                                                              && \
    ln -s /opt/tomcat/conf /var/lib/tomcat/conf                                                                                                                                     && \
    ln -s /config/log/tomcat /var/lib/tomcat/logs                                                                                                                                   && \
    sed -i '/<\/Host>/i \        <Valve className=\"org.apache.catalina.valves.RemoteIpValve\"\n               remoteIpHeader=\"x-forwarded-for\" />' /opt/tomcat/conf/server.xml

EXPOSE 8080

VOLUME ["/config"]

CMD [ "/etc/firstrun/firstrun.sh" ]


############################
### Build image with MariaDB
FROM nomariadb AS mariadb
ARG GUAC_VER
LABEL version=$GUAC_VER

RUN apk add --no-cache mariadb mariadb-client

COPY image-mariadb /

RUN chmod +x /etc/firstrun/mariadb.sh

### END
### To make this a persistent guacamole container, you must map /config of this container
### to a folder on your host machine.
###
