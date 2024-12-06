## get latest files from from github
$files= "CopyVMCrossTenant.ps1","README.md"
foreach ($file in $files) 
{
    (iwr "https://raw.githubusercontent.com/gbordier/CopyVMCrossTenant/main/$file"  ).content | Set-Content .\$file
    unblock-file $file
}