<#

.SYNOPSIS

CopyVMCrossTenant is a script to copy a VM from one Tenant to an other.

Azure subscriptions are part of Azure AD tenants, they can be moved from one tenant to the other, but it is not always possible
- different ownerships
- some resources cannnot move across 
- the source subscription might need to remain in-place
- ...

.PARAMETER sametenant
switch sametenant means we are going to move or copy the VM to a target resource resource group or vnet

.PARAMETER samesubscription
this will force a move (force sametenant)


.PARAMETER resourcegroupname
source resource group name, a resource group with this name will be used or created at the target

.PARAMETER vmname
name  of the VM to copy over


.PARAMETER location
location to create (defaults to northeurope !!)

.PARAMETER containername 
Azure Storage Container name for target blobs, defaults to "vhds"

.PARAMETER stkname 
optional target  storage account name, defaults to  "(resourcegroupname)vhdsstk" 

.PARAMETER vmsize
optional parameter to set something other than the cheap Standard_DS1_v2 as default VM size

.PARAMETER storagesku
optional parameter to set storage sku to something other than Standard_LRS

.NOTES


 TODO : add blob age verification
 note : to remove a storage account : 
 note : boot diagnistics resquire Standard_GRS storage account, so disabling them
 note : 

 .EXAMPLE

 Connect-AzAccount -tenantid $sourcetenant -subscriptionid $sourcesub  -contextname Source -Force
 Connect-AzAccount -tenantid $targettenant -subscriptionid $targetsub  -contextname Target -Force
 select-azcontext Target

 .\CopVMCrossTenant.ps1 -resourcegroupname myRG -vmname VM1

 delete VM and recreate on alternate  vnet
 .\CopyVMCrossTenant.ps1 -resourcegroupname tredunion -vmname daloradius -targetvnet vnetxxx   -samesubscription



