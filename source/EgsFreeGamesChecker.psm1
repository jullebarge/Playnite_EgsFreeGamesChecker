function GetMainMenuItems
{
    param(
        $getMainMenuItemsArgs
    )
    
    $menuItem1 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem1.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_MenuItemAddTagEGSGivenGamesDescription")
    $menuItem1.FunctionName = "CheckLibrary"
    $menuItem1.MenuSection = "@EGS Free Games checker"
	
	$menuItem2 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem2.Description =  [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_MenuItemUpdateTagName")
    $menuItem2.FunctionName = "UpdateTagName"
    $menuItem2.MenuSection = "@EGS Free Games checker"
	
    return $menuItem1, $menuItem2

}

function OnApplicationStarted
{
    Register-ObjectEvent -InputObject $PlayniteApi.Database.Games -EventName ItemCollectionChanged -Action {
		
		#Parameters
		$ExtensionName = "EGS Free Games checker"
		$CountertagAdded = 0
		$csvFilePath = $CurrentExtensionDataPath + "\EpicGameList.csv"
		$csvUrl = "https://raw.githubusercontent.com/jullebarge/Playnite_EgsFreeGamesChecker/main/csv/EpicGameList.csv"
		
		try {
			Invoke-WebRequest $csvUrl -OutFile $csvFilePath
		} catch {
			$errorMessage = $_.Exception.Message
			$__logger.Error("$ExtensionName - Impossible to download the game database. Error : $errorMessage")
		 return
		}
		
		# Import the CSV of given games
		$GivenEgsGames = Import-Csv $csvFilePath
		$__logger.Info("$ExtensionName - $($GivenEgsGames.count) games found in the EGS given list")
		
		if ($GivenEgsGames.count -eq 0)
		{
			$__logger.Error("$ExtensionName - Error: No game gifted on EGS found")
			return
		}
		
		foreach ($game in $event.SourceEventArgs.addedItems) {
		
			$__logger.Info("$ExtensionName - Checking the game $($game)")
			$Result = CheckGame $game $GivenEgsGames 
			if ($Result -eq "GivenAdded")
			{
				$CountertagAdded++
			}
		}

		$__logger.Info("$ExtensionName - Tag added to $CountertagAdded game(s).")
    }
}

function CheckLibrary
{
    param(
        $scriptMainMenuItemActionArgs
    )

	#Parameters
    $ExtensionName = "EGS Free Games checker"
	$countergivenGame = 0
    $CountertagAdded = 0
	$csvFilePath = $CurrentExtensionDataPath + "\EpicGameList.csv"
	$csvUrl = "https://raw.githubusercontent.com/jullebarge/Playnite_EgsFreeGamesChecker/main/csv/EpicGameList.csv"
	$tagFilePath = $CurrentExtensionDataPath + "\tagname.txt"
	
	# Get the CSV	
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
		
		$Result = CheckGame $game $GivenEgsGames 
		if ($Result -eq "GivenAdded")
		{
			$countergivenGame++
			$CountertagAdded++
		}
		elseif ($Result -eq "Given")
		{
			$countergivenGame++
		}
	}

	$tagName = Get-Content $tagFilePath
	
    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_ResultsMessageTag") -f  $countergivenGame, $tagName, $CountertagAdded), $ExtensionName)
}

function CheckGame ($gameToCheck, $CsvList)
{
	# $__logger.Debug("Start CheckGame")
	#Parameters
    $ExtensionName = "EGS Free Games checker"
	$tagFilePath = $CurrentExtensionDataPath + "\tagname.txt"
	
	$ReturnValue = ""
	
    $tagName = Get-Content $tagFilePath
	if ($tagName -eq "")
    {
		UpdateTagName
		$tagName = Get-Content $tagFilePath
    }
	
    $tagEGS = $PlayniteApi.Database.Tags.Add($tagName)
	
	#Ignore if game is not an EGS game
	$gameLibraryPlugin = [Playnite.SDK.BuiltinExtensions]::GetExtensionFromId($gameToCheck.PluginId)
	if ($gameLibraryPlugin -ne 'EpicLibrary')
	{
		$__logger.Info("$ExtensionName - Game `"$($gameToCheck.name)`" is not an EGS game")
		continue
	}
	
	#Verify if the EGS tag is already present
	if ($null -ne $gameToCheck.Tags)
	{
		$EGSTagPresent = $false
		foreach ($tag in $gameToCheck.Tags)
		{
			if ($tag.Name -eq $tagName)
			{
				$__logger.Info("$ExtensionName - Game `"$($gameToCheck.name)`" already has `"$($tagName)`" tag")
				$EGSTagPresent = $true
				$ReturnValue = "Given"
				break
			}
		}

		if ($EGSTagPresent -eq $true)
		{
			# $__logger.Debug("End CheckGame because game already has the tag")
			return "Given"
		}
	}

	# Looking for the game in the CSV provided with the extension
	$gameName = Clean-Text($gameToCheck.name)
	foreach ($item in $CsvList){
		$itemName = Clean-Text($item.name)
		
		if ($itemName -eq $gameName)
		{
			$__logger.Info("$ExtensionName - Added free EGS tag to `"$($gameToCheck.name)`".")
			$ReturnValue = "GivenAdded"
			# Add tag Id to game
			if ($gameToCheck.TagIds)
			{
				$gameToCheck.TagIds += $tagEGS.Id
				break
			}
			else
			{
				# Fix in case game has null TagIds
				$gameToCheck.TagIds = $tagEGS.Id
				break
			}			
		}
	}
	
	# Update game in database
	$PlayniteApi.Database.Games.Update($gameToCheck)
	# $__logger.Debug("End CheckGame. ReturnValue = " + $ReturnValue)
	return $ReturnValue
		
}

function UpdateTagName
{
	param(
        $scriptMainMenuItemActionArgs
    )
	
	$ExtensionName = "EGS Free Games checker"
	$defaultTagName = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_DefaultTagName")
	# $__logger.Info("$ExtensionName - CurrentExtensionDataPath = $($CurrentExtensionDataPath)")
	$tagFilePath = $CurrentExtensionDataPath + "\tagname.txt"
	if ((Test-Path $tagFilePath) -ne $true) {
		New-Item $tagFilePath
		Set-Content $tagFilePath $defaultTagName
	}
	
	[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

	$title = $ExtensionName
	$msg   = [Playnite.SDK.ResourceProvider]::GetString("LOCEGS_Free_Games_Checker_PopupTagLabel")

	$oldTagName = Get-Content $tagFilePath
	if ($oldTagName -eq "")
	{
		$oldTagName = $defaultTagName
	}
	
	$tagName = [Microsoft.VisualBasic.Interaction]::InputBox($msg, $title, $oldTagName)
	# $__logger.Info("$ExtensionName - tagName after popup = $($tagName)")
	Set-Content $tagFilePath $tagName
}

function Clean-Text 
{
    param (
        [string]$text
    )

    $text = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding("ISO-8859-8").GetBytes($text))
	
    $text = $text -replace '[^a-zA-Z0-9\s]', '' -replace '[:-]', ''

    $text = $text.ToLower().Trim()

    return $text
}
