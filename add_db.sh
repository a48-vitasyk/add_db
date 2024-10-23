#!/bin/bash

# Log file location
LOG_FILE="/home/db_installation.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Function to generate a random password
generate_password() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# Function to check for an existing container
check_existing_container() {
    local db_version=$1
    if [ "$(docker ps -a --filter "name=${db_version}" --format '{{.Names}}')" ]; then
        log "Container named ${db_version} is already running. Removing existing container..."
        docker rm -f ${db_version}
    fi
}

# Function to check if Docker is installed
check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        log "Docker is not installed. Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        systemctl start docker
        systemctl enable docker
    else
        log "Docker is already installed."
    fi
}

# Function to check if Docker Compose is installed
check_docker_compose_installed() {
    if ! command -v docker-compose &> /dev/null; then
        log "Docker Compose is not installed. Installing Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/download/$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    else
        log "Docker Compose is already installed."
    fi
}

# Проверка установки Docker
if ! command -v docker &> /dev/null; then
    log "Docker не установлен. Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl start docker
    systemctl enable docker
else
    log "Docker уже установлен."
fi

# Проверка установки Docker Compose
if ! command -v docker-compose &> /dev/null; then
    log "Docker Compose не установлен. Устанавливаем Docker Compose..."
    curl -SL https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log "Docker Compose версии $(docker-compose --version) успешно установлен."
else
    log "Docker Compose уже установлен."
fi


# Generate passwords
MYSQL_ROOT_PASSWORD=$(generate_password)

# Prompting the user to select a database version
log "Prompting the user to select a database version..."
echo "Select the database version to install:"
echo "1) MySQL 5.7"
echo "2) MySQL 8.0"
echo "3) MariaDB 10.8"
echo "4) MariaDB 10.9"
echo "5) MariaDB 10.11"
read -p "Enter the number corresponding to your choice: " db_choice

case $db_choice in
    1)
        DB_IMAGE="mysql:5.7.44-oraclelinux7"
        DB_VERSION="mysql-5.7"
        DB_TYPE="mysql"
        ;;
    2)
        DB_IMAGE="mysql:8.0"
        DB_VERSION="mysql-8.0"
        DB_TYPE="mysql"
        ;;
    3)
        DB_IMAGE="mariadb:10.8"
        DB_VERSION="mariadb-10.8"
        DB_TYPE="mariadb"
        ;;
    4)
        DB_IMAGE="mariadb:10.9"
        DB_VERSION="mariadb-10.9"
        DB_TYPE="mariadb"
        ;;
    5)
        DB_IMAGE="mariadb:10.11"
        DB_VERSION="mariadb-10.11"
        DB_TYPE="mariadb"
        ;;
    *)
        log "Invalid choice. Installation aborted."
        exit 1
        ;;
esac

# Check for an existing container
check_existing_container $DB_VERSION

# Add unique hostname to /etc/hosts
if ! grep -q "${DB_VERSION}" /etc/hosts; then
    echo "127.0.0.1 ${DB_VERSION}" >> /etc/hosts
    log "Added hostname ${DB_VERSION} to /etc/hosts"
fi

# Create Docker Compose configuration
log "Creating Docker Compose configuration..."
AVAILABLE_PORT=3306
while ss -tuln | grep -q ":$AVAILABLE_PORT"; do
    AVAILABLE_PORT=$((AVAILABLE_PORT + 1))
done
mkdir -p /root/docker_${DB_VERSION}

# Create init script and configuration for MySQL 8.0
if [ "$DB_TYPE" = "mysql" ] && [ "$DB_VERSION" = "mysql-8.0" ]; then
    # Create init script
    cat << EOF > /root/docker_${DB_VERSION}/init.sql
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    # Create docker-compose.yml
    cat << EOF > /root/docker_${DB_VERSION}/docker-compose.yml
version: '3.8'
services:
  ${DB_VERSION}:
    image: $DB_IMAGE
    container_name: ${DB_VERSION}
    ports:
      - "${AVAILABLE_PORT}:3306"
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
    command: --default-authentication-plugin=mysql_native_password --bind-address=0.0.0.0
    volumes:
      - /var/lib/${DB_VERSION}:/var/lib/mysql
      - /root/docker_${DB_VERSION}/init.sql:/docker-entrypoint-initdb.d/init.sql
    restart: always
EOF

