[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$Path,

    [ValidateSet("Gutmann", "DoD")]
    [string]$Algorithm = "Gutmann",

    [int]$Passes = 35,

    [switch]$Recurse,
    [switch]$NoUI,

    [switch]$Confirm,

    # Options avancées de suppression
    [switch]$UltraSecure,
    [switch]$Verify,          # Vérifier la dernière passe (0x00)
    [int]$RenameCount = 3,
    [switch]$WipeFreeSpace,
    [switch]$Trim,

    # === NEW: Vérification / Score
    [switch]$VerifyDeletion   # En CLI: calcule et affiche le score après l’opération
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------
# Logging UI/Console
# -----------------------------
function Write-Log {
    param (
        [string]$Message,
        [System.Windows.Forms.TextBox]$TextBox
    )
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$timestamp] $Message"
    if ($TextBox) {
        $TextBox.AppendText($line + [Environment]::NewLine)
        $TextBox.ScrollToCaret()
    }
    else {
        Write-Host $line
    }
}

function Get-DriveLetterFromPath {
    param([string]$FullPath)
    try {
        $root = [System.IO.Path]::GetPathRoot($FullPath)
        if ($root -and $root.Length -ge 2) {
            return $root.Substring(0, 1).ToUpper()
        }
    }
    catch { }
    return $null
}

