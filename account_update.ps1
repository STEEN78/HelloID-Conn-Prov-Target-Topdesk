#####################################################
# HelloID-Conn-Prov-Target-Topdesk-Update
#
# Version: 2.0
#####################################################

# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$mRef = $managerAccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Set debug logging
switch ($($config.IsDebug)) {
    $true  { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region mapping
# Last name generation based on name convention code
#  B  "<birth name prefix> <birth name>"
#  P  "<partner name prefix> <partner name>"
#  BP "<birth name prefix> <birth name> - <partner name prefix> <partner name>"
#  PB "<partner name prefix> <partner name> - <birth name prefix> <birth name>"
function New-TopdeskName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object]
        $Person
    )

    if([string]::IsNullOrEmpty($person.Name.Initials)) {
        $initials = $person.Name.Initials
    } else {
        $initials = $person.Name.Initials[0..9] -join ""        # Max 10 chars
    }

    if([string]::IsNullOrEmpty($Person.Name.FamilyNamePrefix)) {
        $prefix = ""
    } else {
        $prefix = $Person.Name.FamilyNamePrefix + " "
    }

    if([string]::IsNullOrEmpty($Person.Name.FamilyNamePartnerPrefix)) {
        $partnerPrefix = ""
    } else {
        $partnerPrefix = $Person.Name.FamilyNamePartnerPrefix + " "
    }

    $TopdeskSurname = switch($Person.Name.Convention) {
                    "B"  { $Person.Name.FamilyName }
                    "BP" { $Person.Name.FamilyName + " - " + $partnerprefix + $Person.Name.FamilyNamePartner }
                    "P"  { $Person.Name.FamilyNamePartner }
                    "PB" { $Person.Name.FamilyNamePartner + " - " + $prefix + $Person.Name.FamilyName }
                    default { $prefix + $Person.Name.FamilyName }
    }

    $TopdeskPrefix = switch($Person.Name.Convention) {
                    "B"  { $prefix }
                    "BP" { $prefix }
                    "P"  { $partnerPrefix }
                    "PB" { $partnerPrefix }
                    default { $prefix }
    }

    $output = [PSCustomObject]@{
        prefixes    = $TopdeskPrefix
        surname     = $TopdeskSurname
        initials    = $Initials
    }
    Write-Output $output
}

function New-TopdeskGender {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object]
        $Person
    )

    $gender = switch($Person.details.Gender) {
        "M" { "MALE" }
        "V" { "FEMALE" }
        default { 'UNDEFINED' }
    }

    Write-Output $gender
}

function Get-RandomCharacters($length, $characters) {
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length }
    $private:ofs=""
    return [String]$characters[$random]
}


# Account mapping. See for all possible options the Topdesk 'supporting files' API documentation at
# https://developers.topdesk.com/explorer/?page=supporting-files#/Persons/createPerson
$account = [PSCustomObject]@{
    surName             = (New-TopdeskName -Person $p).surname # Generate surname according to the naming convention code.
    prefixes            = (New-TopdeskName -Person $p).prefixes
    firstName           = $p.Name.NickName
    firstInitials       = (New-TopdeskName -Person $p).initials # Generate initials max 10 char
    gender              = New-TopdeskGender -Person $p
    #email               = $p.Accounts.MicrosoftActiveDirectory.mail
    employeeNumber      = $p.ExternalId
    #networkLoginName    = $p.Accounts.MicrosoftActiveDirectory.UserPrincipalName
    #tasLoginName        = $p.Accounts.MicrosoftActiveDirectory.UserPrincipalName # When setting a username, a (dummy) password will need to be set.
    #password            = (Get-RandomCharacters -length 10 -characters 'ABCDEFGHKLMNOPRSTUVWXYZ1234567890')
    jobTitle            = $p.PrimaryContract.Title.Name
    branch              = @{ lookupValue = $p.Location.Name }
    department          = @{ lookupValue = $p.PrimaryContract.Department.DisplayName }
    budgetHolder        = @{ lookupValue = $p.PrimaryContract.CostCenter.Name }
    #isManager           = $false
    manager             = @{ id = $mRef }
    #showDepartment      = $true
}
#endregion mapping

