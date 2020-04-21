#!/usr/bin/env bash

# App url
APPGW_APP1_URL=votingapp-ha.contoso.com
APPGW_APP2_URL=testapp-ha.contoso.com

# Zones
ZONE1=1
ZONE2=3

# IP Addresses
NET_PREFIX=10.0.0.0/16
APPGW_PREFIX=10.0.1.0/24
REDIS1_PREFIX=10.0.11.0/24
REDIS2_PREFIX=10.0.12.0/24
ASE1_PREFIX=10.0.101.0/24
ASE2_PREFIX=10.0.102.0/24
FIREWALL_PREFIX=10.0.200.0/24
JUMPBOX_PREFIX=10.0.250.0/24

# create self-signed SSL certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=${APPGW_APP1_URL}" -out appgw_ha.crt -keyout appgw_ha.key
openssl pkcs12 -export -out appgw_ha.pfx -in appgw_ha.crt -inkey appgw_ha.key -passout pass:$PFX_PASSWORD
CERT_DATA_1=$(cat appgw_ha.pfx | base64 | tr -d '\n' | tr -d '\r')
rm appgw_ha.crt appgw_ha.key appgw_ha.pfx

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=${APPGW_APP2_URL}" -out appgw_ha.crt -keyout appgw_ha.key
openssl pkcs12 -export -out appgw_ha.pfx -in appgw_ha.crt -inkey appgw_ha.key -passout pass:$PFX_PASSWORD
CERT_DATA_2=$(cat appgw_ha.pfx | base64 | tr -d '\n' | tr -d '\r')
rm appgw_ha.crt appgw_ha.key appgw_ha.pfx

# 1. creates the resource group
az group create --name "${RGNAME}" --location "${RGLOCATION}"

# 2. deploy global network related resources
VNET_NAME=$(az network vnet list -g $RGNAME --query "[?contains(addressSpace.addressPrefixes, '${NET_PREFIX}')]" --query [0].name -o tsv)
az group deployment create --resource-group $RGNAME --template-file templates/network.json --parameters existentVnetName=$VNET_NAME vnetAddressPrefix=$NET_PREFIX
VNET_NAME=$(az group deployment show -g $RGNAME -n network --query properties.outputs.vnetName.value -o tsv)
VNET_ROUTE_NAME=$(az group deployment show -g $RGNAME -n network --query properties.outputs.vnetRouteName.value -o tsv)

# 3. deploy ASE - ZONE 1 & 2
az group deployment create --resource-group $RGNAME --template-file templates/ase.json -n ase1 --parameters vnetName=$VNET_NAME vnetRouteName=$VNET_ROUTE_NAME aseSubnetAddressPrefix=$ASE1_PREFIX zone=$ZONE1 &
az group deployment create --resource-group $RGNAME --template-file templates/ase.json -n ase2 --parameters vnetName=$VNET_NAME vnetRouteName=$VNET_ROUTE_NAME aseSubnetAddressPrefix=$ASE2_PREFIX zone=$ZONE2 &
wait
ASE1_DNS_SUFFIX=$(az group deployment show -g $RGNAME -n ase1 --query properties.outputs.dnsSuffix.value -o tsv)
ASE1_SUBNET_NAME=$(az group deployment show -g $RGNAME -n ase1 --query properties.outputs.aseSubnetName.value -o tsv)
ASE1_NAME=$(az group deployment show -g $RGNAME -n ase1 --query properties.outputs.aseName.value -o tsv)
ASE1_ID=$(az group deployment show -g $RGNAME -n ase1 --query properties.outputs.aseId.value -o tsv)
ASE1_ILB_IP_ADDRESS=$(az resource show --ids ${ASE1_ID}/capacities/virtualip --api-version 2018-02-01 --query internalIpAddress --output tsv)
ASE2_DNS_SUFFIX=$(az group deployment show -g $RGNAME -n ase2 --query properties.outputs.dnsSuffix.value -o tsv)
ASE2_SUBNET_NAME=$(az group deployment show -g $RGNAME -n ase2 --query properties.outputs.aseSubnetName.value -o tsv)
ASE2_NAME=$(az group deployment show -g $RGNAME -n ase2 --query properties.outputs.aseName.value -o tsv)
ASE2_ID=$(az group deployment show -g $RGNAME -n ase2 --query properties.outputs.aseId.value -o tsv)
ASE2_ILB_IP_ADDRESS=$(az resource show --ids ${ASE2_ID}/capacities/virtualip --api-version 2018-02-01 --query internalIpAddress --output tsv)

