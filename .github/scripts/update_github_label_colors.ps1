# PowerShell script to update GitHub label colors for pvandervelde/RepoRoller
# Requires: GitHub CLI (gh) installed and authenticated
# Colors chosen from ColorBrewer/Colorblind-safe palettes for accessibility

# Label definitions: name, color, description
$labelDefinitions = @(
    @{ Name = "type: feat"; Color = "fcc37b"; Description = "New feature or enhancement" }
    @{ Name = "type: fix"; Color = "fcc37b"; Description = "Bug fix" }
    @{ Name = "type: chore"; Color = "fcc37b"; Description = "Chore or maintenance task" }
    @{ Name = "type: docs"; Color = "fcc37b"; Description = "Documentation change" }
    @{ Name = "type: refactor"; Color = "fcc37b"; Description = "Code refactoring" }
    @{ Name = "type: test"; Color = "fcc37b"; Description = "Test-related change" }
    @{ Name = "type: ci"; Color = "fcc37b"; Description = "Continuous integration or build change" }

    @{ Name = "status: needs-triage"; Color = "64befb"; Description = "Needs triage" }
    @{ Name = "status: in-progress"; Color = "64befb"; Description = "Work in progress" }
    @{ Name = "status: needs-review"; Color = "64befb"; Description = "Needs review" }
    @{ Name = "status: blocked"; Color = "64befb"; Description = "Blocked by another issue or PR" }
    @{ Name = "status: completed"; Color = "64befb"; Description = "Work completed" }

    @{ Name = "prio: high"; Color = "e94648"; Description = "High priority" }
    @{ Name = "prio: medium"; Color = "e94648"; Description = "Medium priority" }
    @{ Name = "prio: low"; Color = "e94648"; Description = "Low priority" }

    @{ Name = "comp: core"; Color = "91c764"; Description = "Core crate (credential-provider-core)" }
    @{ Name = "comp: aws"; Color = "91c764"; Description = "AWS credential adapter" }
    @{ Name = "comp: azure"; Color = "91c764"; Description = "Azure credential adapter" }
    @{ Name = "comp: vault"; Color = "91c764"; Description = "HashiCorp Vault credential adapter" }
    @{ Name = "comp: env"; Color = "91c764"; Description = "Environment variable credential adapter" }
    @{ Name = "comp: caching"; Color = "91c764"; Description = "Credential caching layer" }
    @{ Name = "comp: test-support"; Color = "91c764"; Description = "Test support and mock utilities" }

    @{ Name = "size: XS"; Color = "fecc3e"; Description = "Extra small change" }
    @{ Name = "size: S"; Color = "fecc3e"; Description = "Small change" }
    @{ Name = "size: M"; Color = "fecc3e"; Description = "Medium change" }
    @{ Name = "size: L"; Color = "fecc3e"; Description = "Large change" }
    @{ Name = "size: XL"; Color = "fecc3e"; Description = "Extra large change" }

    @{ Name = "feedback: discussion"; Color = "c8367a"; Description = "Discussion or feedback requested" }
    @{ Name = "feedback: rfc"; Color = "c8367a"; Description = "Request for comments" }
    @{ Name = "feedback: question"; Color = "c8367a"; Description = "Question or clarification needed" }

    @{ Name = "inactive: duplicate"; Color = "d3d8de"; Description = "Duplicate issue or PR" }
    @{ Name = "inactive: wontfix"; Color = "d3d8de"; Description = "Will not fix" }
    @{ Name = "inactive: by-design"; Color = "d3d8de"; Description = "Closed by design" }
)

# Get all current labels from GitHub, handling pagination
function Get-AllLabels
{
    $perPage = 100
    $labels = gh label list --json name --limit $perPage | ConvertFrom-Json
    if ($labels.Count -eq 0)
    {
        break
    }

    $allLabels = @()
    $allLabels += $labels

    return $allLabels | ForEach-Object { $_.name }
}
$currentLabels = Get-AllLabels

# Create or update labels as needed
foreach ($labelDef in $labelDefinitions)
{
    $name = $labelDef.Name
    $color = $labelDef.Color
    $desc = $labelDef.Description

    if ($currentLabels -contains $name)
    {
        Write-Host "Updating label '$name' to color #$color and description '$desc'"
        gh label edit "$name" --color $color --description "$desc"
    }
    else
    {
        Write-Host "Creating label '$name' with color #$color and description '$desc'"
        gh label create "$name" --color $color --description "$desc"
    }
}

# Remove labels not in the desired list
$desiredNames = $labelDefinitions | ForEach-Object { $_.Name }
$labelsToRemove = $currentLabels | Where-Object { $desiredNames -notcontains $_ }
foreach ($label in $labelsToRemove)
{
    Write-Host "Deleting label '$label' (not in desired list)"
    gh label delete "$label" --yes
}
