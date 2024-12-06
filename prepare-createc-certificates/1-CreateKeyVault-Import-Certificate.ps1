## this call into 0-prepare-xtenants-creds.ps1 will create a certificate and app registration and upload the certificate in an azure keyvault

$currentpath = ([System.IO.FileInfo] [string]$script:myinvocation.MyCommand.Definition ).Directory.FullName
$rootpath = Split-Path -Path $currentpath -Parent

$conf= gc -Path (join-path $rootpath   "azure.json" ) | convertfrom-json

"keyVaultName" ,    "keyVaultResourceGroupName",    "keyVaultSecretName" |% {
    if (!$conf.Cred.$_) {write-error "$_ not found in azure.json";exit}
}




## make sure cert and app are ready
$cert = & (join-path $currentpath,"0-prepare-xtenants-creds.ps1")
if (!$cert) {
    write-error "failed to create certificate"
    exit
}


Select-AzContext "Target"

## create keyvault and upload certificate to vault
$kv=Get-AzKeyVault -VaultName $conf.cred.keyVaultName -ResourceGroupName $conf.cred.keyVaultResourceGroupName -ErrorAction SilentlyContinue
if (!$kv){
	write-host "creating keyvault"
	$kv=New-AzKeyVault -VaultName $conf.cred.keyVaultName -ResourceGroupName $conf.cred.keyVaultResourceGroupName -Location $location
	## self assign certificate officer role

}
else {
	write-host "keyvault already exists"
}

## self assign certificate officer role
if (!(get-azroleassignment -RoleDefinitionName "Key Vault Certificates Officer" -scope $kv.ResourceId -PrincipalId (Get-AzADUser -SignedIn).id )) {
	new-azroleassignment -RoleDefinitionName "Key Vault Certificates Officer" -PrincipalId (Get-AzADUser -SignedIn).id  -scope $kv.ResourceId
}




$existingcert=Get-AzKeyVaultCertificate -VaultName $conf.cred.keyVaultName -Name $conf.cred.certificateName -ErrorAction SilentlyContinue



if (!$existingcert){

	if (!$cert) {
		write-error "failed to create certificate"
		exit
	}

	write-host "uploading certificate to keyvault"
		Import-AzKeyVaultCertificate -VaultName $kv.vaultname -Name $keyVaultSecretName-CertificateString ([System.Convert]::ToBase64String($cert.RawData))
}
else {
	write-host "certificate already exists in keyvault"
}


