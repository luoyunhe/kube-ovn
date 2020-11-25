#!/bin/bash
set -eo pipefail

# https://bugs.launchpad.net/neutron/+bug/1776778
if grep -q "3.10.0-862" /proc/version
then
    echo "kernel version 3.10.0-862 has a nat related bug that will affect ovs function, please update to a version greater than 3.10.0-898"
    exit 1
fi

# https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1794232
if [ ! -f "/proc/net/if_inet6" ] && grep -q "3.10" /proc/version ; then
    echo "geneve requires ipv6, please add ipv6.disable=0 to kernel follow the instruction below:"
    echo "
vi /etc/default/grub
find GRUB_CMDLINE_LINUX=  and change ipv6.disable=1 to ipv6.disable=0
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot
cat /proc/cmdline"
    exit 1
fi

DB_NB_ADDR=${DB_NB_ADDR:-::}
DB_NB_PORT=${DB_NB_PORT:-6641}
DB_SB_ADDR=${DB_SB_ADDR:-::}
DB_SB_PORT=${DB_SB_PORT:-6642}
ENABLE_SSL=${ENABLE_SSL:-false}

function gen_conn_str {
  t=$(echo -n "${NODE_IPS}" | sed 's/[[:space:]]//g' | sed 's/,/ /g')
  if [[ "$ENABLE_SSL" == "false" ]]; then
    x=$(for i in ${t}; do echo -n "tcp:[$i]:$1",; done| sed 's/,$//')
  else
    x=$(for i in ${t}; do echo -n "ssl:[$i]:$1",; done| sed 's/,$//')
  fi
  echo "$x"
}

function get_leader_ip {
  while true;
  do
    leader=$(kubectl get ep -n "${POD_NAMESPACE}" ovn-"$1" -o jsonpath={.subsets\[0\].addresses\[0\].ip})
    if [ "$leader" == "" ]; then
      # no available leader
      break
    else
      if [[ "$leader" != "${POD_IP}" ]]; then
        echo "$leader"
        return
      else
        # "leader cannot be self, waiting new leader"
        sleep 5
      fi
    fi
  done

  # If no available leader the first ip will be the leader
  t=$(echo -n "${NODE_IPS}" | sed 's/[[:space:]]//g' | sed 's/,/ /g')
  echo -n "${t}" | cut -f 1 -d " "
}

function quit {
    /usr/share/ovn/scripts/ovn-ctl stop_northd
    exit 0
}
trap quit EXIT
if [[ "$ENABLE_SSL" == "false" ]]; then
  if [[ -z "$NODE_IPS" ]]; then
      /usr/share/ovn/scripts/ovn-ctl restart_northd
      ovn-nbctl set-connection ptcp:"${DB_NB_PORT}":["${DB_NB_ADDR}"]
      ovn-nbctl set Connection . inactivity_probe=0
      ovn-sbctl set-connection ptcp:"${DB_SB_PORT}":["${DB_SB_ADDR}"]
      ovn-sbctl set Connection . inactivity_probe=0
  else
      if [[ ! "$NODE_IPS" =~ "$POD_IP" ]]; then
        echo "ERROR! host ip $POD_IP not in env NODE_IPS $NODE_IPS"
        exit 1
      fi
      /usr/share/ovn/scripts/ovn-ctl stop_northd

      nb_leader_ip=$(get_leader_ip nb)
      sb_leader_ip=$(get_leader_ip sb)
      if [[ "$nb_leader_ip" == "${POD_IP}" ]]; then
          # Start ovn-northd, ovn-nb and ovn-sb
          /usr/share/ovn/scripts/ovn-ctl \
              --db-nb-create-insecure-remote=yes \
              --db-sb-create-insecure-remote=yes \
              --db-nb-cluster-local-addr="[${POD_IP}]" \
              --db-sb-cluster-local-addr="[${POD_IP}]" \
              --db-nb-addr=[::] \
              --db-sb-addr=[::] \
              --ovn-northd-nb-db="$(gen_conn_str 6641)" \
              --ovn-northd-sb-db="$(gen_conn_str 6642)" \
              start_northd
          ovn-nbctl set-connection ptcp:"${DB_NB_PORT}":[::]
          ovn-nbctl set Connection . inactivity_probe=0
          ovn-sbctl set-connection ptcp:"${DB_SB_PORT}":[::]
          ovn-sbctl set Connection . inactivity_probe=0
      else
          while ! nc -z "${nb_leader_ip}" "${DB_NB_PORT}" >/dev/null;
          do
              echo "sleep 5 seconds, waiting for ovn-nb ${nb_leader_ip}:${DB_NB_PORT} ready "
              sleep 5;
          done
          while ! nc -z "${sb_leader_ip}" "${DB_SB_PORT}" >/dev/null;
          do
              echo "sleep 5 seconds, waiting for ovn-sb ${sb_leader_ip}:${DB_NB_PORT} ready "
              sleep 5;
          done

          # Start ovn-northd, ovn-nb and ovn-sb
          /usr/share/ovn/scripts/ovn-ctl \
              --db-nb-create-insecure-remote=yes \
              --db-sb-create-insecure-remote=yes \
              --db-nb-cluster-local-addr="[${POD_IP}]" \
              --db-sb-cluster-local-addr="[${POD_IP}]" \
              --db-nb-cluster-remote-addr="[${nb_leader_ip}]" \
              --db-sb-cluster-remote-addr="[${sb_leader_ip}]" \
              --ovn-northd-nb-db="$(gen_conn_str 6641)" \
              --ovn-northd-sb-db="$(gen_conn_str 6642)" \
              start_northd
      fi
  fi
