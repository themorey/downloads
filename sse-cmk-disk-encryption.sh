#!/bin/bash
set -x
exec 1>/var/log/az-des-cmk.log 2>&1
az login

## Get input and set variables
subscriptionId=$(az account show -o yaml | awk '/^id: /{print $NF}')
read -p 'Existing Resource Group name [testRG]: ' rgName; rgName=${rgName:-testRG}
read -p 'Location [eastus]: ' location; location=${location:-eastus}
read -p 'SSH public key (paste contents): ' sshpubkey; sshpubkey=${sshpubkey:-}
read -p 'KeyVault Name [AzureKeyVault]: ' keyVaultName; keyVaultName=${keyVaultName:-AzureKeyVault}
read -p 'Key Name [diskEncyptionSetKey]: ' keyName; keyName=${keyName:-diskEncyptionSetKey}
read -p 'Disk Encryption Set Name [diskEncyptionSet]: ' diskEncryptionSetName; diskEncryptionSetName=${diskEncryptionSetName:-diskEncyptionSet}
read -p 'Azure Compute Gallery Name [azureComputeGallery]: ' GALLERY_NAME; GALLERY_NAME=${GALLERY_NAME:-azureComputeGallery}


## Create the Key Vault and CMK
az account set --subscription $subscriptionId
az keyvault purge -n $keyVaultName  # Purge any deleted KV with same name
az keyvault create -n $keyVaultName -g $rgName -l $location --enable-purge-protection true --enable-soft-delete true
az keyvault key create --vault-name $keyVaultName -n $keyName --protection software

## Create an instance of a DiskEncryptionSet
keyVaultId=$(az keyvault show --name $keyVaultName --query [id] -o tsv)
keyVaultKeyUrl=$(az keyvault key show --vault-name $keyVaultName --name $keyName --query [key.kid] -o tsv)
az disk-encryption-set create -n $diskEncryptionSetName -l $location -g $rgName --source-vault $keyVaultId --key-url $keyVaultKeyUrl

## Grant the DiskEncryptionSet resource access to the key vault
desIdentity=$(az disk-encryption-set show -n $diskEncryptionSetName -g $rgName --query [identity.principalId] -o tsv)
az keyvault set-policy -n $keyVaultName -g $rgName --object-id $desIdentity --key-permissions wrapkey unwrapkey get
az role assignment create --assignee $desIdentity --role Reader --scope $keyVaultId


#
### Create Azure Compute Gallery
#
az sig create --resource-group $rgName --gallery-name ${GALLERY_NAME}

# Create the Gallery image definition
az sig image-definition create \
   --resource-group $rgName \
   --gallery-name ${GALLERY_NAME} \
   --gallery-image-definition testCmkAdeImage \
   --hyper-v-generation V2 \
   --publisher msgbb \
   --offer CentOS \
   --sku 7_9-gen2 \
   --os-type Linux \
   --os-state generalized


## Create a VM with encrypted OS disk using CMK
vmName=VM-FOR-IMAGE
vmSize=Standard_F8s_v2
image=OpenLogic:CentOS:7_9-gen2:latest

diskEncryptionSetId=$(az disk-encryption-set show -n $diskEncryptionSetName -g $rgName --query [id] -o tsv)
az vm create -g $rgName -n $vmName -l $location --image $image --size $vmSize --generate-ssh-keys --admin-username azureuser --ssh-key-values "$sshpubkey" --os-disk-encryption-set $diskEncryptionSetId --public-ip-address-allocation static --storage-sku Standard_LRS

# Add a 30s wait before trying to SSH into VM
sleep 30

## Capture the VM image with encrypted disk for use with CycleCloud
vmIp=$(az vm list-ip-addresses -g $rgName -n $vmName -o yaml  | grep ipAddress | awk '{print $NF}')
ssh -oStrictHostKeyChecking=no -t azureuser$vmIp "sudo sed -i 's/SELINUX=permissive/SELINUX=enforcing/g' /etc/selinux/config && sudo setenforce 0 && sudo waagent -deprovision+user -force"
az vm deallocate --resource-group $rgName --name $vmName
az vm generalize --resource-group $rgName --name $vmName

#az image create --resource-group $rgName --source $vmName --name encryptedDiskImage
az sig image-version create --resource-group $rgName \
--gallery-name ${GALLERY_NAME} --gallery-image-definition testCmkAdeImage \
--gallery-image-version 1.0.0 \
--managed-image /subscriptions/${subscriptionId}/resourceGroups/$rgName/providers/Microsoft.Compute/virtualMachines/$vmName

echo "Image Resource ID is " $(az image show -g $rgName -n testCmkAdeImage -o yaml | awk '/^id: /{print $NF}')
