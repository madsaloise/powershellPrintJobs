param (
    [string]$RefactorLogPath = "E:\BI-Warehouse\DWH\dwh.refactorlog",
    [string]$AfterDate = "01/01/2026",   # dd/MM/yyyy
    [string]$BeforeDate = "31/12/2026",  # dd/MM/yyyy
    [string]$outputFileName = "C:\Users\b119820\Desktop\refactorlogoversigt.md"
)

if (-not (Test-Path $RefactorLogPath)) {
    throw "dwh.refactorlog not found at path: $RefactorLogPath"
}

# Parse dates
$startDate = [DateTime]::ParseExact($AfterDate, 'dd/MM/yyyy', $null)
$endDate = [DateTime]::ParseExact($BeforeDate, 'dd/MM/yyyy', $null)

# Load XML with namespace
[xml]$xml = Get-Content $RefactorLogPath
$ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$ns.AddNamespace("d", "http://schemas.microsoft.com/sqlserver/dac/Serialization/2012/02")

# Function to normalize names (remove brackets, keep full path)
function Get-NormalizedName {
    param([string]$name)
    if ([string]::IsNullOrEmpty($name)) { return $null }
    
    # Remove all brackets and trim
    $cleaned = $name -replace '\[|\]', ''
    $cleaned = $cleaned.Trim('.')
    
    return $cleaned
}

# Parse all operations within date range
$operations = $xml.SelectNodes("//d:Operation", $ns) | ForEach-Object {
    $changeDate = [datetime]::ParseExact($_.ChangeDateTime, "MM/dd/yyyy HH:mm:ss", $null)
    
    if ($changeDate -ge $startDate -and $changeDate -le $endDate) {
        $props = @{}
        foreach ($p in $_.SelectNodes("d:Property", $ns)) {
            $props[$p.Name] = $p.Value
        }
        
        [PSCustomObject]@{
            ChangeDateTime    = $changeDate
            Operation         = $_.Name
            ElementName       = $props["ElementName"]
            ElementType       = $props["ElementType"]
            ParentElementName = $props["ParentElementName"]
            ParentElementType = $props["ParentElementType"]
            NewName           = $props["NewName"]
            NewSchema         = $props["NewSchema"]
            Key               = $_.Key
        }
    }
} | Sort-Object ChangeDateTime

# Build lineage chains
# We'll track what each object's current name is, then build backwards
$chains = @{}  # Key = original name, Value = @{ Current, Operations }

foreach ($op in $operations) {
    if ($op.Operation -eq "Rename Refactor") {
        $oldFull = Get-NormalizedName $op.ElementName
        $newName = Get-NormalizedName $op.NewName
        
        if (-not $oldFull -or -not $newName) { continue }
        
        # Build new full name
        $oldParts = $oldFull -split '\.'
        if ($oldParts.Count -eq 3) {
            # Column: schema.table.column -> schema.table.newColumn
            $newFull = "$($oldParts[0]).$($oldParts[1]).$newName"
        } elseif ($oldParts.Count -eq 2) {
            # Table/Proc: schema.object -> schema.newObject
            $newFull = "$($oldParts[0]).$newName"
        } else {
            # Just name
            $newFull = $newName
        }
        
        # Find the chain this belongs to
        $chainRoot = $null
        foreach ($root in @($chains.Keys)) {
            if ($chains[$root].Current -eq $oldFull) {
                $chainRoot = $root
                break
            }
        }
        
        if (-not $chainRoot) {
            # New chain starts here
            $chainRoot = $oldFull
            $chains[$chainRoot] = @{
                Current = $oldFull
                Operations = @()
                ElementType = $op.ElementType
                ParentType = $op.ParentElementType
            }
        }
        
        # Add operation and update current
        $chains[$chainRoot].Operations += $op
        $chains[$chainRoot].Current = $newFull
        
    } elseif ($op.Operation -eq "Move Schema") {
        $oldFull = Get-NormalizedName $op.ElementName
        $newSchema = $op.NewSchema
        
        if (-not $oldFull -or -not $newSchema) { continue }
        
        # Build new full name with new schema
        $oldParts = $oldFull -split '\.'
        if ($oldParts.Count -eq 2) {
            $newFull = "$newSchema.$($oldParts[1])"
        } elseif ($oldParts.Count -eq 3) {
            $newFull = "$newSchema.$($oldParts[1]).$($oldParts[2])"
        } else {
            $newFull = "$newSchema.$oldFull"
        }
        
        # Find the chain this belongs to
        $chainRoot = $null
        foreach ($root in @($chains.Keys)) {
            if ($chains[$root].Current -eq $oldFull) {
                $chainRoot = $root
                break
            }
        }
        
        if (-not $chainRoot) {
            # New chain starts here
            $chainRoot = $oldFull
            $chains[$chainRoot] = @{
                Current = $oldFull
                Operations = @()
                ElementType = $op.ElementType
                ParentType = $op.ParentElementType
            }
        }
        
        # Add operation and update current
        $chains[$chainRoot].Operations += $op
        $chains[$chainRoot].Current = $newFull
    }
}

