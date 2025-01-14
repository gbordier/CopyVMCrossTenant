## this script is run from the users latptop with interactive authentication
## it creates a certificate, an app and uploads the certificate to a keyvault

# steps
## establish delegation on both tenants
# 1. read the azure.json file
# 2. create an app if not found in Cred.appid property
# 3. grant the app owner role to both source and target subscriptions
# 4. create a certificate if not found in Cred.Thumbprint property
# 5. assign the certificate as credential to the app

## persistence for a cloud run 
# 6. create or retrieve a keyvault from the target subscription
# 7. upload the certificate to the keyvault
# 8. create the compute needed to run the script (container instance, automation runbook, etc) in target sub
# 6. assign the certificate user role to the compute managed identity


# 4. create a keyvault if not found in Cred.keyVaultName property
# 5. upload the certificate to the keyvault

# 7. assign the certificate to the app

function retrieveorcreatecertificate {
	param(
		$conf
	)


	if (-not($PSVersionTable.Platform) -or $PSVersionTable.Platform -and $PSVersionTable.Platform -ne "Unix") {
		## tries to load cert from store
		$cert=Get-ChildItem -Path cert:\currentuser\my |?{$_.Thumbprint -eq $conf.cred.thumbprint}
	}
	if (!$cert) {
		foreach ($f in (Get-ChildItem -Path @( $currentpath ,$env:temp) -filter "*.pfx" ))
		{
			$cert=Get-PfxCertificate -FilePath $f.FullName
			if ($cert.Thumbprint -eq $conf.cred.thumbprint) {
				break
			}
			else {
				$cert=$null
			}

		}
	}
	if ($cert)
	{
		## validate expiration
		if ($cert.NotAfter -lt (Get-Date).AddDays(30) ) {
			write-host "certificate is about to expire, creating a new one"
			$cert=$null
		} 
		## validate certificate validity length it not greater than 380 days (per ms policy)
		if (($cert.NotAfter - $cert.NotBefore).TotalDays -gt 380) {
			write-host "certificate is too long, creating a new one"
			$cert=$null
		}

	}
	if (!$cert) {
		Write-Host "creating certificate"
		$cert=New-SelfSignedCertificate  -certstorelocation cert:\currentuser\my -dnsname $conf.cred.certificateName -KeyExportPolicy ExportableEncrypted -KeySpec KeyExchange -NotAfter (Get-Date).AddDays(375) -NotBefore (Get-Date).AddDays(-1) -KeyUsage KeyEncipherment,DigitalSignature -KeyLength 2048
		if (!$cert){
			write-error "failed to create certificate"
			exit
		}
		$conf.Cred.thumbprint = $cert.Thumbprint
		$conf | convertto-json | set-content -path (join-path $rootpath   "azure.json" )
	}
	return $cert	

	
}
## run this from your laptop or gh actoin pipeline

$currentpath = ([System.IO.FileInfo] [string]$script:myinvocation.MyCommand.Definition ).Directory.FullName
$rootpath = Split-Path -Path $currentpath -Parent

$location="northeurope"

## connect go both tenantswith interactive (from windows), create app, certifiate and upload cert


if (-not (test-path -Path (join-path $rootpath   "azure.json" ) )) {
	write-error "no azure.json file found in $rootpath"
	exit
}

$conf= gc -Path (join-path $rootpath   "azure.json" ) | convertfrom-json
if (!$conf.cred) {
	write-error "no cred section found in azure.json"
	exit
}
if (!$conf.Cred.certificateName){
	write-error "no certificateName found in azure.json"
	exit
}



## authenticate using MSI
write-host "connecting to source tenant"
$source=$conf.subs |?{$_.Name -eq "Source"} 
$target=$conf.subs |?{$_.Name -eq "Target"}
Connect-AzAccount -tenantid $source.tenant -subscriptionid $source.sub  -contextname "Source" -Force
if (!Get-AzContext -name "source") {
	write-error "failed to connect to source tenant"
	exit
}
write-host "connecting to target tenant"
Connect-AzAccount -tenantid $target.tenant -subscriptionid $target.sub  -contextname "Target" -Force
if (!Get-AzContext -name "target") {
	write-error "failed to connect to target tenant"
	exit
}

select-azcontext -name Target

write-host "looking for it locally or creating it"	
## select or create pfx
$cert=retrieveorcreatecertificate -conf $conf
$app=Get-AzADApplication -ApplicationId $conf.cred.appid
if (!$app){
	write-host "creating app"
	$app=New-AzADApplication -DisplayName $conf.cred.appid  -CertValue ([System.Convert]::ToBase64String($cert.RawData)) -CertType AsymmetricX509Cert -KeyType AsymmetricX509Cert -KeyUsage Verify -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date).AddYears(1)
	$conf.Cred.appid = $app.ApplicationId
	$conf | convertto-json | set-content -path (join-path $rootpath   "azure.json" )
}

if ($app){
	write-host "!! addding app credential to $($app.id)  :: $($cert.GetType())"
	$appcred=New-AzADAppCredential -ObjectId $app.id -CertValue ([System.Convert]::ToBase64String($cert.RawData)) -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date).AddYears(1)
}
else {
	write-error "failed to create app"
	<# Action when all if and elseif conditions are false #>

}

