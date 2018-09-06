#!/bin/sh
. init-properties.sh

########################################################################
# Startup checks
########################################################################"
command -v oc >/dev/null 2>&1 || {
  echo >&2 "The oc client tools need to be installed to connect to OpenShift.";
  echo >&2 "Download it from https://www.openshift.org/download.html and confirm that \"oc version\" runs.";
  exit 1;
}

# Additional properties
#PROJECT_GIT_BRANCH=master
#PROJECT_GIT_DIR=./support/demo_project_git
#PROJECT_GIT_REPO_NAME=examples-rhpam7-mortgage-demo-repo.git
#OFFLINE_MODE=false

# wipe screen.
clear

########################################################################
# Command line parameters
########################################################################"

function usage {
      echo "Usage: init-openshift.sh [args...]"
      echo "where args include:"
      echo "    -d              Demo name. E.g. 'rhpam7-mortgage, rhpam7-install, etc.'"
      echo "    -n              OpenShift Namespace."
}

#Parse the params
while getopts ":d:n:h" opt; do
  case $opt in
    d)
      DEMO=$OPTARG
      ;;
    n)
      NAMESPACE=$OPTARG
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

########################################################################
# Variables
########################################################################"
if [ -z "$DEMO" ]
then
  echo "No demo name specified. Please use the '-d' command line argument to pass the name of the demo to which you would like to add monitoring functionality."
  exit 1
else
  echo "Demo is: $DEMO"
fi

