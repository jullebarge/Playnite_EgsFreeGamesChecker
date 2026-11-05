$script:ExtensionName = 'EGS Free Games checker'
$script:JsonUrl = 'https://raw.githubusercontent.com/jullebarge/Playnite_EgsFreeGamesChecker/main/data/freeGames.json'
$script:SchemaVersion = 1
$script:CacheMaxAgeHours = 6

function Clean-Text
{
    param (
        [string]$text
    )

    # Must stay strictly identical to Get-NormalizedTitle in scripts/Update-FreeGames.ps1,
    # otherwise existing matches break. See docs/data-contract.md.
    if ($null -eq $text) { return '' }
    $text = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding('ISO-8859-8').GetBytes($text))
    $text = $text -replace '[^a-zA-Z0-9\s]', '' -replace '[:-]', ''
    $text = $text.ToLower().Trim()
    return $text
}

$script:State = @{
    Titles       = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    BackfillId   = $null
    Fingerprint  = $null
    GeneratedAt  = $null
    Count        = 0
    Loaded       = $false
    TagFilePath  = $null
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

function Get-TagFilePath
{
    return (Join-Path $CurrentExtensionDataPath 'tagname.txt')
}

function Get-CacheFilePath
{
    return (Join-Path $CurrentExtensionDataPath 'freeGames.json')
}

function Get-SnapshotFilePath
{
    return (Join-Path $PSScriptRoot 'data\freeGames.json')
}

function Get-MarkerFilePath
{
    return (Join-Path $CurrentExtensionDataPath 'lastDatasetFingerprint.txt')
}

function Get-TitlesFingerprint
{
    param([System.Collections.Generic.HashSet[string]]$Titles)

    # Stable fingerprint of the matchable title set. Used to detect that the dataset gained
    # entries (daily update, newly-current giveaway, expanded bundle) so the library can be
    # rescanned without rescanning on every launch.
    $sorted = @($Titles) | Sort-Object
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($sorted -join "`n"))
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    }
    finally
    {
        $sha.Dispose()
    }
}

function Get-TagName
{
    $path = Get-TagFilePath
    if (Test-Path $path)
    {
        $name = Get-Content $path -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name.Trim() }
    }

    $default = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_DefaultTagName')
    if ([string]::IsNullOrWhiteSpace($default)) { $default = 'Given by EGS' }
    return $default
}

function Initialize-TagFile
{
    $path = Get-TagFilePath
    if (-not (Test-Path $path))
    {
        Set-Content -Path $path -Value (Get-TagName) -Encoding UTF8
        $__logger.Info("$script:ExtensionName - Created default tag file: $path")
    }
    $script:State.TagFilePath = $path
}

# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------

function Load-FreeGamesData
{
    param([string]$Path)

    $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $json -or $json.schemaVersion -ne $script:SchemaVersion)
    {
        throw "Unsupported dataset schema in $Path"
    }

    $titles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $now = [DateTimeOffset]::UtcNow
    $future = 0

    foreach ($game in @($json.games))
    {
        if ($null -eq $game -or [string]::IsNullOrWhiteSpace([string]$game.title)) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$game.startDate)) { continue }

        try
        {
            $start = [DateTimeOffset]::Parse([string]$game.startDate, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch
        {
            continue
        }

        if ($start -gt $now)
        {
            $future++
            continue
        }

        [void]$titles.Add((Clean-Text ([string]$game.title)))
    }

    # Mutate the shared HashSet in place so event handlers holding a reference see the update.
    $script:State.Titles.Clear()
    foreach ($title in $titles) { [void]$script:State.Titles.Add($title) }

    $script:State.BackfillId = [string]$json.backfillId
    $script:State.Fingerprint = Get-TitlesFingerprint $script:State.Titles
    $script:State.GeneratedAt = [string]$json.generatedAt
    $script:State.Count = @($json.games).Count
    $script:State.Loaded = $true

    $__logger.Info("$script:ExtensionName - Loaded $($script:State.Count) entries from $Path ($($script:State.Titles.Count) matchable, $future future entries ignored)")
}

function Initialize-FreeGamesData
{
    $cache = Get-CacheFilePath
    $snapshot = Get-SnapshotFilePath

    if (Test-Path $cache)
    {
        try
        {
            Load-FreeGamesData $cache
            return
        }
        catch
        {
            $__logger.Warn("$script:ExtensionName - Invalid cache file, falling back to embedded snapshot: $($_.Exception.Message)")
        }
    }

    if (Test-Path $snapshot)
    {
        try
        {
            Load-FreeGamesData $snapshot
            return
        }
        catch
        {
            $__logger.Error("$script:ExtensionName - Invalid embedded snapshot: $($_.Exception.Message)")
        }
    }

    $__logger.Error("$script:ExtensionName - No free games dataset available")
}

