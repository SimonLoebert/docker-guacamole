#!/bin/bash

### Source layout of the official guacamole/guacamole image (1.6.0 and later):
###   /opt/guacamole/webapp/guacamole.war   the web application itself
###   /opt/guacamole/extensions/...         one directory per extension
###   /opt/guacamole/drivers/...            JDBC drivers
EXT_STORE="/opt/guacamole"
EXT_SRC="$EXT_STORE/extensions"
DRIVER_SRC="$EXT_STORE/drivers"

GUAC_HOME="${GUACAMOLE_HOME:-/config/guacamole}"
GUAC_EXT="$GUAC_HOME/extensions"
GUAC_LIB="$GUAC_HOME/lib"
TOMCAT_LOG="/config/log/tomcat"

### Returns success if the named OPT_* variable is set to Y.
enabled() {
  local value="${!1:-N}"
  [ "${value^^}" = "Y" ]
}

### Returns success if at least one file matches the glob.
exists() {
  compgen -G "$1" > /dev/null
}

### install_extension <label> <glob> <source jar> [destination prefix]
###
### Installs (or replaces, when the shipped jar differs from the installed one)
### a single extension jar in $GUAC_EXT. The glob is matched against the
### installed jars so that renamed jars from older Guacamole releases are
### cleaned up rather than left behind next to the new one.
install_extension() {
  local label="$1" glob="$2" src="$3" prefix="${4:-}"
  local dest="$GUAC_EXT/${prefix}$(basename "$src")"

  if [ ! -f "$src" ]; then
    echo "Warning: $label extension is not shipped with this image, skipping."
    return
  fi

  if [ -f "$dest" ] && diff -q "$dest" "$src" > /dev/null 2>&1; then
    echo "Using existing $label extension."
    return
  fi

  if exists "$GUAC_EXT/$glob"; then
    echo "Upgrading $label extension."
    rm -f "$GUAC_EXT"/$glob
  else
    echo "Copying $label extension."
  fi

  cp "$src" "$dest"
}

### remove_extension <label> <glob>
remove_extension() {
  local label="$1" glob="$2"

  if exists "$GUAC_EXT/$glob"; then
    echo "Removing $label extension."
    rm -f "$GUAC_EXT"/$glob
  fi
}

### sync_schema <source directory> <destination directory>
###
### Copies the SQL/LDIF files an administrator needs to initialise an external
### database or directory. Always refreshed so they match the installed jars.
sync_schema() {
  local src="$1" dest="$2"

  [ -d "$src" ] || return
  mkdir -p "$dest"
  cp -R "$src"/. "$dest"/
}

# Create user
PUID=${PUID:-99}
PGID=${PGID:-100}

groupmod -o -g "$PGID" abc
usermod -o -u "$PUID" abc

echo "----------------------"
echo "User UID: $(id -u abc)"
echo "User GID: $(id -g abc)"
echo "----------------------"

chown -R abc:abc /config
chown -R abc:abc /opt/tomcat /var/run/tomcat /var/lib/tomcat

mkdir -p "$GUAC_EXT" "$GUAC_LIB" "$TOMCAT_LOG"

# Check if properties file exists. If not, copy in the starter database
if [ -f "$GUAC_HOME"/guacamole.properties ]; then
  echo "Using existing properties file."