#region helperfunctions
function Set-AuthorizationHeaders {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Username,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ApiKey
    )
    # Create basic authentication string
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("${Username}:${Apikey}")
    $base64 = [System.Convert]::ToBase64String($bytes)

    # Set authentication headers
    $authHeaders = [System.Collections.Generic.Dictionary[string, string]]::new()
    $authHeaders.Add("Authorization", "BASIC $base64")
    $authHeaders.Add("Accept", 'application/json')

    Write-Output $authHeaders
}

function Invoke-TopdeskRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [object]
        $Body,

        [string]
        $ContentType = 'application/json; charset=utf-8',

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers
    )
    process {
        try {
            $splatParams = @{
                Uri         = $Uri
                Headers     = $Headers
                Method      = $Method
                ContentType = $ContentType
            }
            if ($Body) {
                $splatParams['Body'] = [Text.Encoding]::UTF8.GetBytes($Body)
            }
            Invoke-RestMethod @splatParams -Verbose:$false
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}

function Get-TopdeskBranch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        [ref]$Account,

        [System.Collections.Generic.List[PSCustomObject]]
        [ref]$AuditLogs
    )

    # Check if branch.lookupValue property exists in the account object set in the mapping
    if (-not($account.branch.Keys -Contains 'lookupValue')) {
        $errorMessage = "Requested to lookup branch, but branch.lookupValue is missing. This is a scripting issue."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
        return
    }

    # When branch.lookupValue is null or empty (it is empty in the source or it's a mapping error)
    if ([string]::IsNullOrEmpty($Account.branch.lookupValue)) {

            # As branch is always a required field,  no branch in lookup value = error
            $errorMessage = "The lookup value for Branch is empty but it's a required field."
            $AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
    } else {

        # Lookup Value is filled in, lookup value in Topdesk
        $splatParams = @{
            Uri     = "$BaseUrl/tas/api/branches"
            Method  = 'GET'
            Headers = $Headers
        }
        $responseGet = Invoke-TopdeskRestMethod @splatParams
        $branch = $responseGet | Where-object name -eq $Account.branch.lookupValue

        # When branch is not found in Topdesk
        if ([string]::IsNullOrEmpty($branch.id)) {

            # As branch is a required field, if no branch is found, an error is logged
            $errorMessage = "Branch with name [$($Account.branch.lookupValue)] isn't found in Topdesk but it's a required field."
            $AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
        } else {

            # Branch is found in Topdesk, set in Topdesk
            $Account.branch.Remove('lookupValue')
            $Account.branch.Add('id', $branch.id)
        }
    }
}

function Get-TopdeskDepartment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        $LookupErrorHrDepartment,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        $LookupErrorTopdesk,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        [ref]$Account,

        [System.Collections.Generic.List[PSCustomObject]]
        [ref]$AuditLogs
    )

    # Check if department.lookupValue property exists in the account object set in the mapping
    if (-not($Account.department.Keys -Contains 'lookupValue')) {
        $errorMessage = "Requested to lookup department, but department.lookupValue is not set. This is a scripting issue."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
        return
    }

    # When department.lookupValue is null or empty (it is empty in the source or it's a mapping error)
    if ([string]::IsNullOrEmpty($Account.department.lookupValue)) {
        if ([System.Convert]::ToBoolean($LookupErrorHrDepartment)) {

            # True, no department in lookup value = throw error
            $errorMessage = "The lookup value for Department is empty and the connector is configured to stop when this happens."
            $AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
        } else {

            # False, no department in lookup value = clear value
            Write-Verbose "Clearing department. (lookupErrorHrDepartment = False)"
            $Account.department.PSObject.Properties.Remove('lookupValue')
            $Account.department | Add-Member -NotePropertyName id -NotePropertyValue $null
        }
    } else {

        # Lookup Value is filled in, lookup value in Topdesk
        $splatParams = @{
            Uri     = "$BaseUrl/tas/api/departments"
            Method  = 'GET'
            Headers = $Headers
        }
        $responseGet = Invoke-TopdeskRestMethod @splatParams
        $department = $responseGet | Where-object name -eq $Account.department.lookupValue

        # When department is not found in Topdesk
        if ([string]::IsNullOrEmpty($department.id)) {
            if ([System.Convert]::ToBoolean($LookupErrorTopdesk)) {

                # True, no department found = throw error
                $errorMessage = "Department [$($Account.department.lookupValue)] not found in Topdesk and the connector is configured to stop when this happens."
                $AuditLogs.Add([PSCustomObject]@{
                    Message = $errorMessage
                    IsError = $true
                })
            } else {

                # False, no department found = remove department field (leave empty on creation or keep current value on update)
                $Account.department.Remove('lookupValue')
                $Account.PSObject.Properties.Remove('department')
                Write-Verbose "Not overwriting or setting department as it can't be found in Topdesk. (lookupErrorTopdesk = False)"
            }
        } else {

            # Department is found in Topdesk, set in Topdesk
            $Account.department.Remove('lookupValue')
            $Account.department.Add('id', $department.id)
        }
    }
}