#>
Param( 
    [Parameter(mandatory = $true)]$resourcegroupname,
    [Parameter(mandatory = $true)] [string] $vmname, 
    $sourcecontext = (get-azcontext -name "Source"),
    [ValidateSet("Copy", "MoveToVnet")][string] $action="Copy",
    [string]$location = "northeurope",
    [string]$containername = "vhds",
    [string] $vmsize = "Standard_DS1_v2",
    [string] $storagesku = "Standard_LRS",
    [string] $targetvnet,
    [string] $sourceresourcegroupname,
    [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $vm,
    [string]$stkname,
    [switch] $sametenant,
    [switch] $samesubscription,
    [switch] $deletesourcevm
)

## globals
$currentscript = ([System.IO.FileInfo] [string]$script:myinvocation.MyCommand.Definition )
$currentpath = $currentscript.Directory.FullName

$myscriptshortname = $currentscript.Extension
$LOGFILENAME = join-path $currentpath "$myscriptshortname.log"

#region log Logging Functions
function AddLog( [ValidateSet("STEP", "INFO", "ERROR", "WARNING", "DEBUG")] [string] $type, [string] $text , [object] $status) {
    $line = (Get-Date).ToString("dd/MM/yyyy %H:mm:ss") + "`t" + $type + "`t" + $text
    switch ($type) {
      
        "STEP" { $color = "Green" }
        "WARNING" { $color = "Yellow" }
        "ERROR" { $color = "Red" }
        default { $color = "white" }
    }
    ##_truncateLog -logfile "$LOGFILENAME"
    write-output $line | out-file -append -filepath "$LOGFILENAME"
    if ($type -ne "INFO") { $output = $true }
    if ($type -ieq "debug") { $output = $false }
	
    if (($type -ieq "debug") -and $debug) { $output = $true } 
    if ($output) {	write-host -ForegroundColor $color $line }
    
    if ($script:status -ne $null) {
        $script:status.Text = $line
        $script:statusstrip.Update()
    }
    
    if ($script:txtLog -ne $null) {
        
        #$txtLog.Lines+=$line
        [void] $txtLog.Items.Add($line)
        $txtlog.selectedindex = $txtLog.Items.Count - 1
        [void] $txtlog.Update()
    }
    
}

#endregion
#region ResourceID Azure Resource Manipulation
function get-snapshotnextname ($snapshots, $name) {
    $i = 1
    $n = $name
    while ($snapshots | ? { $_.name -eq $n }) {
        $i++
        $n = "$name-$i"
    }
    return $n
}

function get-parent ([string] $resourceid, $level = 1, [switch] $Leaf) {
    if (!$resourceid) { return }
    for ($i = 0 ; $i -lt $level; $i++) {
        $resourceid = $resourceid.substring(0, $resourceid.LastIndexOf("/")) 
    }
    if ($leaf) {
        $resourceid = $resourceid.substring($resourceid.LastIndexOf("/") + 1)  
    }
    return $resourceid
}

function GetNetInterfaceFromIpConfig ([string] $ipconf) {
    if (!$ipconf) { return }
    $ipconf = get-parent -resourceid $ipconf -level 2
    
    if ($ipconf) {
        return (Get-AzNetworkInterface -ResourceId  $ipconf)
    }
    else {
        return $null
    }
}

#endregion

#region disk Blob, BlobSnapshot , Managed disk and snapshots manipulation
Function CopyDiskFromTenant($sourcediskprofile, $diskname, $resourcegroupname, $stk, $sourcecontext, $vmname, $ostype = "Windows", $stksku = "Standard_LRS") {
    
    ## storage section
    $sourceismanaged = $false
    if ($sourcediskprofile.Vhd) {

    
        write-host "source disk is $($sourcediskprofile.vhd.uri) lookging for vdisk named $diskname"
        $disk = get-azdisk -resourcegroupname $resoucegroupname -name $diskname -ErrorAction SilentlyContinue
        if (!$disk) {
        
            write-host "looking for blob $($sourcediskprofile.Vhd.uri) at target"
            $blob = Get-AzStorageBlob -context $stk.context -container "vhds" -prefix "$($diskname).vhd" | sort lastmodified | select -last 1 | ? { ((get-date) - $_.Lastmodified.localdatetime ).totaldays -lt 10 }
            if (!$blob) {
                write-host "copying  blob $($sourcediskprofile.Vhd.uri) from source"
                $blob = CopyBlobFromTenanttoDest -sourceuri $sourcediskprofile.Vhd.Uri  -sourcecontext $sourcecontext -resourcegroupname $resourcegroupname -targetstk $stk
            }
            if (!$blob -or -not $blob.BlobClient.uri) {
                write-host "could not create or copy blob from source to target "
                $blob
                return
            }


            write-host "target sub blob found at $($blob.BlobClient.uri.AbsolutePath)), creating disk with blob"
            $disk = GetOrCreateDiskFromBlob  -DiskName $diskname -stkname $stk.StorageAccountName -resourcegroupname $resourcegroupname   -vmname $vmname -ostype $ostype -sku $stksku 
            if (!$disk) {
                write-host "could not create disk from blob "
                return
            }
        }
        else { write-host "vdisk $($disk.name) found with resid $($disk.id)" }
    }
    if ($sourcediskprofile.ManagedDisk) {
        $sourceismanaged = $true
    
        $disk = get-azdisk -resourcegroupname $resoucegroupname -name $diskname -ErrorAction SilentlyContinue
        if (!$disk) {
            write-host "looking for recent blob with correct vhd name for $diskname"

            $blob = Get-AzStorageBlob -context $stk.context -container "vhds" -prefix "$($diskname).vhd" -ErrorAction SilentlyContinue | sort lastmodified | select -last 1 | ? { ((get-date) - $_.Lastmodified.localdatetime ).totaldays -lt 10 }
            if ($blob) {
                write-host "found azdisk for $diskname"
            }
            else {
                ## TODO identigy existing blob target to avoid copying twice
                $sourcedisk = $sourcediskprofile.ManagedDisk | Get-AzResource -azcontext $sourcecontext | get-azdisk -AzContext $sourcecontext
                write-host "locating new recent snapshot for $($sourcedisk.name)[$($sourcedisk.id)]  " 
                $sourcesnapshots = Get-AzSnapshot -ResourceGroupName $resourcegroupname -AzContext $sourcecontext 
                $sourcesnapshot = $sourcesnapshots | ? { $_.CreationData.SourceResourceId -eq $sourcedisk.Id } | ? { ((get-date) - $_.TimeCreated ).totaldays -lt 10 } | Sort-Object timecreated  | Select-Object -last 1
                if (!$sourcesnapshot) {
                    write-host "could not find a recent snapshot for $($sourcedisk.name) creating a new one" 
                    $snapshotname = get-snapshotnextname -snapshots $sourcesnapshots -name "$($sourcedisk.name)-snapshot"
                    
                    $snapshotconf = New-AzSnapshotConfig -sourceuri $sourcediskprofile.OsDisk.ManagedDisk.Id  -Location $sourcedisk.Location  -CreateOption copy -azcontext $sourcecontext  -SkuName Standard_LRS
                    $sourcesnapshot = New-AzSnapshot     -Snapshot $snapshotconf -SnapshotName  $snapshotname  -ResourceGroupName $resourceGroupName  -azcontext $sourcecontext
                    if (!$sourcesnapshot ) {
                        write-host "could not create snapshot " 
                        return
                    }
                }
                write-host " found source snapshot $($sourcesnapshot.name) for disk $diskname copying as blob  in target"
                write-host "graning access to source snapshot"
                $sourcesas = Grant-AzSnapshotAccess -SnapshotName $sourcesnapshot.Name -ResourceGroupName $sourcesnapshot.ResourceGroupName -Access "Read"  -DurationInSecond 10000  -AzContext $sourcecontext
    
                #Copy the snapshot to the storage account 
                ## check for destination container 

                $blob = Start-AzStorageBlobCopy -AbsoluteUri $sourcesas.AccessSAS -DestContainer "vhds" -DestContext $stk.context -DestBlob "$diskname.vhd"
                if (!$blob) {
                    write-host "could not copy snapshot to target"
                    return
                }
                
            }
            while (( Get-AzStorageBlobCopyState   -Container vhds -Context $stk.Context -Blob $blob.Name).status -eq "Pending") {
                write-host "blob $($blob.name) copy pending"
                sleep -Seconds 40

            }
            $copystate = (Get-AzStorageBlobCopyState   -Container vhds -Context $stk.Context -Blob $blob.Name).status
            $null = revoke-AzSnapshotAccess -SnapshotName $sourcesnapshot.Name -ResourceGroupName $sourcesnapshot.ResourceGroupName  -AzContext $sourcecontext  -ErrorAction SilentlyContinue
            ## revoking access is necessary to be able to delete the snapshot
            write-host "copy finished, revoking access on source snapshot"

            write-host "copy state for $($blob.name) is $copystate "
            if ($copystate -eq "Success") {
                write-host "successfully copied $($blob.name) $($copystate |out-string )"   
            
            }
            else {
                write-host "copy failed,TODO :  deleting target blob"
                return
            }
            ## handle the managed disk creation from the copy
            $disk = GetOrCreateDiskFromBlob  -DiskName $diskname  -stkname $stk.StorageAccountName -resourcegroupname $resourcegroupname  -vmname $vmname -ostype $ostype -sku $stksku
            if (!$disk) {
                write-host "could not create disk from blob "
                return
            }
            
        
        }
        #If you're creating a Premium SSD v2 or an Ultra Disk, add "-Zone $zone" to the end of the command
    
        #    $diskConfig = New-AzDiskConfig -SkuName "standard_lrs" -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id -DiskSizeGB $diskSize
        #   $disk=New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroupName -DiskName $diskName
    }
    return $disk
}

Function GetOrCreateDiskFromBlob ($diskname, $stkname, $containername = "vhds", $resourcegroupname, $sku = "Standard_LRS", $vmname, $ostype = "windows" ) {

    $stk = Get-AzStorageAccount -name $stkname -ResourceGroupName $resourcegroupname
    $location = $stk.location
    $disk = get-azdisk -resourcegroupname $resoucegroupname -name $diskname
    if (!$disk) {

        write-host "disk $diskname not found, creating it"
        $blobs = Get-AzStorageBlob  -Container $containername -Context $stk.Context  
        $blob = $blobs | ? { $_.Name -ilike "$($diskname)*" } 
        if (!$blob) {
            write-host "could not find blob for the disk name $diskname, looking for one with the vm name $vmname"
            $blob = $blobs | ? { $_.Name -ilike "$($vmname)*" } 
        }
        if ($blob.count -ne 1) {
            write-host "found $($blob.count) blobs, aborting"
            return
        }
        ## |?{$_.Name -ilike "$($vmname)*"} | select -first 1 
        
        $uri = $blob.BlobClient.uri.AbsoluteUri
        write-host "sku $sku name $diskname"
        $diskConfig = New-AzDiskConfig -SkuName $sku -Location $location -DiskSizeGB ($blob.length / 1024 / 1024 / 1024 ) -SourceUri $uri -CreateOption Import  -storageaccountid $stk.id  -OsType $ostype
            
        $disk = New-AzDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $resourceGroupName 
        
    }
    return $disk
}



Function CopyBlobFromTenanttoDest ([Parameter(mandatory = $true)]$sourceuri, [Parameter(mandatory = $true)]$resourcegroupname , [Parameter(mandatory = $true)]$sourcecontext, [switch]$force = $false, [Parameter(mandatory = $true)] $targetstk) {
    $sourcestk = Get-AzStorageAccount -AzContext $sourcecontext | ? { $_.StorageAccountName -eq ($sourceuri.split(".")[0].split("/")[2] ) }
    write-host "source storage account is $($sourcestk.name) source uri is $sourceuri"
    $currentblob = Get-AzStorageBlob -Container vhds -Context $sourcestk.Context | ? { $_.blobclient.uri -eq $sourceuri }

    $stk = $targetstk
    write-host "looking for blob at target to avoid coping twice : prefix is $($currentblob.name)"
    ## TODO add blob age verification
    $targetblob = Get-AzStorageBlob -Container vhds -Context $stk.Context -prefix $currentblob.name | sort lastmodified  | select -last 1
    
    if ($targetblob -and $targetblob.length -and !$force) {
        write-host "target blob $($targetblob.name) dated $($targetblob.LastModified) already preset and -force not used, skiping blob copy"
        return $targetblob
    }

    ## create blob  snapshot for source blob
    $snap = $currentblob.BlobBaseClient.CreateSnapshot()
    #retrieve last instanciation
    $blob = Get-AzStorageBlob -Container vhds -Context $sourcestk.Context -prefix $currentblob.name | sort lastmodified  | select -last 1
    write-host "blob $($blob.name)  last snapshot is [$($blob.blobclient.uri.AbsoluteUri)] "
    ## generate sas key for 10 hours
    $sassource = $blob.BlobClient.GenerateSasUri("All", (get-date).AddHours(10) )


    $container = get-azstoragecontainer -container vhds -context $stk.context
    $sastarget = $container.BlobContainerClient.GetBlobClient($blob.Name).generatesasuri("all", (get-date).AddHours(10))
    ## source testing SAS keys

    $sourcecontainersas = $container.BlobContainerClient.GenerateSasUri(-1, (get-date).AddHours(10) )
    ## testing SAS access to the source blob container 
    $cc = new-object Azure.Storage.Blobs.BlobContainerClient($sourcecontainersas)
    try {
        $testblobs = $cc.GetBlobs()
    }
    catch {
        write-host "$error[0] | out-string"
        write-host "failed using GenerateSas try using aad (you may need to use azcopy login on the source tenant first"
    }

    if (!$testblobs) {
        ## removing sas key from source url
        write-host "trying to use source blob without sas key"
        $sassource = $blob.BlobClient.uri.AbsoluteUri
    }

    if ($sassource -and $sastarget) {
        Write-Host "copiny blob from source to target"
        write-host "source" $sassource
        write-host "target" $sastarget
        
        $blobcopy = Start-AzStorageBlobCopy -AbsoluteUri $sassource -DestContainer $container.Name  -DestContext $stk.context -DestBlob "$($blob.name)"
        #& .\azcopy.exe copy "$sassource" "$sastarget" --s2s-preserve-access-tier=false
        while (( Get-AzStorageBlobCopyState   -Container $container.Name -Context $stk.Context -Blob $blob.Name).status -eq "Pending") {
            write-host "blob copy pending $($blobcopy.name)"
            sleep -Seconds 80

        }
    }
    else {
        write-host "missing sas source or target"
        exit
    }

    $blobtarget = Get-AzStorageBlob -Container "vhds" -Context $stk.Context -prefix $blob.name | sort lastmodified | select -last 1
    write-host " blob copied with $($blobtarget.name) " #[$($blobtarget|out-string)]" 
    return $blobtarget
}
#endregion

#region network
function Resolve-VMNetworkconfig ($vm, $AzContext)
{
    ## store source nics and vnet config
if (!$AzContext) {$AzContext = get-azcontext }

$nics = @()
$vm.NetworkProfile.NetworkInterfaces | % {
    $nic = $_ | Get-AzResource -AzContext $AzContext | Get-AzNetworkInterface -AzContext $AzContext
    $ipconfs = @()
    $nic | Get-AzNetworkInterfaceIpConfig  -AzContext $AzContext | % {
        $subnet=$_.Subnet| get-azresource -AzContext $AzContext  | Get-AzVirtualNetworkSubnetConfig -AzContext $AzContext
        $_.subnet=$subnet
        $ipconfs += $_
    }
    $nic | Add-Member -MemberType NoteProperty -Name "ipconfigs" -Value $ipconfs
    $nics += $nic
}

$vnet= get-azresource -AzContext $AzContext -ResourceId( get-parent $nics[0].ipconfigs[0].subnet.Id -level 2 ) | Get-AzVirtualNetwork -AzContext $AzContext

$vm | add-member -MemberType NoteProperty -name "vnet" -value $vnet

$vm | Add-Member -MemberType NoteProperty -Name "nics" -Value $nics

return $vm 
}
#endregion

###
### MAIN
###

## Mode X Tenant Copy or X Subscription: X Tenant copy targetresoucegroup 
## Mode Intra Subscription Copy : need to rename resources unless different region is used? ???
## Mode intre subscription X Vnet  Move : need to destroy VM and NIcs; recreate at target with same os disks
## validate inputs

if (!$sourceresourcegroupname) {
    $sourceresourcegroupname = $resourcegroupname
}
if ($samesubscription){$sametenant=$true}

if ($sametenant ) {
    
    if ($samesubscription) {
        write-host "sametenant and  copying VM to same  subscription or or recreating VM with "
        $sourcecontext = get-azcontext
    }
    
}
$targetcontext = get-azcontext
if (!$sourcecontext) {
    write-host "source context was not found, please use new-azcontext to create a source autgentication context for the source azure tenant "
    return
}


    
if (!$sametenant -and  $targetcontext.subscription.id -eq $sourcecontext.subscription.id) {
    write-host "source and target conext are the same, stopping here"
    write-host " you should use something like `nConnect-AzAccount -tenantid $sourcetenant -subscriptionid $sourcesub  -contextname Source -Force
    `nConnect-AzAccount -tenantid $targettenant -subscriptionid $targetsub  -contextname Target -Force
    `nselect-azcontext Target`n to connect to required contexts"
    
    return
}

AddLog -type STEP -text "Checking target resource group $resourcegroupname"
##  STEP : create target resource group if nonexisting
$rg = get-azresourcegroup -ResourceGroupName $resourcegroupname -ErrorAction SilentlyContinue

if (!$rg) {
    $rg = new-azresourcegroup -name $ResourceGroupName -location $location    
}
$location = $rg.location

AddLog -type STEP -text "Selecting  target storage acconut in  $resourcegroupname"
## pick first storage account in target RG
if ($stkname) {
    $stk = Get-AzStorageAccount -name $stkname -ResourceGroupName $resourcegroupname
}
else {
    $stk = Get-AzStorageAccount -ResourceGroupName $resourcegroupname | select -first 1
}

if (!$stk) {
    write-host "could not find a storage account in target RG $resourcegroupname"
    write-host "creating new one"
    $stk = New-AzStorageAccount -ResourceGroupName $resourcegroupname -Name "$($resourcegroupname)vhdsstk" -SkuName $storagesku -Location $location -AllowBlobPublicAccess $false
     
}
if (!$stk) {
    write-host "could not find a storage account in target RG $resourcegroupname"
    return
}

write-host "reading data from source VM $vmname in $($sourcecontext.name)"
if ($vm) { $svm = $vm }
else {
    $svm = get-azvm -azcontext $sourcecontext -name $vmname -resourcegroupname $sourceresourcegroupname
}



if (!$svm -and !$sametenant -and !$samesubscription) {
    write-host "source vm not found, abort"

    return
}




if (!$svm -and $sametenant -and $samesubscription  ) {
    write-host "trying to use backup of source vm configuration assuming disks have not been deleted"
    $svm = import-clixml (join-path $currentpath "$vmName.xml")
}
else {
    $svm=Resolve-VMNetworkconfig -vm $svm -AzContext $sourcecontext

    if ($sametenant -and $samesubscription -and $deletesourcevm ) {
        write-host "saving VM definition before deleting it"
        $svm | Export-Clixml (join-path $currentpath "$($svm.Name).xml") -Depth 99
        $svm | remove-azvm
        
        

        $svnetid = get-parent $svm.nics[0].ipconfs[0].subnet.id -level 2 -Leaf

        Add-Log -type STEP -text "Remove network interfaces bound to source vnet $vnetid"
        $svm.NetworkProfile.NetworkInterfaces | get-azresource | Remove-AzNetworkInterface -Force


    }
}
if(!$svm)
{
    addlog -type ERROR "could not find source vm in xml or source tenant, aborting"
    return
}

$ostype = $svm.StorageProfile.OsDisk.OsType
$vm = get-azvm -name $vmname -resourcegroupname $resourcegroupname -ErrorAction SilentlyContinue
if ($vm) {
    write-host "vm $vmname already found at target resouce group $resourcegroupname"
    return
}

$dcip = $null
$addomain = $null
if ($svm.Tags.AdRole -and $svm.Tags.AdDomain) {
    $addomain = $svm.Tags["AdDomain"]
    $adrole = $svm.Tags["AdRole"]
    
}

$tagsdict = @{}
write-host "looking for domain controller on $resourcegroupname "
get-azvm  -ResourceGroupName $resourcegroupname   | % { 
    $v = $_
    $tagsdict[$_.Name] = $v.tags
    if ($adrole -ne "DC") {}
    if ($v.Tags -and $v.Tags.ContainsKey("AdRole") -and $v.Tags.adRole -eq "DC" -and $v.Tags.ContainsKey("AdDomain") -and $v.Tags["AdDomain"] -eq $addomain) {
        $dcip = $v.NetworkProfile.NetworkInterfaces | ? { $_.Primary } | Get-AzResource | Get-AzNetworkInterface | Get-AzNetworkInterfaceIpConfig  | select -ExpandProperty  PrivateIpAddress
        write-host "this VM $($v.name) is a DC, we will use its IP $dcip to set dns server to $($svm.name)"
    }
}

write-host ($svm | out-string)


## checking vhds container 
if ( !( Get-AzStorageContainer -Context $stk.context -Name "vhds" -ErrorAction SilentlyContinue )) {
    New-AzStorageContainer -Context $stk.context -name "vhds" 
}

## storage section
$sourceismanaged = $false

$diskname = "$($vmname)-os"

write-host "attempt creating OS disk "
$osdisk = CopyDiskFromTenant -sourcediskprofile $svm.StorageProfile.OsDisk -diskname $diskname -resourcegroupname $resourcegroupname -stk  $stk -sourcecontext $sourcecontext -vmname $vmname -ostype $ostype -stksku $storagesku -location $svm.location
if (!$osdisk ) {
    write-host "could not create OS  disk at $resourcegroupname in storage account $($stk.name) "
    return
}
if ($svm.StorageProfile.DataDisks) {
    $datadisks = @()
    $i = 1
    foreach ($datadisk in $svm.StorageProfile.DataDisks) {
        $diskname = "$($vmname)-data-$i"
        $disk = CopyDiskFromTenant -sourcediskprofile $datadisk -diskname $diskname -resourcegroupname $resourcegroupname -stk $stk -sourcecontext $sourcecontext -vmname $vmname -ostype $ostype -stksku $storagesku -location $svm.location
        if (!$disk) {
            write-host "could not create data disk $i   disk at $resourcegroupname in storage account $($stk.name) "
            return
        }

        $datadisks += $disk

        
        $i++
    }
}
    

## create sntopshot from source and copy to target vhd
## if more than 1 vnet in source sub , create all vnets

## network secstion

if (!$targetvnet) {
    $sourcevnets = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -azcontext $sourcecontext


    if ($sourcevnets.count -gt 1 ) {
        $hassereralvnets = $true
        foreach ($v in $sourcevnets ) {
            if (!(get-AzVirtualNetwork -Name $v.Name -ResourceGroupName $v.ResourceGroupName -ErrorAction SilentlyContinue )) {
                write-host "found serveral vnets, recreating vnets $($v.name) at target"
                #            write-host "$($v|out-string)  subnets $($v.subnets | out-string) $($v.ResourceGroupName)  pref :$($v.AddressSpace.AddressPrefixes|out-string) locatoin : $($rg.location)"
                $subnets = $v.Subnets  | % { New-AzVirtualNetworkSubnetConfig -Name $_.name -AddressPrefix $_.AddressPrefix }
                New-AzVirtualNetwork -Name $v.Name -ResourceGroupName $v.ResourceGroupName -AddressPrefix $v.AddressSpace.AddressPrefixes -Subnet $subnets -Location $rg.Location
            }
        }
    }
    else {
    
        $vnetname = "$($resourceGroupName)-vnet"
        write-host "only one vnet at source , creating a default one at target with name $vnetname if it does not exist"
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -name $vnetname -ErrorAction SilentlyContinue
        if (!$vnet) {
            ## create subnet looking like source vnet, do not create peerings
            write-host "looking for vnet in source context"
            $svnet = get-azvirtualnetwork -ResourceGroupName $resourceGroupName -azcontext $sourcecontext

            #	$subnet=New-AzVirtualNetworkSubnetConfig -name "main" -addressprefix $svnet.AddressSpace.addressprefixes[0]
            $vnet = new-azvirtualnetwork -ResourceGroupName $resourceGroupName -name $vnetname -location $location -addressprefix $svnet.AddressSpace.addressprefixes -subnet $svnet.subnets

        }

    }
}
else {
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $resourcegroupname -name  $targetvnet -ErrorAction SilentlyContinue
    if (!$vnet) {

        #	$subnet=New-AzVirtualNetworkSubnetConfig -name "main" -addressprefix $svnet.AddressSpace.addressprefixes[0]
        $vnet = new-azvirtualnetwork -ResourceGroupName $resourceGroupName -name $targetvnet -location $location -addressprefix $svm.vnet.AddressSpace.addressprefixes -subnet $svm.vnet.subnets

    }
}

$vnet = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName | select -first 1
if ($osdisk -and $vnet ) {
    
    write-host "creating vm $vmname on vnet $($vnet.name) with disk name $($osdisk.name)"
    
    $vm = New-AzVMConfig -VMName $vmname -VMSize $vmsize

    ## 
    if ($svm.NetworkProfile.NetworkInterfaces ) {
        $i = 0
        foreach ($snic in $svm.nics) {
            $i++
            $nic = Get-AzNetworkInterface -Name "$vmname-nic$i"   -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    
            if (!$nic) {
                $sourceipconfig = $snic.ipconfigs
                
                $sourcesubnet =  $sourceipconfig[0].Subnet  
                if (!$targetvnet){
                    $vnetname = get-parent -resourceid $sourceipconfig.Subnet.id   -level 2   -Leaf
                }
                else {
                    $vnetname = $targetvnet
                }

                ## first look for exact match 
                $vnet = Get-AzVirtualNetwork -Name $vnetname -ErrorAction SilentlyContinue
                if (!$vnet ) { 
                    write-host "could not find exact match for $vnetname, looking for vnet name with name similar to resource groupe $resourcegroupname"
                    $vnet = Get-AzVirtualNetwork -ResourceGroupName $resourcegroupname | ? { $_.Name -ilike "$($vnetname)*" }
                }
                if (!$vnet ) {
                    write-host "could not find vnet with name $vnetname or similar $resourcegroupname"
                    return
                }
                ## look for source  subnet  in target
                $subnet = $vnet.Subnets |?{$_.name -eq $sourcesubnet.name}
                if (!$subnet ){
                    $subnet = $vnet.Subnets[0]
                }
                write-host "creating nic with id $vmname-nic$i in vnet $($vnet.name) on subnet $($sourcesubnet.name) "
                $nic = New-AzNetworkInterface -Force -Name "$vmname-nic$i"   -ResourceGroupName $ResourceGroupName -Location $location -SubnetId $subnet.id
            }
            $nicId = $nic.Id;
            
            $vm = Add-AzVMNetworkInterface -VM $vm -Id $nicId;
            if ($i -eq 1 ) {
                $vm.NetworkProfile.NetworkInterfaces[0].Primary = $true
            }
        }
    }

    $nic = Get-AzNetworkInterface -Name "$vmname-nic1"  -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
##    $nic.Primary = $true
    if ($dcip) {
        $nic.DnsSettings.DnsServers = @($dcip)
        $nic = $nic | Set-AzNetworkInterface
    }


    
    switch ([string]$svm.StorageProfile.osdisk.ostype ) {
        "Windows" {
            write-host "setting os disk as windows"
            $vm = Set-AzVMOSDisk -VM $vm  -ManagedDiskId $osdisk.id -CreateOption Attach  -windows
        }
        "Linux" {
            write-host "setting os disk as linux"
            $vm = Set-AzVMOSDisk -VM $vm  -ManagedDiskId $osdisk.id -CreateOption Attach  -Linux
        }
        default {
            write-host "unknown OS type, aborting"
            return
        }
    }
    $i = 1
    foreach ($datadisk in $datadisks) {
        $vm = Add-AzVMDataDisk -VM $vm -Name $datadisk.name -Caching 'ReadOnly'  -ManagedDiskId $datadisk.id -CreateOption Attach  -Lun $i
        $i++

    }
    $vm = Set-AzVMBootDiagnostic -Disable -VM $vm
    $vm.Tags = $tagsdict[$vmname] 

    ## write-host " net : $($vm.NetworkProfile.NetworkInterfaces| out-string)  "
    if ($svc.StorageProfile.osdisk.ostype -eq "Linux") {
        $vm = Set-AzVMOperatingSystem -Linux -VM $vm 
    }
    new-azvm -vm $vm  -ResourceGroupName $resourceGroupName -location $location 
    
    
    $vm
}