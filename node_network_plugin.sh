#!/bin/bash
#
# KuberDock - is a platform that allows users to run applications using Docker
# container images and create SaaS / PaaS based on these applications.
# Copyright (C) 2017 Cloud Linux INC
#
# This file is part of KuberDock.
#
# KuberDock is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# KuberDock is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with KuberDock; if not, see <http://www.gnu.org/licenses/>.
#

ACTION=$1

# At this moment this is also kuberdock-pod-uid
NAMESPACE=$2
KUBERNETES_POD_ID=$3
DOCKER_PAUSE_ID=$4

source /etc/kubernetes/kubelet
source /etc/sysconfig/flanneld

if [ "$0" != "-bash" ]
then
  pushd $(dirname $0) > /dev/null
  PLUGIN_DIR=$(pwd -P)
  popd > /dev/null
else
  PLUGIN_DIR="."
fi

LOG_FILE="$PLUGIN_DIR/kuberdock.log"
LOG_ENABLED="1"

INGRESS_SERVICE_IP="10.254.0.100"

function log {
  if [ "$LOG_ENABLED" == "1" ];then
    if [ $(wc -l < "$LOG_FILE") -ge 100 ];then    # limit log to 100 lines
      tail -n 100 "$LOG_FILE" > "$LOG_FILE.tmp"
      mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    echo "$(date -uIns) $@" >> "$LOG_FILE"
  fi
}

function if_failed {
  local status=$?
  if [ "$status" -ne 0 ]
  then
      MSG=$(/usr/bin/env python2 "$PLUGIN_DIR/kuberdock.py" ex_status add $NAMESPACE $KUBERNETES_POD_ID "$1")
      log "$MSG"
  fi
}

API_SERVER=$(cut -d '=' -f 2 <<< $KUBELET_API_SERVER)
if_failed "Error while init API_SERVER"
MASTER_IP=$(echo $API_SERVER | grep -oP '\d+\.\d+\.\d+\.\d+')
if_failed "Error while init MASTER_IP"
TOKEN=$(grep token /etc/kubernetes/configfile | grep -oP '[a-zA-Z0-9]+$')
if_failed "Error while init TOKEN"
# TODO must be taken from some node global.env for all settings
IFACE=$(cut -d '=' -f 2 <<< $FLANNEL_OPTIONS)
if_failed "Error while init IFACE"
NODE_IP=$(ip -o ad | grep " $IFACE " | head -1 | awk '{print $4}' | cut -d/ -f1)
if_failed "Error while init NODE_IP"
DATA_DIR="$PLUGIN_DIR/data/$NAMESPACE"
DATA_INFO="$DATA_DIR/$KUBERNETES_POD_ID"


function rule_reject_pod_local_input {
  iptables -w -$1 KUBERDOCK -t filter -i docker0 -o docker0 -d $2 -m set ! --match-set $3 src -j REJECT
}


function rule_reject_pod_local_output {
  iptables -w -$1 KUBERDOCK -t filter -i docker0 -o docker0 -s $2 -m set ! --match-set $3 dst -j REJECT
}


function rule_reject_pod_output {
  iptables -w -$1 KUBERDOCK -t filter -i docker0 ! -o docker0 -s $2 -m set ! --match-set $3 dst -m conntrack ! --ctstate RELATED,ESTABLISHED -j REJECT
}


function rule_reject_service {
  iptables -w -$1 KUBERDOCK -t nat -s $2 -m set ! --match-set $3 dst -j ACCEPT
}


function rule_ingress_input {
  iptables -w -"$1" KUBERDOCK -t filter -d "$2" -m set --match-set kuberdock_ingress src -j ACCEPT
}


function rule_ingress_output {
  iptables -w -"$1" KUBERDOCK -t filter -s "$2" -m set --match-set kuberdock_ingress dst -j ACCEPT
}


function get_setname {
  echo "kuberdock_user_$1"
}


# TODO comment all input '$1' params
function add_rules {
  set=$(get_setname $2)
  ipset -exist create $set hash:ip  # workaround for non-existent ip set
  if ! rule_reject_pod_local_input C $1 $set
  then
    rule_reject_pod_local_input A $1 $set
  fi
  if ! rule_reject_pod_local_output C $1 $set
  then
    rule_reject_pod_local_output A $1 $set
  fi
  if ! rule_reject_pod_output C $1 $set
  then
    rule_reject_pod_output A $1 $set
  fi
  if ! rule_reject_service C $1 $set
  then
    rule_reject_service A $1 $set
  fi
}


function del_rules {
  set=$(get_setname $2)
  rule_reject_pod_local_input D $1 $set
  rule_reject_pod_local_output D $1 $set
  rule_reject_pod_output D $1 $set
  rule_reject_service D $1 $set
}


