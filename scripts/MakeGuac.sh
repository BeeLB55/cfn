#!/bin/sh
#
# Description:
#    This script is intended to aid an administrator in quickly
#    setting up a baseline configuration of the Guacamole
#    management-protocol HTTP-tunneling service. When the script
#    exits successfully:
#    * The Tomcat6 servlet-service will have been downloaded and
#      enabled
#    * The Guacamole service will have been configured to tunnel
#      SSH based connections to the Guacamole host to a remote,
#      HTML 5 compliant web browser.
#    * Apache will have been configured to provide a proxy of
#      all public-facing port 80/tcp traffic to the Guacamole
#      servlet listening at localhost port 8080/tcp
#    * A internally-mapped (via /etc/guacamole/user-mapping.xml)
#      account will have been created to password protect the
#      front-end guacamole service
#    * An operating system user account will have been created
#      and password-enabled to allow login to the hosting-OS
#      from the Guacamole interface. The useraccount will also
#      have been granted passwordless sudoers access to root
#
#################################################################
GUACUSER="${1:-admin}"
GUACPASS="${2:-PASSWORD}"
SSHUSER="sshuser"
SSHPASS="P@ssw0rd"
PWCRYPT=$( python -c "import random,string,crypt,getpass,pwd; \
           randomsalt = ''.join(random.sample(string.ascii_letters,8)); \
           print crypt.crypt('${SSHPASS}', '\$6\$%s))\$' % randomsalt)" )
GBINSRC="http://sourceforge.net/projects/guacamole/files/current/binary/"
ADDUSER="/usr/sbin/useradd"
MODUSER="/usr/sbin/usermod"

__md5sum() {
    local pass="${1}"
    echo -n "${pass}" | /usr/bin/md5sum - | cut -d ' ' -f 1
}

GUACPASS_MD5=$(__md5sum "${GUACPASS}")

# Create our SSH login-user
getent passwd ${SSHUSER} > /dev/null
if [[ $? -eq 0 ]]
then
    printf "User account already exists [${SSHUSER}].\n"
elif [[ $(${ADDUSER} ${SSHUSER})$? -ne 0 ]]
then
    (
        printf "Failed to create ssh user account "
        printf "[${SSHUSER}]. Aborting...\n"
    ) > /dev/stderr
    exit 1
fi

# Set password for our SSH login-user
if  [[ $(${MODUSER} -p "${PWCRYPT}" ${SSHUSER}) -ne 0 ]]
then
    (
        printf "Failed to set password for ssh user account. "
        printf "Aborting...\n"
    ) > /dev/stderr
    exit 1
fi

# Add SSH login-user to sudoers list
printf "${SSHUSER}\tALL=(root)\tNOPASSWD:ALL\n" > \
    /etc/sudoers.d/user_${SSHUSER}
if [[ $? -ne 0 ]]
then
    echo "Failed to add ${SSHUSER} to sudoers" > /dev/stderr
    exit 1
fi

# Install OS standard Tomcat and Apache
yum install -y httpd tomcat6

# Install EPEL repos
yum install -y \
    http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm

# Install guacamole components from EPEL
yum -y install guacd libguac-client-* dejavu-sans-mono-fonts

# Enable Web components to start at next boot
for SVC in httpd tomcat6 guacd
do
    chkconfig ${SVC} on
done

# Can't put this earlier because "not installed yet"
GVERS=$(rpm -q guacd --qf '%{version}')

# Download version-matched Guacamole client from project repo
curl -s -L ${GBINSRC}/guacamole-${GVERS}.war/download \
    -o /var/lib/tomcat6/webapps/guacamole.war

# Gotta make SELinux happy...
if [[ $(getenforce) = "Enforcing" ]] || [[ $(getenforce) = "Permissive" ]]
then
    chcon -R --reference=/var/lib/tomcat6/webapps \
        /var/lib/tomcat6/webapps/guacamole.war
    if [[ $(getsebool httpd_can_network_relay | \
        cut -d ">" -f 2 | sed 's/[ ]*//g') = "off" ]]
    then
        echo "Enable httpd-based proxying within SELinux"
        setsebool -P httpd_can_network_relay=1
    fi
fi

