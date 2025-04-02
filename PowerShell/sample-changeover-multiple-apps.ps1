[CmdletBinding()] param ()
# Filename:    sample-changeover-multiple-apps.ps1
# Description:  Sample PSh script for changing claims provider for an AD FS connected application when there is no network connectivity to a specific endpoint, customize for your own use.
#               This sample is provided **AS-IS** without support.This is part of the Microsoft Entra ID resilience for federated apps tutorial.
#
# DISCLAIMER:
# Copyright (c) Microsoft Corporation. All rights reserved. This
# script is made available to you without any express, implied or
# statutory warranty, not even the implied warranty of
# merchantability or fitness for a particular purpose, or the
# warranty of title or non-infringement. The entire risk of the
# use or the results from the use of this script remains with you.
#


# Ensure that you have already registered the source by using the cmdlet
# New-EventLog -LogName Application -Source "AD FS changeover script"
$EventLogSource = "AD FS changeover script"
$EventLogName = 'Application'

# These should match the list of claims providers in AD FS
$ClaimsProviderNormal = "Microsoft Entra"
$ClaimsProviderFailover = "Active Directory"

# This list of applications should match the name of the relying party application in AD FS
$ApplicationNames = @()
$ApplicationNames += "sampleapp"

$TargetUriEntra = "https://login.microsoftonline.com"

try {
    $EAP = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    Write-Debug "locating claims provider $ClaimsProviderNormal"
    # confirm that the providers are present
    $p = Get-AdfsClaimsProviderTrust -Name $ClaimsProviderNormal
    if ($null -eq $p) {
        throw "Claims provider $ClaimsProviderNormal not found"
    }
    write-Debug "locating claims provider $ClaimsProviderFailover"
    $p = Get-AdfsClaimsProviderTrust -Name $ClaimsProviderFailover
    if ($null -eq $p) {
        throw "Claims provider $ClaimsProviderFailover not found"
    }

    foreach ($ApplicationName in $ApplicationNames) {

        write-Debug "locating application $ApplicationName"
        # confirm that the relying party trust for the application is present
        $t = Get-AdfsRelyingPartyTrust -Name $ApplicationName
        if ($null -eq $t) {
            throw "Relying party trust $ApplicationName not found"
        }
        $CurrentClaimsProviderName = $t.ClaimsProviderName
        Write-Debug "current claims provider for Application is $CurrentClaimsProviderName"
        if ($CurrentClaimsProviderName -eq $ClaimsProviderFailover -or $CurrentClaimsProviderName -match $ClaimsProviderFailover) {
            Write-Debug "current claims provider for Application $ApplicationName is already set to include $ClaimsProviderFailover"

            Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 2 -Message "Relying party trust $ApplicationName claims provider currently set to $CurrentClaimsProviderName"
            # note that this sample does not perform failback from the failover provider to the normal operations provider
        
        } else {
            try {
                Write-Debug "about to contact $TargetUriEntra"
                # -SkipHttpErrorCheck -SkipCertificateCheck are not available in PowerShell 5.1
                $Result = Invoke-WebRequest -Uri $TargetUriEntra -Method Post 
                $StatusCode = $Result.StatusCode
                Write-Debug "HTTP result is $StatusCode"
                if ($StatusCode -eq 200) {
                    Write-Debug "Successfully reached $TargetUriEntra"
                    # do nothing, the normal claims provider is already set
            
                } else {
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Warning -EventId 3 -Message "Received HTTP status code $StatusCode from $TargetUriEntra, but not changing claims provider for $ApplicationName"
                }
            } catch {
                Write-Debug "failed to connect $_"
                # if a status code is received, assume it is reachable
                $StatusCode = $_.Exception.Response.StatusCode.value__
                if ($null -ne $StatusCode) {
                    Write-Debug "HTTP result is $StatusCode"
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Warning -EventId 3 -Message "Received HTTP status code $StatusCode from $TargetUriEntra, but not changing claims provider for $ApplicationName"
                } else {
                    # if the endpoint is not reachable, set the claims provider to the failover provider
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 4 -Message "Failed to reach $TargetUriEntra due to $_, setting claims provider for $ApplicationName to $ClaimsProviderFailover"
                    Write-Debug "about to set failover claims provider $ClaimsProviderFailover"
                    Set-AdfsRelyingPartyTrust -TargetName $ApplicationName -ClaimsProviderName $ClaimsProviderFailover
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Warning -EventId 5 -Message "Failed to reach $TargetUriEntra, set claims provider for $ApplicationName to $ClaimsProviderFailover"
                }
            }
        }

    }

    Write-Debug "completed"

} catch {
    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 1 -Message $_
    Write-Error @_
} finally {
    $ErrorActionPreference = $EAP
}