function etcd_ {
  args="${FLANNEL_ETCD}/v2/keys${FLANNEL_ETCD_KEY}plugin/users/"
  if [ ! -z "$2" ]
  then
    args+="$2/"
  fi
  if [ ! -z "$3" ]
  then
    args+="$3/"
  fi
  if [ ! -z "$4" ]
  then
    args[1]="-d value=$4"
  fi
  curl -sS --cacert "$ETCD_CAFILE" --cert "$ETCD_CERTFILE" --key "$ETCD_KEYFILE" \
    -X "$1" ${args[@]}
  if_failed "Error while work with Etcd: $1 ${args[@]}"
}




function get_pod_spec {
  curl -f -sS -k "$API_SERVER/api/v1/namespaces/$NAMESPACE/pods/$KUBERNETES_POD_ID" --header "Authorization: Bearer $TOKEN"
}


function iptables_ {
  action=$1
  shift 1
  if ! iptables -w -C ${@}
    then
      iptables -w ${action} ${@}
    fi
}


function teardown_pod {
    log "Teardown Pod $POD_IP (Service $SERVICE_IP) of user $USER_ID; PUBLIC_IP: \"$POD_PUBLIC_IP\"; domain: \"$POD_DOMAIN\""
    del_rules "$POD_IP" "$USER_ID"

    if [ "$POD_PUBLIC_IP" != "" ];then
        MSG=$(/usr/bin/env python2 "$PLUGIN_DIR/kuberdock.py" teardown $POD_PUBLIC_IP $POD_IP $IFACE $NAMESPACE $KUBERNETES_POD_ID $DATA_INFO $DATA_INFO-spec)
        log "$MSG"
    fi

    if [ "$SERVICE_IP" == "$INGRESS_SERVICE_IP" ];then
        log "INGRESS-CONTROLLER teardown: $POD_IP"
        rule_ingress_input D "$POD_IP"
        rule_ingress_output D "$POD_IP"
    fi

    if [ "$POD_DOMAIN" != "" ];then
        echo "INGRESS del: $POD_IP"
        ipset del kuberdock_ingress "$POD_IP"
    fi

    etcd_ DELETE "$USER_ID" "$POD_IP"
    rm -rf "$DATA_INFO"
    rm -rf "$DATA_INFO-spec"
    if [ ! $(ls "$DATA_DIR") ];then   # is empty
      rm -rf "$DATA_DIR"
    fi
}


function add_resolve {
  for resolve in $2
  do
    curl -sS --cacert "$ETCD_CAFILE" --cert "$ETCD_CERTFILE" --key "$ETCD_KEYFILE" \
      -X PUT "https://10.254.0.10:2379/v2/keys/skydns/kuberdock/svc/$1/$resolve" \
      -d value="{\"host\":\"127.0.0.1\",\"priority\":10,\"weight\":10,\"ttl\":30,\"targetstrip\":0}"
    if_failed "Error while add resolve to Etcd"
  done
}


# Reject version
function protect_cluster_reject {
    # MARKS:
    # 1 - traffic to reject/drop
    # 2 - traffic for public ip (will be added and used later)

    iptables -w -N KUBERDOCK -t mangle
    iptables_ -I PREROUTING -j KUBERDOCK -t mangle

    # Before other
    iptables -w -N KUBERDOCK-PUBLIC-IP -t mangle
    iptables_ -I PREROUTING -j KUBERDOCK-PUBLIC-IP -t mangle

    iptables_ -A KUBERDOCK -t mangle -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # Don't know corrct place for this rule;
    # Alternatively we can add ACCEPT RULE for each public rule in chain above
    iptables_ -A KUBERDOCK -t mangle -m mark --mark 2 -j ACCEPT

    # Needed for rsyslog for example
    iptables_ -A KUBERDOCK -t mangle -i lo -d 127.0.0.1 -j ACCEPT

    # before 'accept kuberdock_cluster':
    iptables_ -A KUBERDOCK -t mangle -i docker0 -d "$NODE_IP" -j MARK --set-mark 1
    # This is one not works, and don't know why (maybe next rule pass unwanted traffic):
    # iptables_ -A KUBERDOCK -t mangle -i docker0 ! -d "$NODE_IP" -j ACCEPT

    # if this one rule used then only after ssh rule and other
#    iptables_ -A KUBERDOCK -t mangle -m set ! --match-set kuberdock_cluster src -j MARK --set-mark 1
    iptables_ -A KUBERDOCK -t mangle -m set --match-set kuberdock_cluster src -j ACCEPT

    iptables_ -A KUBERDOCK -t mangle -s "$MASTER_IP" -j ACCEPT
    # Allow ssh to all node's addresses except pods.
    iptables_ -A KUBERDOCK -t mangle -p tcp --dport 22 -m set ! --match-set kuberdock_flannel dst -j ACCEPT
    iptables_ -A KUBERDOCK -t mangle -p icmp --icmp-type echo-request -j ACCEPT

    # Reject all other
    iptables_ -A KUBERDOCK -t mangle -j MARK --set-mark 1

    # Reject all bad packets
    # TODO I saw cases where this rules appears after docker rules due
    # services start ordering. So this is not robust
    # TODO create chaines for them
    iptables_ -I INPUT -t filter -m mark --mark 1 -j REJECT
    iptables_ -I FORWARD -t filter -m mark --mark 1 -j REJECT
}


