#!/bin/bash

### Version of Guacamole shipped in this image; baked in by the Dockerfile.
GUAC_VER="${GUAC_VER:-unknown}"

MYSQL_CONFIG=/etc/my.cnf.d/mariadb-server.cnf
MYSQL_SCHEMA=/opt/guacamole/extensions/guacamole-auth-jdbc/mysql/schema
MYSQL_DATABASE=/config/databases
VERSION_FILE="$MYSQL_DATABASE/guacamole/version"

sed -i '/\[mysqld\]/a user= '"$PUID"'' "$MYSQL_CONFIG"
mkdir -p /var/run/mysqld /var/log/mysql
chown -R abc:abc /var/log/mysql /var/lib/mysql /var/run/mysqld
chmod -R 777 /var/log/mysql /var/lib/mysql /var/run/mysqld

start_mysql() {
  echo "Starting MariaDB."
  /usr/bin/mysqld_safe > /dev/null 2>&1 &
  RET=1
  while [[ RET -ne 0 ]]; do
      mysql -uroot -e "status" > /dev/null 2>&1
      RET=$?
      sleep 1
  done
}

stop_mysqld() {
  echo "Stopping MariaDB."
  mysqladmin -u root shutdown
  sleep 3
}

### Returns success if $1 is an older version than $2.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

### Determine the schema version of a database that predates the version file,
### by probing for the objects the individual upgrade scripts introduce:
### guacamole_user.full_name (pre-0.9.13), guacamole_user_history (pre-0.9.14)
### and guacamole_user_group (pre-1.0.0). The result is returned in
### DETECTED_VERSION rather than on stdout, which start_mysql also writes to.
detect_schema_version() {
  DETECTED_VERSION="0.9.12"

  start_mysql
  if mysql -uroot -e "DESCRIBE guacamole.guacamole_user_group" > /dev/null 2>&1; then
    DETECTED_VERSION="1.0.0"
  elif mysql -uroot -e "DESCRIBE guacamole.guacamole_user_history" > /dev/null 2>&1; then
    DETECTED_VERSION="0.9.14"
  elif mysql -uroot -e "SELECT full_name FROM guacamole.guacamole_user LIMIT 0" > /dev/null 2>&1; then
    DETECTED_VERSION="0.9.13"
  fi
  stop_mysqld
}

### Applies every upgrade script the database has not seen yet. The scripts are
### read straight from the extension shipped in this image, so a new Guacamole
### release only needs its version bumped in the Dockerfile.
upgrade_database() {
  local from="$1"
  local script upgrade_ver applied=false

  for script in $(ls "$MYSQL_SCHEMA"/upgrade/upgrade-pre-*.sql 2>/dev/null | sort -V); do
    upgrade_ver=$(basename "$script" .sql)
    upgrade_ver=${upgrade_ver#upgrade-pre-}

    version_lt "$from" "$upgrade_ver" || continue

    if [ "$applied" = false ]; then
      start_mysql
      applied=true
    fi

    echo "Applying schema upgrade pre-$upgrade_ver."
    if ! mysql -uroot guacamole < "$script"; then
      echo "Error! Schema upgrade pre-$upgrade_ver failed. Not recording the upgrade."
      stop_mysqld
      return 1
    fi
    echo "$upgrade_ver" > "$VERSION_FILE"
  done

  if [ "$applied" = true ]; then
    stop_mysqld
    echo "Database upgrade complete."
  else
    echo "Database upgrade not needed."
  fi
}

# If databases do not exist, create them
if [ -f "$MYSQL_DATABASE"/guacamole/guacamole_user.ibd ]; then
  echo "Database exists."

  if [ -f "$VERSION_FILE" ]; then
    OLD_GUAC_VER=$(cat "$VERSION_FILE")
  else
    detect_schema_version
    OLD_GUAC_VER="$DETECTED_VERSION"
    echo "No version file found, assuming schema version $OLD_GUAC_VER."
    echo "$OLD_GUAC_VER" > "$VERSION_FILE"
  fi

  echo "Database schema version: $OLD_GUAC_VER (image ships Guacamole $GUAC_VER)."
  upgrade_database "$OLD_GUAC_VER"
  chown abc:abc "$VERSION_FILE"
else
  if [ -f /config/guacamole/guacamole.properties ]; then
    echo "Initializing Guacamole database."
    /usr/bin/mysql_install_db --datadir="$MYSQL_DATABASE"
    echo "Database installation complete."
    start_mysql
    echo "Creating Guacamole database."
    mysql -uroot -e "CREATE DATABASE guacamole"
    echo "Creating Guacamole database user."
    PW=$(grep -m 1 "mysql-password:\s" /config/guacamole/guacamole.properties | sed 's/mysql-password:\s//')
    mysql -uroot -e "CREATE USER 'guacamole'@'localhost' IDENTIFIED BY '$PW'"
    echo "Database created. Granting access to 'guacamole' user for localhost."
    mysql -uroot -e "GRANT SELECT,INSERT,UPDATE,DELETE ON guacamole.* TO 'guacamole'@'localhost'"
    mysql -uroot -e "FLUSH PRIVILEGES"
    echo "Creating Guacamole database schema and default admin user."
    mysql -uroot guacamole < ${MYSQL_SCHEMA}/001-create-schema.sql
    mysql -uroot guacamole < ${MYSQL_SCHEMA}/002-create-admin-user.sql
    echo "$GUAC_VER" > "$VERSION_FILE"
    stop_mysqld
    echo "Setting database file permissions"
    chown -R abc:abc /config/databases
    chmod -R 755 /config/databases
    echo "Removing mysql-server logrotate directive"
    rm -f /etc/logrotate.d/mysql-server
    sleep 3
    echo "Initialization complete."
  else
    echo "Error! Unable to create database. guacamole.properties file does not exist."
    echo "If you see this error message, please open an issue at"
    echo "https://github.com/SimonLoebert/docker-guacamole/issues"
  fi
fi
