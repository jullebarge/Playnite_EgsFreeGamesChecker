function GetMainMenuItems
{
    param(
        $getMainMenuItemsArgs
    )
    
    $menuItem1 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem1.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_MenuItemAddTagEGSGivenGamesDescription")
    $menuItem1.FunctionName = "Add-EgsGivenTag"
    $menuItem1.MenuSection = "@EGS Free Games checker"
	
	$menuItem2 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem2.Description =  [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_MenuItemUpdateTagName")
    $menuItem2.FunctionName = "UpdateTagName"
    $menuItem2.MenuSection = "@EGS Free Games checker"
	
    return $menuItem1

}

function Add-EgsGivenTag
{
    param(
        $scriptMainMenuItemActionArgs
    )

	#Parameters
    $ExtensionName = "EGS Free Games checker"
	$countergivenGame = 0
    $CountertagAdded = 0
	$EnableGgDeals = $false
	$EnableITAD = $true
	$ggdealsUrl = "https://gg.deals/games/?platform=1&type=1&title="
	$ItadPlainUrl = "https://api.isthereanydeal.com/v02/game/plain/?key="
	$IteadHistoricalLowUrl = "https://api.isthereanydeal.com/v01/game/lowest/?key="
	$key = "380c5031d9ca9a5185af32d5a725c2e40786b8ea"
	$tagFilePath = $CurrentExtensionDataPath + "\tagname.txt"
	$csvFilePath = $CurrentExtensionDataPath + "\EpicGameList.csv"
	
	UpdateTagName
    $tagName = Get-Content $tagFilePath
    $tagEGS = $PlayniteApi.Database.Tags.Add($tagName)

	$csvUrl = "https://raw.githubusercontent.com/jullebarge/Playnite_EgsFreeGamesChecker/main/csv/EpicGameList.csv"
	try {
		Invoke-WebRequest $csvUrl -OutFile $csvFilePath
	} catch {
		$errorMessage = $_.Exception.Message
		$PlayniteApi.Dialogs.ShowErrorMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_GivenListDownloadFailErrorMessage") -f $errorMessage), $ExtensionName)
	 return
	}
	
	# Import the CSV of given games
	$GivenEgsGames = Import-Csv $csvFilePath
	$__logger.Info("$ExtensionName - $($GivenEgsGames.count) games found in the EGS given list")
	
    if ($GivenEgsGames.count -eq 0)
    {
        $PlayniteApi.Dialogs.ShowErrorMessage([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_NoGivenGamesErrorMessage"), $ExtensionName)
        return
    }

	foreach ($game in $PlayniteApi.Database.Games) {
		
		$gameFound = $false
		
		#Ignore if game is not an EGS game
		$gameLibraryPlugin = [Playnite.SDK.BuiltinExtensions]::GetExtensionFromId($game.PluginId)
		if ($gameLibraryPlugin -ne 'EpicLibrary')
        {
            $__logger.Info("$ExtensionName - Game `"$($game.name)`" is not an EGS game")
			continue
        }
		
		#Verify if the EGS tag is already present
		if ($null -ne $game.Tags)
        {
            $EGSTagPresent = $false
            foreach ($tag in $game.Tags) {
                if ($tag.Name -eq $tagName)
                {
                    $__logger.Info("$ExtensionName - Game `"$($game.name)`" already has `"$($tagName)`" tag")
                    $EGSTagPresent = $true
					$countergivenGame++
                    break
                }
            }

            if ($EGSTagPresent -eq $true)
            {
                continue
            }
        }
	
		# Looking for the game in the CSV provided with the extension
		$gameName = $game.name.ToLower() -replace '[^\p{L}\p{Nd}]', ''
		foreach ($item in $GivenEgsGames){
			$itemName = $item.name.ToLower() -replace '[^\p{L}\p{Nd}]', ''
			
			if ($itemName -eq $gameName)
			{
				$__logger.Info("$ExtensionName - Added free EGS tag to `"$($game.name)`".")
				$gameFound = $true
				$CountertagAdded++
				$countergivenGame++
				# Add tag Id to game
				if ($game.TagIds)
				{
					$game.TagIds += $tagEGS.Id
					break
				}
				else
				{
					# Fix in case game has null TagIds
					$game.TagIds = $tagEGS.Id
					break
				}			
			}
		}
		
		# If the game is not found in the CSV, we check on GG Deals or ITAD
		if (!$gameFound)
		{
			if ($EnableGgDeals)
			{
				$__logger.Info("$ExtensionName - Looking for `"$($game.name)`" on GG Deals")
				try {
					$uri = $ggdealsUrl + $game.name
					$req = Invoke-WebRequest $uri
				} catch {
					$errorMessage = $_.Exception.Message
					$PlayniteApi.Dialogs.ShowErrorMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_GivenListDownloadFailErrorMessage") -f $errorMessage), $ExtensionName)
				 return
				}
				
				$gameLink =  $req.Links | Where-Object class -like 'full-link' | select -First 1 -expand href
				if (!$gameLink.Contains("/game/"))
				{
					$__logger.Info("$ExtensionName - Error getting the page link for `"$($game.name)`".")
					continue
				}
				
				$fullLink = "https://gg.deals" + $gameLink
				$__logger.Info("$ExtensionName - fullLink = $($fullLink)")
				
				try {
					$page = Invoke-WebRequest -Uri $fullLink -UseBasicParsing
				} catch {
					$errorMessage = $_.Exception.Message
					$PlayniteApi.Dialogs.ShowErrorMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_GivenListDownloadFailErrorMessage") -f $errorMessage), $ExtensionName)
				 return
				}
				
				$HTML = New-Object -Com "HTMLFile"
				$HTML.IHTMLDocument2_write($page.Content)

				$priceHistory = ($HTML.getElementById('game-lowest-tab-price')).innerText.replace("`r`n","")
				
				if ($priceHistory.Contains("Free Epic Games Store"))
				{
					$__logger.Info("$ExtensionName - Add free EGS tag to `"$($game.name)`".")
					$CountertagAdded++
					$countergivenGame++
					# Add tag Id to game
					if ($game.TagIds)
					{
						$game.TagIds += $tagEGS.Id
					}
					else
					{
						# Fix in case game has null TagIds
						$game.TagIds = $tagEGS.Id
					}
				}
			}
			elseif ($EnableITAD)
			{

				#Look for the game plains on ITAD API
				try {
					$uri = $ItadPlainUrl + $key + "&shop=epic&title=" + $game.name
					$webClient = New-Object System.Net.WebClient
					$webClient.Encoding = [System.Text.Encoding]::UTF8
					$downloadedString = $webClient.DownloadString($uri)
					$gamePlain = $downloadedString | ConvertFrom-Json
					$webClient.Dispose()
				} catch {
					$errorMessage = $_.Exception.Message
					$PlayniteApi.Dialogs.ShowErrorMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_GivenListDownloadFailErrorMessage") -f $errorMessage), $ExtensionName)
				 return
				}

				if ($gamePlain.meta.match -eq "false")
				{
					$__logger.Info("$ExtensionName - `"$($uri)`" did not produce any results")
					continue
				}
				
				if ($gamePlain.meta.active -eq "false")
				{
					$__logger.Info("$ExtensionName - `"$($uri)`" did not have price on ITAD")
					continue
				}
				
				$itadPlain = $gamePlain.data.plain
				#$__logger.Info("$ExtensionName - Game $($gameName) => Plain = $($itadPlain)")
				
				if (!$itadPlain)
				{
					$__logger.Info("$ExtensionName - Plain not found for `"$($gameName)`"")
					continue
				}
				
				#Look for the game historical lowest price on EGS with ITAD API
				try {
					$uri = $IteadHistoricalLowUrl + $key + "&shop=epic&plains=" + $itadPlain
					$webClient = New-Object System.Net.WebClient
					$webClient.Encoding = [System.Text.Encoding]::UTF8
					$downloadedString = $webClient.DownloadString($uri)
					$gameInfo = $downloadedString | ConvertFrom-Json
					$webClient.Dispose()
				} catch {
					$errorMessage = $_.Exception.Message
					$PlayniteApi.Dialogs.ShowErrorMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_GivenListDownloadFailErrorMessage") -f $errorMessage), $ExtensionName)
				 return
				}
				
				$price = $gameInfo.data.${itadPlain}.price
				$cut = $gameInfo.data.${itadPlain}.cut
				
				if (($price -eq 0) -and ($cut -eq 100))
				{
					$__logger.Info("$ExtensionName - Add free EGS tag to `"$($game.name)`".")
					$CountertagAdded++
					$countergivenGame++
					# Add tag Id to game
					if ($game.TagIds)
					{
						$game.TagIds += $tagEGS.Id
					}
					else
					{
						# Fix in case game has null TagIds
						$game.TagIds = $tagEGS.Id
					}			
				}
			}
		}
		
		# Update game in database
		$PlayniteApi.Database.Games.Update($game)
	
	}	

    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_ResultsMessageTag") -f  $countergivenGame, $tagName, $CountertagAdded), $ExtensionName)
}

function UpdateTagName
{
	param(
        $scriptMainMenuItemActionArgs
    )
	
	$ExtensionName = "EGS Free Games checker"
	# $__logger.Info("$ExtensionName - CurrentExtensionDataPath = $($CurrentExtensionDataPath)")
	$tagFilePath = $CurrentExtensionDataPath + "\tagname.txt"
	if ((Test-Path $tagFilePath) -ne $true) {
		New-Item $tagFilePath
		Set-Content $tagFilePath "Given by EGS"
	}
	
	[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

	$title = $ExtensionName
	$msg   = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_PopupTagLabel")

	$oldTagName = Get-Content $tagFilePath
	$tagName = [Microsoft.VisualBasic.Interaction]::InputBox($msg, $title, $oldTagName)
	$__logger.Info("$ExtensionName - tagName = $($tagName)")
	Set-Content $tagFilePath $tagName
}