# Drop version. Simpler and more robust (clean mangle table only)
function protect_cluster_drop {
    # MARKS:
    # 1 - traffic to reject/drop
    # 2 - traffic for public ip (will be added and used later)

    iptables -w -N KUBERDOCK -t mangle
    iptables_ -I PREROUTING -j KUBERDOCK -t mangle

    # Before other chaines
    iptables -w -N KUBERDOCK-PUBLIC-IP -t mangle
    iptables_ -I PREROUTING -j KUBERDOCK-PUBLIC-IP -t mangle

    iptables_ -A KUBERDOCK -t mangle -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # Don't know corrct place for this rule
    # Alternatively we can add ACCEPT RULE for each public rule in chain above
    iptables_ -A KUBERDOCK -t mangle -m mark --mark 2 -j ACCEPT

    # Needed for rsyslog for example
    iptables_ -A KUBERDOCK -t mangle -i lo -d 127.0.0.1 -j ACCEPT

    # before 'accept kuberdock_cluster':
    iptables_ -A KUBERDOCK -t mangle -i docker0 -d "$NODE_IP" -j DROP
    # This is not works, and don't know why (maybe next rule pass unwanted traffic):
    # iptables_ -A KUBERDOCK -t mangle -i docker0 ! -d "$NODE_IP" -j ACCEPT

    iptables_ -A KUBERDOCK -t mangle -m set --match-set kuberdock_cluster src -j ACCEPT

    iptables_ -A KUBERDOCK -t mangle -s "$MASTER_IP" -j ACCEPT

    # Allow ssh to all node's addresses except pods.
    iptables_ -A KUBERDOCK -t mangle -p tcp --dport 22 -m set ! --match-set kuberdock_flannel dst -j ACCEPT
    iptables_ -A KUBERDOCK -t mangle -p icmp --icmp-type echo-request -j ACCEPT

    # Reject all other
    iptables_ -A KUBERDOCK -t mangle -j DROP
}



