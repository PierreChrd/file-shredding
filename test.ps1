$path = "C:\Users\pchaussa\OneDrive - Capgemini\001_Scripts PowerShell\z - Autres\file-shredding\main.ps1"

# 1) Charger en texte brut
$content = Get-Content -LiteralPath $path -Raw

# 2) Corriger les entités HTML usuelles
$map = @{
  '&gt;'    = '>'
  '&lt;'    = '<'
  '&quot;'  = '"'
  '&apos;'  = "'"
  '&amp;'   = '&'
}
foreach ($k in $map.Keys) { $content = $content.Replace($k, $map[$k]) }

# 3) Remplacer les caractères problématiques par des équivalents ASCII
#    NBSP (0x00A0), ZWSP (200B), ZWNJ (200C), ZWJ (200D), BOM (FEFF)
#    Guillemets typographiques, tirets en/em, etc.
$repls = @{
  ([char]0x00A0) = ' '   # NBSP -> espace normal
  ([char]0x200B) = ''    # Zero Width Space -> supprimer
  ([char]0x200C) = ''    # Zero Width Non-Joiner
  ([char]0x200D) = ''    # Zero Width Joiner
  ([char]0xFEFF) = ''    # BOM/ZWNBSP
  ([char]0x2018) = "'"   # ‘
  ([char]0x2019) = "'"   # ’
  ([char]0x201C) = '"'   # “
  ([char]0x201D) = '"'   # ”
  ([char]0x2013) = '-'   # –
  ([char]0x2014) = '-'   # —
  ([char]0x25BA) = '>'   # ► (optionnel)
}
foreach ($k in $repls.Keys) { $content = $content.Replace($k, $repls[$k]) }

# 4) Sauvegarder en UTF-8 (sans BOM)
Set-Content -LiteralPath $path -Value $content -Encoding UTF8
Write-Host "Nettoyage terminé. Ré-essaie d'exécuter le script."