# Obtain ASE management IP endpoints
ENDPOINTS_LIST=$(az rest --method get --uri $ASE_ID/inboundnetworkdependenciesendpoints?api-version=2016-09-01 | jq '.value[0].endpoints | join(", ")' -j)

# Deploy AF
az group deployment create --resource-group $RGNAME --template-file templates/firewall.json \
    --parameters vnetName=$VNET_NAME firewallSubnetPrefix=$FIREWALL_PREFIX vnetRouteName=$VNET_ROUTE_NAME \
                 aseManagementEndpointsList="$ENDPOINTS_LIST"
                 
# 4. deploy the private DNS zone - ZONE 1 & 2
az group deployment create --resource-group $RGNAME --template-file templates/dns.json -n dns1 --parameters vnetName=$VNET_NAME zoneName=$ASE1_DNS_SUFFIX ipAddress=$ASE1_ILB_IP_ADDRESS &
az group deployment create --resource-group $RGNAME --template-file templates/dns.json -n dns2 --parameters vnetName=$VNET_NAME zoneName=$ASE2_DNS_SUFFIX ipAddress=$ASE2_ILB_IP_ADDRESS &
wait

# 5. deploy jumpbox
az group deployment create --resource-group $RGNAME --template-file templates/jumpbox.json --parameters vnetName=$VNET_NAME \
    subnetAddressPrefix=$JUMPBOX_PREFIX adminUsername=$JUMPBOX_USER adminPassword=$JUMPBOX_PASSWORD
JUMPBOX_PUBLIC_IP=$(az group deployment show -g $RGNAME -n jumpbox --query properties.outputs.jumpboxPublicIpAddress.value -o tsv)
JUMPBOX_SUBNET_NAME=$(az group deployment show -g $RGNAME -n jumpbox --query properties.outputs.jumpboxSubnetName.value -o tsv)

# 6. deploy services: cosmos, sql, servicebus and storage
ALLOWED_SUBNET_NAMES=${ASE1_SUBNET_NAME},${ASE2_SUBNET_NAME},${JUMPBOX_SUBNET_NAME}
az group deployment create --resource-group $RGNAME --template-file templates/services.json \
    --parameters vnetName=$VNET_NAME allowedSubnetNames=$ALLOWED_SUBNET_NAMES \
                 sqlAdminUserName=$SQLADMINUSER sqlAdminPassword=$SQLADMINPASSWORD sqlAadAdminSid=$ADMIN_USER_ID \
                 zoneRedundant="true"
COSMOSDB_NAME=$(az group deployment show -g $RGNAME -n services --query properties.outputs.cosmosDbName.value -o tsv)
SQL_SERVER=$(az group deployment show -g $RGNAME -n services --query properties.outputs.sqlServerName.value -o tsv)
SQL_DATABASE=$(az group deployment show -g $RGNAME -n services --query properties.outputs.sqlDatabaseName.value -o tsv)
SERVICEBUS_NAME=$(az group deployment show -g $RGNAME -n services --query properties.outputs.serviceBusName.value -o tsv)
KEYVAULT_NAME=$(az group deployment show -g $RGNAME -n services --query properties.outputs.keyVaultName.value -o tsv) 
RESOURCES_STORAGE_ACCOUNT=$(az group deployment show -g $RGNAME -n services --query properties.outputs.resourcesStorageAccountName.value -o tsv)
RESOURCES_CONTAINER_NAME=$(az group deployment show -g $RGNAME -n services --query properties.outputs.resourcesContainerName.value -o tsv)

# Setup the database schema
MY_PUBLIC_IP=$(dig @resolver1.opendns.com ANY myip.opendns.com +short)
az sql server firewall-rule create -g $RGNAME -s $SQL_SERVER -n localip --start-ip-address $MY_PUBLIC_IP --end-ip-address $MY_PUBLIC_IP
sqlcmd -S tcp:${SQL_SERVER}.database.windows.net,1433 -d $SQL_DATABASE -U $SQLADMINUSER -P $SQLADMINPASSWORD -N -l 30 -Q "IF OBJECT_ID('dbo.Counts', 'U') IS NULL CREATE TABLE Counts(ID INT NOT NULL IDENTITY PRIMARY KEY, Candidate VARCHAR(32) NOT NULL, Count INT);"

