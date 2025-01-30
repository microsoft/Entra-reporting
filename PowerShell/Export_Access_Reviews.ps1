# Filename:    Export_Access_Reviews.ps1
# Description: Creates JSON files containing access reviews.  This is part of
#              the Microsoft Entra ID Governance tutorial.
#
# DISCLAIMER:
# Copyright (c) Microsoft Corporation. All rights reserved. This
# script is made available to you without any express, implied or
# statutory warranty, not even the implied warranty of
# merchantability or fitness for a particular purpose, or the
# warranty of title or non-infringement. The entire risk of the
# use or the results from the use of this script remains with you.
#
# Ensure you have the necessary permissions to access Access Reviews data in Microsoft Graph.
#
# Depending on the volume of data, the script's execution time may vary. Monitor the process and adjust parameters as needed.
#
# Regularly update the Microsoft Graph PowerShell module to benefit from the latest features and fixes.
#
#
# Define the root export path
param (
    [Parameter(Mandatory = $true)]
    [string]$ExportFolder,

    [Parameter(Mandatory = $true)]
    [datetime]$InstanceStartDate,

    [Parameter(Mandatory = $true)]
    [datetime]$InstanceEndDate
)

# Ensure the export directory exists
if (-Not (Test-Path -Path $ExportFolder)) {
    New-Item -Path $ExportFolder -ItemType Directory | Out-Null
    Write-Host "Created export folder at $ExportFolder"
}

# Define subfolders
$reviewInstancesFolder = Join-Path -Path $ExportFolder -ChildPath "ReviewInstances"
$reviewDecisionsFolder = Join-Path -Path $ExportFolder -ChildPath "ReviewInstanceDecisionItems"
$reviewContactedReviewersFolder = Join-Path -Path $ExportFolder -ChildPath "ReviewInstanceContactedReviewers"

foreach ($folder in @($reviewInstancesFolder, $reviewDecisionsFolder, $reviewContactedReviewersFolder)) {
    if (-Not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory | Out-Null
        Write-Host "Created folder: $folder"
    }
}

