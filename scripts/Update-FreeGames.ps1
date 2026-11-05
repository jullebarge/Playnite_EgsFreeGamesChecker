#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the EGS free games dataset consumed by the "EGS Free Games checker" Playnite extension.

.DESCRIPTION
    Two modes:

      daily      - Reads Epic Games Store's official freeGamesPromotions endpoint, keeps the free
                   promotions (current + next week) and merges them into the dataset. This is the
                   only mode used by the scheduled GitHub Action.

      reconcile  - Reads the EGData history API (2018 -> now), expands bundles into their component
                   games and merges everything into the dataset. Used once for the initial backfill
                   and then manually to recover from an outage or to expand a detected bundle.

    The merge never removes entries. The dataset is written to data/freeGames.json and copied to
    source/data/freeGames.json (embedded snapshot shipped inside the .pext).

.PARAMETER Mode
    daily or reconcile.

.PARAMETER Ci
    Writes a Markdown summary to $GITHUB_STEP_SUMMARY and emits GitHub annotations.
#>
[CmdletBinding()]
param(
    [ValidateSet('daily', 'reconcile')]
    [string]$Mode = 'daily',

    [string]$RepoRoot,

    [string]$EgsUrl = 'https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?country=US',

    [string]$EgDataBase = 'https://api.egdata.app',

    [int]$MaxPages = 40,

    [switch]$Ci,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

$DataFile = Join-Path $RepoRoot 'data\freeGames.json'
$SnapshotFile = Join-Path $RepoRoot 'source\data\freeGames.json'

$SchemaVersion = 1
$MinimumReconcileEntries = 600
$UserAgent = 'Playnite-EgsFreeGamesChecker-Dataset/0.6'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $Level, $Message
    Write-Host $line
}

function Invoke-JsonRequest {
    param(
        [string]$Uri,
        [int]$Attempts = 3,
        [int]$TimeoutSec = 30
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{
                'User-Agent' = $UserAgent
                'Accept'     = 'application/json'
            }

            # Force UTF-8 decoding: Invoke-WebRequest on PowerShell 5.1 can fall back to
            # ISO-8859-1 when the response has no explicit charset, which mangles accents.
            $bytes = $response.RawContentStream.ToArray()
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            return ($text | ConvertFrom-Json)
        }
        catch {
            if ($attempt -eq $Attempts) { throw }
            Write-Log "Request failed (attempt $attempt/$Attempts): $Uri - $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function ConvertTo-IsoDate {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $dto = [DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return $dto.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-CategoryPaths {
    param($Categories)

    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($category in @($Categories)) {
        if ($null -eq $category) { continue }
        if ($category -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($category)) { $result.Add($category) }
        }
        elseif ($category.PSObject.Properties['path'] -and $category.path) {
            $result.Add([string]$category.path)
        }
    }
    return $result.ToArray()
}

function Test-IsGameCategory {
    param([string[]]$Categories)

    if ($Categories -notcontains 'games') { return $false }
    foreach ($excluded in @('addons', 'bundles', 'games/dlc', 'software', 'spthidden')) {
        if ($Categories -contains $excluded) { return $false }
    }
    return $true
}

function Test-IsBundleCategory {
    param([string[]]$Categories)
    return ($Categories -contains 'bundles')
}

function Get-NormalizedTitle {
    param([string]$Text)

    if ($null -eq $Text) { return '' }

    # Must stay byte-for-byte identical to Clean-Text in EgsFreeGamesChecker.psm1,
    # otherwise existing matches break.
    $Text = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding('ISO-8859-8').GetBytes($Text))
    $Text = $Text -replace '[^a-zA-Z0-9\s]', '' -replace '[:-]', ''
    return $Text.ToLower().Trim()
}