# Uploads image to the storage account
az storage blob upload -c $RESOURCES_CONTAINER_NAME -f Microsoft_Azure_logo_small.png -n Microsoft_Azure_logo_small.png --account-name $RESOURCES_STORAGE_ACCOUNT 
RESOURCE_URL="$(az storage account show -n $RESOURCES_STORAGE_ACCOUNT --query primaryEndpoints.blob -o tsv)$RESOURCES_CONTAINER_NAME/Microsoft_Azure_logo_small.png"

# 7. deploy the application services inside the ASE - ZONE 1 & 2
az group deployment create --resource-group $RGNAME --template-file templates/sites.json -n sites1 --parameters aseName=$ASE1_NAME \
    vnetName=$VNET_NAME redisSubnetAddressPrefix=$REDIS1_PREFIX serviceBusName=$SERVICEBUS_NAME cosmosDbName=$COSMOSDB_NAME \
    sqlServerName=$SQL_SERVER sqlDatabaseName=$SQL_DATABASE keyVaultName=$KEYVAULT_NAME \
    aseDnsSuffix=$ASE1_DNS_SUFFIX zone=$ZONE1 &
az group deployment create --resource-group $RGNAME --template-file templates/sites.json -n sites2 --parameters aseName=$ASE2_NAME \
    vnetName=$VNET_NAME redisSubnetAddressPrefix=$REDIS2_PREFIX serviceBusName=$SERVICEBUS_NAME cosmosDbName=$COSMOSDB_NAME \
    sqlServerName=$SQL_SERVER sqlDatabaseName=$SQL_DATABASE keyVaultName=$KEYVAULT_NAME \
    aseDnsSuffix=$ASE2_DNS_SUFFIX zone=$ZONE2 &
wait
INTERNAL_APP1_URL1=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.votingAppUrl.value -o tsv) && \
INTERNAL_APP1_URL2=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.votingAppUrl.value -o tsv) && \
INTERNAL_APP2_URL1=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.testAppUrl.value -o tsv) && \
INTERNAL_APP2_URL2=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.testAppUrl.value -o tsv) && \
VOTING_WEB_APP1_PRINCIPAL_ID=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.votingWebAppIdentityPrincipalId.value -o tsv) && \
VOTING_WEB_APP2_PRINCIPAL_ID=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.votingWebAppIdentityPrincipalId.value -o tsv) && \
VOTING_COUNTER_FUNCTION1_NAME=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.votingFunctionName.value -o tsv) && \
VOTING_COUNTER_FUNCTION2_NAME=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.votingFunctionName.value -o tsv) && \
VOTING_COUNTER_FUNCTION1_PRINCIPAL_ID=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.votingCounterFunctionIdentityPrincipalId.value -o tsv) && \
VOTING_COUNTER_FUNCTION2_PRINCIPAL_ID=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.votingCounterFunctionIdentityPrincipalId.value -o tsv) && \
VOTING_API1_NAME=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.votingApiName.value -o tsv) && \
VOTING_API2_NAME=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.votingApiName.value -o tsv) && \
VOTING_API1_PRINCIPAL_ID=$(az group deployment show -g $RGNAME -n sites1 --query properties.outputs.votingApiIdentityPrincipalId.value -o tsv) && \
VOTING_API2_PRINCIPAL_ID=$(az group deployment show -g $RGNAME -n sites2 --query properties.outputs.votingApiIdentityPrincipalId.value -o tsv)

