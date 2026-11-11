#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Unit tests for the Microsoft Graph batch / retry helpers that are embedded in the import scripts.

    HelloID scripts must be self-contained, so every import script carries its own copy of
    Invoke-MSEntraBatchRequest. These tests extract the function definitions from each script
    (without executing the script itself) and run the same scenarios against every copy.

    Invoke-RestMethod is replaced by an in-memory fake of Microsoft Graph that can be told to
    throttle (429) or fail (5xx) specific sub-requests, the $batch call itself, or pagination calls.
#>

BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $scriptsWithBatchFunction = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
        Where-Object { (Get-Content -Path $_.FullName -Raw) -match '(?m)^function Invoke-MSEntraBatchRequest' } |
        Sort-Object FullName

    $script:connectorScripts = foreach ($file in $scriptsWithBatchFunction) {
        @{
            Path = $file.FullName
            Name = $file.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
        }
    }
}

BeforeAll {
    function Get-ConnectorFunctionDefinition {
        # Returns the source of all top-level functions in a connector script, without running the script
        param([string] $Path)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "Parse errors in [$Path]: $($parseErrors -join '; ')"
        }
        $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        ($functions | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    }

    if (-not ('FakeWebException' -as [type])) {
        # Mimics the shape of the error Windows PowerShell 5.1 throws (WebException with an HttpWebResponse),
        # which is also the fallback code path in the connector for any non-HttpResponseMessage response.
        Add-Type -TypeDefinition @'
public class FakeHttpResponse
{
    public System.Net.HttpStatusCode StatusCode;
    public System.Net.WebHeaderCollection Headers = new System.Net.WebHeaderCollection();
}
public class FakeWebException : System.Exception
{
    public FakeHttpResponse Response;
    public FakeWebException(string message, FakeHttpResponse response) : base(message)
    {
        Response = response;
    }
}
'@
    }

    function New-FakeWebException {
        param([int] $StatusCode, [string] $RetryAfter)
        $response = [FakeHttpResponse]::new()
        $response.StatusCode = [System.Net.HttpStatusCode]$StatusCode
        if ($RetryAfter) {
            $response.Headers.Add('Retry-After', $RetryAfter)
        }
        [FakeWebException]::new("The remote server returned an error: ($StatusCode).", $response)
    }

    function New-HttpResponseException {
        # The error PowerShell 7 throws for a non-success status code
        param([int] $StatusCode, [int] $RetryAfterSeconds)
        $message = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
        if ($RetryAfterSeconds) {
            $message.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds($RetryAfterSeconds))
        }
        [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $StatusCode.", $message)
    }

    function New-TestRequest {
        param([int] $Count)
        @(for ($n = 0; $n -lt $Count; $n++) {
                @{ Method = 'GET'; Uri = "/groups/group-$n/members?`$select=id&`$top=999" }
            })
    }

    function Get-ExpectedMemberId {
        param([int] $Index)
        "member-of-/groups/group-$Index/members?`$select=id&`$top=999"
    }

    function Reset-FakeGraph {
        $script:FakeGraph = @{
            # key (relative sub-request url, or absolute url for direct calls) -> queue of status codes to return
            Plan             = @{}
            RetryAfter       = @{}
            # relative sub-request url -> nextLink returned in its first page
            NextLinks        = @{}
            # absolute url -> page object returned for that url
            Pages            = @{}
            # exceptions thrown by the $batch POST before it is processed
            BatchFailures    = [System.Collections.Generic.Queue[object]]::new()
            ReverseResponses = $false
            Calls            = [System.Collections.Generic.List[object]]::new()
        }
    }

    function Set-FakeStatus {
        param([string] $Key, [int[]] $Status, [string] $RetryAfter)
        $queue = [System.Collections.Generic.Queue[int]]::new()
        foreach ($s in $Status) { $queue.Enqueue($s) }
        $script:FakeGraph.Plan[$Key] = $queue
        if ($RetryAfter) {
            $script:FakeGraph.RetryAfter[$Key] = $RetryAfter
        }
    }

    function Get-NextFakeStatus {
        param([string] $Key)
        $queue = $script:FakeGraph.Plan[$Key]
        if ($null -ne $queue -and $queue.Count -gt 0) {
            return $queue.Dequeue()
        }
        return 200
    }

    function Invoke-FakeGraph {
        param($Method, $Uri, $Body)
        $uriString = "$Uri"

        if ($uriString -like '*/$batch') {
            $batch = $Body | ConvertFrom-Json
            $script:FakeGraph.Calls.Add([pscustomobject]@{
                    Kind     = 'batch'
                    Uri      = $uriString
                    Requests = @($batch.requests)
                })
            if ($script:FakeGraph.BatchFailures.Count -gt 0) {
                throw $script:FakeGraph.BatchFailures.Dequeue()
            }

            $responses = [System.Collections.Generic.List[object]]::new()
            foreach ($request in @($batch.requests)) {
                $status = Get-NextFakeStatus -Key $request.url
                if ($status -eq 200) {
                    $body = [ordered]@{ value = @([pscustomobject]@{ id = "member-of-$($request.url)" }) }
                    if ($script:FakeGraph.NextLinks.ContainsKey($request.url)) {
                        $body['@odata.nextLink'] = $script:FakeGraph.NextLinks[$request.url]
                    }
                    $responses.Add([pscustomobject]@{ id = $request.id; status = 200; headers = [pscustomobject]@{}; body = [pscustomobject]$body })
                }
                else {
                    $headers = [ordered]@{}
                    if ($script:FakeGraph.RetryAfter.ContainsKey($request.url)) {
                        $headers['Retry-After'] = $script:FakeGraph.RetryAfter[$request.url]
                    }
                    $responses.Add([pscustomobject]@{
                            id      = $request.id
                            status  = $status
                            headers = [pscustomobject]$headers
                            body    = [pscustomobject]@{ error = [pscustomobject]@{ code = "Status$status"; message = "Simulated HTTP $status" } }
                        })
                }
            }
            $responseArray = $responses.ToArray()
            if ($script:FakeGraph.ReverseResponses) {
                [array]::Reverse($responseArray)
            }
            return [pscustomobject]@{ responses = $responseArray }
        }

        $script:FakeGraph.Calls.Add([pscustomobject]@{ Kind = 'direct'; Uri = $uriString; Requests = @() })
        $status = Get-NextFakeStatus -Key $uriString
        if ($status -ne 200) {
            throw (New-FakeWebException -StatusCode $status -RetryAfter $script:FakeGraph.RetryAfter[$uriString])
        }
        if (-not $script:FakeGraph.Pages.ContainsKey($uriString)) {
            throw "Fake Graph has no page for [$uriString]"
        }
        return $script:FakeGraph.Pages[$uriString]
    }

    $script:headers = @{ Authorization = 'Bearer fake-token'; Accept = 'application/json' }
}