# -----------------------------
# Overwrite helpers (chunked)
# -----------------------------
function Overwrite-RandomData {
    param ([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $len = $item.Length
    if ($len -le 0) { return }

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $chunkSize = 8MB
    $bytesLeft = $len

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Position = 0
        while ($bytesLeft -gt 0) {
            $take = [Math]::Min($chunkSize, $bytesLeft)
            $buf = New-Object byte[] $take
            $rng.GetBytes($buf)
            $fs.Write($buf, 0, $buf.Length)
            $bytesLeft -= $take
        }
        $fs.Flush($true)
    }
    finally {
        $fs.Close()
    }
}

function Overwrite-Pattern {
    param (
        [string]$Path,
        [byte]$Pattern
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $len = (Get-Item -LiteralPath $Path -Force).Length
    if ($len -le 0) { return }

    $chunkSize = 8MB
    $buf = New-Object byte[] $chunkSize
    [byte[]]::Fill($buf, $Pattern)

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Position = 0
        $left = $len
        while ($left -gt 0) {
            $take = [Math]::Min($chunkSize, $left)
            $fs.Write($buf, 0, $take)
            $left -= $take
        }
        $fs.Flush($true)
    }
    finally {
        $fs.Close()
    }
}

function Verify-Pattern {
    param (
        [string]$Path,
        [byte]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $len = (Get-Item -LiteralPath $Path -Force).Length
    if ($len -le 0) { return $true }

    $probes = 8
    $chunk = 1MB
    $rnd = New-Object System.Random
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        for ($i = 0; $i -lt $probes; $i++) {
            $offset = [long]([double]$len * $rnd.NextDouble())
            if ($offset -gt ($len - $chunk)) { $offset = $len - $chunk }
            if ($offset -lt 0) { $offset = 0 }
            $buf = New-Object byte[] $chunk
            $fs.Position = $offset
            $read = $fs.Read($buf, 0, $buf.Length)
            for ($j = 0; $j -lt $read; $j++) {
                if ($buf[$j] -ne $Expected) { return $false }
            }
        }
        return $true
    }
    finally { $fs.Close() }
}

# -----------------------------
# ADS helpers (NTFS)
# -----------------------------
function Get-AlternateStreams {
    param([string]$Path)
    try {
        Get-Item -LiteralPath $Path -Force -Stream * -ErrorAction Stop |
        Where-Object { $_.Stream -ne '::$DATA' }
    }
    catch { @() }
}

function Remove-ADS-Secure {
    param(
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )
    $adsList = Get-AlternateStreams -Path $Path
    $ok = $true
    foreach ($ads in $adsList) {
        $adsPath = "$Path`:$($ads.Stream)"
        try {
            Overwrite-RandomData -Path $adsPath
            Overwrite-RandomData -Path $adsPath
            Overwrite-Pattern    -Path $adsPath -Pattern 0x00 | Out-Null
            Remove-Item -LiteralPath $adsPath -Force -ErrorAction SilentlyContinue
            Write-Log "ADS wiped: $adsPath" $Output
        }
        catch {
            $ok = $false
            Write-Log "⚠ ADS wipe failed: $adsPath => $($_.Exception.Message)" $Output
        }
    }
    return $ok
}

# -----------------------------
# Prep: attributes + renames + timestamp fog
# -----------------------------
function Prepare-FileForDeletion {
    param(
        [string]$Path,
        [int]$RenameCount = 3
    )
    try { Attrib -R -S -H -A -I -O -U -P -Q -Y -LiteralPath $Path *>$null } catch { }

    $current = $Path
    for ($i = 0; $i -lt $RenameCount; $i++) {
        try {
            $dir = Split-Path -LiteralPath $current -Parent
            $ext = [System.IO.Path]::GetExtension($current)
            $rnd = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
            $newName = if ($ext) { "$rnd$ext" } else { $rnd }
            Rename-Item -LiteralPath $current -NewName $newName -Force
            $current = Join-Path $dir $newName
        }
        catch { break }
    }

    try {
        $dt = Get-Date ((Get-Date).AddYears( - (Get-Random -Min 5 -Max 15))) -Hour (Get-Random -Min 0 -Max 23) -Minute (Get-Random -Min 0 -Max 59)
        (Get-Item -LiteralPath $current -Force).CreationTime = $dt
        (Get-Item -LiteralPath $current -Force).LastWriteTime = $dt
        (Get-Item -LiteralPath $current -Force).LastAccessTime = $dt
    }
    catch { }

    return $current
}

# -----------------------------
# Algorithms
# -----------------------------
function SecureDelete-DoD {
    param (
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "DoD expects a file. Got directory: $Path" }

    $patterns = @(0x00, 0xFF, $null)
    for ($i = 0; $i -lt $patterns.Count; $i++) {
        $pattern = $patterns[$i]
        if ($pattern -eq $null) {
            Write-Log "DoD pass $($i+1)/3 (random) on $Path..." $Output
            Overwrite-RandomData -Path $Path
        }
        else {
            Write-Log ("DoD pass {0}/3 (pattern 0x{1:X2}) on {2}..." -f ($i + 1), $pattern, $Path) $Output
            Overwrite-Pattern -Path $Path -Pattern ([byte]$pattern)
        }
    }
    Remove-Item -LiteralPath $Path -Force
    Write-Log "✔ Deleted (DoD): $Path" $Output
}

function SecureDelete-Gutmann {
    param (
        [string]$Path,
        [int]$Iterations = 35,
        [System.Windows.Forms.TextBox]$Output
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Gutmann expects a file. Got directory: $Path" }

    for ($i = 1; $i -le $Iterations; $i++) {
        Write-Log "Gutmann pass $i/$Iterations on $Path..." $Output
        Overwrite-RandomData -Path $Path
    }
    Remove-Item -LiteralPath $Path -Force
    Write-Log "✔ Deleted (Gutmann $Iterations passes): $Path" $Output
}

function SecureDelete-Ultra {
    param(
        [string]$Path,
        [int]$RenameCount = 3,
        [switch]$Verify,
        [System.Windows.Forms.TextBox]$Output
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log "⚠ File not found: $Path" $Output
        return [pscustomobject]@{ VerifiedZero = $false; ADSWiped = $false; Removed = $false }
    }

    $work = Prepare-FileForDeletion -Path $Path -RenameCount $RenameCount
    $adsOk = Remove-ADS-Secure -Path $work -Output $Output

    Write-Log "UltraSecure: random pass 1 => $work" $Output
    Overwrite-RandomData -Path $work
    Write-Log "UltraSecure: random pass 2 => $work" $Output
    Overwrite-RandomData -Path $work
    Write-Log "UltraSecure: final 0x00 pass => $work" $Output
    Overwrite-Pattern -Path $work -Pattern 0x00

    $verified = $false
    if ($Verify) {
        Write-Log "UltraSecure: verifying 0x00 pattern..." $Output
        $verified = Verify-Pattern -Path $work -Expected 0x00
        if (-not $verified) { Write-Log "❌ Verification failed: $work" $Output } else { Write-Log "✔ Verification OK" $Output }
    }

    Remove-Item -LiteralPath $work -Force
    Write-Log "✔ Deleted (UltraSecure): $Path" $Output

    return [pscustomobject]@{
        VerifiedZero = [bool]$verified
        ADSWiped     = [bool]$adsOk
        Removed      = $true
    }
}

# -----------------------------
# Free space wipe & TRIM
# -----------------------------
function Invoke-FreeSpaceWipe {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern("^[A-Z]$")][string]$DriveLetter,
        [System.Windows.Forms.TextBox]$Output
    )
    $root = "$DriveLetter`:\"
    Write-Log "Wiping free space on $root ..." $Output

    $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    $isNTFS = $false
    if ($vol -and $vol.FileSystem -eq 'NTFS') { $isNTFS = $true }

    if ($isNTFS) {
        try {
            Start-Process -FilePath "$env:SystemRoot\System32\cipher.exe" -ArgumentList "/w:$root" -Wait -NoNewWindow
            Write-Log "✔ cipher /w completed on $root" $Output
            return $true
        }
        catch {
            Write-Log "cipher /w failed on $root, fallback to fill-file method. Reason: $($_.Exception.Message)" $Output
        }
    }

    $wipeFile = Join-Path $root "__wipe_free_space__.bin"
    try {
        $fs = [System.IO.File]::Open($wipeFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buf = New-Object byte[] (8MB)
        $wrote = 0
        try {
            while ($true) {
                $fs.Write($buf, 0, $buf.Length)
                $wrote += $buf.Length
                if (($wrote % (512MB)) -eq 0) { Write-Log ("... wrote {0:N0} MB" -f ($wrote / 1MB)) $Output }
            }
        }
        catch { } finally { $fs.Flush($true); $fs.Close() }
    }
    catch { Write-Log "⚠ Fallback write failed: $($_.Exception.Message)" $Output } finally {
        try { Remove-Item -LiteralPath $wipeFile -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-Log "✔ free space wipe (fallback) completed on $root" $Output
    return $true
}

function Invoke-ReTrim {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern("^[A-Z]$")][string]$DriveLetter,
        [System.Windows.Forms.TextBox]$Output
    )
    try {
        Optimize-Volume -DriveLetter $DriveLetter -ReTrim -Verbose -ErrorAction Stop | Out-Null
        Write-Log "✔ ReTrim done on $DriveLetter :`\" $Output
        return $true
    }
    catch {
        Write-Log "⚠ ReTrim failed on $DriveLetter :`\" $Output
        return $false
    }
}

# -----------------------------
# === NEW: Détection de snapshots (VSS)
# -----------------------------
function Test-VolumeHasShadowCopies {
    param([Parameter(Mandatory = $true)][ValidatePattern("^[A-Z]$")][string]$DriveLetter)
    try {
        $out = (vssadmin list shadows) 2>$null
        if (-not $out) { return $false }
        # Cherche des snapshots qui pointent sur la même partition (Volume name contient la lettre)
        # C'est un check heuristique (non destructif)
        return ($out -match ("Volume: .*" + [regex]::Escape("$DriveLetter") + ":\\"))
    }
    catch { return $false }
}

# -----------------------------
# === NEW: Score de délétion
# -----------------------------
function New-DeletionReport {
    param(
        [string]$OriginalPath,
        [string]$Algorithm,
        [switch]$UltraSecure,
        [bool]$VerifiedZero,
        [bool]$ADSWiped,
        [bool]$Removed,
        [bool]$FreeSpaceWipeDone,
        [bool]$TrimDone
    )
    $drive = Get-DriveLetterFromPath -FullPath $OriginalPath
    $hasVSS = if ($drive) { Test-VolumeHasShadowCopies -DriveLetter $drive } else { $false }

    [pscustomobject]@{
        OriginalPath      = $OriginalPath
        Algorithm         = if ($UltraSecure) { "UltraSecure" } else { $Algorithm }
        VerifiedZero      = [bool]$VerifiedZero
        ADSWiped          = [bool]$ADSWiped
        Removed           = [bool]$Removed
        FreeSpaceWipeDone = [bool]$FreeSpaceWipeDone
        TrimDone          = [bool]$TrimDone
        VolumeHasVSS      = [bool]$hasVSS
        Timestamp         = (Get-Date)
    }
}

function Compute-DeletionScore {
    param([Parameter(Mandatory = $true)]$Report)

    $score = 0
    $details = @()

    if ($Report.Removed) {
        $score += 20; $details += "+20 : fichier supprimé (pas de Corbeille)"
    }
    else {
        $details += "  0 : fichier toujours présent"
    }

    if ($Report.VerifiedZero) {
        $score += 40; $details += "+40 : vérification contenu (0x00) OK"
    }
    else {
        $details += "  0 : vérification du contenu non effectuée/échouée"
    }

    if ($Report.ADSWiped) {
        $score += 20; $details += "+20 : ADS nettoyés"
    }
    else {
        $details += "  0 : ADS non confirmés"
    }

    if ($Report.FreeSpaceWipeDone) {
        $score += 10; $details += "+10 : espace libre écrasé"
    }
    else {
        $details += "  0 : espace libre non écrasé"
    }

    if ($Report.TrimDone) {
        $score += 10; $details += "+10 : TRIM/ReTrim effectué"
    }
    else {
        $details += "  0 : TRIM non effectué"
    }

    if ($Report.VolumeHasVSS) {
        $score -= 10; $details += "−10 : snapshots VSS présents (risque résiduel)"
    }

    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    # classification simple
    $class = switch ($score) {
        { $_ -ge 98 } { "Effacement irréversible" ; break }
        { $_ -ge 90 } { "Effacement excellent" ; break }
        { $_ -ge 75 } { "Bon" ; break }
        { $_ -ge 50 } { "Moyen" ; break }
        default { "Faible (récupération plausible)" }
    }

    [pscustomobject]@{
        Score          = [int][Math]::Round($score, 0)
        Classification = $class
        Breakdown      = $details
    }
}

# -----------------------------
# === NEW: Quick check indépendant
# -----------------------------
function Test-DeletionQuickCheck {
    param([Parameter(Mandatory = $true)][string]$Path)

    $exists = Test-Path -LiteralPath $Path
    $drive = Get-DriveLetterFromPath -FullPath $Path
    $hasVSS = if ($drive) { Test-VolumeHasShadowCopies -DriveLetter $drive } else { $false }

    if ($exists) {
        return [pscustomobject]@{
            Score          = 0
            Classification = "Fichier présent"
            Breakdown      = @("0 : fichier toujours présent")
        }
    }
    else {
        # Estimation prudente sans logs d’opération
        $score = 60
        $details = @("+60 : fichier absent (aucune preuve contraire)")
        if ($hasVSS) { $score -= 10; $details += "−10 : snapshots VSS présents" }
        return [pscustomobject]@{
            Score          = [int]$score
            Classification = if ($score -ge 75) { "Bon" } elseif ($score -ge 50) { "Moyen" } else { "Faible" }
            Breakdown      = $details
        }
    }
}

# -----------------------------
# Secure delete (file)
# -----------------------------
function SecureDelete-File {
    param(
        [string]$Path,
        [string]$Algorithm = "DoD",
        [int]$Passes = 35,
        [switch]$UltraSecure,
        [switch]$Verify,
        [int]$RenameCount = 3,
        [switch]$WipeFreeSpace,
        [switch]$Trim,
        [System.Windows.Forms.TextBox]$Output
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log "⚠ File not found: $Path" $Output
        return $null
    }

    $fsWiped = $false
    $trimmed = $false
    $algo = $Algorithm
    $verified0 = $false
    $adsOk = $false
    $removed = $false

    if ($UltraSecure) {
        $result = SecureDelete-Ultra -Path $Path -RenameCount $RenameCount -Verify:$Verify -Output $Output
        $verified0 = [bool]$result.VerifiedZero
        $adsOk = [bool]$result.ADSWiped
        $removed = [bool]$result.Removed
        $algo = "UltraSecure"
    }
    else {
        $path2 = Prepare-FileForDeletion -Path $Path -RenameCount $RenameCount
        $adsOk = Remove-ADS-Secure -Path $path2 -Output $Output
        switch ($Algorithm) {
            "Gutmann" { SecureDelete-Gutmann -Path $path2 -Iterations $Passes -Output $Output }
            "DoD" { SecureDelete-DoD     -Path $path2 -Output $Output }
        }
        $removed = $true

        if ($Verify -and (Test-Path -LiteralPath $path2 -PathType Leaf)) {
            # Cas très rare si suppression a échoué
            $verified0 = Verify-Pattern -Path $path2 -Expected 0x00
        }
        elseif ($Verify) {
            # Vérif non applicable car déjà supprimé
            $verified0 = $false
        }
    }

    # Wipe espace libre / TRIM si demandé
    $drv = Get-DriveLetterFromPath -FullPath $Path
    if ($WipeFreeSpace -and $drv) { $fsWiped = Invoke-FreeSpaceWipe -DriveLetter $drv -Output $Output }
    if ($Trim -and $drv) { $trimmed = Invoke-ReTrim -DriveLetter $drv -Output $Output }

    # Rapport & Score
    $report = New-DeletionReport -OriginalPath $Path -Algorithm $Algorithm -UltraSecure:$UltraSecure -VerifiedZero:$verified0 -ADSWiped:$adsOk -Removed:$removed -FreeSpaceWipeDone:$fsWiped -TrimDone:$trimmed
    $score = Compute-DeletionScore -Report $report

    Write-Log ("► Deletion Score: {0}% — {1}" -f $score.Score, $score.Classification) $Output
    foreach ($line in $score.Breakdown) { Write-Log ("   " + $line) $Output }

    return [pscustomobject]@{
        Report = $report
        Score  = $score
    }
}

# -----------------------------
# Secure delete (folder)
# -----------------------------
function SecureDelete-Folder {
    param(
        [string]$FolderPath,
        [string]$Algorithm = "DoD",
        [int]$Passes = 35,
        [switch]$UltraSecure,
        [switch]$Verify,
        [int]$RenameCount = 3,
        [switch]$Recurse,
        [switch]$WipeFreeSpace,
        [switch]$Trim,
        [System.Windows.Forms.TextBox]$Output
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        Write-Log "⚠ Folder not found: $FolderPath" $Output
        return $null
    }

    $folderItem = Get-Item -LiteralPath $FolderPath -Force
    if ($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log "⚠ Skipping reparse point: $FolderPath" $Output
        return $null
    }

    Write-Log "Scanning folder: $FolderPath (Recurse=$Recurse)" $Output

    $files = if ($Recurse) {
        Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction SilentlyContinue
    }
    else {
        Get-ChildItem -LiteralPath $FolderPath -File -Force -ErrorAction SilentlyContinue
    }

    $fsWipedOverall = $false
    $trimmedOverall = $false
    $drv = Get-DriveLetterFromPath -FullPath $FolderPath

    $allReports = @()
    foreach ($f in $files) {
        try {
            $res = SecureDelete-File -Path $f.FullName -Algorithm $Algorithm -Passes $Passes -UltraSecure:$UltraSecure -Verify:$Verify -RenameCount $RenameCount -Output $Output
            if ($res) { $allReports += $res.Report }
        }
        catch {
            Write-Log "❌ File delete failed: $($f.FullName) => $($_.Exception.Message)" $Output
        }
    }

    # Remove directories bottom-up
    $dirs = if ($Recurse) {
        Get-ChildItem -LiteralPath $FolderPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    }
    else { @() }

    foreach ($d in $dirs) {
        try {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    try {
        Remove-Item -LiteralPath $FolderPath -Force -ErrorAction SilentlyContinue
        Write-Log "✔ Folder removed: $FolderPath" $Output
        if ($drv -and $WipeFreeSpace) { $fsWipedOverall = Invoke-FreeSpaceWipe -DriveLetter $drv -Output $Output }
        if ($drv -and $Trim) { $trimmedOverall = Invoke-ReTrim -DriveLetter $drv -Output $Output }
    }
    catch {
        Write-Log "⚠ Could not remove folder (in use or not empty): $FolderPath" $Output
    }

    # Score dossier: moyenne pondérée des fichiers, + bonus si wipe/trim sur volume
    if ($allReports.Count -gt 0) {
        $scores = $allReports | ForEach-Object { (Compute-DeletionScore -Report $_).Score }
        $avg = [int]([Math]::Round(($scores | Measure-Object -Average).Average, 0))
        if ($fsWipedOverall) { $avg = [Math]::Min(100, $avg + 5) }
        if ($trimmedOverall) { $avg = [Math]::Min(100, $avg + 5) }
        Write-Log ("► Folder Deletion Score (avg): {0}%" -f $avg) $Output
        return [pscustomobject]@{ Score = $avg; Reports = $allReports }
    }
    else {
        return $null
    }
}

# -----------------------------
# GUI
# -----------------------------
function Start-ShredderGUI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Secure File Shredder"
    $form.Size = New-Object System.Drawing.Size(660, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(10, 10)
    $listBox.Size = New-Object System.Drawing.Size(620, 220)
    $listBox.SelectionMode = "MultiExtended"
    $form.Controls.Add($listBox)

    $buttonSelect = New-Object System.Windows.Forms.Button
    $buttonSelect.Location = New-Object System.Drawing.Point(10, 240)
    $buttonSelect.Size = New-Object System.Drawing.Size(120, 30)
    $buttonSelect.Text = "Select"
    $buttonSelect.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Multiselect = $true
            $dlg.Filter = "All files (*.*)|*.*"
            if ($dlg.ShowDialog() -eq "OK") {
                foreach ($f in $dlg.FileNames) {
                    if (-not $listBox.Items.Contains($f)) {
                        $listBox.Items.Add($f)
                    }
                }
            }
        })
    $form.Controls.Add($buttonSelect)

    $buttonDelete = New-Object System.Windows.Forms.Button
    $buttonDelete.Location = New-Object System.Drawing.Point(140, 240)
    $buttonDelete.Size = New-Object System.Drawing.Size(120, 30)
    $buttonDelete.Text = "Delete"
    $form.Controls.Add($buttonDelete)

    $buttonAnalyze = New-Object System.Windows.Forms.Button
    $buttonAnalyze.Location = New-Object System.Drawing.Point(270, 240)
    $buttonAnalyze.Size = New-Object System.Drawing.Size(150, 30)
    $buttonAnalyze.Text = "Analyser / Scorer"
    $form.Controls.Add($buttonAnalyze)

    $labelAlgorithm = New-Object System.Windows.Forms.Label
    $labelAlgorithm.Location = New-Object System.Drawing.Point(10, 280)
    $labelAlgorithm.Text = "Deletion algorithm:"
    $form.Controls.Add($labelAlgorithm)

    $comboBoxAlgorithm = New-Object System.Windows.Forms.ComboBox
    $comboBoxAlgorithm.Location = New-Object System.Drawing.Point(10, 300)
    $comboBoxAlgorithm.Size = New-Object System.Drawing.Size(240, 20)
    $comboBoxAlgorithm.Items.Add("UltraSecure (Pro)")
    $comboBoxAlgorithm.Items.Add("Gutmann (35 passes)")
    $comboBoxAlgorithm.Items.Add("DoD 5220.22-M (3 passes)")
    $comboBoxAlgorithm.SelectedIndex = 0
    $form.Controls.Add($comboBoxAlgorithm)

    $checkVerify = New-Object System.Windows.Forms.CheckBox
    $checkVerify.Location = New-Object System.Drawing.Point(270, 300)
    $checkVerify.Text = "Verify last pass"
    $checkVerify.Checked = $true
    $form.Controls.Add($checkVerify)

    $checkWipe = New-Object System.Windows.Forms.CheckBox
    $checkWipe.Location = New-Object System.Drawing.Point(400, 300)
    $checkWipe.Text = "Wipe free space"
    $checkWipe.Checked = $false
    $form.Controls.Add($checkWipe)

    $checkTrim = New-Object System.Windows.Forms.CheckBox
    $checkTrim.Location = New-Object System.Drawing.Point(520, 300)
    $checkTrim.Text = "TRIM"
    $checkTrim.Checked = $false
    $form.Controls.Add($checkTrim)

    $labelIterations = New-Object System.Windows.Forms.Label
    $labelIterations.Location = New-Object System.Drawing.Point(10, 325)
    $labelIterations.Text = "Gutmann iterations:"
    $form.Controls.Add($labelIterations)

    $numericUpDownIterations = New-Object System.Windows.Forms.NumericUpDown
    $numericUpDownIterations.Location = New-Object System.Drawing.Point(130, 323)
    $numericUpDownIterations.Minimum = 1
    $numericUpDownIterations.Maximum = 100
    $numericUpDownIterations.Value = 35
    $form.Controls.Add($numericUpDownIterations)

    $labelRename = New-Object System.Windows.Forms.Label
    $labelRename.Location = New-Object System.Drawing.Point(270, 325)
    $labelRename.Text = "Random renames:"
    $form.Controls.Add($labelRename)

    $numericRename = New-Object System.Windows.Forms.NumericUpDown
    $numericRename.Location = New-Object System.Drawing.Point(380, 323)
    $numericRename.Minimum = 0
    $numericRename.Maximum = 10
    $numericRename.Value = 3
    $form.Controls.Add($numericRename)

    $textBoxProgress = New-Object System.Windows.Forms.TextBox
    $textBoxProgress.Location = New-Object System.Drawing.Point(10, 355)
    $textBoxProgress.Size = New-Object System.Drawing.Size(620, 100)
    $textBoxProgress.Multiline = $true
    $textBoxProgress.ScrollBars = "Vertical"
    $form.Controls.Add($textBoxProgress)

    # Actions
    $buttonDelete.Add_Click({
            $items = @($listBox.SelectedItems)
            if ($items.Count -eq 0) { Write-Log "⚠ No file selected." $textBoxProgress; return }

            foreach ($item in $items) {
                if (-not (Test-Path -LiteralPath $item)) {
                    Write-Log "⚠ Not found: $item" $textBoxProgress
                    continue
                }
                $choice = $comboBoxAlgorithm.SelectedItem
                $drv = Get-DriveLetterFromPath -FullPath $item
                switch -Wildcard ($choice) {
                    "UltraSecure*" {
                        SecureDelete-File -Path $item -UltraSecure -Verify:$($checkVerify.Checked) -RenameCount ([int]$numericRename.Value) -WipeFreeSpace:$($checkWipe.Checked) -Trim:$($checkTrim.Checked) -Output $textBoxProgress | Out-Null
                    }
                    "Gutmann*" {
                        SecureDelete-File -Path $item -Algorithm Gutmann -Passes ([int]$numericUpDownIterations.Value) -RenameCount ([int]$numericRename.Value) -WipeFreeSpace:$($checkWipe.Checked) -Trim:$($checkTrim.Checked) -Output $textBoxProgress | Out-Null
                    }
                    "DoD*" {
                        SecureDelete-File -Path $item -Algorithm DoD -RenameCount ([int]$numericRename.Value) -WipeFreeSpace:$($checkWipe.Checked) -Trim:$($checkTrim.Checked) -Output $textBoxProgress | Out-Null
                    }
                }
                $listBox.Items.Remove($item)
            }
        })

    $buttonAnalyze.Add_Click({
            $items = @($listBox.SelectedItems)
            if ($items.Count -eq 0) {
                Write-Log "ℹ Entrez un chemin à analyser (quick check)..." $textBoxProgress
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $dlg.Multiselect = $false
                $dlg.Filter = "All files (*.*)|*.*"
                if ($dlg.ShowDialog() -eq "OK") { $items = @($dlg.FileName) } else { return }
            }

            foreach ($item in $items) {
                $qc = Test-DeletionQuickCheck -Path $item
                Write-Log ("► QuickCheck Score: {0}% — {1}" -f $qc.Score, $qc.Classification) $textBoxProgress
                foreach ($line in $qc.Breakdown) { Write-Log ("   " + $line) $textBoxProgress }
            }
        })

    $comboBoxAlgorithm.add_SelectedIndexChanged({
            $numericUpDownIterations.Enabled = ($comboBoxAlgorithm.SelectedItem -like "Gutmann*")
            $checkVerify.Enabled = ($comboBoxAlgorithm.SelectedItem -like "UltraSecure*")
        })

    $form.ShowDialog() | Out-Null
}

# -----------------------------
# Entry point: CLI or GUI
# -----------------------------
if ($NoUI) {
    if (-not $Path) {
        throw "In CLI mode (-NoUI), you must provide -Path (file or folder)."
    }

    if ($Confirm) {
        $q = Read-Host "DELETE '$Path' using $(if($UltraSecure){'UltraSecure'}else{$Algorithm})? (Y/N)"
        if ($q -notin @('Y', 'y', 'O', 'o')) { Write-Host "Cancelled."; exit 0 }
    }

    $result = $null

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $result = SecureDelete-File -Path $Path -Algorithm $Algorithm -Passes $Passes -UltraSecure:$UltraSecure -Verify:$Verify -RenameCount $RenameCount -WipeFreeSpace:$WipeFreeSpace -Trim:$Trim
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        $result = SecureDelete-Folder -FolderPath $Path -Algorithm $Algorithm -Passes $Passes -UltraSecure:$UltraSecure -Verify:$Verify -RenameCount $RenameCount -Recurse:$Recurse -WipeFreeSpace:$WipeFreeSpace -Trim:$Trim
    }
    else {
        throw "Path not found: $Path"
    }

    if ($VerifyDeletion) {
        if ($result -and $result.Score) {
            $s = $result.Score
            Write-Host ""
            Write-Host ("=== Deletion Score ===`nScore: {0}%`nClass: {1}" -f $s.Score, $s.Classification)
            Write-Host ("Details:`n - " + ($s.Breakdown -join "`n - "))
        }
        else {
            # Aucun log d’opération (ex: vérification indépendante)
            $qc = Test-DeletionQuickCheck -Path $Path
            Write-Host ("[QuickCheck] Score: {0}% — {1}" -f $qc.Score, $qc.Classification)
            Write-Host ("Details:`n - " + ($qc.Breakdown -join "`n - "))
        }
    }
}
else {
    Start-ShredderGUI
}