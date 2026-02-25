# Secure File Shredder (PowerShell)

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows](https://img.shields.io/badge/OS-Windows%2010%2F11-informational?logo=windows)
![Algorithms](https://img.shields.io/badge/Algorithms-Gutmann%20%7C%20DoD%205220.22M-0aa)
![ADS](https://img.shields.io/badge/NTFS-ADS%20wipe%20support-7957d5)
![MadeInFrance](https://img.shields.io/badge/Made_in-🟦⬜🟥-ffffff)

Outil de **destruction sécurisée de fichiers et dossiers** en PowerShell, avec :
- **GUI moderne** (WinForms, thème sombre, drag‑and‑drop, résumé taille/compte, barre de progression)
- **Mode CLI** pour automatisation et scripting
- Prise en charge des **flux alternatifs NTFS (ADS)**
- Algorithmes **Gutmann** (N passes) et **DoD 5220.22‑M** (3 passes 00 / FF / aléatoire)
- **Renommage aléatoire** avant suppression, journalisation détaillée
- **Sécurité** : évite les points de réanalyse (symlinks/jonctions)


---

## Caractéristiques
- Deux algorithmes : Gutmann (N passes) & DoD 5220.22-M (3 passes)
- Effacement des ADS NTFS
- Renommage aléatoire avant suppression
- Protection contre les reparse points
- Logs horodatés + barre de progression
- GUI complète avec résumé

---

## Prérequis
- Windows 10/11
- PowerShell 5.1 ou PowerShell 7 Windows
- NTFS recommandé (ADS)

---

## Installation
```powershell
Unblock-File -Path .\SecureShredder.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## Utilisation rapide
### GUI
```powershell
.\SecureShredder.ps1
```

### CLI
```powershell
.\SecureShredder.ps1 -NoUI -Path "C:\SensitiveFile.txt" -Algorithm Gutmann -Passes 35
```

---

## Paramètres
| Paramètre | Type | Description |
|----------|-------|-------------|
| `-Path` | string | Fichier ou dossier à détruire |
| `-Algorithm` | string | `Gutmann` ou `DoD` |
| `-Passes` | int | Nombre de passes (Gutmann seulement) |
| `-Recurse` | switch | Suppression récursive pour dossiers |
| `-NoUI` | switch | Mode CLI |
| `-AskConfirmation` | switch | Confirmation interactive |

---

## Scénarios d'utilisation
### Fichier
```powershell
.\SecureShredder.ps1 -NoUI -Path "C:\Secret.bin"
```

### DoD
```powershell
.\SecureShredder.ps1 -NoUI -Path "C:\Secret.bin" -Algorithm DoD
```

### Dossier récursif
```powershell
.\SecureShredder.ps1 -NoUI -Path "C:\Export" -Recurse
```

---

## 🔥 Algorithmes de suppression

Votre script supporte deux méthodes d’effacement sécurisées : **Gutmann** et **DoD 5220.22‑M**.  
Ces deux algorithmes écrasent le contenu d’un fichier avant sa suppression afin d’empêcher sa récupération.

### 🧬 Algorithme Gutmann (35 passes par défaut)

L’algorithme de Gutmann est un procédé d’effacement extrêmement complet conçu pour les anciens disques durs magnétiques.

#### Fonctionnement :
- Effectue **N passes** (35 par défaut)
- Chaque passe écrit des **données aléatoires** sur l’intégralité du fichier
- Supprime ensuite le fichier et vérifie l’absence de résidus

#### Points clés :
- Très efficace sur les **HDD anciens** sensibles à l’analyse magnétique
- Considérablement **lent** sur les gros fichiers
- Peu utile sur **SSD / NVMe** à cause du wear‑leveling

Dans ce script :
- Les passes historiques spécifiques (MFM/RLL) de 1996 ne sont pas utilisées
- Les passes sont **entièrement aléatoires**, méthode moderne plus réaliste et compatible

### 🛡️ Algorithme DoD 5220.22‑M (3 passes fixes)

Le standard DoD 5220.22‑M est une méthode d’effacement définie par le Département de la Défense américain.

#### Passes utilisées (version la plus courante) :
1. Écriture de **0x00**
2. Écriture de **0xFF**
3. Écriture de **données aléatoires**

#### Points clés :
- Beaucoup plus **rapide** que Gutmann
- Suffisant dans la grande majorité des cas
- Conçu pour les **HDD magnétiques**
- Ne bénéficie pas aux **SSD** (TRIM / wear‑leveling)

Dans ce script :
- Les 3 passes sont **fixes** (le paramètre -Passes est ignoré)
- Le fichier est supprimé après les passes
- Les flux alternatifs NTFS (ADS) sont également nettoyés


### ⚖️ Gutmann vs DoD : quel algorithme choisir ?

| Critère | Gutmann | DoD 5220.22‑M |
|--------|---------|---------------|
| Sécurité (HDD anciens) | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| Vitesse | ❌ Très lent | ✔ Rapide |
| Passes | 35 (ou configurable) | 3 fixes |
| Utile sur SSD | ❌ Non | ❌ Non |
| Usage recommandé | Données ultra-sensibles sur HDD | Usage général |

**Conclusion :**
- Pour un usage courant → **DoD suffit largement**  
- Pour un effacement intensif sur HDD → **Gutmann recommandé**  
- Sur SSD : préférer le **chiffrement** + **Secure Erase** plutôt que l’overwrite


### ⚠️ Important concernant les SSD / NVMe

Les algorithmes Gutmann et DoD sont historiquement conçus pour des **disques durs magnétiques**.  
Sur les SSD, l'écrasement multiple **ne garantit pas** l'effacement réel, à cause :

- du **wear‑leveling** (les écritures vont ailleurs physiquement)
- de la commande **TRIM** (les blocs sont réalloués en arrière‑plan)
- des caches internes du contrôleur

Pour les SSD :
- Utiliser le chiffrement complet du disque (BitLocker)
- Puis effectuer un **Secure Erase** matériel si nécessaire

---

## Bonnes pratiques
- Sur SSD : overwrite ≠ suppression physique (TRIM / wear leveling)
- Préférez chiffrement complet du disque
- Fermer toutes les applications utilisant les fichiers

---

## Dépannage
- *Access denied* → exécuter en Administrateur
- *Path not found* → vérifier guillemets
- *GUI ne se lance pas* → utiliser PowerShell 5.1

---

## Licence
À définir par l'auteur.

> Créé par **Pierre CHAUSSARD** — https://github.com/PierreChrd