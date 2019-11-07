## aquiva-sfdx-buildpack

This is a custom Heroku buildpack for deploying/testing/packaging SFDC code using SFDX. The buildpack uses Heroku environment variables to get data for the build execution. Each build, performed by this buildpack includes 4 stages:

1. SFDX Auth
2. Prepare package info
3. Run Apex tests
4. Create and install package version

### SFDX Auth

First to all the buildpack makes SOAP request to Dev Hub and QA/Staging org (depends on the build type) to get the session ID and instance URL of the org for SFDX auth.

Heroku variables:
```
DEV_HUB_USERNAME
DEV_HUB_TOKEN
DEV_HUB_PASSWORD

SF_ORG_USERNAME
SF_ORG_TOKEN
SF_ORG_PASSWORD
SF_ORG_IS_SANDBOX
```

### Prepare package info

Further buildpack checks if there is an existing package created on the Dev Hub and in the `sfdx-project.json` file. If not - creates the new one. In case of QA build will be created Unlocked package without namespace, for the Staging build the package will be created with provided namespace.

Heroku variables:
```
SFDX_PACKAGE_NAME
PACKAGE_NAMESPACE
STAGE
```
`STAGE = DEV` for QA build and `STAGE = STAGING` for the Staging build.

### Run Apex tests

Then buildpack creates scratch on the provided Dev Hub, pushes all code from the repo to it and running all Apex tests (if they exists).

### Create and install package version

If the tests runned successfully, then starts creation of the new package version and installing it on the corresponding org. If everything done successfully, then the link to the new package version will be shown in the build log on Heroku. In case if package not exists in the Dev Hub, the new package will be created and `sfdx-project.json` file be updated with newly created package name and ID, all other info in project file will be populated from the existing `sfdx-project.json` file.