function Get-TopdeskBudgetHolder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        $LookupErrorHrBudgetHolder,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        $LookupErrorTopdesk,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        [ref]$Account,

        [System.Collections.Generic.List[PSCustomObject]]
        [ref]$AuditLogs
    )

    # Check if budgetholder.lookupValue property exists in the account object set in the mapping
    if (-not($Account.budgetHolder.Keys -Contains 'lookupValue')) {
        $errorMessage = "Requested to lookup budgetholder, but budgetholder.lookupValue is missing. This is a scripting issue."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
        return
    }

    # When budgetholder.lookupValue is null or empty (it is empty in the source or it's a mapping error)
    if ([string]::IsNullOrEmpty($Account.budgetHolder.lookupValue)) {
        if ([System.Convert]::ToBoolean($lookupErrorHrBudgetHolder)) {

            # True, no budgetholder in lookup value = throw error
            $errorMessage = "The lookup value for budgetholder is empty and the connector is configured to stop when this happens."
            $auditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
        } else {

            # False, no budgetholder in lookup value = clear value
            $Account.budgetHolder.PSObject.Properties.Remove('lookupValue')
            $Account.budgetHolder | Add-Member -NotePropertyName id -NotePropertyValue $null
            Write-Verbose "Clearing budgetholder. (lookupErrorHrBudgetHolder = False)"
        }
    } else {

        # Lookup Value is filled in, lookup value in Topdesk
        $splatParams = @{
            Uri     = "$BaseUrl/tas/api/budgetholders"
            Method  = 'GET'
            Headers = $Headers
        }
        $responseGet = Invoke-TopdeskRestMethod @splatParams
        $budgetHolder = $responseGet | Where-object name -eq $Account.budgetHolder.lookupValue

        # When budgetholder is not found in Topdesk
        if ([string]::IsNullOrEmpty($budgetHolder.id)) {
            if ([System.Convert]::ToBoolean($lookupErrorTopdesk)) {

                # True, no budgetholder found = throw error
                $errorMessage = "Budgetholder [$($Account.budgetHolder.lookupValue)] not found in Topdesk and the connector is configured to stop when this happens."
                $AuditLogs.Add([PSCustomObject]@{
                    Message = $errorMessage
                    IsError = $true
                })
            } else {

                # False, no budgetholder found = remove budgetholder field (leave empty on creation or keep current value on update)
                $Account.budgetHolder.Remove('lookupValue')
                $Account.PSObject.Properties.Remove('budgetHolder')
                Write-Verbose "Not overwriting or setting budgetholder as it can't be found in Topdesk. (lookupErrorTopdesk = False)"
            }
        } else {

            # Budgetholder is found in Topdesk, set in Topdesk
            $Account.budgetHolder.Remove('lookupValue')
            $Account.budgetHolder.Add('id', $budgetHolder.id)
        }
    }
}

function Get-TopdeskPersonById {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]
        $PersonReference
    )

    # Lookup value is filled in, lookup person in Topdesk
    $splatParams = @{
        Uri     = "$BaseUrl/tas/api/persons/id/$PersonReference"
        Method  = 'GET'
        Headers = $Headers
    }
    $responseGet = Invoke-TopdeskRestMethod @splatParams

    # Output result if something was found. Result is empty when nothing is found
    Write-Output $responseGet
}

