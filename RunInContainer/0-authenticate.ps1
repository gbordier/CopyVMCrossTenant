
$currentpath = ([System.IO.FileInfo] [string]$script:myinvocation.MyCommand.Definition ).Directory.FullName

## step 1 use Managed Identity to retrieve authentication certificate from keyvault

if (-not (test-path -Path (join-path $currentpath   "azure.json" ) )) {
	write-error "no azure.json file found in $currentpath"
	exit
}

$conf= gc -Path (join-path $currentpath   "azure.json" ) | convertfrom-json

$pfxfile=join-path $($env:temp) "pfx.pfx"


## authenticate using MSI
Connect-AzAccount -Identity

## we need a certificate and not an MSI to connect to other tenants

## get cert first to check thumbprint 
$cert=get-AzKeyVaultCertificate  -VaultName $conf.cred.keyVaultName  -Name $conf.cred.certificateName

## then get pfx 
$pfx=Get-AzKeyVaultSecret -VaultName $conf.cred.keyVaultName  -Name $conf.cred.certificateName -AsPlainText

[SYstem.Convert]::FromBase64String( $pfx)|set-content -AsByteStream -path $pfxfile


## step 2 use retrieved certificate to connect to both tenants (Managed Identity cannot connect across tenants :()

foreach ($env in $conf.subs)
{
	write-host "connecting to env $($env.Name) with tenantid = $($env.tenant)"
	$p=@{"CertificatePath"= $pfxfile ; "ServicePrincipal"=$true ; "ApplicationId"= $conf.cred.appid ;"tenantid"= $env.tenant ; contextname =$env.Name;Force=$true}
	if ($env.sub) {$p["subscriptionid"] = $env.sub}
	$context= Connect-AzAccount @p 
	if ( $env.psobject.Properties |?{$_.Name -eq "context" } ) {
		$conf.subs.$env.context = $context
	}
	else{
		$env | add-member -notepropertyname "context" -notepropertyvalue $context
	}
}


