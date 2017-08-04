#!/bin/bash

set -e

! read -rd '' HELP_STRING <<"EOF"
Usage: ctl.sh [OPTION]... [-i|--install] PROMETHEUS_HOST GRAFANA_HOST
   or: ctl.sh [OPTION]...

Install Prometheus Operator to Kubernetes cluster.
Default namespace is 'monitoring'. Can be overridden with '-n' option.

Mandatory arguments:
  -i, --install                install into 'monitoring' namespace, override with '-n' option
  -u, --upgrade                upgrade existing installation, will reuse password and host names
  -d, --delete                 remove everything, including the namespace
  --retention                  how long will Prometheus store metrics
  --storage-class-name         name of the storage class
  --storage-size               storage size with optional IEC suffix

Optional arguments:
  -h, --help                   output this message
  -n, --namespace              use provided namespace insted of the 'monitoring' default
EOF

RANDOM_NUMBER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 4 | head -n 1)
TMP_DIR="/tmp/prometheus-ctl-$RANDOM_NUMBER"
WORKDIR="$TMP_DIR/prometheus-operator-master/contrib/kube-prometheus"
DEPLOY_SCRIPT="hack/cluster-monitoring/self-hosted-deploy"
TEARDOWN_SCRIPT="hack/cluster-monitoring/self-hosted-teardown"

MODE=""
NAMESPACE="monitoring"
FIRST_INSTALL="true"
USER="admin"
USER_BASE64=$(echo -n "$USER" | base64 -w0)
PASSWORD='~,eirbDjhj,eirb'
STORAGE_CLASS_NAME="rbd"
STORAGE_SIZE="20Gi"
RETENTION_PERIOD="1440h"


TEMP=$(getopt -o i,u,d,n,h --long help,install,upgrade,delete,retention:,storage-class-name:,storage-size:,namespace: \
             -n 'ctl' -- "$@")

eval set -- "$TEMP"

while true; do
  case "$1" in
    -i | --install )
      MODE=install; shift ;;
    -u | --upgrade )
      MODE=upgrade; shift ;;
    -d | --delete )
      MODE=delete; shift ;;
    -n | --namespace )
      NAMESPACE="$2"; shift 2;;
    --retention )
      RETENTION_PERIOD="$2"; shift 2;;
    --storage-class-name )
      STORAGE_CLASS_NAME="$2"; shift 2;;
    --storage-size )
      STORAGE_SIZE="$2"; shift 2;;
    -h | --help )
      echo "$HELP_STRING"; exit 0 ;;
    -- )
      shift; break ;;
    * )
      break ;;
  esac
done

if [ -z "$MODE" ]; then echo "Mode of operation not provided. Use '-h' to print proper usage."; exit 1; fi

type curl >/dev/null 2>&1 || { echo >&2 "I require curl but it's not installed.  Aborting."; exit 1; }
type base64 >/dev/null 2>&1 || { echo >&2 "I require base64 but it's not installed.  Aborting."; exit 1; }
type unzip >/dev/null 2>&1 || { echo >&2 "I require unzip but it's not installed.  Aborting."; exit 1; }
type kubectl >/dev/null 2>&1 || { echo >&2 "I require kubectl but it's not installed.  Aborting."; exit 1; }
type jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed.  Aborting."; exit 1; }
type htpasswd >/dev/null 2>&1 || { echo >&2 "I require kubectl but it's not installed. Please, install 'apache2-utils'. Aborting."; exit 1; }


mkdir -p "$TMP_DIR"
cd "$TMP_DIR"
curl -OJL "https://github.com/flant/prometheus-operator/archive/master.zip" -o prometheus-operator-master.zip
unzip -o prometheus-operator-master.zip >/dev/null 2>&1
cd "$WORKDIR"