function Get-TopdeskPerson {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [String]
        $AccountReference,

        [System.Collections.Generic.List[PSCustomObject]]
        [ref]$AuditLogs
    )

    # Check if the account reference is empty, if so, generate audit message
    if ([string]::IsNullOrEmpty($AccountReference)) {

        # Throw an error when account reference is empty
        $errorMessage = "The account reference is empty. This is a scripting issue."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
        return
    }

    # AcountReference is available, query person
    $splatParams = @{
        Headers                   = $Headers
        BaseUrl                   = $BaseUrl
        PersonReference           = $AccountReference
    }
    $person = Get-TopdeskPersonById @splatParams

    if ([string]::IsNullOrEmpty($person)) {
        $errorMessage = "Person with reference [$AccountReference)] is not found. If the person is deleted, you might need to regrant the entitlement."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
    } else {
        Write-Output $person
    }
}

function Get-TopdeskPersonManager {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        [Ref]$Account,

        [System.Collections.Generic.List[PSCustomObject]]
        [ref]$AuditLogs
    )

    # Check if manager.id property exists in the account object set in the mapping
    if (-not($Account.manager.Keys -Contains 'id')) {
        $errorMessage = "Requested to lookup manager, but manager.id is missing. This is a scripting issue."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
        return
    }

    # Check if the manager reference is empty, if so, generate audit message or clear the manager attribute
    if ([string]::IsNullOrEmpty($Account.manager.id)) {
            #As manager.Id is empty, nothing needs to be done here
            Write-Verbose "Manager Id is empty, clearing manager."
        return
    }

    # manager.Id is available, query manager
    $splatParams = @{
        Headers                   = $Headers
        BaseUrl                   = $BaseUrl
        PersonReference           = $Account.manager.id
    }
    $personManager = Get-TopdeskPersonById @splatParams

    if ([string]::IsNullOrEmpty($personManager)) {
        $errorMessage = "Manager with reference [$($Account.manager.id)] is not found."
        $AuditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
    } else {
        Write-Output $personManager
    }
}
function Set-TopdeskPersonArchiveStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        [Ref]$TopdeskPerson,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Bool]
        $Archive,

        [Parameter()]
        [String]
        $ArchivingReason,

        [System.Collections.Generic.List[PSCustomObject]]
        [ref]$AuditLogs
    )

    # Set ArchiveStatus variables based on archive parameter
    if ($Archive -eq $true) {

         #When the 'archiving reason' setting is not configured in the target connector configuration
        if ([string]::IsNullOrEmpty($ArchivingReason)) {
            $errorMessage = "Configuration setting 'Archiving Reason' is empty. This is a configuration error."
            $AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
            Throw "Error(s) occured while looking up required values"
        }

        $splatParams = @{
            Uri     = "$baseUrl/tas/api/archiving-reasons"
            Method  = 'GET'
            Headers = $Headers
        }

        $responseGet = Invoke-TopdeskRestMethod @splatParams
        $archivingReasonObject = $responseGet | Where-object name -eq $ArchivingReason

        #When the configured archiving reason is not found in Topdesk
        if ([string]::IsNullOrEmpty($archivingReasonObject.id)) {
            $errorMessage = "Archiving reason [$ArchivingReason] not found in Topdesk"
            $AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
            Throw "Error(s) occured while looking up required values"
        } # else

        $archiveStatus = 'personArchived'
        $archiveUri = 'archive'
        $body = @{ id = $archivingReasonObject.id }
    } else {
        $archiveStatus = 'person'
        $archiveUri = 'unarchive'
        $body = $null
    }

    # Check the current status of the Person and compare it with the status in archiveStatus
    if ($archiveStatus -ne $TopdeskPerson.status) {

        # Archive / unarchive person
        Write-Verbose "[$archiveUri] person with id [$($TopdeskPerson.id)]"
        $splatParams = @{
            Uri     = "$BaseUrl/tas/api/persons/id/$($TopdeskPerson.id)/$archiveUri"
            Method  = 'PATCH'
            Headers = $Headers
            Body    = $body | ConvertTo-Json
        }
        $null = Invoke-TopdeskRestMethod @splatParams
        $TopdeskPerson.status = $archiveStatus
    }
}

