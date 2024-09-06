/*region Header
      =========================================================================================================
      Created by:       Author: Your Name | your.name@azurestream.io 
      Description:      AI Services in-a-box - Doc Intelligence in-a-box
      =========================================================================================================

      Dependencies:
        Install Azure CLI
        https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest 

        Install Latest version of Bicep
        https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/install
      
        To Run:
        az login
        az account set --subscription <subscription id>
        az group create --name <your resource group name> --location <your resource group location>
        az ad user show --id 'your email' --query id

        Copy above output to main.bicepparam; also add your resource group name and location to main.bicepparam and save

        az bicep build --file main.bicep
        az deployment group create --resource-group <your resource group name>  --template-file main.bicep --parameters main.bicepparam --name Doc-intelligence-in-a-Box --query 'properties.outputs' 

        After deployment, deploy code to function app (the name should be yourprefix-funcapp):
        func azure functionapp publish <your funcapp name> --python

      SCRIPT STEPS 
      1 - Create UAMI
      2 - Create Key Vault
      3 - Create Storage Account
      4 - Create CosmosDB
      5-  Create Form Recognizer
      6 - Assign Blob Contributor Role to UAMI
      7 - Assign Blob Contributor Role to Form Recognizer
      8 - Create Function App
      9 - Create KV Access Policies for Function App
      10- Create APIs to ADLS and CosmosDB
      11- Create form processing logic app that uses azure functions app's host key
      //=====================================================================================

*/

//********************************************************
// Global Parameters
//********************************************************
targetScope = 'subscription'

@description('Create or select an Azure resource group.')
param resourceGroupName string
@description('Select the Azure region for the resources to be deployed.')
param resourceLocation string
@description('The prefix for the resources that will be created')
param prefix string
@description('The suffix for the resources that will be created')
param uniqueSuffix string
@description('Your Object ID')
param spObjectId string = ''//This is your own users Object ID
@description('The name of the environment')
param environmentName string
param tags object = {}


var vprefix = toLower('${prefix}')
var vsuffix = toLower('${uniqueSuffix}')

//UAMI Module Parameters
var deploymentScriptUAMIName = '${vprefix}-uami'

//Key Vault Module Parameters
var keyVaultName = '${vprefix}-kv-${vsuffix}'
var kvKeyPermissions = [
  'all'
  'create'
  'delete'
  'get'
  'update'
  'list'
  'purge'
]

var kvSecretPermissions = [
  'all'
  'set'
  'get'
  'delete'
  'purge'
]


//Storage Account Module Parameters - ADLS
var storageAccountName =  '${replace(vprefix,'-','0')}0storage0${replace(vsuffix,'-','0')}'

//CosmosDB Module Parameters
var cosmosAccountName = '${vprefix}-cosmos-${vsuffix}'
var cosmosDbName = 'form-db' // preset for solution
var cosmosDbContainerName = 'form-docs' // preset for solution

//Doc Intelligence Module Parameters
var documentIntelligenceAccountName = '${vprefix}-fr-${vsuffix}'

//Function App Module Parameters
var funcAppName = '${vprefix}-funcapp'
var funAppStorageName = '${vprefix}funcapp${vsuffix}'

//Logic App Module Parameters
var logicAppFormProcName = '${vprefix}-logicapp-${vsuffix}'
var apiCnxADLSName = '${vprefix}-ApiCnxADLS'
var apiCnxCosmosDBName = '${vprefix}-ApiCnxCosmosDB'

//====================================================================================
// Existing Resource Group 
//====================================================================================
resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${vprefix}-rg-${vsuffix}'
  location: resourceLocation
}

//1. Deploy UAMI
module m_uaManagedIdentity 'modules/uami.bicep' = {
  name: 'deploy_UAMI'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    deploymentScriptUAMIName: deploymentScriptUAMIName
  }
}

//2. Deploy Required Key Vault and UAMI
module m_keyvault 'modules/keyvault.bicep' = {
  name: 'deploy_keyvault'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    keyVaultName: keyVaultName
    principalId: m_uaManagedIdentity.outputs.uamiPrincipleId

    //Send in Service Principal and/or User Oject ID
    spObjectId: spObjectId

    kvSecretPermissions: kvSecretPermissions
    kvKeyPermissions: kvKeyPermissions
  }
}

//3. Deploy Storage Account
module m_datalake 'modules/datalake.bicep' = {
  name: 'deploy_datalake'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    storageAccountName: storageAccountName
    storageAccountType: 'Standard_LRS'
    containerList: [
      'files-1-input'
      'files-2-split'
      'files-3-recognized'
      'samples'
    ]
    keyVaultName: keyVaultName
    uami: m_uaManagedIdentity.outputs.uamiId
  }
  dependsOn: [
    m_keyvault
  ]
}

