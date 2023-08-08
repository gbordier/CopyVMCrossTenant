# Why CopyVMCrossTenant

CopyVMCrossTenant is a script to copy a VM from one Tenant to an other.

Azure subscriptions are part of Azure AD tenants, they can be moved from one tenant to the other, but it is not always possible

- different ownerships
- some resources cannnot move across
- the source subscription might need to remain in-place
- ...

this script will perform the actual copy of the VM including its undering resources providing the VM is not too complex.

# Features list
- Copy VM **across tenant** with same name, vnet name and convert disks to managed disks
- Copy VM inside tenant to another subscription with same name , vnet name 
- Delete/Recreate VM in a **different vnet**  in the same subscription


## Copy VM across tenant

- create dependant Virtual networks with the same address space and subnets
- create Windows or Linux VM  enveloppe at the target preserving the following items
  - network interfaces (static ips are not preserved)
  - VM name
  - Tags

- assign all network interfaces to a single network security group
- create the target storage account if it does not exist yet in the target resource group
- copy blob-based or managed disk based OS and Data drives to the target and *transform* them into Managed Disks using a simple naming such as vmname-OS, vmnamem-data-1 ... for BHD files

``` powershell
.\CopyVMCrossTenant.ps1 -resourcegroupname mytargetrg -vmname myVM 

```


** Public IPs are NOT preserved if needed they could be added later using an auxilairy script **



## Recreate VM in another vnet
``` powershell

.\CopyVMCrossTenant.ps1 -resourcegroupname myrg -vmname myVM -targetvnet vnetxxx  -samesubscription

```

# pre-reqs

you *must* have the required permission on both the source and the target subscriptions, ideally you would use an Azure AD app and a certificate to get access to it , see (<https://learn.microsoft.com/en-us/powershell/azure/authenticate-azureps?view=azps-10.1.0>)

to be able to use both tenant's credentials, we must store the cred as "Azure Context" and give them a name.

the current context for the script will be the target context, the source context must exist and its name be passed to the script.

## connect with admin credentials


``` powershell

Connect-AzAccount -tenantid $sourcetenant -subscriptionid
$sourcesub  -contextname "Source" -Force
Connect-AzAccount -tenantid $targettenant -subscriptionid $targetsub  -contextname "Target" -Force
select-azcontext Target

```
## use an AAD app and certificate to authenticate

if you are using the preferred method of using an AppID and Certificate,
- create an AppID in one tenant, make it Cross tenant
- grant the subscription owner permission to that app
- Create a certificate for the App
- add the Service Principal for this AppID in the other tenant
- grant the service principal in the local tenant with the required permission to create VMs, virtual networks  ...
- connect with certificate using the following

``` powershell

Connect-AzAccount -CertificateThumbprint $thumbprint -ServicePrincipal -tenantid $sourcetenant -subscriptionid
$sourcesub  -contextname "Source" -Force
Connect-AzAccount -CertificateThumbprint $thumbprint -ServicePrincipal -tenantid $targettenant -subscriptionid $targetsub  -contextname "Target" -Force
select-azcontext Target

```
	
#  What could go wrong

## Machine not rebooting correctly
to diagnoze, enable boot diagnostics and review console screen shot

##  0x7B inaccessible boot device

Usually with VMs that have several disks , try removing data disk and rebooti

if that works, check disk signature with diskpart

``` cmd

diskpart list disk (usually 3 disks here with the temp D disk)
sel dis 0 
uniqueid disk
sel dis 2
uniqueid disk
if both are the same , use
uniqueid disk ID=4324234 or to fix disk signature conflict.

``` 
##  Stuck on black screen with blinking cursor

usually, when the HyperV Generation is wrong, you may have created a V1 VM for a V2 source
- delete the VM
- delete the disk 
- run the script again with -Generation2 switch to force Gen2




the HyperV Generation might be wrong
## inbound network connection blocked