if [ -z "$NAMESPACE" ]
then
  NAMESPACE=$(oc project | awk '{print $3}' | sed s/\"//g)
fi

echo "Namespace is: $NAMESPACE"

# TODO: automatically get all installed KIE-Servers from oc ....: oc get dc | grep -i kieserver | awk '{print $1}'

KIE_SERVER_SERVICE=$DEMO-kieserver
KIE_SERVER_DC=$DEMO-kieserver

echo
echo "######################################################################"
echo "##                                                                  ##"
echo "##  Setting up the ${DEMO}                                 ##"
echo "##                                                                  ##"
echo "##                                                                  ##"
echo "##     ####  #   # ####   ###   #   #   #####    #####              ##"
echo "##     #   # #   # #   # #   # # # # #     #     #   #              ##"
echo "##     ####  ##### ####  ##### #  #  #   ###     #   #              ##"
echo "##     # #   #   # #     #   # #     #   #       #   #              ##"
echo "##     #  #  #   # #     #   # #     #  #     #  #####              ##"
echo "##                                                                  ##"
echo "##  brought to you by,                                              ##"
echo "##             ${AUTHORS}                                              ##"
echo "##                                                                  ##"
echo "##                                                                  ##"
echo "##  ${PROJECT}         ##"
echo "##                                                                  ##"
echo "######################################################################"
echo

########################################################################
# Functions
########################################################################"

function echo_header() {
  echo
  echo "########################################################################"
  echo $1
  echo "########################################################################"
}

########################################################################
# Configure KIE-Server
########################################################################"

# Create the config-map with required Prometheus JAR
oc create configmap rhpam-kieserver-prometheus-config-map --from-file=support/openshift/jmx_prometheus_javaagent-0.3.1.jar,support/openshift/jmx_exporter_conf-wildfly-10.yaml

# Mount ConfigMap in container
oc volume dc/$KIE_SERVER_DC --add --name=prometheus-config-volume --configmap-name=rhpam-kieserver-prometheus-config-map --mount-path=/tmp/prometheus

# Set the JBoss Modules System Packackes environment variable
oc set env dc/$KIE_SERVER_DC JAVA_OPTS_APPEND="-Dkie.mbeans=enabled -javaagent:/tmp/prometheus/jmx_prometheus_javaagent-0.3.1.jar=58080:/tmp/prometheus/jmx_exporter_conf-wildfly-10.yaml"

# Expose the 58080 Prometheus port from the container
echo "Patching KIE-Server DC with port."
oc patch dc/$KIE_SERVER_DC -p '{"spec":{"template":{"spec":{"containers":[{"name":"'${KIE_SERVER_DC}'", "ports":[{"name":"prometheus", "containerPort":58080, "protocol":"TCP"}]}]}}}}'

# Add that port to service
oc patch svc/$KIE_SERVER_SERVICE -p '{"spec":{"ports":[{"name":"prometheus", "port":58080, "protocol":"TCP", "targetPort":58080}]}}'

#Create the route
oc expose svc/$KIE_SERVER_SERVICE --name=rhpam-dev-kieserver-prometheus --port=58080

########################################################################
# Deploy Prometheus
########################################################################"

echo_header "Deploying Prometheus"

# Create the prom secret
# Patch the prometheus.yml file to point to the demo's KIE-Server
sed s/.*targets:\ \\[\'rhpam.*/\ \ \ \ \ \ -\ targets\ :\ \[\'$KIE_SERVER_SERVICE:58080\'\]/g support/openshift/prometheus.yml.orig > support/openshift/prometheus.yml
oc create secret generic prom --from-file=support/openshift/prometheus.yml

# Create the prom-alerts secret
oc create secret generic prom-alerts --from-file=support/openshift/alertmanager.yml

# Create the prometheus instance
oc process -f https://raw.githubusercontent.com/openshift/origin/master/examples/prometheus/prometheus-standalone.yaml | oc apply -f -
#oc process -f prometheus-standalone.yaml | oc apply -f -

# Grant the PROM service account access to review Bearer tokens.
# This is needed so we can use bearer token authentication between Grafana and Prometheus.
# See also: https://access.redhat.com/solutions/3430731
# See also: https://github.com/openshift/oauth-proxy/issues/70
USER=prom
oc adm policy add-cluster-role-to-user system:auth-delegator -z ${USER} -n ${NAMESPACE}
oc adm policy add-role-to-user view -z ${USER}

# Patch the OAuth proxy to allow Bearer token authentication
oc patch statefulset/prom --type='json' -p="[{'op': 'add', 'path': '/spec/template/spec/containers/0/args/-', 'value': '-openshift-delegate-urls={\"/\":{\"resource\":\"pods\",\"namespace\":\"\$(NAMESPACE)\",\"name\":\"prom\",\"verb\":\"get\"}}'}]"

########################################################################
# Deploy Grafana
########################################################################"

echo_header "Deploying Grafana"

oc new-app -f https://raw.githubusercontent.com/mrsiano/openshift-grafana/master/grafana-ocp.yaml -p NAMESPACE=$NAMESPACE -p IMAGE_GF=mrsiano/openshift-grafana:5.2.0

########################################################################
# Configure Grafana Datasource
########################################################################"

echo_header "Creating Prometheus datasource in Grafana"

## Wait for Grafana to start before configuring the datasource
STARTUP_WAIT=60

SA_READER=prom
PROTOCOL=http

GRAFANA_HOST="${PROTOCOL}://$( oc get route grafana-ocp -o jsonpath='{.spec.host}' )"

#First check if the Grafana REST API is available. We'll wait for 60 seconds
echo "Waiting for Grafana REST API to become available at URL: ${GRAFANA_HOST}/api/datasources "
count=0
launched=false
until [ $count -gt $STARTUP_WAIT ]
do
  curl --output /dev/null --silent --head --fail ${GRAFANA_HOST}/api/datasources
  #curl --fail  ${GRAFANA_HOST}/api/datasources
  if [ $? -eq 0 ] ; then
    echo "Grafana REST API started."
    launched=true
    break
  fi
  printf '.'
  sleep 5
  let count=$count+5;
done

#Check that the platform has started, otherwise exit.
if [ $launched = "false" ]
then
  echo "Grafana did not start correctly. Exiting."
  exit 1
else
  echo "Grafana started."
fi

echo "Create Prometheus Datasource."

PAYLOAD="$( mktemp )"
cat <<EOF >"${PAYLOAD}"
{
"name": "prometheus",
"type": "prometheus",
"typeLogoUrl": "",
"access": "proxy",
"url": "https://$( oc get route prom -n "${NAMESPACE}" -o jsonpath='{.spec.host}' )",
"basicAuth": false,
"withCredentials": false,
"jsonData": {
    "tlsSkipVerify":true
},
"secureJsonData": {
    "httpHeaderName1":"Authorization",
    "httpHeaderValue1":"Bearer $( oc sa get-token "${SA_READER}" -n "${NAMESPACE}" )"
}
}
EOF

# setup grafana data source
curl --insecure -H "Content-Type: application/json" -u admin:admin "${GRAFANA_HOST}/api/datasources" -X POST -d "@${PAYLOAD}"


echo
echo "$PRODUCT $VERSION $DEMO Setup Complete."
echo
