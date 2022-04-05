#####################################################
# HelloID-Conn-Prov-Target-TOPdesk-Delete
#
# Version: 1.0.0
#####################################################

# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
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
# Clear email, networkLoginName & tasLoginName, if you need to clear other values, add these here
$account = [PSCustomObject]@{
    email               = $null
    networkLoginName    = $null
    tasLoginName        = ''
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
                Write-Verbose 'Adding body to request'
                $splatParams['Body'] = [Text.Encoding]::UTF8.GetBytes($Body)
            }
            Invoke-RestMethod @splatParams -Verbose:$false
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
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
        Uri     = "$baseUrl/tas/api/persons/id/$PersonReference"
        Method  = 'GET'
        Headers = $Headers
    }
    $responseGet = Invoke-TopdeskRestMethod @splatParams

    # Output result if something was found. Result is empty when nothing is found (i think) - TODO: Test this!!!
    Write-Output $responseGet
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
        $Archive
    )

    # Set ArchiveStatus variables based on archive parameter
    if ($Archive -eq $true) {
        $archiveStatus = 'personArchived'
        $archiveUri = 'archive'
    } else {
        $archiveStatus = 'person'
        $archiveUri = 'unarchive'
    }

    # Check the current status of the Person and compare it with the status in ArchiveStatus
    if ($archiveStatus -ne $TopdeskPerson.status) {

        # Archive / unarchive person
        Write-Verbose "[$archiveUri] person with id [$($TopdeskPerson.id)]"
        $splatParams = @{
            Uri     = "$baseUrl/tas/api/person/$($TopdeskPerson.id)/$archiveUri"
            Method  = 'PATCH'
            Headers = $Headers
        }
        $null = Invoke-TopdeskRestMethod @splatParams
        $TopdeskPerson.status = $archiveStatus
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

    Write-Verbose "Updating person"
    $splatParams = @{
        Uri     = "$baseUrl/tas/api/person/$($TopdeskPerson.id)"
        Method  = 'PATCH'
        Headers = $Headers
        Body    = $Account | ConvertTo-Json
    }
    $null = Invoke-TopdeskRestMethod @splatParams
}
#endregion helperfunctions

try {
    $splatParams = @{
        Headers                   = $Headers
        BaseUrl                   = $baseUrl
        PersonReference           = $aRef
    }
    $TopdeskPerson = Get-TopdeskPersonById @splatParams



    if ([string]::IsNullOrEmpty($TopdeskPerson)) {

        # When a person cannot be found, assume the person is already deleted and report success with the default audit message
        if ($dryRun -eq $true) {
            $auditLogs.Add([PSCustomObject]@{
                Message = "Archiving TOPdesk person for: [$($p.DisplayName)]: person with account reference [$aRef] cannot be found"
            })
        }
    } else {

        # Add an auditMessage showing what will happen during enforcement
        if ($dryRun -eq $true) {
            $auditLogs.Add([PSCustomObject]@{
                Message = "Archiving TOPdesk person for: [$($p.DisplayName)], will be executed during enforcement"
            })
        } else {
            Write-Verbose "Archiving TOPdesk person"

            # Unarchive person if required
            if ($TopdeskPerson.status -eq 'personArchived') {

                # Unarchive person
                $splatParamsPersonUnarchive = @{
                    TopdeskPerson   = [ref]$TopdeskPerson
                    Headers         = $authHeaders
                    BaseUrl         = $config.baseUrl
                    Archive         = $false
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

            # Always archive person in the delete process
            if ($TopdeskPerson.status -ne 'personArchived') {

                # Archive person
                $splatParamsPersonArchive = @{
                    TopdeskPerson   = [ref]$TopdeskPerson
                    Headers         = $authHeaders
                    BaseUrl         = $config.baseUrl
                    Archive         = $true
                }
                Set-TopdeskPersonArchiveStatus @splatParamsPersonArchive
            }

            $success = $true
            $auditLogs.Add([PSCustomObject]@{
                Message = "Archive person was successful."
                IsError = $false
            })
        }
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorMessage = "Could not archive person. Error: $($ex.ErrorDetails.Message)"
    } else {
        $errorMessage = "Could not archive person. Error: $($ex.Exception.Message) $($ex.ScriptStackTrace)"
    }

    $auditLogs.Add([PSCustomObject]@{
        Message = $errorMessage
        IsError = $true
    })
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}