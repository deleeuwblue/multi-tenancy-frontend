#!/usr/bin/env bash

if kubectl get namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"; then
  echo "Namespace ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} found!"
else
  kubectl create namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE";
fi

if kubectl get secret -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$IMAGE_PULL_SECRET_NAME"; then
  echo "Image pull secret ${IMAGE_PULL_SECRET_NAME} found!"
else
  if [[ -n "$BREAK_GLASS" ]]; then
    kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $IMAGE_PULL_SECRET_NAME
  namespace: $IBMCLOUD_IKS_CLUSTER_NAMESPACE
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(jq .parameters.docker_config_json /config/artifactory)
EOF
  else
    kubectl create secret docker-registry \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --docker-server "$REGISTRY_URL" \
      --docker-password "$IBMCLOUD_API_KEY" \
      --docker-username iamapikey \
      --docker-email ibm@example.com \
      "$IMAGE_PULL_SECRET_NAME"
  fi
fi

if kubectl get serviceaccount -o json default --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" | jq -e 'has("imagePullSecrets")'; then
  if kubectl get serviceaccount -o json default --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" | jq --arg name "$IMAGE_PULL_SECRET_NAME" -e '.imagePullSecrets[] | select(.name == $name)'; then
    echo "Image pull secret $IMAGE_PULL_SECRET_NAME found in $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
  else
    echo "Adding image pull secret $IMAGE_PULL_SECRET_NAME to $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
    kubectl patch serviceaccount \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --type json \
      --patch '[{"op": "add", "path": "/imagePullSecrets/-", "value": {"name": "'"$IMAGE_PULL_SECRET_NAME"'"}}]' \
      default
  fi
else
  echo "Adding image pull secret $IMAGE_PULL_SECRET_NAME to $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
  kubectl patch serviceaccount \
    --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
    --patch '{"imagePullSecrets":[{"name":"'"$IMAGE_PULL_SECRET_NAME"'"}]}' \
    default
fi

IMAGE_NAME="${REGISTRY_URL}"/"${REGISTRY_NAMESPACE}"/"${IMAGES_NAME_FRONTEND}":"${REGISTRY_TAG}"
echo "IMAGE_NAME:"
echo ${IMAGE_NAME}

YAML_FILE="deployments/kubernetes.yml"
cp ${YAML_FILE} "${YAML_FILE}org"
rm ${YAML_FILE}
sed "s#IMAGE_NAME#${IMAGE_NAME}#g" "${YAML_FILE}org" > ${YAML_FILE}
cat ${YAML_FILE}

deployment_name=$(yq r ${YAML_FILE} metadata.name)
service_name=$(yq r -d1 ${YAML_FILE} metadata.name)
echo "deployment_name:"
echo ${deployment_name}
echo "service_name:"
echo ${service_name}


#####################

ibmcloud resource service-key ${APPID_SERVICE_KEY_NAME} --output JSON > ./appid-key-temp.json
APPID_OAUTHSERVERURL=$(cat ./appid-key-temp.json | jq '.[].credentials.oauthServerUrl' | sed 's/"//g' ) 
APPID_APPLICATION_DISCOVERYENDPOINT=$(cat ./appid-key-temp.json | jq '.[].credentials.discoveryEndpoint' | sed 's/"//g' )
APPID_TENANT_ID=$(cat ./appid-key-temp.json | jq '.[].credentials.tenantId' | sed 's/"//g' )
APPID_MANAGEMENT_URL=$(cat ./appid-key-temp.json | jq '.[].credentials.managementUrl' | sed 's/"//g' )

OAUTHTOKEN=$(ibmcloud iam oauth-tokens | awk '{print $4;}')
APPID_MANAGEMENT_URL_ALL_APPLICATIONS=${APPID_MANAGEMENT_URL}/managememt/v4/${APPID_TENANT_ID}/applications
echo $APPID_MANAGEMENT_URL_ALL_APPLICATIONS
result=$(curl -H "Content-Type: application/json" -H "Authorization: Bearer $OAUTHTOKEN" $APPID_MANAGEMENT_URL_ALL_APPLICATIONS)
echo $result
APPID_CLIENT_ID=$(echo $result | sed -n 's|.*"clientId":"\([^"]*\)".*|\1|p')
echo $APPID_CLIENT_ID

#####################

kubectl create secret generic appid.discovery-endpoint \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "VUE_APPID_DISCOVERYENDPOINT=$APPID_APPLICATION_DISCOVERYENDPOINT"
kubectl create secret generic appid.client-id-fronted \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "VUE_APPID_CLIENT_ID=$APPID_CLIENT_ID"

#####################

BACKEND_ADDRESS="${IBMCLOUD_IKS_CLUSTER_NAMESPACE}.service-backend"
BACKEND_PORT=$(kubectl get service -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "service-backend" -o json | jq -r '.spec.ports[0].nodePort')
SERVICE_CATALOG_URL="http://${BACKEND_ADDRESS}:${BACKEND_PORT}"

#--env VUE_APP_API_URL_PRODUCTS="$SERVICE_CATALOG_URL/base/category" \
#--env VUE_APP_API_URL_ORDERS="$SERVICE_CATALOG_URL/base/customer/Orders" \
#--env VUE_APP_API_URL_CATEGORIES="$SERVICE_CATALOG_URL/base/category" \
#--env VUE_APP_CATEGORY_NAME="$(params.APPLICATION_CATEGORY)" \
#--env VUE_APP_HEADLINE="$(params.APPLICATION_CONTAINER_NAME_FRONTEND)" \
#--env VUE_APP_ROOT="/" \

#set_env APPLICATION_CONTAINER_NAME_BACKEND "${APPLICATION_CONTAINER_NAME_BACKEND}"
#set_env APPLICATION_CONTAINER_NAME_FRONTEND "${APPLICATION_CONTAINER_NAME_FRONTEND}"
#set_env APPLICATION_CATEGORY "${APPLICATION_CATEGORY}"




#####################

kubectl apply --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" -f ${YAML_FILE}
if kubectl rollout status --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "deployment/$deployment_name"; then
  status=success
else
  status=failure
fi

kubectl get events --sort-by=.metadata.creationTimestamp -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"

if [ "$status" = failure ]; then
  echo "Deployment failed"
  if [[ -z "$BREAK_GLASS" ]]; then
    ibmcloud cr quota
  fi
  exit 1
fi

IP_ADDRESS=$(kubectl get nodes -o json | jq -r '[.items[] | .status.addresses[] | select(.type == "ExternalIP") | .address] | .[0]')
PORT=$(kubectl get service -n  "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$service_name" -o json | jq -r '.spec.ports[0].nodePort')

echo "Application URL: http://${IP_ADDRESS}:${PORT}"

echo -n "http://${IP_ADDRESS}:${PORT}" > ../app-url