case "$ACTION" in
  "init")
    rm -f "$LOG_FILE"
    iptables -w -N KUBERDOCK -t filter
    iptables -w -N KUBERDOCK -t nat
    iptables -w -N KUBERDOCK-PUBLIC-IP -t nat
    iptables -w -N KUBERDOCK-PUBLIC-IP-SNAT -t nat
    iptables_ -I FORWARD -t filter -j KUBERDOCK
    iptables_ -I PREROUTING -t nat -j KUBERDOCK
    iptables_ -I PREROUTING -t nat -j KUBERDOCK-PUBLIC-IP
    iptables_ -I POSTROUTING -t nat ! -o flannel.1 -j KUBERDOCK-PUBLIC-IP-SNAT
    MSG=$(/usr/bin/env python2 "$PLUGIN_DIR/kuberdock.py" init)
    log "$MSG"
    iptables_ -I KUBERDOCK -t filter -i docker0 ! -o docker0 -m set ! --match-set kuberdock_cluster dst -j ACCEPT
    iptables_ -I KUBERDOCK -t nat -m set ! --match-set kuberdock_cluster dst -j ACCEPT
    # reject outgoing not authorized smtp packets, to prevent spamming from containers
    iptables_ -I KUBERDOCK -t filter -p tcp --dport 25 -i docker0 -m set ! --match-set kuberdock_cluster dst -j REJECT
    protect_cluster_drop
    ipset -exist create kuberdock_ingress hash:ip
    ;;
  "setup")
    /usr/bin/env python2 "$PLUGIN_DIR/kuberdock.py" teardown_unexisting

    # Workaround 1
    # TODO what if api-server is down ?
    POD_SPEC=$(get_pod_spec)
    if_failed "Error while get pod spec"
    # Protection from fast start/stop pod; Must be first check
    if [ "$POD_SPEC" == "" ];then
      log "Empty spec case. Skip setup"
      exit
    fi

    # Workaround 2
    if [ -d "$DATA_DIR" ];then  # Protection from absent teardown
      log "Forced teardown"
      OLD_POD="$(ls -1 $DATA_DIR | head -1)"
      source "$DATA_DIR/$OLD_POD"
      teardown_pod
      rm -rf "$DATA_DIR/$OLD_POD"
    fi

    POD_IP=$(docker inspect --format="{{.NetworkSettings.IPAddress}}" "$DOCKER_PAUSE_ID")
    if_failed "Error while get POD_IP"
    SERVICE_IP=$(iptables -w -n -L -t nat | grep "$NAMESPACE" | head -1 | awk '{print $5}')
    if_failed "Error while get SERVICE_IP"
    USER_ID=$(echo "$POD_SPEC" | grep kuberdock-user-uid | awk '{gsub(/,$/,""); print $2}' | tr -d \")
    if_failed "Error while get USER_ID"
    if [ -z "$USER_ID" ]
      then
      log "Error while get USER_ID"
      exit
    fi
    POD_PUBLIC_IP=$(echo "$POD_SPEC" | grep kuberdock-public-ip | awk '{gsub(/,$/,""); print $2}' | tr -d \")
    if_failed "Error while get POD_PUBLIC_IP"
    RESOLVE=$(echo "$POD_SPEC" | grep kuberdock_resolve | awk '{gsub(/,$/,""); for(i=2; i<=NF; ++i) print $i}' | tr -d \" | xargs echo)
    if_failed "Error while get RESOLVE"
    POD_DOMAIN=$(echo "$POD_SPEC" | grep kuberdock-domain | awk '{gsub(/,$/,""); print $2}' | tr -d \")

    log "Setup Pod $POD_IP (Service $SERVICE_IP) of user $USER_ID; PUBLIC_IP: \"$POD_PUBLIC_IP\"; resolve: \"$RESOLVE\"; domain: \"$POD_DOMAIN\""

    mkdir -p "$DATA_DIR"
    echo "POD_IP=$POD_IP" > "$DATA_INFO"
    echo "SERVICE_IP=$SERVICE_IP" >> "$DATA_INFO"
    echo "USER_ID=$USER_ID" >> "$DATA_INFO"
    echo "$POD_SPEC" > "$DATA_INFO-spec"

    if [ "$POD_PUBLIC_IP" != "" ];then
      echo "POD_PUBLIC_IP=$POD_PUBLIC_IP" >> "$DATA_INFO"
      MSG=$(/usr/bin/env python2 "$PLUGIN_DIR/kuberdock.py" setup $POD_PUBLIC_IP $POD_IP $IFACE $NAMESPACE $KUBERNETES_POD_ID $DATA_INFO $DATA_INFO-spec)
      if [ ! $? -eq 0 ]; then
       log "$MSG"
       exit 1
      fi
      log "$MSG"
    fi

    if [ "$SERVICE_IP" == "$INGRESS_SERVICE_IP" ];then
      log "INGRESS-CONTROLLER setup: $POD_IP"
      if ! rule_ingress_output C "$POD_IP"
      then
        rule_ingress_output I "$POD_IP"
      fi
      if ! rule_ingress_input C "$POD_IP"
      then
        rule_ingress_input I "$POD_IP"
      fi
    fi

    if [ "$POD_DOMAIN" != "" ];then
      echo "POD_DOMAIN=$POD_DOMAIN" >> "$DATA_INFO"
      log "INGRESS add: $POD_IP"
      ipset add kuberdock_ingress "$POD_IP"
    fi

    MSG=$(/usr/bin/env python2 "$PLUGIN_DIR/kuberdock.py" initlocalstorage $DATA_INFO-spec 2>&1)
    if [ ! $? -eq 0 ]; then
     log "$MSG"
     exit 1
    fi
    log "$MSG"

    etcd_ PUT "$USER_ID" "$POD_IP" "{\"node\":\"$NODE_IP\",\"service\":\"$SERVICE_IP\"}"
    add_rules "$POD_IP" "$USER_ID"

    if [ ! -z "$RESOLVE" ]
    then
      add_resolve "$NAMESPACE" "$RESOLVE"
    fi

    # Workaround 3. Recheck that pod still exists.
    # TODO what if api-server is down ?
    POD_SPEC=$(get_pod_spec)
    if_failed "Error while get pod spec"
    if [ "$POD_SPEC" == "" ];then
      log "Pod already not exists. Make teardown"
      teardown_pod
      exit
    fi

    ;;
  "teardown")
    if [ -f "$DATA_INFO" ];then
      source "$DATA_INFO"
      teardown_pod
    else
      log "Teardown called for not existed pod. Skip"
    fi
    ;;
esac