# Generate summary
$summary = $chains.GetEnumerator() | ForEach-Object {
    $root = $_.Key
    $chain = $_.Value
    
    if ($chain.Current -ne $root -and $chain.Operations.Count -gt 0) {
        $ops = $chain.Operations
        $renameCount = ($ops | Where-Object { $_.Operation -eq "Rename Refactor" }).Count
        $schemaCount = ($ops | Where-Object { $_.Operation -eq "Move Schema" }).Count
        
        $startParts = $root -split '\.'
        $endParts = $chain.Current -split '\.'
        
        [PSCustomObject]@{
            ElementType       = $chain.ElementType
            ParentType        = $chain.ParentType
            StartSchema       = if ($startParts.Count -ge 2) { $startParts[0] } else { "" }
            StartName         = $root
            EndSchema         = if ($endParts.Count -ge 2) { $endParts[0] } else { "" }
            EndName           = $chain.Current
            TotalRefactors    = $ops.Count
            RenameCount       = $renameCount
            SchemaChangeCount = $schemaCount
            FirstChange       = ($ops | Sort-Object ChangeDateTime | Select-Object -First 1).ChangeDateTime
            LastChange        = ($ops | Sort-Object ChangeDateTime | Select-Object -Last 1).ChangeDateTime
            Operations        = $ops
        }
    }
} | Sort-Object LastChange

# Display to console
Write-Host "`n=== Refactor Lineage Report ===" -ForegroundColor Cyan
Write-Host "Period: $($startDate.ToString('dd/MM/yyyy')) to $($endDate.ToString('dd/MM/yyyy'))" -ForegroundColor Cyan
Write-Host "Total changed elements: $($summary.Count)`n" -ForegroundColor Cyan

$summary | Select-Object ElementType, StartName, EndName, RenameCount, SchemaChangeCount, TotalRefactors, 
    @{N='FirstChange';E={$_.FirstChange.ToString('dd/MM/yyyy')}},
    @{N='LastChange';E={$_.LastChange.ToString('dd/MM/yyyy')}} |
    Format-Table -AutoSize

# Generate Markdown report
$markdown = @"
# Refactor Lineage Report

**Period:** $($startDate.ToString('dd/MM/yyyy')) to $($endDate.ToString('dd/MM/yyyy'))  
**Total Changed Elements:** $($summary.Count)  
**Generated:** $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')

---

## Summary Table

| Element Type | Start Name | End Name | Renames | Schema Changes | Total Refactors | First Change | Last Change |
|-------------|------------|----------|---------|----------------|-----------------|--------------|-------------|
"@

foreach ($item in $summary) {
    $markdown += "`n| $($item.ElementType) | ``$($item.StartName)`` | ``$($item.EndName)`` | $($item.RenameCount) | $($item.SchemaChangeCount) | $($item.TotalRefactors) | $($item.FirstChange.ToString('dd/MM/yyyy')) | $($item.LastChange.ToString('dd/MM/yyyy')) |"
}