function Flatten-Properties {
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$Object
    )

    $flatObject = @{}

    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Value -is [Array] -or $property.Value -is [Collections.IEnumerable]) {
            # Skip enumerable types or handle them differently if needed
            $flatObject[$property.Name] = $property.Value
        } elseif ($property.Value -ne $null -and `
                 ($property.Value.GetType().IsPrimitive -or `
                $property.Value -is [string] -or `
                $property.Value -is [datetime])) {
            # Treat primitives and specific types as leaf nodes
            $flatObject[$property.Name] = $property.Value
        } elseif ($property.Value -ne $null -and $property.Value.PSObject.Properties.Count -gt 0) {
            # Recursively process complex objects
            $nestedProperties = Flatten-Properties -Object $property.Value
            foreach ($nestedKey in $nestedProperties.Keys) {
                $flatObject["$($property.Name)_$nestedKey"] = $nestedProperties[$nestedKey]
            }
        } else {
            # Directly assign properties that don't fall into other categories
            $flatObject[$property.Name] = $property.Value
        }
    }

    return $flatObject
}

# Function to export data to JSON with pretty formatting
function Export-ToJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [array]$Data
    )
    if ($Data.Count -gt 0) {
        try {
            $json = $Data | ConvertTo-Json -Depth 10 -Compress | Out-String | ConvertFrom-Json | ConvertTo-Json -Depth 10
            Set-Content -Path $Path -Value $json -Encoding UTF8
            Write-Host "Exported data to $Path"
        } catch {
            Write-Host "Error exporting data to $Path $_" -ForegroundColor Red
        }
    } else {
        Write-Host "No data to export for path $Path" -ForegroundColor Yellow
    }
}

# Initialize file counters
$reviewInstancesFileIndex = 1
$reviewDecisionsFileIndex = 1
$reviewContactedReviewersFileIndex = 1

# Buffer size for batching data
$batchSize = 1000

# Global buffers
$globalInstancesBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
$globalDecisionsBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
$globalReviewersBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()

# Function to save batched data
function Save-Batch {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Folder,
        [Parameter(Mandatory = $true)]
        [string]$FilePrefix,
        [Parameter(Mandatory = $true)]
        [array]$Data,
        [Parameter(Mandatory = $true)]
        [int]$Index
    )
    if ($Data.Count -gt 0) {
        try {
            $path = Join-Path -Path $Folder -ChildPath "$($FilePrefix)_$($Index).json"
            Export-ToJson -Path $path -Data $Data
        } catch {
            Write-Host "Error saving batch: $_" -ForegroundColor Red
        }
    }
}

# Helper function to merge dictionaries and handle duplicate keys
function Merge-Dictionaries {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Primary,
        [Parameter(Mandatory = $true)]
        [hashtable]$Secondary,
        [Parameter(Mandatory = $true)]
        [string]$PrimaryPrefix,
        [Parameter(Mandatory = $true)]
        [string]$SecondaryPrefix
    )
    $merged = @{}
    foreach ($key in $Primary.Keys) {
        $newKey = "$($PrimaryPrefix)$($key)"
        $merged[$newKey] = $Primary[$key]
    }
    foreach ($key in $Secondary.Keys) {
        $newKey = "$($SecondaryPrefix)$($key)"
        $merged[$newKey] = $Secondary[$key]
    }
    return $merged
}

# Helper function to process review definitions
function Process-ReviewDefinitions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilterStatus
    )

    $skip = 0
    $top = 100

    Write-Host "Fetching review definitions with status '$FilterStatus'..."

    do {
        $reviewDefinitions = Get-MgIdentityGovernanceAccessReviewDefinition -Filter "status eq '$FilterStatus'" -Skip $skip -Top $top
        $skip += $top

        foreach ($definition in $reviewDefinitions) {
            Write-Host "Processing review definition: $($definition.Id) with status '$FilterStatus'"

            $definitionProperties = Flatten-Properties -Object $definition

            $instanceSkip = 0

            do {
                $instances = Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId $definition.Id -Skip $instanceSkip -Top $top |
                             Where-Object { $_.StartDateTime -ge $InstanceStartDate -and $_.EndDateTime -le $InstanceEndDate }
                $instanceSkip += $top

                foreach ($instance in $instances) {
                    $instanceProperties = Flatten-Properties -Object $instance
                    $mergedRecord = Merge-Dictionaries -Primary $definitionProperties -Secondary $instanceProperties -PrimaryPrefix "ReviewDefinition" -SecondaryPrefix "ReviewInstance"
                    $globalInstancesBuffer.Add([PSCustomObject]$mergedRecord)

                    if ($globalInstancesBuffer.Count -ge $batchSize) {
                        Save-Batch -Folder $reviewInstancesFolder -FilePrefix "ReviewInstances" -Data $globalInstancesBuffer -Index $reviewInstancesFileIndex
                        $globalInstancesBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
                        $reviewInstancesFileIndex = $reviewInstancesFileIndex + 1
                    }

                    # Fetch and process decisions
                    $decisionSkip = 0
                    do {
                        $decisions = Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision -AccessReviewInstanceId $instance.Id -AccessReviewScheduleDefinitionId $definition.Id -Skip $decisionSkip -Top $top
                        $decisionSkip += $top

                        foreach ($decision in $decisions) {
                            $decisionProperties = Flatten-Properties -Object $decision
                            $decisionProperties['AccessReviewInstanceId'] = $instance.Id
                            $decisionProperties['AccessReviewDefinitionId'] = $definition.Id
                            $globalDecisionsBuffer.Add([PSCustomObject]$decisionProperties)

                            if ($globalDecisionsBuffer.Count -ge $batchSize) {
                                Save-Batch -Folder $reviewDecisionsFolder -FilePrefix "ReviewInstanceDecisions" -Data $globalDecisionsBuffer -Index $reviewDecisionsFileIndex
                                $globalDecisionsBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
                                $reviewDecisionsFileIndex = $reviewDecisionsFileIndex+1
                            }
                        }
                    } while ($decisions.Count -eq $top)

                    # Fetch and process contacted reviewers
                    $reviewerSkip = 0
                    do {
                        $reviewers = Get-MgIdentityGovernanceAccessReviewDefinitionInstanceContactedReviewer `
                            -AccessReviewInstanceId $instance.Id `
                            -AccessReviewScheduleDefinitionId $definition.Id `
                            -Skip $reviewerSkip `
                            -Top $top
                        $reviewerSkip += $top

                        foreach ($reviewer in $reviewers) {
                            $reviewerProperties = Flatten-Properties -Object $reviewer
                            $reviewerProperties['AccessReviewInstanceId'] = $instance.Id
                            $reviewerProperties['AccessReviewDefinitionId'] = $definition.Id
                            $globalReviewersBuffer.Add([PSCustomObject]$reviewerProperties)

                            if ($globalReviewersBuffer.Count -ge $batchSize) {
                                Save-Batch -Folder $reviewContactedReviewersFolder -FilePrefix "ReviewInstanceContactedReviewers" -Data $globalReviewersBuffer -Index $reviewContactedReviewersFileIndex
                                $globalReviewersBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
                                $reviewContactedReviewersFileIndex = $reviewContactedReviewersFileIndex + 1
                            }
                        }
                    } while ($reviewers.Count -eq $top)
                }
            } while ($instances.Count -eq $top)
        }
    } while ($reviewDefinitions.Count -eq $top)
}

try {
    # Process InProgress definitions first
    Process-ReviewDefinitions -FilterStatus "InProgress"

    # Then process Completed definitions
    Process-ReviewDefinitions -FilterStatus "Completed"
} catch {
    Write-Host "Error occurred during processing: $_" -ForegroundColor Red
} finally {
    # Ensure all buffers are flushed on termination
    Save-Batch -Folder $reviewInstancesFolder -FilePrefix "ReviewInstances" -Data $globalInstancesBuffer -Index $reviewInstancesFileIndex
    Save-Batch -Folder $reviewDecisionsFolder -FilePrefix "ReviewInstanceDecisions" -Data $globalDecisionsBuffer -Index $reviewDecisionsFileIndex
    Save-Batch -Folder $reviewContactedReviewersFolder -FilePrefix "ReviewInstanceContactedReviewers" -Data $globalReviewersBuffer -Index $reviewContactedReviewersFileIndex
}