else
    # Create init script for other versions
    if [ "$DB_TYPE" = "mysql" ]; then
        cat << EOF > /root/docker_${DB_VERSION}/init.sql
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    elif [ "$DB_TYPE" = "mariadb" ]; then
        cat << EOF > /root/docker_${DB_VERSION}/init.sql
CREATE OR REPLACE USER 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    fi

    # Create docker-compose.yml
    cat << EOF > /root/docker_${DB_VERSION}/docker-compose.yml
version: '3.8'
services:
  ${DB_VERSION}:
    image: $DB_IMAGE
    container_name: ${DB_VERSION}
    ports:
      - "${AVAILABLE_PORT}:3306"
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_ROOT_HOST: '%'
    command: --bind-address=0.0.0.0
    volumes:
      - /var/lib/${DB_VERSION}:/var/lib/mysql
      - /root/docker_${DB_VERSION}/init.sql:/docker-entrypoint-initdb.d/init.sql
    restart: always
EOF

fi

# Проверка существования директории данных и создание бэкапа
if [ -d "/var/lib/${DB_VERSION}" ]; then
    log "Директория с данными найдена. Создание резервной копии..."
    BACKUP_DIR="/var/lib/${DB_VERSION}_backup_$(date +%Y%m%d%H%M%S)"
    mv /var/lib/${DB_VERSION} $BACKUP_DIR
    log "Резервная копия создана: ${BACKUP_DIR}"
else
    log "Директория с данными не найдена. Пропускаем создание резервной копии."
fi

# Удаление существующей директории данных
log "Удаление существующей директории данных..."
rm -rf /var/lib/${DB_VERSION}


# Start the database using Docker Compose
log "Starting Docker Compose for ${DB_VERSION}..."
docker-compose -f /root/docker_${DB_VERSION}/docker-compose.yml up -d

# Wait for the database to be ready
log "Waiting for the database to be ready..."
RETRIES=30
for i in $(seq 1 $RETRIES); do
    if docker exec ${DB_VERSION} mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SELECT VERSION();" >/dev/null 2>&1; then
        log "Database is ready."
        break
    else
        log "Database is not ready yet. Retrying in 5 seconds..."
        sleep 10
    fi
    if [ "$i" -eq "$RETRIES" ]; then
        log "Failed to connect to the database after $RETRIES attempts. Please check the Docker container logs for more information."
        exit 1
    fi
done

# Add database access to HestiaCP
log "Adding database access to HestiaCP..."
v-add-database-host mysql ${DB_VERSION} root $MYSQL_ROOT_PASSWORD '' '' '' $AVAILABLE_PORT

# Update phpMyAdmin configuration
log "Updating phpMyAdmin configuration..."
cat << EOF >> /etc/phpmyadmin/conf.d/01-localhost.php
\$i++;

\$cfg['Servers'][\$i]['host'] = '${DB_VERSION}';
\$cfg['Servers'][\$i]['port'] = '$AVAILABLE_PORT';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['verbose'] = '${DB_VERSION}';

// Session termination settings
\$cfg['LoginCookieValidity'] = 1440;
\$cfg['LoginCookieStore'] = 0;
\$cfg['ShowPhpInfo'] = true;

// Interface additional settings
\$cfg['ShowChgPassword'] = true;
\$cfg['ShowDbStructureCharset'] = true;
\$cfg['ShowDbStructureCreation'] = true;
\$cfg['ShowDbStructureLastUpdate'] = true;
\$cfg['ShowDbStructureLastCheck'] = true;

// Memory and runtime settings
\$cfg['MemoryLimit'] = '512M';
\$cfg['ExecTimeLimit'] = 300;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
EOF

# Output access details in red color
RED='\033[0;31m'
NC='\033[0m' # No Color

# Log access details
log "Installation of ${DB_VERSION} server completed successfully."
log "Access details:"
log "Host: ${DB_VERSION}"
log "Port: $AVAILABLE_PORT"
log "User: root"
log "Password: $MYSQL_ROOT_PASSWORD"

echo -e "${RED}"
echo "==========================================="
echo "            ACCESS DETAILS"
echo "-------------------------------------------"
echo "Host: ${DB_VERSION}"
echo "Port: $AVAILABLE_PORT"
echo "User: root"
echo "Password: $MYSQL_ROOT_PASSWORD"
echo "==========================================="
echo -e "${NC}"

exit 0