function New-GameEntry {
    param(
        [string]$Title,
        [string]$OfferId,
        [string]$Namespace,
        [string]$StartDate,
        [string]$EndDate,
        [string]$Type,
        [string[]]$Categories,
        [string]$Source,
        [string]$BundleId,
        [string]$BundleTitle
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }

    $entry = [ordered]@{
        title           = $Title
        normalizedTitle = Get-NormalizedTitle $Title
        offerId         = $OfferId
        namespace       = $Namespace
        startDate       = $StartDate
        endDate         = $EndDate
        type            = $Type
        categories      = @($Categories)
        source          = $Source
    }

    if (-not [string]::IsNullOrWhiteSpace($BundleId)) {
        $entry.bundleId = $BundleId
        $entry.bundleTitle = $BundleTitle
    }

    if ($Type -eq 'BUNDLE') {
        $entry.expanded = $false
    }

    return [pscustomobject]$entry
}

function Get-EntryKey {
    param($Entry)

    $title = $Entry.normalizedTitle
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Get-NormalizedTitle ([string]$Entry.title)
    }
    return ('{0}|{1}' -f $title, $Entry.startDate)
}

function Read-Dataset {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            schemaVersion = $SchemaVersion
            generatedAt   = $null
            lastEgsRun    = $null
            backfillId    = $null
            count         = 0
            games         = @()
        }
    }

    $doc = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($doc.schemaVersion -ne $SchemaVersion) {
        throw "Unsupported schemaVersion '$($doc.schemaVersion)' in $Path (expected $SchemaVersion)."
    }
    return $doc
}

