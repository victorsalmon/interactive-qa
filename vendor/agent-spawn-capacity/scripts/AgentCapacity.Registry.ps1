#Requires -Version 7.0
<#
.SYNOPSIS
    Shared registry resolvers for the spawn-capacity scripts.

.DESCRIPTION
    Dot-sourced by AgentCapacity.ps1 (the gate) and Sync-ExecutorDefaults.ps1
    (the projector) so the work-role -> (route, effort) mapping has ONE owner.
    Callers must have defined Get-Prop first.
#>

function Resolve-RouteForWorkRole {
    <#
    .SYNOPSIS
        The route role a pool uses for a work role.
    .DESCRIPTION
        workRoles.<role>.route pins a route; absent, the pool's first route is
        the default (the same rule Resolve-RouteSelection applies at Acquire).
    #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$PoolId, [Parameter(Mandatory)][string]$WorkRole)

    $pool = Get-Prop (Get-Prop $Registry 'pools' @{}) $PoolId
    if ($null -eq $pool) { return '' }
    $workRoles = Get-Prop $pool 'workRoles' @{}
    if ($workRoles.Contains($WorkRole)) {
        $pin = [string](Get-Prop $workRoles[$WorkRole] 'route' '')
        if (-not [string]::IsNullOrWhiteSpace($pin)) { return $pin }
    }
    $routes = @(Get-Prop $pool 'routes' @())
    if ($routes.Count -eq 0) { return '' }
    return [string](Get-Prop $routes[0] 'role' '')
}

function Resolve-RouteEffort {
    <#
    .SYNOPSIS
        The effort ONE ROUTE uses for one work role.
    .DESCRIPTION
        routes[].efforts.<workRole> is authoritative - routes[].thinking remains
        the fallback for a work role the route does not declare. An empty result
        means the harness takes no effort flag at all (Gemini, Devin).
    #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$PoolId, [Parameter(Mandatory)][string]$RouteRole, [Parameter(Mandatory)][string]$WorkRole)

    $pool = Get-Prop (Get-Prop $Registry 'pools' @{}) $PoolId
    if ($null -eq $pool) { return '' }
    foreach ($route in @(Get-Prop $pool 'routes' @())) {
        if ([string](Get-Prop $route 'role' '') -ne $RouteRole) { continue }
        $efforts = Get-Prop $route 'efforts' @{}
        if ($efforts.Contains($WorkRole)) {
            $declared = Get-Prop $efforts $WorkRole $null
            if ($null -ne $declared -and -not [string]::IsNullOrWhiteSpace([string]$declared)) { return [string]$declared }
        }
        return [string](Get-Prop $route 'thinking' '')
    }
    return ''
}

function Resolve-Effort {
    <#
    .SYNOPSIS
        The effort the PREFERRED route uses for a work role.
    .DESCRIPTION
        Convenience for callers that want one answer per work role (the
        projector). Per-route truth is Resolve-RouteEffort.
    #>
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$PoolId, [Parameter(Mandatory)][string]$WorkRole)

    $routeRole = Resolve-RouteForWorkRole -Registry $Registry -PoolId $PoolId -WorkRole $WorkRole
    if (-not $routeRole) { return '' }
    return (Resolve-RouteEffort -Registry $Registry -PoolId $PoolId -RouteRole $routeRole -WorkRole $WorkRole)
}