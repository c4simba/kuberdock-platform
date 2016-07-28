#!/bin/bash

FLANNEL_CONFIG=/etc/sysconfig/flanneld
PROXY_CONFIG=/etc/kubernetes/config
PROXY_CONFIG_ARGS=/etc/kubernetes/proxy
GLOBAL_KCLI_CONFIG=/etc/kubecli.conf
KCLI_CONFIG=.kubecli.conf
DEPLOY_LOG_FILE=/var/log/kuberdock_client_deploy.log
EXIT_MESSAGE="Installation error. Install log saved to $DEPLOY_LOG_FILE"


if [ $USER != "root" ];then
    echo "Superuser privileges required" | tee -a $DEPLOY_LOG_FILE
    exit 1
fi


tty -s
if [ $? -ne 0 ];then
    read -s -r KD_PASSWORD
fi


show_help() {
    echo "-U|--upgrade   : Upgrade kuberdock packages"
    echo "-u|--user      : Specify kuberdock admin username (if not specified 'admin' is used)"
    echo "-t|--testing   : Use testing repositories"
    echo "-k|--kuberdock : Specify KuberDock master hostname or IP address (if not specified '127.0.0.1' is used)"
    echo "-i|--interface : Network interface to use"
    echo "-h|--help      : Show this help"
    exit 0
}


do_and_log() {
    "$@" 2>&1 | tee -a $DEPLOY_LOG_FILE
    temp=$PIPESTATUS
    if [ $temp -ne 0 ];then
      echo $EXIT_MESSAGE
      exit $temp
    fi
}


log_errors() {
    echo "Doing $@" >> $DEPLOY_LOG_FILE
    "$@" 2> >(tee -a $DEPLOY_LOG_FILE)
    temp=$PIPESTATUS
    if [ $temp -ne 0 ];then
      echo $EXIT_MESSAGE
      exit $temp
    fi
}


yum_wrapper() {
    if [ -z "$TESTING" ];then
        log_errors yum --enablerepo=kube-client $@
    else
        log_errors yum --enablerepo=kube-client --enablerepo=kube-client-testing $@
    fi
}


upgrade() {
    yum_wrapper -y update flannel kubernetes-proxy kuberdock-cli kuberdock-plugin
    sed -i "s/^#\?KUBE_PROXY_ARGS=.*$/KUBE_PROXY_ARGS=\"--proxy-mode userspace\"/" $PROXY_CONFIG_ARGS
    do_and_log service flanneld restart
    do_and_log service kube-proxy restart
    exit 0
}


TEMP=$(getopt -o k:u:i:th,U -l kuberdock:,user:,interface:,testing,help,upgrade -n 'kcli-deploy.sh' -- "$@")
eval set -- "$TEMP"


while true;do
    case "$1" in
        -k|--kuberdock)
            KD_HOST=$2;shift 2;
        ;;
        -u|--user)
            KD_USER=$2;shift 2;
        ;;
        -t|--testing)
            TESTING=true;shift;
        ;;
        -i|--interface)
            IFACE=$2;shift 2;
        ;;
        -h|--help)
            show_help;break
        ;;
         -U|--upgrade)
            upgrade;break
        ;;
        --) shift;break;
    esac
done


if [ -z "$KD_HOST" ];then
    read -r -p "Enter KuberDock host name or IP address: " KD_HOST
    if [ -z "$KD_HOST" ];then
        KD_HOST="127.0.0.1"
    else
        KD_HOST=$(echo $KD_HOST|sed 's/^https\?:\/\///')
    fi
fi

if [ -z "$KD_USER" ];then
    read -r -p "Enter KuberDock admin username: " KD_USER
    if [ -z "$KD_USER" ];then
        KD_USER="admin"
    fi
fi

if [ -z "$KD_PASSWORD" ];then
    read -s -r -p "Enter KuberDock admin password: " KD_PASSWORD
    echo
    if [ -z "$KD_PASSWORD" ];then
        KD_PASSWORD="admin"
    fi
fi