function install {
  PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  echo "Login: admin"
  echo "Password: $PASSWORD"
  PASSWORD_BASE64=$(echo -n "$PASSWORD" | base64 -w0)
  BASIC_AUTH_SECRET=$(echo "$PASSWORD" | htpasswd -ni admin | base64 -w0)
  # install basic-auth secret
  sed -i -e "s%##BASIC_AUTH_SECRET##%$BASIC_AUTH_SECRET%" manifests/ingress/basic-auth-secret.yaml
  # install grafana credentials and ingress host
  sed -i -e "s/##GRAFANA_USER##/$USER_BASE64/" -e "s/##GRAFANA_PASSWORD##/$PASSWORD_BASE64/" manifests/grafana/grafana-credentials.yaml
  sed -i -e "s/##GRAFANA_HOST##/$GRAFANA_HOST/g" manifests/ingress/grafana-ingress.yaml
  # install prometheus ingress host
  sed -i "s/##PROMETHEUS_HOST##/$PROMETHEUS_HOST/g" manifests/ingress/prometheus-ingress.yaml
  # set storage parameters
  sed -i -e "s/##RETENTION_PERIOD##/$RETENTION_PERIOD/g" \
         -e "s/##STORAGE_CLASS_NAME##/$STORAGE_CLASS_NAME/g" \
         -e "s/##STORAGE_SIZE##/$STORAGE_SIZE/g" \
              manifests/prometheus/prometheus-k8s.yaml
  $DEPLOY_SCRIPT
}

function upgrade {
  USER=$(kubectl -n "$NAMESPACE" get secret grafana-credentials -o json | jq .data.user -r | base64 -d)
  PASSWORD=$(kubectl -n "$NAMESPACE" get secret grafana-credentials -o json | jq .data.password -r | base64 -d)
  PASSWORD_BASE64=$(echo -n "$PASSWORD" | base64 -w0)
  PROMETHEUS_HOST=$(kubectl -n "$NAMESPACE" get ingress prometheus-ingress -o json | jq -r '.spec.rules[0].host')
  GRAFANA_HOST=$(kubectl -n "$NAMESPACE" get ingress grafana-ingress -o json | jq -r '.spec.rules[0].host')
  BASIC_AUTH_SECRET=$(echo "$PASSWORD" | htpasswd -ni admin | base64 -w0)
  # install basic-auth secret
  sed -i -e "s%##BASIC_AUTH_SECRET##%$BASIC_AUTH_SECRET%" manifests/ingress/basic-auth-secret.yaml
  # install grafana credentials and ingress host
  sed -i -e "s/##GRAFANA_USER##/$USER_BASE64/" -e "s/##GRAFANA_PASSWORD##/$PASSWORD_BASE64/" manifests/grafana/grafana-credentials.yaml
  sed -i -e "s/##GRAFANA_HOST##/$GRAFANA_HOST/g" manifests/ingress/grafana-ingress.yaml
  # install prometheus ingress host
  sed -i "s/##PROMETHEUS_HOST##/$PROMETHEUS_HOST/g" manifests/ingress/prometheus-ingress.yaml
  # get storage parameters

  # set storage parameters
  sed -i -e "s/##RETENTION_PERIOD##/$RETENTION_PERIOD/g" \
         -e "s/##STORAGE_CLASS_NAME##/$STORAGE_CLASS_NAME/g" \
         -e "s/##STORAGE_SIZE##/$STORAGE_SIZE/g" \
              manifests/prometheus/prometheus-k8s.yaml
  $DEPLOY_SCRIPT
}

if [ "$MODE" == "install" ]
then
  if [ -z "$1" ] && [ -z "$2" ]; then echo "Two positional arguments required. See '--help' for more information."; exit 1; fi
  PROMETHEUS_HOST="$1"
  GRAFANA_HOST="$2"
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 && FIRST_INSTALL="false"
  if [ "$FIRST_INSTALL" == "true" ]
  then
    install
  else
    echo "Namespace $NAMESPACE exists. Please, delete or run with the --upgrade option it to avoid shooting yourself in the foot."
  fi
elif [ "$MODE" == "upgrade" ]
then
  upgrade
elif [ "$MODE" == "delete" ]
then
  $TEARDOWN_SCRIPT || true
  kubectl delete ns "$NAMESPACE" || true
fi

function cleanup {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