function Update-FreeGamesCache
{
    param([switch]$Force)

    $cache = Get-CacheFilePath

    if (-not $Force -and (Test-Path $cache))
    {
        $age = (Get-Date) - (Get-Item $cache).LastWriteTime
        if ($age.TotalHours -lt $script:CacheMaxAgeHours) { return }
    }

    $temp = "$cache.tmp"
    try
    {
        Invoke-WebRequest -Uri $script:JsonUrl -OutFile $temp -UseBasicParsing -TimeoutSec 15
        $json = Get-Content $temp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json -or $json.schemaVersion -ne $script:SchemaVersion -or @($json.games).Count -lt 100)
        {
            throw 'Downloaded dataset is invalid'
        }

        Move-Item -Path $temp -Destination $cache -Force
        Load-FreeGamesData $cache
        $__logger.Info("$script:ExtensionName - Dataset refreshed from $script:JsonUrl")
    }
    catch
    {
        Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue
        $__logger.Warn("$script:ExtensionName - Unable to refresh dataset, keeping local cache: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# Tagging
# ---------------------------------------------------------------------------

function Test-IsEpicGame
{
    param($Game)

    if ($null -eq $Game -or $null -eq $Game.PluginId) { return $false }

    try
    {
        return ([Playnite.SDK.BuiltinExtensions]::GetExtensionFromId($Game.PluginId) -eq 'EpicLibrary')
    }
    catch
    {
        return $false
    }
}

function Add-TagToGame
{
    param($Game, $Tag)

    if ($null -eq $Game -or $null -eq $Tag) { return $false }

    if ($Game.TagIds)
    {
        foreach ($tagId in $Game.TagIds)
        {
            if ($tagId -eq $Tag.Id) { return $false }
        }
    }

    if ($Game.Tags)
    {
        foreach ($existingTag in $Game.Tags)
        {
            if ($existingTag.Id -eq $Tag.Id) { return $false }
        }
    }

    $tagIds = New-Object 'System.Collections.Generic.List[Guid]'
    if ($Game.TagIds)
    {
        foreach ($tagId in $Game.TagIds) { $tagIds.Add($tagId) }
    }
    $tagIds.Add($Tag.Id)

    $Game.TagIds = $tagIds
    $PlayniteApi.Database.Games.Update($Game)
    return $true
}

function Invoke-LibraryScan
{
    param([switch]$ShowMessage)

    $tagName = Get-TagName
    if ([string]::IsNullOrWhiteSpace($tagName))
    {
        if ($ShowMessage)
        {
            $PlayniteApi.Dialogs.ShowErrorMessage(
                [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_TagNameEmptyInfoMessage'),
                $script:ExtensionName)
        }
        return
    }

    $tag = $PlayniteApi.Database.Tags.Add($tagName)
    $matched = 0
    $added = 0
    $epicCount = 0

    foreach ($game in $PlayniteApi.Database.Games)
    {
        if (-not (Test-IsEpicGame $game)) { continue }
        $epicCount++

        if (-not $script:State.Titles.Contains((Clean-Text $game.Name))) { continue }
        $matched++

        if (Add-TagToGame $game $tag) { $added++ }
    }

    $__logger.Info("$script:ExtensionName - Library scan: $epicCount EGS games, $matched free games found, $added tag(s) added")

    if ($ShowMessage)
    {
        $message = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_ResultsMessageTag') -f $matched, $tagName, $added
        $PlayniteApi.Dialogs.ShowMessage($message, $script:ExtensionName)
    }

    return [pscustomobject]@{
        EpicGames = $epicCount
        Matched   = $matched
        Added     = $added
    }
}

function Invoke-AutoRescan
{
    if (-not $script:State.Loaded) { return }
    if ([string]::IsNullOrWhiteSpace([string]$script:State.Fingerprint)) { return }

    $marker = Get-MarkerFilePath
    $lastFingerprint = ''
    if (Test-Path $marker)
    {
        $lastFingerprint = (Get-Content $marker -Raw -ErrorAction SilentlyContinue)
        if ($null -eq $lastFingerprint) { $lastFingerprint = '' }
        $lastFingerprint = $lastFingerprint.Trim()
    }

    if ($lastFingerprint -eq [string]$script:State.Fingerprint) { return }

    $__logger.Info("$script:ExtensionName - Dataset changed (backfillId $($script:State.BackfillId)), running full library scan")

    $result = Invoke-LibraryScan
    Set-Content -Path $marker -Value ([string]$script:State.Fingerprint) -Encoding UTF8

    if ($result.Added -gt 0)
    {
        $message = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_AutoRescanMessage') -f $result.Added
        $PlayniteApi.Notifications.Add('egs-free-games-rescan', $message, [Playnite.SDK.NotificationType]::Info)
    }
}

# ---------------------------------------------------------------------------
# Playnite entry points
# ---------------------------------------------------------------------------

function GetMainMenuItems
{
    param(
        $getMainMenuItemsArgs
    )

    $menuItem1 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem1.Description = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_MenuItemAddTagEGSGivenGamesDescription')
    $menuItem1.FunctionName = 'CheckLibrary'
    $menuItem1.MenuSection = '@EGS Free Games checker'

    $menuItem2 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem2.Description = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_MenuItemUpdateTagName')
    $menuItem2.FunctionName = 'UpdateTagName'
    $menuItem2.MenuSection = '@EGS Free Games checker'

    $menuItem3 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem3.Description = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_MenuItemRefreshFreeGames')
    $menuItem3.FunctionName = 'RefreshFreeGames'
    $menuItem3.MenuSection = '@EGS Free Games checker'

    return $menuItem1, $menuItem2, $menuItem3
}

function OnApplicationStarted
{
    Initialize-TagFile
    Initialize-FreeGamesData

    Register-ObjectEvent -InputObject $PlayniteApi.Database.Games -EventName ItemCollectionChanged -MessageData $script:State -Action {
        $state = $event.MessageData
        $addedItems = $event.SourceEventArgs.AddedItems
        if ($null -eq $addedItems -or $addedItems.Count -eq 0) { return }

        $tagName = $null
        if ($state.TagFilePath -and (Test-Path $state.TagFilePath))
        {
            $tagName = Get-Content $state.TagFilePath -Raw -ErrorAction SilentlyContinue
            if ($null -ne $tagName) { $tagName = $tagName.Trim() }
        }
        if ([string]::IsNullOrWhiteSpace($tagName)) { return }

        $tag = $PlayniteApi.Database.Tags.Add($tagName)
        $tagged = 0

        foreach ($game in $addedItems)
        {
            if ($null -eq $game -or $null -eq $game.PluginId) { continue }
            if ([Playnite.SDK.BuiltinExtensions]::GetExtensionFromId($game.PluginId) -ne 'EpicLibrary') { continue }

            $normalized = Clean-Text $game.Name
            if (-not $state.Titles.Contains($normalized)) { continue }

            $hasTag = $false
            if ($game.TagIds)
            {
                foreach ($tagId in $game.TagIds)
                {
                    if ($tagId -eq $tag.Id) { $hasTag = $true; break }
                }
            }
            if (-not $hasTag -and $game.Tags)
            {
                foreach ($existingTag in $game.Tags)
                {
                    if ($existingTag.Id -eq $tag.Id) { $hasTag = $true; break }
                }
            }
            if ($hasTag) { continue }

            $tagIds = New-Object 'System.Collections.Generic.List[Guid]'
            if ($game.TagIds)
            {
                foreach ($tagId in $game.TagIds) { $tagIds.Add($tagId) }
            }
            $tagIds.Add($tag.Id)
            $game.TagIds = $tagIds
            $PlayniteApi.Database.Games.Update($game)
            $tagged++
        }

        if ($tagged -gt 0)
        {
            $__logger.Info("$script:ExtensionName - Tag added to $tagged newly added game(s).")
        }
    } | Out-Null
}

function OnLibraryUpdated
{
    Update-FreeGamesCache
    Invoke-AutoRescan
}

function CheckLibrary
{
    param(
        $scriptMainMenuItemActionArgs
    )

    Update-FreeGamesCache -Force
    Invoke-LibraryScan -ShowMessage
}

function RefreshFreeGames
{
    param(
        $scriptMainMenuItemActionArgs
    )

    Update-FreeGamesCache -Force

    if ($script:State.Loaded)
    {
        $message = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_RefreshSuccessMessage') -f $script:State.Count
        $PlayniteApi.Dialogs.ShowMessage($message, $script:ExtensionName)
    }
    else
    {
        $PlayniteApi.Dialogs.ShowErrorMessage(
            [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_RefreshFailMessage'),
            $script:ExtensionName)
    }
}

function UpdateTagName
{
    param(
        $scriptMainMenuItemActionArgs
    )

    $defaultTagName = [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_DefaultTagName')
    if ([string]::IsNullOrWhiteSpace($defaultTagName)) { $defaultTagName = 'Given by EGS' }

    if (-not (Test-Path (Get-TagFilePath)))
    {
        Set-Content -Path (Get-TagFilePath) -Value $defaultTagName -Encoding UTF8
    }

    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

    $oldTagName = Get-TagName
    $tagName = [Microsoft.VisualBasic.Interaction]::InputBox(
        [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_PopupTagLabel'),
        $script:ExtensionName,
        $oldTagName)

    if ([string]::IsNullOrWhiteSpace($tagName))
    {
        $PlayniteApi.Dialogs.ShowErrorMessage(
            [Playnite.SDK.ResourceProvider]::GetString('LOCEGS_Free_Games_Checker_TagNameEmptyInfoMessage'),
            $script:ExtensionName)
        return
    }

    Set-Content -Path (Get-TagFilePath) -Value $tagName.Trim() -Encoding UTF8
}