//4. Deploy CosmosDB
module m_cosmosdb 'modules/cosmosdb.bicep' = {
  name: 'deploy_cosmosdb'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    keyVaultName: keyVaultName
    cosmosAccountName: cosmosAccountName
    cosmosDbName: cosmosDbName
    cosmosDbContainerName: cosmosDbContainerName
  }
  dependsOn: [
    m_keyvault
  ]
}

//5. Create Form Recognizer (Document Intelligence)
module m_docintelligence 'modules/documentIntelligence.bicep' = {
  name: 'deploy_docintelligence'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    documentIntelligenceAccountName: documentIntelligenceAccountName
    keyVaultName: keyVaultName
  }
  dependsOn: [
    m_keyvault
  ]
}

//6. Assign Blob Contributor Role to UAMI
module m_assignBlobContributorRoleToUAMI 'modules/assign-blobcontributor.bicep' = {
  name: 'deploy_assignBlobContributorRoleToUAMI'
  scope: resourceGroup
  params: {
    storageAccountName: storageAccountName
    principalId: m_uaManagedIdentity.outputs.uamiPrincipleId
    principalType: 'ServicePrincipal'
  }
}

//7. Assign Blob Contributor Role to Form Recognizer
module m_assignBlobContributorRoleToFR 'modules/assign-blobcontributor.bicep' = {
  name: 'deploy_assignBlobContributorRoleToFR'
  scope: resourceGroup
  params: {
    storageAccountName: storageAccountName
    principalId: m_docintelligence.outputs.documentIntelligencePrincipalId
    principalType: 'ServicePrincipal'
  }
}

//8. Create Function App
module m_functionApp 'modules/functionapp.bicep' = {
  name: 'deploy_functionapp'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    funcAppName: funcAppName
    funAppStorageName: funAppStorageName
    uamiId: m_uaManagedIdentity.outputs.uamiId
    uamiClientId: m_uaManagedIdentity.outputs.uamiClientid
    keyVaultName: keyVaultName
    tags: tags
    serviceName: 'processforms'
  }
  dependsOn: [
    m_uaManagedIdentity
    m_keyvault
  ]
}

//9. Create KV Access Policies for Function App
module m_keyVaultPolicy 'modules/keyvaultpolicy.bicep' = {
  scope: resourceGroup
  name: 'deploy_kv_accessPolicies'
  params: {
    keyVaultResourceName: keyVaultName
    principalId: m_functionApp.outputs.principalId
  }
  dependsOn: [
    m_functionApp
  ]
}

//====================================================================================
// Reusing Resources already created
//====================================================================================

resource keyvaultRef 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: m_keyvault.outputs.keyVaultName
  scope: resourceGroup
}

resource uaManagedIdentityRef 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: m_uaManagedIdentity.outputs.uamiName
  scope: resourceGroup
}

//====================================================================================
// Create Logic Apps with working API connections 
//====================================================================================
// Resources Created: 
//      API Connection to Azure Data Lake 
//      API Connection to Azure Cosmos DB 
//      Azure Logic App - Form Processing 
//=====================================================================================

//10. Create APIs to ADLS and CosmosDB 
module m_apiAdls 'modules/api-adls.bicep' = {
  name: 'deploy_apiCnxAdls'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    connectionName: apiCnxADLSName
    storageAccountName: storageAccountName
    paramAdlsPrimaryKey: keyvaultRef.getSecret('AdlsPrimaryKey')
  }
  dependsOn: [
    m_keyvault
    m_datalake
  ]
}

module m_apiCosmosDb 'modules/api-cosmosdb.bicep' = {
  name: 'deploy_apiCnxCosmosDB'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    connectionName: apiCnxCosmosDBName
    cosmosAccountName: cosmosAccountName
    paramCosmosAccountKey: keyvaultRef.getSecret('CosmosDbPrimaryKey')
  }
  dependsOn: [
    m_keyvault
    m_cosmosdb
  ]
}

//*************************************************************************************
// Create form processing logic app that uses azure functions app's host key
//*************************************************************************************
//11. Create form processing logic app that uses azure functions app's host key
module m_logicAppFormProc 'modules/logicapp-formproc-hostkey.bicep' = {
  name: 'deploy_logicAppFormProc'
  scope: resourceGroup
  params: {
    resourceLocation: resourceLocation
    logicAppFormProcName: logicAppFormProcName
    azureFunctionsAppName: funcAppName
    uamiId: uaManagedIdentityRef.id
    storageAccountName: storageAccountName
    adlsCnxId: m_apiAdls.outputs.adlsConnectionId
    adlsCnxName: apiCnxADLSName
    cosmosDbCnxId: m_apiCosmosDb.outputs.cosmosDbConnectionId
    cosmosDbCnxName: apiCnxCosmosDBName
    keyVaultName:m_keyvault.outputs.keyVaultName
    
  }
  dependsOn: [
    m_keyvault
    m_apiAdls
    m_apiCosmosDb
    m_functionApp
    m_uaManagedIdentity
    m_cosmosdb
    m_datalake
  ]
}
