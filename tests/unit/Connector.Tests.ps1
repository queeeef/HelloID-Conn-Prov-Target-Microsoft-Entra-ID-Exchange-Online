#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Static checks across all connector scripts. These need no network access and no tenant.
#>

BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:allScripts = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
        Sort-Object FullName |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/') } }

    # Helpers that are copied into several scripts and must stay identical everywhere
    $script:sharedFunctions = @(
        'Get-MSEntraRetryDelay'
        'Invoke-MSEntraRestMethodWithRetry'
        'Invoke-MSEntraBatchRequest'
    ) | ForEach-Object { @{ FunctionName = $_ } }
}

BeforeAll {
    function Get-ScriptAst {
        param([string] $Path)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        [pscustomobject]@{ Ast = $ast; Errors = @($parseErrors) }
    }

    function Get-FunctionDefinition {
        param([System.Management.Automation.Language.Ast] $Ast, [string] $Name)
        $Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
    }

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:parsedScripts = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
        ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Ast = (Get-ScriptAst -Path $_.FullName).Ast } }
}

Describe 'Connector script <Name>' -ForEach $allScripts {
    It 'parses without errors' {
        (Get-ScriptAst -Path $Path).Errors | Should -BeNullOrEmpty
    }

    It 'declares no [scriptblock] parameters (blocked by HelloID)' {
        $ast = (Get-ScriptAst -Path $Path).Ast
        $scriptBlockParameters = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ParameterAst] -and
                $node.StaticType -eq [scriptblock]
            }, $true)
        @($scriptBlockParameters).Count | Should -Be 0
    }
}

Describe 'Shared helper <FunctionName>' -ForEach $sharedFunctions {
    It 'is identical in every script that defines it' {
        $definitions = foreach ($parsed in $parsedScripts) {
            foreach ($definition in (Get-FunctionDefinition -Ast $parsed.Ast -Name $FunctionName)) {
                [pscustomobject]@{
                    Path = $parsed.Path
                    Text = ($definition.Extent.Text -replace "`r`n", "`n")
                }
            }
        }
        @($definitions).Count | Should -BeGreaterThan 0
        $distinct = @($definitions | Group-Object -Property Text)
        $distinct.Count | Should -Be 1 -Because "every copy of $FunctionName should be updated together (found $($distinct.Count) variants in: $(($definitions.Path | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))"
    }

    It 'is defined in every script that calls Invoke-MSEntraBatchRequest' {
        foreach ($parsed in $parsedScripts) {
            $usesBatch = @(Get-FunctionDefinition -Ast $parsed.Ast -Name 'Invoke-MSEntraBatchRequest').Count -gt 0
            if ($usesBatch) {
                @(Get-FunctionDefinition -Ast $parsed.Ast -Name $FunctionName).Count | Should -Be 1 -Because "$($parsed.Path) uses Invoke-MSEntraBatchRequest"
            }
        }
    }
}
