####################################################################
# HelloID-Conn-Prov-Target-Microsoft-Entra-ID-EducationalGroups-Members-ImportSubPermissions
# PowerShell V2
####################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Configure, must be the same as the values used in retrieve permissions
$permissionReference = 'EDU-Teams-Members'
$permissionDisplayName = 'EDU Teams - Members'

#region functions
function Resolve-MS-Entra-ExoError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }

        try {
            if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
                $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message | ConvertFrom-Json
            }
            elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
                if ($null -ne $ErrorObject.Exception.Response) {
                    $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                    if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                        $httpErrorObj.ErrorDetails = $streamReaderResponse
                    }
                }
            }
            $errorDetailsObject = $httpErrorObj.ErrorDetails
            if ($errorDetailsObject.error_description) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.error_description
            }
            elseif ($errorDetailsObject.error.message) {
                $httpErrorObj.FriendlyMessage = "$($errorDetailsObject.error.code): $($errorDetailsObject.error.message)"
            }
            elseif ($errorDetailsObject.error.details.message) {
                $httpErrorObj.FriendlyMessage = "$($errorDetailsObject.error.details.code): $($errorDetailsObject.details.message)"
            }
            else {
                $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}

function Get-MSEntraAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Certificate
    )
    try {
        # Get the DER encoded bytes of the certificate
        $derBytes = $Certificate.RawData

        # Compute the SHA-256 hash of the DER encoded bytes
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($derBytes)
        $base64Thumbprint = [System.Convert]::ToBase64String($hashBytes).Replace('+', '-').Replace('/', '_').Replace('=', '')

        # Create a JWT (JSON Web Token) header
        $header = @{
            'alg'      = 'RS256'
            'typ'      = 'JWT'
            'x5t#S256' = $base64Thumbprint
        } | ConvertTo-Json
        $base64Header = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($header))

        # Calculate the Unix timestamp (seconds since 1970-01-01T00:00:00Z) for 'exp', 'nbf' and 'iat'
        $currentUnixTimestamp = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime()).TotalSeconds)

        # Create a JWT payload
        $payload = [Ordered]@{
            'iss' = "$($actionContext.Configuration.AppId)"
            'sub' = "$($actionContext.Configuration.AppId)"
            'aud' = "https://login.microsoftonline.com/$($actionContext.Configuration.TenantID)/oauth2/token"
            'exp' = ($currentUnixTimestamp + 3600) # Expires in 1 hour
            'nbf' = ($currentUnixTimestamp - 300) # Not before 5 minutes ago
            'iat' = $currentUnixTimestamp
            'jti' = [Guid]::NewGuid().ToString()
        } | ConvertTo-Json
        $base64Payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload)).Replace('+', '-').Replace('/', '_').Replace('=', '')

        # Extract the private key from the certificate
        $rsaPrivate = $Certificate.PrivateKey
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        $rsa.ImportParameters($rsaPrivate.ExportParameters($true))

        # Sign the JWT
        $signatureInput = "$base64Header.$base64Payload"
        $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signatureInput), 'SHA256')
        $base64Signature = [System.Convert]::ToBase64String($signature).Replace('+', '-').Replace('/', '_').Replace('=', '')

        # Ensure the certificate has a private key
        if (-not $Certificate.HasPrivateKey -or -not $Certificate.PrivateKey) {
            throw "The certificate does not have a private key."
        }

        # Create the JWT token
        $jwtToken = "$($base64Header).$($base64Payload).$($base64Signature)"

        $createEntraAccessTokenBody = @{
            grant_type            = 'client_credentials'
            client_id             = $actionContext.Configuration.AppId
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $jwtToken
            resource              = 'https://graph.microsoft.com'
        }

        $createEntraAccessTokenSplatParams = @{
            Uri         = "https://login.microsoftonline.com/$($actionContext.Configuration.TenantID)/oauth2/token"
            Body        = $createEntraAccessTokenBody
            Method      = 'POST'
            ContentType = 'application/x-www-form-urlencoded'
            Verbose     = $false
            ErrorAction = 'Stop'
        }

        $createEntraAccessTokenResponse = Invoke-RestMethod @createEntraAccessTokenSplatParams
        Write-Output $createEntraAccessTokenResponse.access_token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-MSEntraCertificate {
    [CmdletBinding()]
    param()
    try {
        $rawCertificate = [system.convert]::FromBase64String($actionContext.Configuration.AppCertificateBase64String)
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawCertificate, $actionContext.Configuration.AppCertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        Write-Output $certificate
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-MSEntraRetryDelay {
    <#
        Returns the number of seconds to wait before retrying a request.
        Honors the Retry-After value returned by Microsoft Graph (seconds, HTTP-date, TimeSpan or DateTimeOffset)
        and falls back to exponential backoff (2, 4, 8, ... seconds, capped at MaxBackoffSeconds) when it is absent.
        See: https://learn.microsoft.com/en-us/graph/throttling#best-practices-to-handle-throttling
    #>
    [CmdletBinding()]
    param(
        [object]
        $RetryAfter,

        [Parameter(Mandatory)]
        [int]
        $Attempt,

        [int]
        $MaxBackoffSeconds = 60
    )
    $seconds = $null
    if ($RetryAfter -is [TimeSpan]) {
        $seconds = $RetryAfter.TotalSeconds
    }
    elseif ($RetryAfter -is [DateTimeOffset]) {
        $seconds = ($RetryAfter - [DateTimeOffset]::UtcNow).TotalSeconds
    }
    elseif (-not [string]::IsNullOrWhiteSpace("$RetryAfter")) {
        $parsedSeconds = 0
        $parsedDate = [DateTimeOffset]::MinValue
        if ([int]::TryParse("$RetryAfter", [ref]$parsedSeconds)) {
            $seconds = $parsedSeconds
        }
        elseif ([DateTimeOffset]::TryParse("$RetryAfter", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedDate)) {
            $seconds = ($parsedDate - [DateTimeOffset]::UtcNow).TotalSeconds
        }
    }

    if ($null -ne $seconds) {
        Write-Output ([int][Math]::Max(1, [Math]::Ceiling($seconds)))
    }
    else {
        Write-Output ([int][Math]::Min([Math]::Pow(2, $Attempt), $MaxBackoffSeconds))
    }
}

function Invoke-MSEntraRestMethodWithRetry {
    <#
        Invokes Invoke-RestMethod with the given splat parameters and retries transient failures
        (HTTP 429, 500, 502, 503 and 504), honoring the Retry-After header.
        Any other error, or a transient error that persists after MaxRetries retries, is rethrown unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]
        $SplatParams,

        [int]
        $MaxRetries = 5
    )
    $attempt = 0
    while ($true) {
        try {
            $response = Invoke-RestMethod @SplatParams
            return $response
        }
        catch {
            $statusCode = 0
            if ($null -ne $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -notin @(429, 500, 502, 503, 504) -or $attempt -ge $MaxRetries) {
                throw
            }
            $attempt++

            # PowerShell 7 returns an HttpResponseMessage, Windows PowerShell 5.1 a HttpWebResponse
            $retryAfter = $null
            $responseHeaders = $_.Exception.Response.Headers
            if ($null -ne $responseHeaders) {
                if ($responseHeaders.GetType().FullName -eq 'System.Net.Http.Headers.HttpResponseHeaders') {
                    if ($null -ne $responseHeaders.RetryAfter) {
                        if ($null -ne $responseHeaders.RetryAfter.Delta) {
                            $retryAfter = $responseHeaders.RetryAfter.Delta
                        }
                        else {
                            $retryAfter = $responseHeaders.RetryAfter.Date
                        }
                    }
                }
                else {
                    $retryAfter = $responseHeaders['Retry-After']
                }
            }

            $delay = Get-MSEntraRetryDelay -RetryAfter $retryAfter -Attempt $attempt
            Write-Warning "Request [$($SplatParams.Method) $($SplatParams.Uri)] returned HTTP $($statusCode). Retry [$attempt/$MaxRetries] in [$delay] seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-MSEntraBatchRequest {
    <#
        Executes a list of requests against the Microsoft Graph $batch endpoint
        (https://learn.microsoft.com/en-us/graph/json-batching), instead of one request per item.
        Each request is a hashtable with a 'Method' and a relative 'Uri' (e.g. '/groups/{id}/members').
        Returns a hashtable keyed by the (0-based) index of $Requests, where each value is the
        (paginated, fully resolved) 'value' array of that request's response.

        Microsoft Graph evaluates throttling per sub-request: the $batch call itself returns HTTP 200
        while individual sub-requests can return 429 or 5xx. Those sub-requests are retried
        (only the failed ones, honoring their Retry-After header). If they keep failing after MaxRetries
        retries an exception is thrown, so an import never continues with incomplete data.
        Other non-success sub-responses keep the previous behavior: a warning and an empty result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]
        $Requests,

        [Parameter(Mandatory)]
        [hashtable]
        $Headers,

        [ValidateRange(1, 20)]
        [int]
        $BatchSize = 20,

        [int]
        $MaxRetries = 5
    )
    process {
        $resultsByIndex = @{}
        $retryableStatusCodes = @(429, 500, 502, 503, 504)

        for ($i = 0; $i -lt $Requests.Count; $i += $BatchSize) {
            $pendingIndexes = [System.Collections.Generic.List[int]]::new()
            for ($index = $i; $index -lt [Math]::Min($i + $BatchSize, $Requests.Count); $index++) {
                $pendingIndexes.Add($index)
            }

            $attempt = 0
            while ($pendingIndexes.Count -gt 0) {
                # The index in $Requests is used as the batch request id, so responses can be matched regardless of their order
                $batchRequests = [System.Collections.Generic.List[object]]::new()
                foreach ($index in $pendingIndexes) {
                    [void]$batchRequests.Add(
                        @{
                            id     = "$index"
                            method = $Requests[$index].Method
                            url    = $Requests[$index].Uri
                        }
                    )
                }

                $batchSplatParams = @{
                    Uri         = 'https://graph.microsoft.com/v1.0/$batch'
                    Headers     = $Headers
                    Method      = 'POST'
                    Body        = (@{ requests = $batchRequests } | ConvertTo-Json -Depth 10)
                    ContentType = 'application/json; charset=utf-8'
                    Verbose     = $false
                    ErrorAction = 'Stop'
                }
                $batchResponse = Invoke-MSEntraRestMethodWithRetry -SplatParams $batchSplatParams -MaxRetries $MaxRetries

                $responsesById = @{}
                foreach ($batchSubResponse in @($batchResponse.responses)) {
                    $responsesById["$($batchSubResponse.id)"] = $batchSubResponse
                }

                $retryIndexes = [System.Collections.Generic.List[int]]::new()
                $retryDelay = 0
                $lastTransientError = $null
                foreach ($index in $pendingIndexes) {
                    $response = $responsesById["$index"]
                    $requestDescription = "$($Requests[$index].Method) $($Requests[$index].Uri)"
                    if ($null -eq $response) {
                        throw "The batch response did not contain a response for request [$index] [$requestDescription]."
                    }

                    $status = [int]$response.status
                    if ($status -ge 200 -and $status -lt 300) {
                        $values = [System.Collections.ArrayList]@()
                        if ($null -ne $response.body.value) {
                            [void]$values.AddRange(@($response.body.value))
                        }
                        $nextLink = $response.body.'@odata.nextLink'
                        while (-not [string]::IsNullOrEmpty($nextLink)) {
                            $paginationSplatParams = @{
                                Uri         = $nextLink
                                Headers     = $Headers
                                Method      = 'GET'
                                ContentType = 'application/json; charset=utf-8'
                                Verbose     = $false
                                ErrorAction = 'Stop'
                            }
                            $paginationResponse = Invoke-MSEntraRestMethodWithRetry -SplatParams $paginationSplatParams -MaxRetries $MaxRetries
                            if ($null -ne $paginationResponse.value) {
                                [void]$values.AddRange(@($paginationResponse.value))
                            }
                            $nextLink = $paginationResponse.'@odata.nextLink'
                        }
                        $resultsByIndex[$index] = $values
                    }
                    elseif ($status -in $retryableStatusCodes) {
                        [void]$retryIndexes.Add($index)
                        $delay = Get-MSEntraRetryDelay -RetryAfter $response.headers.'Retry-After' -Attempt ($attempt + 1)
                        if ($delay -gt $retryDelay) {
                            $retryDelay = $delay
                        }
                        $lastTransientError = "HTTP $($status) for request [$index] [$requestDescription]: $($response.body.error.message)"
                    }
                    else {
                        Write-Warning "Batch sub-request failed with HTTP $($status) for request at index [$index] [$requestDescription]: $($response.body.error.message)"
                        $resultsByIndex[$index] = @()
                    }
                }

                if ($retryIndexes.Count -gt 0) {
                    if ($attempt -ge $MaxRetries) {
                        throw "[$($retryIndexes.Count)] batch sub-request(s) still failed after [$MaxRetries] retries, aborting to prevent incomplete data. Last error: $lastTransientError"
                    }
                    $attempt++
                    Write-Warning "[$($retryIndexes.Count)] batch sub-request(s) were throttled or failed transiently. Retry [$attempt/$MaxRetries] in [$retryDelay] seconds. Last error: $lastTransientError"
                    Start-Sleep -Seconds $retryDelay
                }
                $pendingIndexes = $retryIndexes
            }
        }

        Write-Output $resultsByIndex
    }
}

function Get-SchoolYear {
    # Calculate school year dependencies
    # School year definition in numbers of 4 or 2 digits
    $schoolYearLength = 2 # Length of school year used in the Teams name - e.g. 24-25 for 2 or 2024-2025 for 4
    $schoolYearSeperator = "" # Used in the Teams name - can be empty
    
    if ($schoolYearLength -eq 2) { $format = "yy" } else { $format = "yyyy" }
    
    $monthcurrent = (Get-Date).Month
    $yearcurrent = (Get-Date).ToString($format)
    $yearprevious = ([int]$yearcurrent - 1).ToString()
    $yearnext = ([int]$yearcurrent + 1).ToString()
    
    If ($monthcurrent -ge 8) {
        $schoolyear = $yearcurrent + $schoolYearSeperator + $yearnext
    }
    else {
        $schoolyear = $yearprevious + $schoolYearSeperator + $yearcurrent
    }
    return $schoolyear
}
#endregion functions


try {
    # Make sure the search query returns the same scope as the 'Handle all action script'. If this is not possible with GraphApi, then filter the data after retrieving it.
    # Example using department_<departmentName>=
    # $searchQuery = "`$filter=startswith(displayName,'department')"
    # Example when using function_<functionName>_department_<departmentName>:
    $schoolyear = Get-SchoolYear
    $searchQuery = '$search="displayName:' + $schoolyear + '"'

    # Setup Connection with Entra/Exo
    $actionMessage = 'connecting to MS-Entra'
    $certificate = Get-MSEntraCertificate
    $entraToken = Get-MSEntraAccessToken -Certificate $certificate

    $headers = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
    $headers.Add('Authorization', "Bearer $entraToken")
    $headers.Add('Accept', 'application/json')
    $headers.Add('Content-Type', 'application/json')
    # Needed to filter on specific attributes (https://docs.microsoft.com/en-us/graph/aad-advanced-queries)
    $headers.Add('ConsistencyLevel', 'eventual')

    # # API docs: https://learn.microsoft.com/en-us/graph/api/group-list?view=graph-rest-1.0&tabs=http
    $actionMessage = "querying groups"
    $entraIDGroups = @()
    $uri = "https://graph.microsoft.com/v1.0/groups?$searchQuery"
    do {
        $getGroupsSplatParams = @{
            Uri         = $uri
            Headers     = $headers
            Method      = 'GET'
            ContentType = 'application/json; charset=utf-8'
            Verbose     = $false
            ErrorAction = "Stop"
        }
        $response = Invoke-RestMethod @getGroupsSplatParams
        $entraIDGroups += $response.value
        Write-Information "Successfully queried [$($entraIDGroups.count)] existing groups"
        $uri = $response.'@odata.nextLink'
    } while ($uri)

    # Using the Batch API to retrieve group members for all groups in batches of 20 (https://learn.microsoft.com/en-us/graph/json-batching)
    $actionMessage = "querying group members"
    $entraIDGroupsMembersRequests = @(foreach ($group in $entraIDGroups) {
        @{
            Method = 'GET'
            Uri    = "/groups/$($group.id)/members?`$select=id&`$top=999"
        }
    })
    $entraIDGroupsMembers = Invoke-MSEntraBatchRequest -Requests $entraIDGroupsMembersRequests -Headers $headers

    for ($groupIndex = 0; $groupIndex -lt $entraIDGroups.Count; $groupIndex++) {
        $entraIDGroup = $entraIDGroups[$groupIndex]
        $entraIDGroupMembers = @($entraIDGroupsMembers[$groupIndex] | Where-Object { $_.'@odata.type' -eq "#microsoft.graph.user" -and $_.id -ne $actionContext.Configuration.ownerGuid })
        $numberOfAccounts = $(($entraIDGroupMembers | Measure-Object).Count)

        # Make sure the displayName has a value of max 100 char
        if (-not([string]::IsNullOrEmpty($entraIDGroup.displayName))) {
            $displayName = $($entraIDGroup.displayName).substring(0, [System.Math]::Min(100, $($entraIDGroup.displayName).Length))
        }
        else {
            $displayName = $entraIDGroup.id
        }

        $permission = @{
            PermissionReference      = @{
                Reference = $permissionReference
            }       
            DisplayName              = "$permissionDisplayName"
            Description              = "$permissionDisplayName"
            SubPermissionReference   = @{
                Id = $entraIDGroup.id
            }
            SubPermissionDisplayName = $displayName
        }

        # Batch permissions based on the amount of account references, 
        # to make sure the output objects are not above the limit
        $accountsBatchSize = 500
        if ($numberOfAccounts -gt 0) {
            $accountsBatchSize = 500
            $batches = 0..($numberOfAccounts - 1) | Group-Object { [math]::Floor($_ / $accountsBatchSize ) }
            foreach ($batch in $batches) {
                $permission.AccountReferences = [array]($batch.Group | ForEach-Object { @($entraIDGroupMembers[$_].id) })
                Write-Output $permission
            }
        }
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-MS-Entra-ExoError -ErrorObject $ex
        $auditMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
        $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    Write-Warning $warningMessage
    Write-Error $auditMessage
}