# Statistics
$markdown += "`n`n---`n`n## Statistics`n`n"
$markdown += "- **Total Tables Changed:** $(($summary | Where-Object { $_.ElementType -eq 'SqlTable' }).Count)`n"
$markdown += "- **Total Columns Changed:** $(($summary | Where-Object { $_.ElementType -eq 'SqlSimpleColumn' }).Count)`n"
$markdown += "- **Total Procedures Changed:** $(($summary | Where-Object { $_.ElementType -eq 'SqlProcedure' }).Count)`n"
$markdown += "- **Total Rename Operations:** $(($summary | Measure-Object -Property RenameCount -Sum).Sum)`n"
$markdown += "- **Total Schema Move Operations:** $(($summary | Measure-Object -Property SchemaChangeCount -Sum).Sum)`n"

# Detailed changes
$markdown += "`n`n---`n`n## Detailed Changes by Type`n"

$groupedByType = $summary | Group-Object ElementType | Sort-Object Name

foreach ($typeGroup in $groupedByType) {
    $markdown += "`n### $($typeGroup.Name) ($($typeGroup.Count) items)`n"
    
    foreach ($item in ($typeGroup.Group | Sort-Object StartName)) {
        $markdown += "`n#### ``$($item.StartName)`` → ``$($item.EndName)```n`n"
        
        if ($item.StartSchema -ne $item.EndSchema -and $item.StartSchema -and $item.EndSchema) {
            $markdown += "- **Schema Change:** ``$($item.StartSchema)`` → ``$($item.EndSchema)``  `n"
        }
        
        $markdown += "- **Operations:** $($item.TotalRefactors) total ($($item.RenameCount) renames, $($item.SchemaChangeCount) schema moves)  `n"
        $markdown += "- **Period:** $($item.FirstChange.ToString('dd/MM/yyyy HH:mm:ss')) to $($item.LastChange.ToString('dd/MM/yyyy HH:mm:ss'))  `n"
        
        # Transformation chain
        if ($item.Operations.Count -gt 0) {
            $markdown += "`n**Transformation Chain:**`n`n"
            $currentName = $item.StartName
            $markdown += "1. Started as: ``$currentName```n"
            $stepNum = 2
            
            foreach ($rop in ($item.Operations | Sort-Object ChangeDateTime)) {
                if ($rop.Operation -eq "Rename Refactor") {
                    $oldFull = Get-NormalizedName $rop.ElementName
                    $newNamePart = Get-NormalizedName $rop.NewName
                    
                    $parts = $oldFull -split '\.'
                    if ($parts.Count -eq 3) {
                        $currentName = "$($parts[0]).$($parts[1]).$newNamePart"
                    } elseif ($parts.Count -eq 2) {
                        $currentName = "$($parts[0]).$newNamePart"
                    } else {
                        $currentName = $newNamePart
                    }
                    
                    $markdown += "$stepNum. $($rop.ChangeDateTime.ToString('dd/MM/yyyy HH:mm')) - Renamed to ``$currentName```n"
                } else {
                    $parts = $currentName -split '\.'
                    if ($parts.Count -ge 2) {
                        if ($parts.Count -eq 3) {
                            $currentName = "$($rop.NewSchema).$($parts[1]).$($parts[2])"
                        } else {
                            $currentName = "$($rop.NewSchema).$($parts[1])"
                        }
                    } else {
                        $currentName = "$($rop.NewSchema).$currentName"
                    }
                    $markdown += "$stepNum. $($rop.ChangeDateTime.ToString('dd/MM/yyyy HH:mm')) - Schema moved to ``$($rop.NewSchema)`` (now ``$currentName``)`n"
                }
                $stepNum++
            }
        }
        $markdown += "`n"
    }
}

# Save to file
$markdown | Out-File -FilePath $outputFileName -Encoding UTF8
Write-Host "`nReport saved to: $outputFileName" -ForegroundColor Green
