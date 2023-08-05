# Why CopyVMCrossTenant

CopyVMCrossTenant is a script to copy a VM from one Tenant to an other.

Azure subscriptions are part of Azure AD tenants, they can be moved from one tenant to the other, but it is not always possible

- different ownerships
- some resources cannnot move across
- the source subscription might need to remain in-place
- ...

this script will perform the actual copy of the VM including its undering resources providing the VM is not too complex.

## feature list

- create dependant Virtual networks with the same address space and subnets
- create Windows or Linux VM  enveloppe at the target preserving the following items
  - network interfaces (static ips are not preserved)
  - VM name
  - Tags

- assign all network interfaces to a single network security group
- create the target storage account if it does not exist yet in the target resource group
- copy blob-based or managed disk based OS and Data drives to the target and *transform* them into Managed Disks using a simple naming such as vmname-OS, vmnamem-data-1 ... for BHD files

**Public IPs are NOT preserved to created at the target**

## pre-reqs

you *must* have the required permission on both the source and the target subscriptions, ideally you would use an Azure AD app and a certificate to get access to it , see (<https://learn.microsoft.com/en-us/powershell/azure/authenticate-azureps?view=azps-10.1.0>)

to be able to use both tenant's credentials, we must store the cred as "Azure Context" and give them a name.

the current context for the script will be the target context, the source context must exist and its name be passed to the script.

``` powershell

Connect-AzAccount -tenantid $sourcetenant -subscriptionid
$sourcesub  -contextname "Source" -Force
Connect-AzAccount -tenantid $targettenant -subscriptionid $targetsub  -contextname "Target" -Force
select-azcontext Target

```

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
	