function Merge-Entries {
    param(
        [object[]]$Existing,
        [object[]]$New
    )

    $map = [ordered]@{}
    $added = 0

    foreach ($entry in @($Existing)) {
        if ($null -eq $entry) { continue }
        $map[(Get-EntryKey $entry)] = $entry
    }

    foreach ($entry in @($New)) {
        if ($null -eq $entry) { continue }
        $key = Get-EntryKey $entry

        if (-not $map.Contains($key)) {
            $map[$key] = $entry
            $added++
            continue
        }

        # Existing entry wins, except for bundle expansion state: once expanded, stay expanded.
        $current = $map[$key]
        if ($current.type -eq 'BUNDLE' -and $current.expanded -ne $true -and $entry.expanded -eq $true) {
            $current.expanded = $true
        }
    }

    return [pscustomobject]@{
        Entries = @($map.Values | Sort-Object -Property startDate, title)
        Added   = $added
    }
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

function Get-EgsEntries {
    param([string]$Url)

    Write-Log "Fetching EGS promotions: $Url"
    $payload = Invoke-JsonRequest -Uri $Url

    if ($null -eq $payload -or $null -eq $payload.data -or $null -eq $payload.data.Catalog -or $null -eq $payload.data.Catalog.searchStore) {
        throw 'Unexpected EGS payload: data.Catalog.searchStore is missing.'
    }

    $elements = @($payload.data.Catalog.searchStore.elements)
    if ($elements.Count -eq 0) {
        throw 'Unexpected EGS payload: no elements returned.'
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $freePromotions = 0

    foreach ($element in $elements) {
        $categories = Get-CategoryPaths $element.categories
        $isGame = Test-IsGameCategory $categories
        $isBundle = Test-IsBundleCategory $categories

        if (-not $isGame -and -not $isBundle) { continue }

        $foundPromotion = $false

        if ($null -ne $element.promotions) {
            foreach ($groupName in @('promotionalOffers', 'upcomingPromotionalOffers')) {
                $groups = @($element.promotions.$groupName)
                foreach ($group in $groups) {
                    if ($null -eq $group) { continue }
                    foreach ($offer in @($group.promotionalOffers)) {
                        if ($null -eq $offer) { continue }
                        if ($null -eq $offer.discountSetting -or $offer.discountSetting.discountPercentage -ne 0) { continue }

                        $foundPromotion = $true
                        $freePromotions++

                        $type = [string]$element.offerType
                        if ([string]::IsNullOrWhiteSpace($type)) {
                            $type = if ($isBundle) { 'BUNDLE' } else { 'BASE_GAME' }
                        }

                        $entry = New-GameEntry `
                            -Title ([string]$element.title) `
                            -OfferId ([string]$element.id) `
                            -Namespace ([string]$element.namespace) `
                            -StartDate (ConvertTo-IsoDate $offer.startDate) `
                            -EndDate (ConvertTo-IsoDate $offer.endDate) `
                            -Type $type `
                            -Categories $categories `
                            -Source 'egs'

                        if ($null -ne $entry) { $entries.Add($entry) }
                    }
                }
            }
        }

        # Safety net: a 100% discount without a promotions block (seen occasionally).
        if (-not $foundPromotion -and $null -ne $element.price -and $null -ne $element.price.totalPrice) {
            $price = $element.price.totalPrice
            if ($price.discountPrice -eq 0 -and $price.originalPrice -gt 0) {
                $freePromotions++
                $type = [string]$element.offerType
                if ([string]::IsNullOrWhiteSpace($type)) {
                    $type = if ($isBundle) { 'BUNDLE' } else { 'BASE_GAME' }
                }

                $entry = New-GameEntry `
                    -Title ([string]$element.title) `
                    -OfferId ([string]$element.id) `
                    -Namespace ([string]$element.namespace) `
                    -StartDate $now `
                    -EndDate $null `
                    -Type $type `
                    -Categories $categories `
                    -Source 'egs-price'

                if ($null -ne $entry) { $entries.Add($entry) }
            }
        }
    }

    if ($freePromotions -eq 0) {
        Write-Log 'No free promotion found in the EGS payload (possible gap week).' 'WARN'
    }

    Write-Log ("EGS: {0} free promotion(s) parsed, {1} entr(ies) built." -f $freePromotions, $entries.Count)
    return $entries.ToArray()
}

function Get-BundleComponents {
    param(
        [string]$BundleId,
        [string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($BundleId)) { return @() }

    $uri = '{0}/offers/{1}/items?country=US&locale=en-US' -f $BaseUrl.TrimEnd('/'), $BundleId
    try {
        $items = @(Invoke-JsonRequest -Uri $uri)
    }
    catch {
        Write-Log "Unable to expand bundle $BundleId : $($_.Exception.Message)" 'WARN'
        return @()
    }

    $components = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $categories = Get-CategoryPaths $item.categories
        if (-not (Test-IsGameCategory $categories)) { continue }
        $components.Add([pscustomobject]@{
            title      = [string]$item.title
            id         = [string]$item.id
            namespace  = [string]$item.namespace
            categories = $categories
        })
    }

    return $components.ToArray()
}

function Get-EgDataEntries {
    param(
        [string]$BaseUrl,
        [int]$Pages = 40
    )

    $raw = New-Object 'System.Collections.Generic.List[object]'

    for ($page = 1; $page -le $Pages; $page++) {
        $uri = '{0}/free-games/history?country=US&locale=en-US&page={1}&limit=25' -f $BaseUrl.TrimEnd('/'), $page
        Write-Log "Fetching EGData history page $page"
        $pageItems = @(Invoke-JsonRequest -Uri $uri)

        if ($pageItems.Count -eq 0) { break }

        foreach ($item in $pageItems) {
            if ($null -eq $item -or $null -eq $item.giveaway) { continue }
            $raw.Add($item)
        }

        Start-Sleep -Milliseconds 200
    }

    Write-Log ("EGData: {0} raw history record(s)." -f $raw.Count)

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $bundles = New-Object 'System.Collections.Generic.List[object]'

    foreach ($item in $raw) {
        $categories = Get-CategoryPaths $item.categories
        $isGame = Test-IsGameCategory $categories
        $isBundle = Test-IsBundleCategory $categories

        if (-not $isGame -and -not $isBundle) { continue }

        $type = [string]$item.offerType
        if ([string]::IsNullOrWhiteSpace($type)) {
            $type = if ($isBundle) { 'BUNDLE' } else { 'BASE_GAME' }
        }

        $entry = New-GameEntry `
            -Title ([string]$item.title) `
            -OfferId ([string]$item.id) `
            -Namespace ([string]$item.namespace) `
            -StartDate (ConvertTo-IsoDate $item.giveaway.startDate) `
            -EndDate (ConvertTo-IsoDate $item.giveaway.endDate) `
            -Type $type `
            -Categories $categories `
            -Source 'egdata'

        if ($null -eq $entry) { continue }
        $entries.Add($entry)
        if ($isBundle) { $bundles.Add($entry) }
    }

    # Expand bundles into the games they actually grant, because Playnite creates one library
    # entry per installable asset, not one per bundle.
    $expandedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($bundle in $bundles) {
        if (-not $expandedIds.Add([string]$bundle.offerId)) { continue }

        Write-Log ("Expanding bundle: {0}" -f $bundle.title)
        $components = Get-BundleComponents -BundleId $bundle.offerId -BaseUrl $BaseUrl

        foreach ($component in $components) {
            $componentEntry = New-GameEntry `
                -Title $component.title `
                -OfferId $component.id `
                -Namespace $component.namespace `
                -StartDate $bundle.startDate `
                -EndDate $bundle.endDate `
                -Type 'GAME' `
                -Categories $component.categories `
                -Source 'egdata-bundle' `
                -BundleId $bundle.offerId `
                -BundleTitle $bundle.title

            if ($null -ne $componentEntry) { $entries.Add($componentEntry) }
        }

        $bundle.expanded = $true
        Start-Sleep -Milliseconds 200
    }

    return [pscustomobject]@{
        Entries      = $entries.ToArray()
        ExpandedIds  = @($expandedIds)
    }
}

function Expand-PendingBundles {
    param(
        [object[]]$Entries,
        [string[]]$AlreadyExpanded,
        [string]$BaseUrl
    )

    $expanded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($AlreadyExpanded)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [void]$expanded.Add([string]$id) }
    }

    $newEntries = New-Object 'System.Collections.Generic.List[object]'

    foreach ($bundle in @($Entries)) {
        if ($null -eq $bundle -or $bundle.type -ne 'BUNDLE') { continue }
        if ($bundle.expanded -eq $true) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$bundle.offerId)) { continue }
        if (-not $expanded.Add([string]$bundle.offerId)) { continue }

        Write-Log ("Expanding pending bundle: {0}" -f $bundle.title)
        $components = Get-BundleComponents -BundleId $bundle.offerId -BaseUrl $BaseUrl
        if ($components.Count -eq 0) {
            Write-Log ("No component found for bundle {0}; keeping it unexpanded." -f $bundle.title) 'WARN'
            continue
        }

        foreach ($component in $components) {
            $componentEntry = New-GameEntry `
                -Title $component.title `
                -OfferId $component.id `
                -Namespace $component.namespace `
                -StartDate $bundle.startDate `
                -EndDate $bundle.endDate `
                -Type 'GAME' `
                -Categories $component.categories `
                -Source 'egdata-bundle' `
                -BundleId $bundle.offerId `
                -BundleTitle $bundle.title

            if ($null -ne $componentEntry) { $newEntries.Add($componentEntry) }
        }

        $bundle.expanded = $true
        Start-Sleep -Milliseconds 200
    }

    return $newEntries.ToArray()
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-Dataset {
    param(
        [object]$Document,
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Document | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)

    # Validate the file we just wrote before declaring success.
    $check = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($check.schemaVersion -ne $SchemaVersion) { throw "Invalid dataset written to $Path" }
    if (@($check.games).Count -ne $Document.count) { throw "Dataset count mismatch in $Path" }
}

