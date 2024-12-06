## create a container instance with the image and ssh enabled 
## upload the container image into ACR in target tenant
## build the container from ACR

Param($vnetname,$subnetname,$subnetprefix,$containername,$sshpublickey)

##  az container create --name scripts  -g ContainerInstances --image mcr.microsoft.com/powershell --command-line "tail -f /dev/null" 
##
## other option  : create a custom image with the script and module dependancies, add ssh and run it

$currentpath = ([System.IO.FileInfo] [string]$script:myinvocation.MyCommand.Definition ).Directory.FullName
$rootpath = Split-Path -Path $currentpath -Parent
$jsonpath = join-path $rootpath "azure.json"

if (-not (test-path $jsonpath)) {
	write-error "no azure.json file found in $currentpath"
	exit
}

$conf= gc -Path $jsonpath | convertfrom-json

$tmpdir=$env:temp
if (-not $tmpdir) {
    $tmpdir="/tmp"
}
$containerdir=join-path $tmpdir "container"
mkdir $containerdir
pushd $containerdir

Remove-Item * -Recurse
copy $jsonpath  .
mkdir root
mkdir root/.ssh
echo $sshpublickey > root/.ssh/authorized_keys


$dockerfile=@'

FROM mcr.microsoft.com/powershell:latest

COPY . .

RUN apt-get update && apt -y install openssh-server && apt clean

EXPOSE 22
RUN [ "/usr/bin/pwsh","-command","\"install-module az.accounts -force\""]
RUN mkdir /run/sshd

CMD ["/usr/sbin/sshd", "-D"]
'@

Set-Content -Path "Dockerfile" -Value $dockerfile
popd



$rg="aca-runner"
$acr="acarunner"

az acr create --sku basic -g $rg -n $acr
az acr login --name $acr
$acrloginserver=$(az acr show -n $acr --query 'loginServer' -o TSV)

az acr build  $containerdir   -r $acr --image pwsh/pwsh:v1.0.0

#docker tag pwsh $acrloginserver/pwsh:v1.0.0
#docker push $acrloginserver/pwsh:v1.0.0

#create user assigned MI
az identity create --resource-group $rg --name $acr

# Get service principal ID of the user-assigned identity
$spID=$(az identity show --resource-group $rg --name $acr --query principalId --output tsv)
$miID=$(az identity show --resource-group $rg --name $acr --query id --output tsv)

$resourceID=$(az acr show --resource-group $rg --name $acr --query id --output tsv)
az role assignment create --assignee $spID --scope $resourceID --role acrpull
az container create -g $rg --name $acr --image $acr.azurecr.io/pwsh:latest --acr-identity $spID
