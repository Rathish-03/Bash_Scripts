#!/bin/bash

# This script automates the deployment of an Nginx web server on AlmaLinux.
# It now includes:
# 1. User prompts for network configuration (Static IP, Gateway, DNS).
# 2. Configuration of static IP using nmcli.
# 3. Ensuring OpenSSH server is installed and running.
# 4. Updates the system.
# 5. Installs Nginx.
# 6. Configures the firewalld to allow HTTP, HTTPS, and SSH traffic.
# 7. Starts and enables the Nginx service.
# 8. Deploys a simple index.html page.
# 9. Creates a basic Nginx server block configuration.
# 10. Tests the Nginx configuration for syntax errors.
# 11. Restarts Nginx to apply changes.
#
# Usage:
#   Make the script executable: chmod +x deploy_nginx.sh
#   Run the script with sudo:    sudo ./deploy_nginx.sh

# --- Configuration Variables ---
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEB_ROOT="/usr/share/nginx/html" # Default Nginx web root on AlmaLinux
SAMPLE_INDEX_HTML_PATH="${WEB_ROOT}/index.html"
NGINX_VHOST_CONF_PATH="${NGINX_CONF_DIR}/default.conf" # Custom config file

# --- Logging and Error Handling Functions ---

# Function to print messages to stdout and log file
log_message() {
    local type="$1" # INFO, SUCCESS, WARN, ERROR
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "[${timestamp}] [${type}] ${message}" | tee -a /var/log/nginx_deploy.log

    if [[ "$type" == "ERROR" ]]; then
        echo "Script terminated due to an error. Check /var/log/nginx_deploy.log for details."
        exit 1
    fi
}

# Function to execute a command and check its success
execute_command() {
    local command_description="$1"
    local command="${@:2}" # All arguments from the second one form the command

    log_message "INFO" "Attempting: ${command_description}..."
    eval "$command" # Use eval to execute the command string correctly

    if [[ $? -eq 0 ]]; then
        log_message "SUCCESS" "${command_description} completed."
    else
        log_message "ERROR" "${command_description} failed."
    fi
}

# --- Main Deployment Steps ---

log_message "INFO" "Starting Nginx web server deployment on AlmaLinux..."

# 1. Check for root privileges
if [[ $EUID -ne 0 ]]; then
   log_message "ERROR" "This script must be run as root. Please use 'sudo'."
fi

# 2. Update System Packages
execute_command "Updating system packages" "dnf update -y"

# --- SSH Service Configuration ---
log_message "INFO" "Ensuring OpenSSH server is installed and running..."
if ! rpm -q openssh-server &> /dev/null; then
    execute_command "Installing OpenSSH server" "dnf install openssh-server -y"
else
    log_message "INFO" "OpenSSH server is already installed."
fi

if ! systemctl is-active --quiet sshd; then
    execute_command "Starting SSH service" "systemctl start sshd"
else
    log_message "INFO" "SSH service is already active."
fi

if ! systemctl is-enabled --quiet sshd; then
    execute_command "Enabling SSH service to start on boot" "systemctl enable sshd"
else
    log_message "INFO" "SSH service is already enabled."
fi
log_message "SUCCESS" "OpenSSH server is ready."

# --- Static IP Configuration ---
log_message "INFO" "Starting network configuration for static IP..."

echo "-----------------------------------------------------"
echo "Available network interfaces:"
nmcli device show | grep "DEVICE:" | awk '{print $2}'
echo "-----------------------------------------------------"

read -p "Enter the network interface name (e.g., enp0s3): " NETWORK_INTERFACE
read -p "Enter the static IP address with CIDR (e.g., 192.168.1.10/24): " STATIC_IP_CIDR
read -p "Enter the Gateway IP address (e.g., 192.168.1.1): " GATEWAY_IP
read -p "Enter DNS server(s) (comma-separated, e.g., 8.8.8.8,8.8.4.4): " DNS_SERVERS

# Check if the interface exists
if ! nmcli device show "$NETWORK_INTERFACE" &> /dev/null; then
    log_message "ERROR" "Network interface '$NETWORK_INTERFACE' not found. Please check the name and try again."
fi

# Find the active connection name for the given interface, or use a default
CURRENT_CONNECTION=$(nmcli -g NAME,DEVICE con show --active | grep "$NETWORK_INTERFACE" | cut -d':' -f1 | head -n 1)

if [[ -z "$CURRENT_CONNECTION" ]]; then
    # If no active connection for this device, create a new one named after the interface
    log_message "INFO" "No active connection found for '$NETWORK_INTERFACE'. Creating a new connection profile."
    execute_command "Adding new ethernet connection for ${NETWORK_INTERFACE}" "nmcli con add type ethernet ifname \"${NETWORK_INTERFACE}\" con-name \"${NETWORK_INTERFACE}-static\""
    CONNECTION_NAME="${NETWORK_INTERFACE}-static"
else
    log_message "INFO" "Modifying existing connection '${CURRENT_CONNECTION}' for interface '$NETWORK_INTERFACE'."
    CONNECTION_NAME="$CURRENT_CONNECTION"
fi

