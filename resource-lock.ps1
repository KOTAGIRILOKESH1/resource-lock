# Main script to handle lock/unlock operations based on the provided inputs

param(
    [Array]$ManagementGroups = @("Managementgrouptest"),   # Accepts multiple Management Groups
    [Array]$Subscriptions = @("3bc8f069-65c7-4d08-b8de-534c20e56c38"), # Accepts multiple Subscriptions
    [Array]$ResourceGroups = @("linux-VM", "Windows-VM"),  # Accepts multiple Resource Groups
    [Array]$ResourceTypes = @("Microsoft.Web/sites", "Microsoft.Compute/virtualMachines"), # Resource types
    [ValidateSet("lock", "unlock")]
    [string]$LockOption = "unlock"    # Default is "lock", can also be "unlock"
)
function Get-AzAccessTokenValue {
    $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    return $token.Token
}
# Helper function to validate Management Group
function Test-ManagementGroup {
    param([string]$GroupName)
    Write-Host "Validating Management Group via REST API: $GroupName"
 
    $token = Get-AzAccessTokenValue
    $uri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/"+$GroupName+"?api-version=2020-05-01"
 
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ Authorization = "Bearer $token" }
        Write-Host "Management Group $GroupName is valid."
        return $true
    } catch {
        Write-Host "Management Group $GroupName does not exist or is inaccessible."
        return $false
    }
}

# Helper function to validate Subscription under a specific Management Group
function Test-SubscriptionUnderMG {
    param(
        [string]$SubscriptionId,
        [string]$ManagementGroupName
    )
 
    Write-Host "Validating if Subscription $SubscriptionId is part of Management Group $ManagementGroupName via REST API"
 
    $token = Get-AzAccessTokenValue
    $uri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupName/subscriptions?api-version=2020-05-01"
 
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ Authorization = "Bearer $token" }
        $subscriptions = $response.value | ForEach-Object { $_.name }
 
        if ($subscriptions -contains $SubscriptionId) {
            Write-Host "Subscription $SubscriptionId is part of Management Group $ManagementGroupName."
            return $true
        } else {
            Write-Host "Subscription $SubscriptionId is NOT part of Management Group $ManagementGroupName."
            return $false
        }
    } catch {
        Write-Host "Failed to validate subscription $SubscriptionId under Management Group $ManagementGroupName."
        return $false
    }
}

# Helper function to validate Subscription (for Case 3 - without MG)
function Test-Subscription {
    param([string]$SubscriptionId)
    Write-Host "Validating Subscription: $SubscriptionId"
    
    # Check if Subscription exists using Azure CLI
    $subExists = az account subscription show --subscription $SubscriptionId --output tsv
    if ($subExists) {
        Write-Host "Subscription $SubscriptionId is valid."
        return $true
    } else {
        Write-Host "Subscription $SubscriptionId does not exist."
        return $false
    }
}

# Helper function to validate Resource Group
function Test-ResourceGroup {
    param([string]$ResourceGroupName, [string]$SubscriptionId)
    Write-Host "Validating Resource Group: $ResourceGroupName under Subscription: $SubscriptionId"
    
    # Check if Resource Group exists using Azure CLI
    $rgExists = az group show --name $ResourceGroupName --subscription $SubscriptionId --output tsv
    if ($rgExists) {
        Write-Host "Resource Group $ResourceGroupName exists under Subscription $SubscriptionId."
        return $true
    } else {
        Write-Host "Resource Group $ResourceGroupName does not exist under Subscription $SubscriptionId."
        return $false
    }
}

# Helper function to fetch Subscriptions under a Management Group
function Get-SubscriptionsUnderMG {

    param (

        [Parameter(Mandatory = $true)]

        [string]$ManagementGroupName

    )
 
    Write-Host "Fetching subscriptions under Management Group: $ManagementGroupName"
 
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token

    $uri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupName/subscriptions?api-version=2020-05-01"
 
    try {

        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ Authorization = "Bearer $token" }
 
        $subscriptions = $response.value | ForEach-Object {

            [PSCustomObject]@{

                SubscriptionId = $_.name

                DisplayName    = $_.displayName

                State          = $_.properties.state

            }

        }
 
        return $subscriptions

    } catch {

        Write-Error "Failed to get subscriptions under Management Group '$ManagementGroupName'. $_"

        return @()

    }

}

 

# Helper function to fetch Resource Groups under a Subscription
function Get-ResourceGroupsUnderSubscription {
    param([string]$SubscriptionId)
    
    Write-Host "Fetching Resource Groups under Subscription: $SubscriptionId"
    
    # Fetch resource groups under the given Subscription using Azure CLI
    $resourceGroups = az group list --subscription $SubscriptionId --query "[].name" -o tsv
    return $resourceGroups
}