cat > /etc/yum.repos.d/kube-client-cloudlinux.repo << EOF
[kube-client]
name=kube-client
baseurl=http://repo.cloudlinux.com/kuberdock-client/\$releasever/\$basearch
enabled=0
gpgcheck=1
gpgkey=http://repo.cloudlinux.com/cloudlinux/security/RPM-GPG-KEY-CloudLinux
EOF

cat > /etc/yum.repos.d/kube-client-testing-cloudlinux.repo << EOF
[kube-client-testing]
name=kube-client-testing
baseurl=http://repo.cloudlinux.com/kuberdock-client-testing/\$releasever/\$basearch
enabled=0
gpgcheck=1
gpgkey=http://repo.cloudlinux.com/cloudlinux/security/RPM-GPG-KEY-CloudLinux
EOF

do_and_log rpm --import http://repo.cloudlinux.com/cloudlinux/security/RPM-GPG-KEY-CloudLinux


yum_wrapper -y install kuberdock-cli kuberdock-plugin

sed -i -e "/^url/ {s|[ \t]*\$||}" -e "/^url/ {s|[^/]\+$|$KD_HOST|}" $GLOBAL_KCLI_CONFIG

KD_URL="https://$KD_HOST"
TOKEN=$(curl -s -k --connect-timeout 1 --user "$KD_USER:$KD_PASSWORD" "$KD_URL/api/auth/token"|tr -d " \t\r\n")
echo $TOKEN|grep -qi token
if [ $? -eq 0 ];then
    TOKEN=$(echo $TOKEN|sed "s/.*\"token\":\"\(.*\)\".*/\1/I")
    KCLI_CONFIG_PATH="$HOME/$KCLI_CONFIG"
    cat > $KCLI_CONFIG_PATH << EOF
[global]
url = $KD_URL

[defaults]
# token to talk to kuberdock
token = $TOKEN
# default registry to pull docker images from
registry = registry.hub.docker.com
EOF
    chmod 0600 $KCLI_CONFIG_PATH
else
    echo "Could not get token from KuberDock."
    echo "Check KuberDock host connectivity, username and password correctness"
    exit 1
fi


echo -n "Registering host in KuberDock... "
REGISTER_INFO=$(kcli kubectl register 2>&1)
if [ $? -ne 0 ];then
    echo $REGISTER_INFO | grep -iq "already registered"
    if [ $? -ne 0 ];then
        echo "Could not register host in KuberDock. Check hostname, username and password and try again. Quitting."
        exit 1
    else
        echo "Already registered"
    fi
else
    echo "Done"
fi

yum_wrapper -y install flannel kubernetes-proxy at

sed -i "s/^FLANNEL_ETCD=.*$/FLANNEL_ETCD=\"http:\/\/$KD_HOST:8123\"/" $FLANNEL_CONFIG
sed -i "s/^FLANNEL_ETCD_KEY=.*$/FLANNEL_ETCD_KEY=\"\/kuberdock\/network\"/" $FLANNEL_CONFIG

sed -i "s/^KUBE_MASTER=.*$/KUBE_MASTER=\"--master=http:\/\/$KD_HOST:8118\"/" $PROXY_CONFIG

if [ -n "$IFACE" ];then
   sed -i "s/^#\?FLANNEL_OPTIONS=.*$/FLANNEL_OPTIONS=\"--iface=$IFACE\"/" $FLANNEL_CONFIG
fi

sed -i "s/^#\?KUBE_PROXY_ARGS=.*$/KUBE_PROXY_ARGS=\"--proxy-mode userspace\"/" $PROXY_CONFIG_ARGS

VER=$(cat /etc/redhat-release|sed -e 's/[^0-9]//g'|cut -c 1)
if [ "$VER" == "7" ];then
    do_and_log systemctl enable flanneld
    do_and_log systemctl start flanneld
    do_and_log systemctl enable kube-proxy
    do_and_log systemctl start kube-proxy
    do_and_log systemctl enable atd
    do_and_log systemctl start atd
else
    do_and_log chkconfig flanneld on
    do_and_log service flanneld start
    do_and_log chkconfig kube-proxy on
    do_and_log service kube-proxy start
    do_and_log chkconfig atd on
    do_and_log service atd start
fi