Describe 'Invoke-MSEntraBatchRequest in <Name>' -ForEach $connectorScripts {
    BeforeAll {
        . ([scriptblock]::Create((Get-ConnectorFunctionDefinition -Path $Path)))
    }

    BeforeEach {
        Reset-FakeGraph
        Mock Invoke-RestMethod { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body }
        Mock Start-Sleep {}
        Mock Write-Warning {}
    }

    Context 'Successful responses' {
        It 'returns an empty hashtable and makes no requests when there are no requests' {
            $result = Invoke-MSEntraBatchRequest -Requests @() -Headers $headers

            $result.Count | Should -Be 0
            $script:FakeGraph.Calls.Count | Should -Be 0
        }

        It 'splits requests into batches of at most 20' {
            $result = Invoke-MSEntraBatchRequest -Requests (New-TestRequest -Count 45) -Headers $headers

            $batchSizes = @($script:FakeGraph.Calls | ForEach-Object { $_.Requests.Count })
            $batchSizes | Should -Be @(20, 20, 5)
            $result.Count | Should -Be 45
        }

        It 'maps every result to the index of its request, even when Graph returns responses out of order' {
            $script:FakeGraph.ReverseResponses = $true

            $result = Invoke-MSEntraBatchRequest -Requests (New-TestRequest -Count 25) -Headers $headers

            for ($n = 0; $n -lt 25; $n++) {
                @($result[$n]).id | Should -Be (Get-ExpectedMemberId -Index $n)
            }
        }

        It 'follows @odata.nextLink and concatenates all pages' {
            $requests = New-TestRequest -Count 2
            $page2 = 'https://graph.microsoft.com/v1.0/groups/group-1/members?$skiptoken=page2'
            $script:FakeGraph.NextLinks[$requests[1].Uri] = $page2
            $script:FakeGraph.Pages[$page2] = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'second-page-member' }) }

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            @($result[1]).id | Should -Be @((Get-ExpectedMemberId -Index 1), 'second-page-member')
        }
    }

    Context 'Throttled or transiently failing sub-requests' {
        It 'retries a throttled (429) sub-request and returns its data instead of an empty result' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[3].Uri -Status 429 -RetryAfter '7'

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            @($result[3]).id | Should -Be (Get-ExpectedMemberId -Index 3)
            for ($n = 0; $n -lt 5; $n++) {
                @($result[$n]).Count | Should -Be 1 -Because "request [$n] must not come back empty"
            }
        }

        It 'only resends the sub-requests that failed' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[3].Uri -Status 429 -RetryAfter '7'

            $null = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            $script:FakeGraph.Calls.Count | Should -Be 2
            @($script:FakeGraph.Calls[1].Requests).url | Should -Be @($requests[3].Uri)
        }

        It 'waits for the Retry-After value of the throttled sub-request' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[3].Uri -Status 429 -RetryAfter '7'

            $null = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
        }

        It 'waits for the longest Retry-After when several sub-requests are throttled' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[1].Uri -Status 429 -RetryAfter '3'
            Set-FakeStatus -Key $requests[4].Uri -Status 429 -RetryAfter '11'

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 11 }
            @($result[1]).Count | Should -Be 1
            @($result[4]).Count | Should -Be 1
        }

        It 'retries a sub-request that returns HTTP <_> using exponential backoff when there is no Retry-After' -ForEach @(500, 502, 503, 504) {
            $requests = New-TestRequest -Count 3
            Set-FakeStatus -Key $requests[0].Uri -Status $_, $_

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            @($result[0]).id | Should -Be (Get-ExpectedMemberId -Index 0)
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
        }

        It 'throws instead of returning incomplete data when a sub-request stays throttled' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[2].Uri -Status (@(429) * 50) -RetryAfter '1'

            { Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers } | Should -Throw
        }

        It 'gives up after the default of 5 retries' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[2].Uri -Status (@(429) * 50) -RetryAfter '1'

            { Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers } | Should -Throw

            $script:FakeGraph.Calls.Count | Should -Be 6
        }

        It 'respects -MaxRetries' {
            $requests = New-TestRequest -Count 5
            Set-FakeStatus -Key $requests[2].Uri -Status (@(429) * 50) -RetryAfter '1'

            { Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers -MaxRetries 2 } | Should -Throw

            $script:FakeGraph.Calls.Count | Should -Be 3
        }

        It 'keeps processing later batches after a retry succeeds' {
            $requests = New-TestRequest -Count 45
            Set-FakeStatus -Key $requests[0].Uri -Status 429 -RetryAfter '1'
            Set-FakeStatus -Key $requests[44].Uri -Status 503

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            for ($n = 0; $n -lt 45; $n++) {
                @($result[$n]).id | Should -Be (Get-ExpectedMemberId -Index $n)
            }
        }
    }

    Context 'Throttled $batch call' {
        It 'retries the whole batch when the $batch call returns 429 and honors Retry-After (Windows PowerShell error shape)' {
            $script:FakeGraph.BatchFailures.Enqueue((New-FakeWebException -StatusCode 429 -RetryAfter '9'))

            $result = Invoke-MSEntraBatchRequest -Requests (New-TestRequest -Count 3) -Headers $headers

            $result.Count | Should -Be 3
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 9 }
        }

        It 'retries the whole batch when the $batch call returns 429 and honors Retry-After (PowerShell 7 error shape)' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
            $script:FakeGraph.BatchFailures.Enqueue((New-HttpResponseException -StatusCode 429 -RetryAfterSeconds 13))

            $result = Invoke-MSEntraBatchRequest -Requests (New-TestRequest -Count 3) -Headers $headers

            $result.Count | Should -Be 3
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 13 }
        }

        It 'retries the whole batch when the $batch call returns 503' {
            $script:FakeGraph.BatchFailures.Enqueue((New-FakeWebException -StatusCode 503))

            $result = Invoke-MSEntraBatchRequest -Requests (New-TestRequest -Count 3) -Headers $headers

            $result.Count | Should -Be 3
        }

        It 'does not retry a non-transient error from the $batch call' {
            $script:FakeGraph.BatchFailures.Enqueue((New-FakeWebException -StatusCode 400))

            { Invoke-MSEntraBatchRequest -Requests (New-TestRequest -Count 3) -Headers $headers } | Should -Throw

            $script:FakeGraph.Calls.Count | Should -Be 1
        }
    }

    Context 'Throttled pagination' {
        It 'retries a throttled @odata.nextLink call' {
            $requests = New-TestRequest -Count 2
            $page2 = 'https://graph.microsoft.com/v1.0/groups/group-0/members?$skiptoken=page2'
            $script:FakeGraph.NextLinks[$requests[0].Uri] = $page2
            $script:FakeGraph.Pages[$page2] = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'second-page-member' }) }
            Set-FakeStatus -Key $page2 -Status 429 -RetryAfter '5'

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            @($result[0]).id | Should -Be @((Get-ExpectedMemberId -Index 0), 'second-page-member')
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'throws when a @odata.nextLink call stays throttled' {
            $requests = New-TestRequest -Count 1
            $page2 = 'https://graph.microsoft.com/v1.0/groups/group-0/members?$skiptoken=page2'
            $script:FakeGraph.NextLinks[$requests[0].Uri] = $page2
            $script:FakeGraph.Pages[$page2] = [pscustomobject]@{ value = @() }
            Set-FakeStatus -Key $page2 -Status (@(429) * 50) -RetryAfter '1'

            { Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers } | Should -Throw
        }
    }

    Context 'Non-transient sub-request errors' {
        It 'keeps the existing behavior for HTTP 404: a warning, an empty result and no retry' {
            $requests = New-TestRequest -Count 3
            Set-FakeStatus -Key $requests[1].Uri -Status 404

            $result = Invoke-MSEntraBatchRequest -Requests $requests -Headers $headers

            @($result[1]).Count | Should -Be 0
            @($result[0]).Count | Should -Be 1
            $script:FakeGraph.Calls.Count | Should -Be 1
            Should -Invoke Write-Warning -Times 1 -Exactly
        }
    }
}