# Deploy RBAC for resources after AAD propagation
until az ad sp show --id ${VOTING_WEB_APP1_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${VOTING_WEB_APP2_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${VOTING_API1_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${VOTING_API2_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${VOTING_COUNTER_FUNCTION1_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
until az ad sp show --id ${VOTING_COUNTER_FUNCTION2_PRINCIPAL_ID} &> /dev/null ; do echo "Waiting for AAD propagation" && sleep 5; done
az group deployment create --resource-group $RGNAME -n rbac1 --template-file templates/rbac.json \
    --parameters votingWebAppIdentityPrincipalId=$VOTING_WEB_APP1_PRINCIPAL_ID votingCounterFunctionIdentityPrincipalId=$VOTING_COUNTER_FUNCTION1_PRINCIPAL_ID \
                 keyVaultName=$KEYVAULT_NAME votingServiceBusNamespace=$SERVICEBUS_NAME &
az group deployment create --resource-group $RGNAME -n rbac2 --template-file templates/rbac.json \
    --parameters votingWebAppIdentityPrincipalId=$VOTING_WEB_APP2_PRINCIPAL_ID votingCounterFunctionIdentityPrincipalId=$VOTING_COUNTER_FUNCTION2_PRINCIPAL_ID \
                 keyVaultName=$KEYVAULT_NAME votingServiceBusNamespace=$SERVICEBUS_NAME &
wait

# Generates parameters file for appgw arm script
cat <<EOF > appgwApps.parameters.json
[
  { 
    "name": "votapp", 
    "hostName": "${APPGW_APP1_URL}", 
    "backendAddresses": [ 
      { 
        "fqdn": "${INTERNAL_APP1_URL1}" 
      },
      { 
        "fqdn": "${INTERNAL_APP1_URL2}" 
      } 
    ], 
    "certificate": { 
      "data": "${CERT_DATA_1}", 
      "password": "${PFX_PASSWORD}" 
    }, 
    "probePath": "/health" 
  },
  { 
    "name": "testapp", 
    "hostName": "${APPGW_APP2_URL}", 
    "backendAddresses": [ 
      { 
        "fqdn": "${INTERNAL_APP2_URL1}" 
      },
      { 
        "fqdn": "${INTERNAL_APP2_URL2}" 
      }      
    ], 
    "certificate": { 
      "data": "${CERT_DATA_2}", 
      "password": "${PFX_PASSWORD}" 
    }, 
    "probePath": "/"
  }
]
EOF

# 8. deploy the application gateway
ZONES=${ZONE1},${ZONE2}
az group deployment create --resource-group $RGNAME --template-file templates/appgw.json --parameters vnetName=$VNET_NAME appgwSubnetAddressPrefix=$APPGW_PREFIX \
    appgwApplications=@appgwApps.parameters.json appgwZones=$ZONES
APPGW_PUBLIC_IP=$(az group deployment show -g $RGNAME -n appgw --query properties.outputs.appGwPublicIpAddress.value -o tsv)

# Removes autogenerated parameter file
rm appgwApps.parameters.json


cat << EOF

NEXT STEPS
---- -----

To finish setting up the managed identities as users in the Sql Database run the following script authenticated as the AAD Admin for the database server

-- script begins
CREATE USER [$VOTING_COUNTER_FUNCTION1_NAME] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$VOTING_COUNTER_FUNCTION1_NAME];
ALTER ROLE db_datawriter ADD MEMBER [$VOTING_COUNTER_FUNCTION1_NAME];

CREATE USER [$VOTING_API_NAME] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$VOTING_API1_NAME];
ALTER ROLE db_datawriter ADD MEMBER [$VOTING_API1_NAME];

CREATE USER [$VOTING_COUNTER_FUNCTION2_NAME] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$VOTING_COUNTER_FUNCTION2_NAME];
ALTER ROLE db_datawriter ADD MEMBER [$VOTING_COUNTER_FUNCTION2_NAME];

CREATE USER [$VOTING_API2_NAME] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$VOTING_API2_NAME];
ALTER ROLE db_datawriter ADD MEMBER [$VOTING_API2_NAME];
-- script ends

1) Please, go to azure portal in the resource group: ${RGNAME} and click on **Azure Cosmos Db Account**
then select **cacheContainer** then click on **Documents**. Click on **New Document**.

Replace the whole json payload with below content and click **Save**

{"id": "1", "Message": "Powered by Azure", "MessageType": "AD", "Url": "${RESOURCE_URL}"}


2) If needed, register domain by adding the following record in local host file
    ${APPGW_PUBLIC_IP} ${APPGW_APP1_URL}
    ${APPGW_PUBLIC_IP} ${APPGW_APP2_URL}


3) RDP to ${JUMPBOX_PUBLIC_IP} and the deploy the testing app using the readme instruction


4) Browse to https://${APPGW_APP1_URL} and https://${APPGW_APP2_URL}

EOF
