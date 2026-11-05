# Contrat de données — `data/freeGames.json`

Ce fichier est la source de vérité des jeux offerts sur l'Epic Games Store. Il est généré par
`scripts/Update-FreeGames.ps1`, jamais édité à la main.

- Producteur : GitHub Actions (`.github/workflows/update-free-games.yml`)
- Consommateur : extension Playnite `EGS Free Games checker`
- URL publique : `https://raw.githubusercontent.com/jullebarge/Playnite_EgsFreeGamesChecker/main/data/freeGames.json`
- Copie embarquée dans le `.pext` : `source/data/freeGames.json`

## Structure

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-05T17:00:00Z",
  "lastEgsRun": "2026-11-05T17:00:00Z",
  "backfillId": "2026-11-05T17:00:00Z",
  "count": 684,
  "games": []
}
```

| Champ | Type | Description |
|---|---|---|
| `schemaVersion` | entier | Version du format. Le consommateur doit refuser une version inconnue. |
| `generatedAt` | date ISO 8601 UTC | Date de la dernière écriture du fichier. |
| `lastEgsRun` | date ISO 8601 UTC \| null | Date du dernier passage en mode `daily`. |
| `backfillId` | date ISO 8601 UTC | Change uniquement quand le mode `reconcile` ajoute des entrées ou éclate un bundle. Sert de repère de version du backfill (diagnostic). |
| `count` | entier | Nombre d'entrées dans `games`. |
| `games` | tableau | Entrées, triées par `startDate` puis `title`. |

## Entrée de jeu

```json
{
  "title": "Sorry We're Closed",
  "normalizedTitle": "sorry were closed",
  "offerId": "a9748abde1c94b66aae5250bb9fc5503",
  "namespace": "7e508f543b05465abe3a935960eb70ac",
  "startDate": "2026-10-29T15:00:00Z",
  "endDate": "2026-11-05T16:00:00Z",
  "type": "BASE_GAME",
  "categories": ["freegames", "games", "games/edition", "games/edition/base"],
  "source": "egs"
}
```

| Champ | Type | Description |
|---|---|---|
| `title` | chaîne | Titre anglais brut (jamais localisé). |
| `normalizedTitle` | chaîne | Résultat de `Clean-Text` (voir ci-dessous). Fourni pour le diagnostic ; le consommateur le recalcule. |
| `offerId` | chaîne | Identifiant de l'offre Epic (ou de l'item pour un composant de bundle). |
| `namespace` | chaîne | Namespace Epic. |
| `startDate` | date ISO 8601 UTC | Début de la période gratuite. |
| `endDate` | date ISO 8601 UTC \| null | Fin de la période gratuite. `null` si inconnue. |
| `type` | chaîne | `BASE_GAME`, `GAME`, `EDITION`, `BUNDLE`, … |
| `categories` | chaîne[] | Catégories Epic (`games`, `bundles`, `addons`, …). |
| `source` | chaîne | `egs`, `egs-price`, `egdata`, `egdata-bundle`. |

Champs supplémentaires pour les composants d'un bundle :

```json
{
  "type": "GAME",
  "source": "egdata-bundle",
  "bundleId": "944b5b5d646d46bc92bc33edfe983d26",
  "bundleTitle": "LISA: The Definitive Edition"
}
```

Champ supplémentaire pour une entrée bundle :

```json
{
  "type": "BUNDLE",
  "expanded": true
}
```

`expanded: false` signifie que les jeux composants n'ont pas encore été ajoutés. L'Action ouvre
alors une issue GitHub et le mode `reconcile` la ferme après expansion.

## Règles de filtrage

Une entrée est retenue si :

- ses catégories contiennent `games` ;
- et ne contiennent ni `addons`, ni `bundles`, ni `games/dlc`, ni `software`, ni `spthidden`
  (pour un jeu) ;
- ou contiennent `bundles` (l'entrée est alors un bundle, destiné à être éclaté).

Les promotions sont retenues uniquement si `discountSetting.discountPercentage == 0`. Les simples
soldes sont ignorés.

## Normalisation des titres

`normalizedTitle` doit rester **strictement identique** à `Clean-Text` dans
`source/EgsFreeGamesChecker.psm1` :

```powershell
$text = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding('ISO-8859-8').GetBytes($text))
$text = $text -replace '[^a-zA-Z0-9\s]', '' -replace '[:-]', ''
return $text.ToLower().Trim()
```

Toute modification de cette fonction doit être appliquée aux deux côtés et accompagnée d'une
régénération complète du jeu de données.

## Règle de fusion

- La clé d'une entrée est `normalizedTitle|startDate`.
- Une entrée existante n'est jamais supprimée.
- Un bundle déjà marqué `expanded: true` le reste.
- `backfillId` n'est mis à jour qu'en mode `reconcile`, et seulement si des entrées ont été ajoutées
  ou des bundles éclatés.

## Déclenchement du scan automatique côté extension

L'extension ne compare pas `backfillId` : elle calcule une empreinte SHA-256 des titres
normalisés **actuellement matchables** (entrées dont `startDate` est passée), triés, et la compare
à l'empreinte stockée dans `lastDatasetFingerprint.txt`.

Un scan complet est donc déclenché quand :

- le mode `reconcile` ajoute des jeux (backfill ou composants de bundle) ;
- le mode `daily` ajoute le jeu de la semaine ;
- une entrée « à venir » devient matchable (le jeu vient d'être offert) ;
- un titre est corrigé dans le jeu de données.

Le scan ne se déclenche pas à chaque lancement si le contenu n'a pas changé.

