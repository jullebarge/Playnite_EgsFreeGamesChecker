function GetMainMenuItems
{
    param(
        $getMainMenuItemsArgs
    )
    
    $menuItem1 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem1.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_MenuItemCheckEGSGivenGamesDescription")
    $menuItem1.FunctionName = "Add-EgsGivenCat"
    $menuItem1.MenuSection = "@EGS Free Games checker"

    return $menuItem1
}

function Add-EgsGivenCat
{
    param(
        $scriptMainMenuItemActionArgs
    )

    $ExtensionName = "EGS Free Games checker"
	$countergivenGame = 0
    $CountercatAdded = 0
    $catName = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_CategoryName")
    $catEGS = $PlayniteApi.Database.Categories.Add($catName)
   
    try {
        $uri = "https://en.everybodywiki.com/List_of_free_Epic_Games_Store_games"
        $req = Invoke-WebRequest $uri
    } catch {
        $errorMessage = $_.Exception.Message
        $PlayniteApi.Dialogs.ShowErrorMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_GivenListDownloadFailErrorMessage") -f $errorMessage), $ExtensionName)
     return
    }

	$table = $req.ParsedHtml.getElementsByTagName('table')[0]
	
	$GivenEgsGames = @()
	for ($x = 1; $x -lt $table.rows.length; $x++) {    
            $GivenEgsGames += $table.rows[$x].cells[1].innerText.trim()
	}

	$__logger.Info("$ExtensionName - $($GivenEgsGames.count) games found in the EGS given list")
 
    if ($GivenEgsGames.count -eq 0)
    {
        $PlayniteApi.Dialogs.ShowErrorMessage([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_NoGivenGamesErrorMessage"), $ExtensionName)
        return
    }

	foreach ($game in $PlayniteApi.Database.Games) {
		#Ignore if game is not an EGS game
		$__logger.Info($game.PluginId)
		$gameLibraryPlugin = [Playnite.SDK.BuiltinExtensions]::GetExtensionFromId($game.PluginId)
		if ($gameLibraryPlugin -ne 'EpicLibrary')
        {
            $__logger.Info("$ExtensionName - Game `"$($game.name)`" is not an EGS game")
			continue
        }
		
		#Verify if the EGS category is already present
		if ($null -ne $game.Categories)
        {
            $EGSCatPresent = $false
            foreach ($cat in $game.Categories) {
                if ($cat.Name -eq $catName)
                {
                    $__logger.Info("$ExtensionName - Game `"$($game.name)`" already has `"$($catName)`" category")
                    $EGSCatPresent = $true
					$countergivenGame++
                    break
                }
            }

            if ($EGSCatPresent -eq $true)
            {
                continue
            }
        }
	
		$gameName = $game.name.ToLower() -replace '[^\p{L}\p{Nd}]', ''
		foreach ($item in $GivenEgsGames){
			$itemName = $item.ToLower() -replace '[^\p{L}\p{Nd}]', ''
			
			if ($itemName -eq $gameName)
			{
				$__logger.Info("$ExtensionName - Added free EGS cat to `"$($game.name)`".")
				$CountercatAdded++
				$countergivenGame++
				# Add cat Id to game
				if ($game.CategoryIds)
				{
					$game.CategoryIds += $catEGS.Id
					break
				}
				else
				{
					# Fix in case game has null CategoryIds
					$game.CategoryIds = $catEGS.Id
					break
				}			
			}
		}
		# Update game in database
		$PlayniteApi.Database.Games.Update($game)
	
	}	

    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_ResultsMessage") -f  $countergivenGame, $catName, $CountercatAdded), $ExtensionName)
}