else
    if [[ -z "$NODE_IPS" ]]; then
      /usr/share/ovn/scripts/ovn-ctl \
        --ovn-nb-db-ssl-key=/var/run/tls/key \
        --ovn-nb-db-ssl-cert=/var/run/tls/cert \
        --ovn-nb-db-ssl-ca-cert=/var/run/tls/cacert \
        --ovn-sb-db-ssl-key=/var/run/tls/key \
        --ovn-sb-db-ssl-cert=/var/run/tls/cert \
        --ovn-sb-db-ssl-ca-cert=/var/run/tls/cacert \
        --ovn-northd-ssl-key=/var/run/tls/key \
        --ovn-northd-ssl-cert=/var/run/tls/cert \
        --ovn-northd-ssl-ca-cert=/var/run/tls/cacert \
        restart_northd
      ovn-nbctl -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert set-connection pssl:"${DB_NB_PORT}":["${DB_NB_ADDR}"]
      ovn-nbctl -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert set Connection . inactivity_probe=0
      ovn-sbctl -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert set-connection pssl:"${DB_SB_PORT}":["${DB_SB_ADDR}"]
      ovn-sbctl -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert set Connection . inactivity_probe=0
  else
      if [[ ! "$NODE_IPS" =~ "$POD_IP" ]]; then
        echo "ERROR! host ip $POD_IP not in env NODE_IPS $NODE_IPS"
        exit 1
      fi
      /usr/share/ovn/scripts/ovn-ctl stop_northd

      nb_leader_ip=$(get_leader_ip nb)
      sb_leader_ip=$(get_leader_ip sb)
      if [[ "$nb_leader_ip" == "${POD_IP}" ]]; then
          # Start ovn-northd, ovn-nb and ovn-sb
          /usr/share/ovn/scripts/ovn-ctl \
              --ovn-nb-db-ssl-key=/var/run/tls/key \
              --ovn-nb-db-ssl-cert=/var/run/tls/cert \
              --ovn-nb-db-ssl-ca-cert=/var/run/tls/cacert \
              --ovn-sb-db-ssl-key=/var/run/tls/key \
              --ovn-sb-db-ssl-cert=/var/run/tls/cert \
              --ovn-sb-db-ssl-ca-cert=/var/run/tls/cacert \
              --ovn-northd-ssl-key=/var/run/tls/key \
              --ovn-northd-ssl-cert=/var/run/tls/cert \
              --ovn-northd-ssl-ca-cert=/var/run/tls/cacert \
              --db-nb-cluster-local-addr="[${POD_IP}]" \
              --db-sb-cluster-local-addr="[${POD_IP}]" \
              --db-nb-addr=[::] \
              --db-sb-addr=[::] \
              --ovn-northd-nb-db="$(gen_conn_str 6641)" \
              --ovn-northd-sb-db="$(gen_conn_str 6642)" \
              start_northd
          ovn-nbctl -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert set-connection pssl:"${DB_NB_PORT}":[::]
          ovn-nbctl set Connection . inactivity_probe=0
          ovn-sbctl -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert set-connection pssl:"${DB_SB_PORT}":[::]
          ovn-sbctl set Connection . inactivity_probe=0
      else
          while ! nc -z "${nb_leader_ip}" "${DB_NB_PORT}" >/dev/null;
          do
              echo "sleep 5 seconds, waiting for ovn-nb ${nb_leader_ip}:${DB_NB_PORT} ready "
              sleep 5;
          done
          while ! nc -z "${sb_leader_ip}" "${DB_SB_PORT}" >/dev/null;
          do
              echo "sleep 5 seconds, waiting for ovn-sb ${sb_leader_ip}:${DB_NB_PORT} ready "
              sleep 5;
          done

          # Start ovn-northd, ovn-nb and ovn-sb
          /usr/share/ovn/scripts/ovn-ctl \
              --ovn-nb-db-ssl-key=/var/run/tls/key \
              --ovn-nb-db-ssl-cert=/var/run/tls/cert \
              --ovn-nb-db-ssl-ca-cert=/var/run/tls/cacert \
              --ovn-sb-db-ssl-key=/var/run/tls/key \
              --ovn-sb-db-ssl-cert=/var/run/tls/cert \
              --ovn-sb-db-ssl-ca-cert=/var/run/tls/cacert \
              --ovn-northd-ssl-key=/var/run/tls/key \
              --ovn-northd-ssl-cert=/var/run/tls/cert \
              --ovn-northd-ssl-ca-cert=/var/run/tls/cacert \
              --db-nb-cluster-local-addr="[${POD_IP}]" \
              --db-sb-cluster-local-addr="[${POD_IP}]" \
              --db-nb-cluster-remote-addr="[${nb_leader_ip}]" \
              --db-sb-cluster-remote-addr="[${sb_leader_ip}]" \
              --ovn-northd-nb-db="$(gen_conn_str 6641)" \
              --ovn-northd-sb-db="$(gen_conn_str 6642)" \
              start_northd
      fi
  fi
fi
chmod 600 /etc/ovn/*
tail -f /var/log/ovn/ovn-northd.log