Describe 'Get-MSEntraRetryDelay' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $path = Get-ChildItem -Path $repoRoot -Recurse -Filter 'importPermission.ps1' | Where-Object { $_.FullName -match '[\\/]groups[\\/]' } | Select-Object -First 1
        . ([scriptblock]::Create((Get-ConnectorFunctionDefinition -Path $path.FullName)))
    }

    It 'uses a Retry-After value in seconds' {
        Get-MSEntraRetryDelay -RetryAfter '17' -Attempt 1 | Should -Be 17
    }

    It 'uses a Retry-After TimeSpan' {
        Get-MSEntraRetryDelay -RetryAfter ([TimeSpan]::FromSeconds(21)) -Attempt 1 | Should -Be 21
    }

    It 'uses a Retry-After HTTP-date' {
        $date = [DateTimeOffset]::UtcNow.AddSeconds(30).ToString('r', [System.Globalization.CultureInfo]::InvariantCulture)
        Get-MSEntraRetryDelay -RetryAfter $date -Attempt 1 | Should -BeIn (28..31)
    }

    It 'waits at least one second' {
        Get-MSEntraRetryDelay -RetryAfter '0' -Attempt 1 | Should -Be 1
    }

    It 'falls back to exponential backoff without Retry-After' {
        @(1, 2, 3, 4) | ForEach-Object { Get-MSEntraRetryDelay -RetryAfter $null -Attempt $_ } | Should -Be @(2, 4, 8, 16)
    }

    It 'caps the exponential backoff' {
        Get-MSEntraRetryDelay -RetryAfter $null -Attempt 10 | Should -Be 60
    }
}
