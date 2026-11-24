# Tech Toolkit

Outil technicien Windows en interface graphique (WPF/PowerShell), dans l'esprit de WinUtil, orienté **SAV, durcissement et contrôle sécurité**.

| Onglet | Contenu |
|---|---|
| **Tweaks & durcissement** | 27 réglages en 4 catégories (Confort & SAV, Confidentialité, Durcissement, Durcissement renforcé), 4 profils, état en direct, point de restauration, **annulation avec restauration des valeurs d'origine réelles** |
| **Contrôle & nettoyage** | Contrôle sécurité du poste (antivirus, pare-feu, BitLocker, patchs, comptes, persistance, outils de prise en main à distance, proxy/hosts/DNS, disques) avec **rapport HTML**, et 14 actions de nettoyage, réparation ou antivirus |
| **Créer ma clé** | Crée ou met à jour la clé technicien depuis l'outil : Ventoy (dernière version, GPT, Secure Boot), partition TOOLS, thème et menus, téléchargement des ISO et outils portables (`config/usb.json`), manifeste SHA256, verrouillage |
| **Outils de la clé** | Lanceur des outils portables de la clé (`tools.json`), en mode USB uniquement |

## Lancement

**Depuis le web** (PowerShell, le dépôt doit être public) :
```powershell
irm https://raw.githubusercontent.com/Nagory-ST/tech-toolkit/main/dist/toolkit.ps1 | iex
```

**Depuis la clé USB** : copie `dist/toolkit.ps1` et `launcher/START.bat` à la racine de la partition TOOLS, à côté de `tools.json`, puis lance `START.bat`.

Dans les deux cas, l'outil demande lui-même l'élévation administrateur et se relance dans Windows PowerShell 5.1 (STA), ce que WPF exige.

## Créer ma clé

1. Branche une clé (32 Go conseillés) et lance l'outil (web ou local).
2. Onglet **Créer ma clé** : choisis le disque, la taille de TOOLS et les composants.
3. Confirme en tapant `EFFACER`. Une clé Tech Toolkit existante est détectée et proposée en **mise à jour sans effacement**.

Les composants sans lien direct stable (Windows 11, WinSCP, HWiNFO…) sont marqués « téléchargement manuel » : leurs pages s'ouvrent à la fin, et la destination est indiquée dans le tableau.
Le kit copié sur la clé (thème Ventoy, menus, scripts) vient du dossier `usb/` de ce dépôt.

## Développement

```
src/start.ps1            en-tête : élévation, détection USB/web, $sync
src/functions/core       journal, tâches de fond (runspaces), restauration
src/functions/tweaks     moteur de tweaks (application / annulation / état)
src/functions/control    contrôle + rapport HTML, nettoyage, outils portables
src/xaml/MainWindow.xaml interface
src/main.ps1             construction de l'interface et événements
config/*.json            tweaks, profils, actions de nettoyage (déclaratifs)
Compile.ps1              assemble tout dans dist/toolkit.ps1
```

```powershell
.\Compile.ps1            # génère dist/toolkit.ps1 + toolkit.ps1.sha256
```
`Compile.ps1` échoue en cas d'erreur de syntaxe, de JSON ou de XAML invalide, ou si un caractère typographique (tiret long, guillemet courbe, etc.) se glisse dans le code PowerShell : ces caractères cassent Windows PowerShell 5.1.

### Ajouter un tweak

Ajoute une entrée dans `config/tweaks.json` :
```json
{
  "id": "TK_Exemple", "category": "Durcissement", "risk": "low",
  "name": "Nom affiché", "description": "Pourquoi / impact",
  "registry": [ { "path": "HKLM:\\...", "name": "Valeur", "type": "DWord", "value": "1", "original": "<RemoveEntry>" } ],
  "services": [ { "name": "Service", "startup": "Disabled", "original": "Manual" } ],
  "invoke": "code PowerShell", "undo": "code PowerShell", "test": "code renvoyant $true si appliqué",
  "restartExplorer": false, "reboot": false
}
```
- `original` ne sert que si aucune sauvegarde n'existe. À la première application, les valeurs réelles du poste sont enregistrées dans `%ProgramData%\TechToolkit\state.json`.
- Un réglage `"risk": "medium"` affiche « à tester » et demande une confirmation avant application.

## Journaux et sorties

- Journal : `%ProgramData%\TechToolkit\logs\`
- Rapports : `Collecte\` sur la partition Ventoy en mode USB, sinon `%ProgramData%\TechToolkit\Rapports\`

## Sécurité

- `irm | iex` exécute ce que sert le dépôt : protège la branche `main` (pas de push direct) et vérifie `dist/toolkit.ps1.sha256`.
- L'effacement des journaux d'événements et du Prefetch est volontairement absent : ce sont des traces utiles en cas d'incident.
- Les réglages HKCU s'appliquent au compte qui lance l'outil. Si l'élévation se fait avec un **autre** compte administrateur, ces réglages iront dans son profil.