else
  echo "Creating properties from template."
  cp /etc/firstrun/templates/* "$GUAC_HOME"
  if enabled OPT_MYSQL && [ -f /etc/firstrun/mariadb.sh ]; then
    echo "Creating Database folders"
    mkdir -p /config/databases
    chown abc:abc /config/databases
  fi
  PW=$(pwgen -1snc 32)
  sed -i -e 's/some_password/'"$PW"'/g' "$GUAC_HOME"/guacamole.properties
fi

# Check if logback.xml exists and set the log level based on LOGBACK_LEVEL value
if [ ! -f "$GUAC_HOME"/logback.xml ]; then
  unzip -o -j "$EXT_STORE"/webapp/guacamole.war WEB-INF/classes/logback.xml -d "$GUAC_HOME" > /dev/null
fi
sed -i 's/ level="[^"]*"/ level="'"$LOGBACK_LEVEL"'"/' "$GUAC_HOME"/logback.xml

### MySQL
### OPT_MYSQL enables the embedded MariaDB, OPT_MYSQL_EXTENSION only installs
### the extension so that an external MySQL/MariaDB server can be used.
if enabled OPT_MYSQL || enabled OPT_MYSQL_EXTENSION; then
  install_extension "MySQL" '*jdbc-mysql*.jar' "$EXT_SRC/guacamole-auth-jdbc/mysql/guacamole-auth-jdbc-mysql.jar"
  sync_schema "$EXT_SRC/guacamole-auth-jdbc/mysql/schema" /config/mysql-schema
  # The driver was renamed from mysql-connector-*.jar to mysql-jdbc.jar in 1.6.0
  rm -f "$GUAC_LIB"/mysql-connector*.jar
  cp -f "$DRIVER_SRC"/mysql-jdbc.jar "$GUAC_LIB"
else
  remove_extension "MySQL" '*jdbc-mysql*.jar'
  rm -f "$GUAC_LIB"/mysql-connector*.jar "$GUAC_LIB"/mysql-jdbc.jar
  rm -rf /config/mysql-schema
fi

### SQL Server
if enabled OPT_SQLSERVER; then
  install_extension "SQL Server" '*jdbc-sqlserver*.jar' "$EXT_SRC/guacamole-auth-jdbc/sqlserver/guacamole-auth-jdbc-sqlserver.jar"
  sync_schema "$EXT_SRC/guacamole-auth-jdbc/sqlserver/schema" /config/sqlserver-schema
  cp -f "$DRIVER_SRC"/mssql-jdbc.jar "$GUAC_LIB"
else
  remove_extension "SQL Server" '*jdbc-sqlserver*.jar'
  rm -f "$GUAC_LIB"/mssql-jdbc.jar
  rm -rf /config/sqlserver-schema
fi

### PostgreSQL
if enabled OPT_POSTGRES; then
  install_extension "PostgreSQL" '*jdbc-postgresql*.jar' "$EXT_SRC/guacamole-auth-jdbc/postgresql/guacamole-auth-jdbc-postgresql.jar"
  sync_schema "$EXT_SRC/guacamole-auth-jdbc/postgresql/schema" /config/postgresql-schema
  cp -f "$DRIVER_SRC"/postgresql-jdbc.jar "$GUAC_LIB"
else
  remove_extension "PostgreSQL" '*jdbc-postgresql*.jar'
  rm -f "$GUAC_LIB"/postgresql-jdbc.jar
  rm -rf /config/postgresql-schema
fi

### LDAP
if enabled OPT_LDAP; then
  install_extension "LDAP" '*ldap*.jar' "$EXT_SRC/guacamole-auth-ldap/guacamole-auth-ldap.jar"
  sync_schema "$EXT_SRC/guacamole-auth-ldap/schema" /config/ldap-schema
else
  remove_extension "LDAP" '*ldap*.jar'
  rm -rf /config/ldap-schema
fi

### Duo two-factor authentication
if enabled OPT_DUO; then
  install_extension "Duo" '*duo*.jar' "$EXT_SRC/guacamole-auth-duo/guacamole-auth-duo.jar"
else
  remove_extension "Duo" '*duo*.jar'
fi

### CAS single sign-on
if enabled OPT_CAS; then
  install_extension "CAS" '*cas*.jar' "$EXT_SRC/guacamole-auth-sso/cas/guacamole-auth-sso-cas.jar"
else
  remove_extension "CAS" '*cas*.jar'
fi

### OpenID Connect single sign-on
### Guacamole loads extensions in alphabetical order and the OpenID extension
### has to come first for redirect-based login to work, hence the "1-" prefix.
if enabled OPT_OPENID; then
  install_extension "OpenID" '*openid*.jar' "$EXT_SRC/guacamole-auth-sso/openid/guacamole-auth-sso-openid.jar" "1-"
else
  remove_extension "OpenID" '*openid*.jar'
fi

### SAML single sign-on
if enabled OPT_SAML; then
  install_extension "SAML" '*saml*.jar' "$EXT_SRC/guacamole-auth-sso/saml/guacamole-auth-sso-saml.jar"
else
  remove_extension "SAML" '*saml*.jar'
fi

### SSL/TLS client certificate authentication
if enabled OPT_SSL; then
  install_extension "SSL" '*sso-ssl*.jar' "$EXT_SRC/guacamole-auth-sso/ssl/guacamole-auth-sso-ssl.jar"
else
  remove_extension "SSL" '*sso-ssl*.jar'
fi

### TOTP two-factor authentication
if enabled OPT_TOTP; then
  install_extension "TOTP" '*totp*.jar' "$EXT_SRC/guacamole-auth-totp/guacamole-auth-totp.jar"
else
  remove_extension "TOTP" '*totp*.jar'
fi

### Quick Connect
if enabled OPT_QUICKCONNECT; then
  install_extension "Quick Connect" '*quickconnect*.jar' "$EXT_SRC/guacamole-auth-quickconnect/guacamole-auth-quickconnect.jar"
else
  remove_extension "Quick Connect" '*quickconnect*.jar'
fi

### HTTP header authentication
if enabled OPT_HEADER; then
  install_extension "Header" '*header*.jar' "$EXT_SRC/guacamole-auth-header/guacamole-auth-header.jar"
else
  remove_extension "Header" '*header*.jar'
fi

### JSON authentication
if enabled OPT_JSON; then
  install_extension "JSON" '*auth-json*.jar' "$EXT_SRC/guacamole-auth-json/guacamole-auth-json.jar"
else
  remove_extension "JSON" '*auth-json*.jar'
fi

### Brute-force protection (new in 1.6.0)
if enabled OPT_BAN; then
  install_extension "Brute-force ban" '*auth-ban*.jar' "$EXT_SRC/guacamole-auth-ban/guacamole-auth-ban.jar"
else
  remove_extension "Brute-force ban" '*auth-ban*.jar'
fi

### Additional login restrictions (new in 1.6.0)
if enabled OPT_RESTRICT; then
  install_extension "Login restriction" '*auth-restrict*.jar' "$EXT_SRC/guacamole-auth-restrict/guacamole-auth-restrict.jar"
else
  remove_extension "Login restriction" '*auth-restrict*.jar'
fi

### Session recording storage
if enabled OPT_HISTORY_RECORDING_STORAGE; then
  install_extension "History recording storage" '*history-recording-storage*.jar' "$EXT_SRC/guacamole-history-recording-storage/guacamole-history-recording-storage.jar"
else
  remove_extension "History recording storage" '*history-recording-storage*.jar'
fi

### On-screen connection statistics
if enabled OPT_DISPLAY_STATISTICS; then
  install_extension "Display statistics" '*display-statistics*.jar' "$EXT_SRC/guacamole-display-statistics/guacamole-display-statistics.jar"
else
  remove_extension "Display statistics" '*display-statistics*.jar'
fi

### Keeper Secrets Manager vault
if enabled OPT_VAULT_KSM; then
  install_extension "Keeper Secrets Manager" '*vault-ksm*.jar' "$EXT_SRC/guacamole-vault/ksm/guacamole-vault-ksm.jar"
else
  remove_extension "Keeper Secrets Manager" '*vault-ksm*.jar'
fi

echo "Updating user permissions."
chown -R abc:abc "$GUAC_HOME" "$TOMCAT_LOG"
chmod -R 755 "$GUAC_HOME"
for schema in /config/mysql-schema /config/sqlserver-schema /config/postgresql-schema /config/ldap-schema; do
  [ -d "$schema" ] && chown -R abc:abc "$schema"
done

if enabled OPT_MYSQL && [ -f /etc/firstrun/mariadb.sh ]; then
  /etc/firstrun/mariadb.sh
  exec /sbin/tini -s -- /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord-mariadb.conf
else
  exec /sbin/tini -s -- /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
fi