# Create /etc/guacamole as necessary
if [[ ! -d /etc/guacamole ]]
then
    if [[ $(mkdir -p /etc/guacamole)$? -ne 0 ]]
    then
        echo "Cannot populate /etc/guacamole" > /dev/stderr
        exit 1
    fi
fi

# Create basic config files in /etc/guacamole
cd /etc/guacamole
(
    echo "# Hostname and port of guacamole proxy"
    echo "guacd-hostname: localhost"
    echo "guacd-port:     4822"
    echo ""
    echo "# Location to read extra .jar's from"
    echo "lib:  /var/lib/tomcat6/webapps/guacamole/WEB-INF/classes"
    echo ""
    echo "# Authentication provider class"
    echo "auth-provider: net.sourceforge.guacamole.net.basic.BasicFileAuthenticationProvider"
    echo ""
    echo "# Properties used by BasicFileAuthenticationProvider"
    echo "basic-user-mapping: /etc/guacamole/user-mapping.xml"
) > /etc/guacamole/guacamole.properties
(
    printf "<user-mapping>\n"
    printf "\t<!-- Per-user authentication and config information -->\n"
    printf "\t<authorize username=\"%s\" password=\"%s\" encoding=\"%s\">\n" "${GUACUSER}" "${GUACPASS_MD5}" "md5"
    printf "\t\t<protocol>ssh</protocol>\n"
    printf "\t\t\t<param name=\"hostname\">localhost</param>\n"
    printf "\t\t\t<param name=\"port\">22</param>\n"
    printf "\t\t\t<param name=\"font-name\">DejaVu Sans Mono</param>\n"
    printf "\t\t\t<param name=\"font-size\">10</param>\n"
    printf "\t</authorize>\n"
    printf "</user-mapping>\n"
) > /etc/guacamole/user-mapping.xml
(
    printf "<configuration>\n"
    printf "\n"
    printf "\t<!-- Appender for debugging -->\n"
    printf "\t<appender name=\"GUAC-DEBUG\" class=\"ch.qos.logback.core.FileAppender\">\n"
    printf "\t\t<file>/var/log/tomcat6/Guacamole.log</file>\n"
    printf "\t\t<encoder>\n"
    printf "\t\t\t<pattern>%%d{HH:mm:ss.SSS} [%%thread] %%-5level %%logger{36} - %%msg%%n</pattern>\n"
    printf "\t\t</encoder>\n"
    printf "\t</appender>\n"
    printf "\n"
    printf "\t<!-- Log at DEBUG level -->\n"
    printf "\t<root level=\"debug\">\n"
    printf "\t\t<appender-ref ref=\"GUAC-DEBUG\"/>\n"
    printf "\t</root>\n"
    printf "\n"
    printf "</configuration>\n"
) > /etc/guacamole/logback.xml


# Create shell-init files
echo "export GUACAMOLE_HOME=/etc/guacamole" > /etc/profile.d/guacamole.sh
echo "setenv GUACAMOLE_HOME /etc/guacamole" > /etc/profile.d/guacamole.csh

# Set SEL contexts on shell-init files
chcon system_u:object_r:bin_t:s0 /etc/profile.d/guacamole.*

# Add a proxy-directive to Apache
(
    printf "<Location /guacamole/>\n"
    printf "\tOrder allow,deny\n"
    printf "\tAllow from all\n"
    printf "\tProxyPass http://localhost:8080/guacamole/"
    printf " flushpackets=on\n"
    printf "\tProxyPassReverse http://localhost:8080/guacamole/\n"
    printf "\tProxyPassReverseCookiePath /guacamole/ /guacamole/\n"
    printf "</Location>\n"
) > /etc/httpd/conf.d/Guacamole-proxy.conf

# Set redirect Guacamole to /etc/guacamole
mkdir /usr/share/tomcat6/.guacamole && \
    cd /usr/share/tomcat6/.guacamole
for FILE in /etc/guacamole/*
do
    ln -s ${FILE}
done

# Start services
echo "Attempting to start proxy-related services"
for SVC in guacd tomcat6 httpd
do
    /sbin/service ${SVC} start
    if [[ $? -ne 0 ]]
    then
      echo "Failed to start ${SVC}" > /dev/stderr
      exit 1
    fi
done