# Helper function to lock/unlock resources (deletion lock)
function LockUnlock-Resources {
    param(
        [Array]$Subscriptions,
        [Array]$ResourceGroups,
        [Array]$ResourceTypes,
        [string]$LockOption  # "lock" to apply lock, "unlock" to remove lock
    )
 
    Write-Host "$LockOption operation on resources under subscriptions: $Subscriptions, resource groups: $ResourceGroups, and resource types: $ResourceTypes"
 
    foreach ($subscription in $Subscriptions) {
        Set-AzContext -SubscriptionId $subscription
 
        foreach ($rg in $ResourceGroups) {
            foreach ($resourceType in $ResourceTypes) {
                Write-Host "Processing $LockOption for Subscription: $subscription, Resource Group: $rg, Resource Type: $resourceType"
 
                # List all resources of this type in the resource group
                $resources = Get-AzResource -ResourceGroupName $rg | Where-Object { $_.ResourceType -eq $resourceType }
 
                foreach ($resource in $resources) {
                    $resourceScope = "/subscriptions/$subscription/resourceGroups/$rg/providers/$resourceType/$($resource.Name)"
                    Write-Host "Resource Scope: $resourceScope"
 
                    if ($LockOption -eq "lock") {
                        Write-Host "Applying deletion lock to resource: $($resource.Name)"
                        # Apply deletion lock using Azure CLI
                        $lockCommand = "az resource lock create --lock-type CanNotDelete --name 'Deletion Lock' --resource $resourceScope"
                        Write-Host "Executing command: $lockCommand"
                        Invoke-Expression $lockCommand
                    }
                    elseif ($LockOption -eq "unlock") {
                        Write-Host "Removing deletion lock from resource: $($resource.Name)"
                        # Get the resource lock ID to remove
                        $lockId = az lock list --resource $resource.name --resource-type $resource.Resourcetype --resource-group $resource.ResourceGroupName | ConvertFrom-Json
 
                        if ($lockId) {
                            # Remove the deletion lock using Azure CLI
                            $removeLockCommand = "az lock delete --name 'Deletion Lock' --resource-group $resource.ResourceGroupName --resource $resource.name --resource-type $resource.Resourcetype"
                            Write-Host "Executing command: $removeLockCommand"
                            Invoke-Expression $removeLockCommand
                        }
                        else {
                            Write-Host "No deletion lock found for resource: $($resource.Name)"
                        }
                    }
                    else {
                        Write-Host "Invalid LockOption. Use 'lock' or 'unlock'."
                    }
                }
            }
        }
    }
}
# Case 1: All inputs (Management Group, Subscriptions, Resource Groups, Resource Types) are given
if ($ManagementGroups -and $Subscriptions -and $ResourceGroups -and $ResourceTypes) {
    # Validate Management Groups
    foreach ($mg in $ManagementGroups) {
        $mgValidation = Test-ManagementGroup -GroupName $mg
        if (-not $mgValidation) {
            Write-Host "Invalid Management Group: $mg"
            exit
        }

        # Validate Subscriptions under the Management Group
        foreach ($subscription in $Subscriptions) {
            $subValidation = Test-SubscriptionUnderMG -SubscriptionId $subscription -ManagementGroupName $mg
            if (-not $subValidation) {
                Write-Host "Subscription $subscription is not part of Management Group $mg"
                exit
            }
        }

        # Validate Resource Groups
        foreach ($rg in $ResourceGroups) {
            $rgValidation = Test-ResourceGroup -ResourceGroupName $rg -SubscriptionId $subscription
            if (-not $rgValidation) {
                Write-Host "Invalid Resource Group $rg"
                exit
            }
        }

        # Proceed to lock/unlock resources
        LockUnlock-Resources -Subscriptions $Subscriptions -ResourceGroups $ResourceGroups -ResourceTypes $ResourceTypes -LockOption $LockOption
    }
}

# Case 2: Only Management Groups are given (without subscriptions and resource groups)
elseif ($ManagementGroups -and -not $Subscriptions -and -not $ResourceGroups) {
    foreach ($mg in $ManagementGroups) {
        # Fetch subscriptions under the Management Group
        $subscriptions = Get-SubscriptionsUnderMG -ManagementGroup $mg

        # Validate Subscriptions under the Management Group
        foreach ($subscription in $subscriptions) {
            $subValidation = Test-SubscriptionUnderMG -SubscriptionId $subscription -ManagementGroupName $mg
            if (-not $subValidation) {
                Write-Host "Subscription $subscription is not part of Management Group $mg"
                exit
            }

            # Fetch Resource Groups under the Subscription
            $resourceGroups = Get-ResourceGroupsUnderSubscription -SubscriptionId $subscription

            # Validate Resource Groups
            foreach ($rg in $resourceGroups) {
                $rgValidation = Test-ResourceGroup -ResourceGroupName $rg -SubscriptionId $subscription
                if (-not $rgValidation) {
                    Write-Host "Invalid Resource Group $rg"
                    exit
                }
            }

            # Proceed to lock/unlock resources
            LockUnlock-Resources -Subscriptions @($subscription) -ResourceGroups $resourceGroups -ResourceTypes $ResourceTypes -LockOption $LockOption
        }
    }
}

# Case 3: Only Subscription(s) and Resource Group(s) are given (Management Groups empty)
elseif (-not $ManagementGroups -and $Subscriptions -and $ResourceGroups) {
    # Validate Subscriptions
    foreach ($subscription in $Subscriptions) {
        $subValidation = Test-Subscription -SubscriptionId $subscription
        if (-not $subValidation) {
            Write-Host "Invalid Subscription $subscription"
            exit
        }
    }

    # Validate Resource Groups
    foreach ($rg in $ResourceGroups) {
        $rgValidation = Test-ResourceGroup -ResourceGroupName $rg -SubscriptionId $subscription
        if (-not $rgValidation) {
            Write-Host "Invalid Resource Group $rg"
            exit
        }
    }

    # Proceed to lock/unlock resources
    LockUnlock-Resources -Subscriptions $Subscriptions -ResourceGroups $ResourceGroups -ResourceTypes $ResourceTypes -LockOption $LockOption
}

else {
    Write-Host "Invalid input. Please provide the necessary parameters."
    exit
}