function Set-TopdeskPersonIsManager {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        [Ref]$TopdeskPerson,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Bool]
        $isManager
    )


	# Check the current status of the Person and compare it with the status in ArchiveStatus
    if ($isManager -ne $TopdeskPerson.isManager) {

        # Turn on / off isManager
        $body = [PSCustomObject]@{
            isManager = $isManager
        }
        Write-Verbose "Setting flag isManager to [$isManager] to person with networkLoginName [$($TopdeskPerson.networkLoginName)] and id [$($TopdeskPerson.id)]"
        $splatParams = @{
            Uri     = "$BaseUrl/tas/api/persons/id/$($TopdeskPerson.id)"
            Method  = 'PATCH'
            Headers = $Headers
            Body    = $body | ConvertTo-Json
        }
        $null = Invoke-TopdeskRestMethod @splatParams
        $TopdeskPerson.status = $isManager
    }
}

function Set-TopdeskPerson {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        $Account,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object]
        $TopdeskPerson
    )

    #Write-Verbose "Updating person"
    $splatParams = @{
        Uri     = "$BaseUrl/tas/api/persons/id/$($TopdeskPerson.id)"
        Method  = 'PATCH'
        Headers = $Headers
        Body    = $Account | ConvertTo-Json
    }
    #Write-Verbose ($splatParams | ConvertTo-Json)
    $null = Invoke-TopdeskRestMethod @splatParams
}
#endregion helperfunctions