execute_command "Setting IPv4 method to manual for ${CONNECTION_NAME}" "nmcli con mod \"${CONNECTION_NAME}\" ipv4.method manual"
execute_command "Setting IPv4 addresses for ${CONNECTION_NAME}" "nmcli con mod \"${CONNECTION_NAME}\" ipv4.addresses \"${STATIC_IP_CIDR}\""
execute_command "Setting IPv4 gateway for ${CONNECTION_NAME}" "nmcli con mod \"${CONNECTION_NAME}\" ipv4.gateway \"${GATEWAY_IP}\""
execute_command "Setting IPv4 DNS servers for ${CONNECTION_NAME}" "nmcli con mod \"${CONNECTION_NAME}\" ipv4.dns \"${DNS_SERVERS}\""
execute_command "Bringing up the network connection ${CONNECTION_NAME}" "nmcli con up \"${CONNECTION_NAME}\""

log_message "SUCCESS" "Static IP configuration complete for interface ${NETWORK_INTERFACE}."

# 3. Install Nginx (re-ordered for logical flow)
log_message "INFO" "Proceeding with Nginx installation..."
# Check if Nginx is already installed
if ! rpm -q nginx &> /dev/null; then
    execute_command "Installing Nginx" "dnf install nginx -y"
else
    log_message "INFO" "Nginx is already installed."
fi

# 4. Configure Firewalld (updated to include SSH)
log_message "INFO" "Configuring Firewalld to allow HTTP/HTTPS/SSH traffic..."
execute_command "Adding HTTP service to firewalld" "firewall-cmd --permanent --add-service=http"
execute_command "Adding HTTPS service to firewalld" "firewall-cmd --permanent --add-service=https"
execute_command "Adding SSH service to firewalld" "firewall-cmd --permanent --add-service=ssh" # Allow SSH
execute_command "Reloading firewalld configuration" "firewall-cmd --reload"
log_message "SUCCESS" "Firewalld configured for HTTP/HTTPS/SSH."


# 5. Start and Enable Nginx Service
# Check if Nginx is already running and enabled
if ! systemctl is-active --quiet nginx; then
    execute_command "Starting Nginx service" "systemctl start nginx"
else
    log_message "INFO" "Nginx service is already active."
fi

if ! systemctl is-enabled --quiet nginx; then
    execute_command "Enabling Nginx service to start on boot" "systemctl enable nginx"
else
    log_message "INFO" "Nginx service is already enabled to start on boot."
fi

# 6. Deploy a Sample Website (index.html)
log_message "INFO" "Deploying a sample index.html page..."
mkdir -p "$WEB_ROOT" # Ensure web root exists
cat <<EOF > "$SAMPLE_INDEX_HTML_PATH"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to Nginx on AlmaLinux!</title>
    <style>
        body {
            font-family: 'Arial', sans-serif;
            background-color: #f0f2f5;
            color: #333;
            margin: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            text-align: center;
        }
        .container {
            background-color: #ffffff;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
            max-width: 600px;
            width: 90%;
        }
        h1 {
            color: #2c3e50;
            margin-bottom: 20px;
        }
        p {
            font-size: 1.1em;
            line-height: 1.6;
        }
        .nginx-logo {
            width: 100px;
            height: auto;
            margin-top: 20px;
        }
        footer {
            margin-top: 30px;
            font-size: 0.9em;
            color: #7f8c8d;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hello from Nginx!</h1>
        <p>This page is being served by Nginx on your AlmaLinux server.</p>
        <p>Congratulations on your successful web server deployment!</p>
        <img src="https://placehold.co/100x100/FF5733/FFFFFF?text=NGINX" alt="Nginx Logo Placeholder" class="nginx-logo">
        <footer>
            <p>&copy; 2025 Automated Nginx Deployment</p>
        </footer>
    </div>
</body>
</html>
EOF
log_message "SUCCESS" "Sample index.html deployed to ${SAMPLE_INDEX_HTML_PATH}."
execute_command "Setting appropriate permissions for ${SAMPLE_INDEX_HTML_PATH}" "chmod 644 ${SAMPLE_INDEX_HTML_PATH}"
execute_command "Setting appropriate SELinux context for ${WEB_ROOT}" "restorecon -Rv ${WEB_ROOT}"


# 7. Create a Basic Nginx Server Block Configuration
log_message "INFO" "Creating a basic Nginx server block configuration at ${NGINX_VHOST_CONF_PATH}..."
mkdir -p "$NGINX_CONF_DIR" # Ensure conf.d directory exists
cat <<EOF > "$NGINX_VHOST_CONF_PATH"
# Basic Nginx server block configuration for a default website
server {
    listen 80;
    listen [::]:80;
    server_name _; # Listen on any hostname
    root ${WEB_ROOT};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Optional: Basic error pages
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        internal;
    }
}
EOF
log_message "SUCCESS" "Nginx server block configuration created."

# 8. Test Nginx Configuration
execute_command "Testing Nginx configuration for syntax errors" "nginx -t"

# 9. Restart Nginx to apply changes
execute_command "Restarting Nginx service to apply new configuration" "systemctl restart nginx"

log_message "INFO" "Nginx web server deployment complete!"
log_message "INFO" "You should now be able to access your web server by opening a web browser and navigating to your AlmaLinux server's IP address or hostname."
log_message "INFO" "If you encounter issues, check /var/log/nginx_deploy.log and 'journalctl -xeu nginx'."