function Write-CiSummary {
    param(
        [string]$Mode,
        [int]$Total,
        [int]$Added,
        [int]$ExpandedBundles,
        [object[]]$UnexpandedBundles
    )

    if (-not $Ci) { return }

    $lines = @(
        "## EGS free games - $Mode",
        '',
        "- Entries: **$Total**"
        "- New entries: **$Added**"
        "- Bundles expanded: **$ExpandedBundles**"
    )

    if (@($UnexpandedBundles).Count -gt 0) {
        $lines += ''
        $lines += '### Bundles to expand'
        $lines += ''
        foreach ($bundle in $UnexpandedBundles) {
            $lines += "- $($bundle.title) ($($bundle.startDate))"
        }
        $lines += ''
        $lines += 'Run the workflow in `reconcile` mode to add their component games.'
        Write-Host ("::warning title=EGS bundle detected::{0}" -f (($UnexpandedBundles | ForEach-Object { $_.title }) -join ', '))
    }

    $summaryPath = $env:GITHUB_STEP_SUMMARY
    if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
        Add-Content -Path $summaryPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Log "Mode: $Mode | Repository: $RepoRoot"

    $existing = Read-Dataset -Path $DataFile
    $existingEntries = @($existing.games)
    Write-Log ("Existing dataset: {0} entr(ies)." -f $existingEntries.Count)

    $newEntries = @()
    $expandedIds = @()

    if ($Mode -eq 'reconcile') {
        $egdata = Get-EgDataEntries -BaseUrl $EgDataBase -Pages $MaxPages

        if (@($egdata.Entries).Count -lt $MinimumReconcileEntries) {
            throw ("EGData returned only {0} entries (minimum {1}). Aborting without writing." -f @($egdata.Entries).Count, $MinimumReconcileEntries)
        }

        $newEntries = @($egdata.Entries)
        $expandedIds = @($egdata.ExpandedIds)
    }
    else {
        $newEntries = @(Get-EgsEntries -Url $EgsUrl)
    }

    $merged = Merge-Entries -Existing $existingEntries -New $newEntries
    $entries = @($merged.Entries)

    # Reconcile also retries every bundle that is still marked unexpanded (for example one
    # discovered by the daily run before it appeared in the EGData history).
    if ($Mode -eq 'reconcile') {
        $pending = @($entries | Where-Object { $_.type -eq 'BUNDLE' -and $_.expanded -ne $true })
        if ($pending.Count -gt 0) {
            $extra = @(Expand-PendingBundles -Entries $pending -AlreadyExpanded $expandedIds -BaseUrl $EgDataBase)
            if ($extra.Count -gt 0) {
                $merged = Merge-Entries -Existing $entries -New $extra
                $entries = @($merged.Entries)
            }
        }
    }

    $totalBefore = $existingEntries.Count
    $totalAfter = $entries.Count

    if ($totalAfter -lt $totalBefore) {
        throw ("Dataset regression: {0} -> {1}. Aborting." -f $totalBefore, $totalAfter)
    }

    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $unexpanded = @($entries | Where-Object { $_.type -eq 'BUNDLE' -and $_.expanded -ne $true })
    $unexpandedBefore = @($existingEntries | Where-Object { $_.type -eq 'BUNDLE' -and $_.expanded -ne $true }).Count
    $bundlesExpanded = $unexpandedBefore - $unexpanded.Count

    $backfillId = $existing.backfillId
    if ($Mode -eq 'reconcile' -and ($totalAfter -gt $totalBefore -or $bundlesExpanded -gt 0)) {
        $backfillId = $now
    }
    if ([string]::IsNullOrWhiteSpace([string]$backfillId)) {
        $backfillId = $now
    }

    $document = [pscustomobject][ordered]@{
        schemaVersion = $SchemaVersion
        generatedAt   = $now
        lastEgsRun    = if ($Mode -eq 'daily') { $now } else { $existing.lastEgsRun }
        backfillId    = $backfillId
        count         = $totalAfter
        games         = $entries
    }

    Write-Log ("Merged dataset: {0} entr(ies) (+{1})." -f $totalAfter, ($totalAfter - $totalBefore))

    if ($DryRun) {
        Write-Log 'Dry run: no file written.'
    }
    else {
        Write-Dataset -Document $document -Path $DataFile
        Write-Dataset -Document $document -Path $SnapshotFile
        Write-Log "Wrote $DataFile"
        Write-Log "Wrote $SnapshotFile"
    }

    Write-CiSummary -Mode $Mode -Total $totalAfter -Added ($totalAfter - $totalBefore) -ExpandedBundles $bundlesExpanded -UnexpandedBundles $unexpanded

    if ($unexpanded.Count -gt 0) {
        Write-Log ("Unexpanded bundle(s): {0}" -f (($unexpanded | ForEach-Object { $_.title }) -join ', ')) 'WARN'
    }
    else {
        Write-Log 'All bundles are expanded.'
    }

    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    if ($Ci -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ("## EGS free games - $Mode`n`n**FAILED**: $($_.Exception.Message)") -Encoding UTF8
    }
    exit 1
}
