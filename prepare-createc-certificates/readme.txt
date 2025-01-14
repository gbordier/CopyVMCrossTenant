## this will be run with admin credentials for both tenants:

## with target tenant admin rights
1) create AAD app in target tenant
2) create certificate and upload to app
3) create keyvault
4) upload cert pfx to azure keyvault
5) create container instance and container managed identity
6) grant keyvault access to container managed identity (secret and certificate operator  at least)

## with source tenant admin rights:
7) grant co-admin priv to app SP in target tenant
8) create Service Principal for app in source tenant 
9) grant co-admin priv to app SP in source tenant