#region lookup
try {
    $action = 'Process'

    # Setup authentication headers
    $authHeaders = Set-AuthorizationHeaders -UserName $Config.username -ApiKey $Config.apiKey

    # Resolve branch id
    $splatParamsBranch = @{
        Account                   = [ref]$account
        AuditLogs                 = [ref]$auditLogs
        Headers                   = $authHeaders
        BaseUrl                   = $config.baseUrl
    }
    Get-TopdeskBranch @splatParamsBranch

    # Resolve department id
    $splatParamsDepartment = @{
        Account                   = [ref]$account
        AuditLogs                 = [ref]$auditLogs
        Headers                   = $authHeaders
        BaseUrl                   = $config.baseUrl
        LookupErrorHrDepartment   = $config.lookupErrorHrDepartment
        LookupErrorTopdesk        = $config.lookupErrorTopdesk
    }
    Get-TopdeskDepartment @splatParamsDepartment

    # Resolve budgetholder id
    $splatParamsBudgetHolder = @{
        Account                   = [ref]$account
        AuditLogs                 = [ref]$auditLogs
        Headers                   = $authHeaders
        BaseUrl                   = $config.baseUrl
        LookupErrorHrBudgetHolder = $config.lookupErrorHrBudgetHolder
        LookupErrorTopdesk        = $config.lookupErrorTopdesk
    }
    Get-TopdeskBudgetHolder @splatParamsBudgetHolder

    # get person
    $splatParamsPerson = @{
        AccountReference          = $aRef
        AuditLogs                 = [ref]$auditLogs
        Headers                   = $authHeaders
        BaseUrl                   = $config.baseUrl
    }
    $TopdeskPerson = Get-TopdeskPerson  @splatParamsPerson

    # get manager
    $splatParamsManager = @{
        Account                   = [ref]$account
        AuditLogs                 = [ref]$auditLogs
        Headers                   = $authHeaders
        baseUrl                   = $config.baseUrl
    }
    $TopdeskManager = Get-TopdeskPersonManager @splatParamsManager

    if ($auditLogs.isError -contains -$true) {
        Throw "Error(s) occured while looking up required values"
    }
#endregion lookup

# region write
    $action = 'Update'

    # Prepare manager record, if manager has to be set
    if (-Not([string]::IsNullOrEmpty($account.manager.id))) {
        if ($TopdeskManager.status -eq 'personArchived') {

            # Unarchive manager
            $shouldArchive  = $true
            $splatParamsManagerUnarchive = @{
                TopdeskPerson   = [ref]$TopdeskManager
                Headers         = $authHeaders
                BaseUrl         = $config.baseUrl
                Archive         = $false
                ArchivingReason = $config.personArchivingReason
                AuditLogs       = [ref]$auditLogs
            }
            Set-TopdeskPersonArchiveStatus @splatParamsManagerUnarchive
        }

        # Set isManager to true
        $splatParamsManagerIsManager = @{
            TopdeskPerson   = [ref]$TopdeskManager
            Headers         = $authHeaders
            BaseUrl         = $config.baseUrl
            IsManager       = $true
        }
        Set-TopdeskPersonIsManager @splatParamsManagerIsManager

        # Archive manager if required
        if ($shouldArchive -and $TopdeskManager.status -ne 'personArchived') {

            # Archive manager
            $splatParamsManagerArchive = @{
                TopdeskPerson   = [ref]$TopdeskManager
                Headers         = $authHeaders
                BaseUrl         = $config.baseUrl
                Archive         = $true
                ArchivingReason = $config.personArchivingReason
                AuditLogs       = [ref]$auditLogs
            }
            Set-TopdeskPersonArchiveStatus @splatParamsManagerArchive
        }
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        $auditLogs.Add([PSCustomObject]@{
            Message = "$action Topdesk account for: [$($p.DisplayName)], will be executed during enforcement"
        })
    }

    # Process
    if (-not($dryRun -eq $true)){
        Write-Verbose "Updating Topdesk person for: [$($p.DisplayName)]"

        # Unarchive person if required
        if ($TopdeskPerson.status -eq 'personArchived') {

            # Unarchive person
            $shouldArchive  = $true
            $splatParamsPersonUnarchive = @{
                TopdeskPerson   = [ref]$TopdeskPerson
                Headers         = $authHeaders
                BaseUrl         = $config.baseUrl
                Archive         = $false
                ArchivingReason = $config.personArchivingReason
                AuditLogs       = [ref]$auditLogs

            }
            Set-TopdeskPersonArchiveStatus @splatParamsPersonUnarchive
        }

        # Update TOPdesk person
        $splatParamsPersonUpdate = @{
            TopdeskPerson   = $TopdeskPerson
            Account         = $account
            Headers         = $authHeaders
            BaseUrl         = $config.baseUrl
        }
        Set-TopdeskPerson @splatParamsPersonUpdate

        # As the update process could be started for an inactive HelloID person, the user return should be archived state
        if ($shouldArchive -and $TopdeskPerson.status -ne 'personArchived') {

            # Archive person
            $splatParamsPersonArchive = @{
                TopdeskPerson   = [ref]$TopdeskPerson
                Headers         = $authHeaders
                BaseUrl         = $config.baseUrl
                Archive         = $true
                ArchivingReason = $config.personArchivingReason
                AuditLogs       = [ref]$auditLogs
            }
            Set-TopdeskPersonArchiveStatus @splatParamsPersonArchive
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
            Message = "Account with id [$($TopdeskPerson.id) successfully updated"
            IsError = $false
        })
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        if (-Not [string]::IsNullOrEmpty($ex.ErrorDetails.Message)) {
            $errorMessage = "Could not $action person. Error: $($ex.ErrorDetails.Message)"
        } else {
            #$errorObj = Resolve-HTTPError -ErrorObject $ex
            $errorMessage = "Could not $action person. Error: $($ex.Exception.Message)"
        }
    } else {
        $errorMessage = "Could not $action person. Error: $($ex.Exception.Message) $($ex.ScriptStackTrace)"
    }

    # Only log when there are no lookup values, as these generate their own audit message
    if (-Not($ex.Exception.Message -eq 'Error(s) occured while looking up required values')) {
        $auditLogs.Add([PSCustomObject]@{
            Message = $errorMessage
            IsError = $true
        })
    }
# End
} finally {
   $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $aref
        Auditlogs        = $auditLogs
        Account          = $account
        ExportData = [PSCustomObject]@{
            externalId          = $aRef
            employeeNumber      = $account.employeeNumber
            networkLoginName    = $account.networkLoginName
            tasLoginName        = $account.tasLoginName
        }
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
#endregion Write
