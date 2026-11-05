# EGS Free Games Checker

A [Playnite](https://playnite.link/) extension that tags the games offered for free on the
Epic Games Store.

- Works on **Playnite 10** (script extension, PowerShell).
- Tags **Epic library games only**, by comparing their title with the list of games that have
  been given away since 2018.
- The game list is a static JSON file shipped with the extension and refreshed automatically
  from GitHub. No third-party API is called while Playnite runs.

## What it does

The extension adds a tag (default: `Given by EGS`) to every game in your Epic library whose
title matches a game that has been offered for free on the Epic Games Store.

Matching is done on a normalized title (lower case, punctuation removed), so small spelling
differences are tolerated. It is still a name-based match: if Playnite stores a game under a
very different name, it will not be recognized.

Games whose free period starts in the future (next week's giveaway, already present in the
dataset) are ignored until the giveaway actually starts.

## Installation

Install the extension from the Playnite add-on browser, or download the latest `.pext` from the
[releases page](https://github.com/jullebarge/Playnite_EgsFreeGamesChecker/releases) and open it
with Playnite.

## Usage

The extension adds an **EGS Free Games checker** section to Playnite's main menu:

| Menu entry | Effect |
|---|---|
| **Add a tag to games gifted by EGS** | Refreshes the list from GitHub, scans your whole library and tags the matching Epic games. Shows a summary when done. |
| **Refresh the free games list** | Downloads the latest list without scanning the library. |
| **Update Tag Name** | Changes the tag used by the extension (default `Given by EGS`). |

Typical usage:

1. Redeem the weekly games on the Epic Games Store.
2. Update your Epic library in Playnite.
3. Run **Add a tag to games gifted by EGS**.

The tag is also applied automatically to newly added Epic games as long as the free games list
already contains their title.

### Automatic rescan

When the extension loads a newer version of the game list (new giveaway, expanded bundle), it
runs a full library scan once, so games that were added before the list was updated are tagged
without any manual action. A notification reports how many games were tagged.

## Why a game can be tagged even though I bought it

Epic does not expose whether a game was obtained for free or purchased. The extension can only
compare titles. A game that was offered for free at some point and that you also own on Epic
will therefore be tagged, even if you paid for it. This is a known limitation.

## License

[MIT](LICENSE)
