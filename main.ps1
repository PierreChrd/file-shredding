[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$false)]
    [string]$Path,

    [ValidateSet("Gutmann","DoD")]
    [string]$Algorithm = "Gutmann",

    [int]$Passes = 35,

    [switch]$Recurse,
    [switch]$NoUI,

    [switch]$Confirm,

    # --- Nouveaux paramètres ---
    [switch]$UltraSecure,     # Chaîne “pro”
    [switch]$Verify,          # Vérifie la dernière passe (0x00)
    [int]$RenameCount = 3,    # Renommages aléatoires avant wipe
    [switch]$WipeFreeSpace,   # Wipe espace libre des volumes concernés
    [switch]$Trim             # Optimize-Volume -ReTrim sur les volumes
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
    } else {
        Write-Host $line
    }
}

function Get-DriveLetterFromPath {
    param([string]$FullPath)
    try {
        $root = [System.IO.Path]::GetPathRoot($FullPath)
        if ($root -and $root.Length -ge 2) {
            return $root.Substring(0,1).ToUpper()
        }
    } catch { }
    return $null
}

# --- Random strong ---
function Overwrite-RandomData {
    param ([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $len  = $item.Length
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
    } finally {
        $fs.Close()
    }
}

# --- Pattern overwrite with verification-friendly last pass ---
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
    } finally {
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

    $probes = 8  # lectures aléatoires
    $chunk  = 1MB
    $rnd = New-Object System.Random
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        for ($i=0; $i -lt $probes; $i++) {
            $offset = [long]($rnd.NextDouble() * [double]$len)
            if ($offset -gt ($len - $chunk)) { $offset = $len - $chunk }
            if ($offset -lt 0) { $offset = 0 }
            $buf = New-Object byte[] $chunk
            $fs.Position = $offset
            $read = $fs.Read($buf, 0, $buf.Length)
            for ($j=0; $j -lt $read; $j++) {
                if ($buf[$j] -ne $Expected) { return $false }
            }
        }
        return $true
    } finally { $fs.Close() }
}

function Get-AlternateStreams {
    param([string]$Path)
    try {
        Get-Item -LiteralPath $Path -Force -Stream * -ErrorAction Stop |
        Where-Object { $_.Stream -ne '::$DATA' }
    } catch { @() }
}

function Remove-ADS-Secure {
    param(
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )
    $adsList = Get-AlternateStreams -Path $Path
    foreach ($ads in $adsList) {
        $adsPath = "$Path`:$($ads.Stream)"
        try {
            # 2 passes random + 1 pass 0x00
            Overwrite-RandomData -Path $adsPath
            Overwrite-RandomData -Path $adsPath
            Overwrite-Pattern    -Path $adsPath -Pattern 0x00 | Out-Null
            Remove-Item -LiteralPath $adsPath -Force -ErrorAction SilentlyContinue
            Write-Log "ADS wiped: $adsPath" $Output
        } catch {
            Write-Log "⚠ ADS wipe failed: $adsPath => $($_.Exception.Message)" $Output
        }
    }
}

function Prepare-FileForDeletion {
    param(
        [string]$Path,
        [int]$RenameCount = 3
    )
    try { Attrib -R -S -H -A -I -O -U -P -Q -Y -LiteralPath $Path *>$null } catch { }

    $current = $Path
    for ($i=0; $i -lt $RenameCount; $i++) {
        try {
            $dir  = Split-Path -LiteralPath $current -Parent
            $ext  = [System.IO.Path]::GetExtension($current)
            $rnd  = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_})
            $newName = if ($ext) { "$rnd$ext" } else { $rnd }
            Rename-Item -LiteralPath $current -NewName $newName -Force
            $current = Join-Path $dir $newName
        } catch { break }
    }

    # timestamps brouillés
    try {
        $dt = Get-Date ((Get-Date).AddYears(- (Get-Random -Min 5 -Max 15))) -Hour (Get-Random -Min 0 -Max 23) -Minute (Get-Random -Min 0 -Max 59)
        (Get-Item -LiteralPath $current -Force).CreationTime  = $dt
        (Get-Item -LiteralPath $current -Force).LastWriteTime = $dt
        (Get-Item -LiteralPath $current -Force).LastAccessTime= $dt
    } catch { }

    return $current
}

function SecureDelete-DoD {
    param (
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "DoD expects a file. Got directory: $Path" }

    $fileSize = $item.Length
    $patterns = @(0x00, 0xFF, $null)
    for ($i = 0; $i -lt $patterns.Count; $i++) {
        $pattern = $patterns[$i]
        if ($pattern -eq $null) {
            Write-Log "DoD pass $($i+1)/3 (random) on $Path..." $Output
            Overwrite-RandomData -Path $Path
        } else {
            Write-Log ("DoD pass {0}/3 (pattern 0x{1:X2}) on {2}..." -f ($i+1), $pattern, $Path) $Output
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

# --- Nouveau : SecureDelete-Ultra (pro) ---
function SecureDelete-Ultra {
    param(
        [string]$Path,
        [int]$RenameCount = 3,
        [switch]$Verify,
        [System.Windows.Forms.TextBox]$Output
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log "⚠ File not found: $Path" $Output
        return $false
    }

    $work = Prepare-FileForDeletion -Path $Path -RenameCount $RenameCount

    # ADS
    Remove-ADS-Secure -Path $work -Output $Output

    # Wipes: 2x random + 1x zero + optional verify
    Write-Log "UltraSecure: random pass 1 => $work" $Output
    Overwrite-RandomData -Path $work
    Write-Log "UltraSecure: random pass 2 => $work" $Output
    Overwrite-RandomData -Path $work
    Write-Log "UltraSecure: final 0x00 pass => $work" $Output
    Overwrite-Pattern -Path $work -Pattern 0x00

    if ($Verify) {
        Write-Log "UltraSecure: verifying 0x00 pattern..." $Output
        $ok = Verify-Pattern -Path $work -Expected 0x00
        if (-not $ok) {
            Write-Log "❌ Verification failed: $work" $Output
            return $false
        } else {
            Write-Log "✔ Verification OK" $Output
        }
    }

    Remove-Item -LiteralPath $work -Force
    Write-Log "✔ Deleted (UltraSecure): $Path" $Output
    return $true
}

function SecureDelete-File {
    param(
        [string]$Path,
        [string]$Algorithm = "DoD",
        [int]$Passes = 35,
        [switch]$UltraSecure,
        [switch]$Verify,
        [int]$RenameCount = 3,
        [System.Windows.Forms.TextBox]$Output
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log "⚠ File not found: $Path" $Output
        return
    }

    if ($UltraSecure) {
        [void](SecureDelete-Ultra -Path $Path -RenameCount $RenameCount -Verify:$Verify -Output $Output)
        return
    }

    $path2 = Prepare-FileForDeletion -Path $Path -RenameCount $RenameCount
    Remove-ADS-Secure -Path $path2 -Output $Output

    switch ($Algorithm) {
        "Gutmann" { SecureDelete-Gutmann -Path $path2 -Iterations $Passes -Output $Output }
        "DoD"     { SecureDelete-DoD     -Path $path2 -Output $Output }
        default   { throw "Unknown algorithm: $Algorithm" }
    }
}

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
        return
    }

    $folderItem = Get-Item -LiteralPath $FolderPath -Force
    if ($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log "⚠ Skipping reparse point: $FolderPath" $Output
        return
    }

    Write-Log "Scanning folder: $FolderPath (Recurse=$Recurse)" $Output

    $files = if ($Recurse) {
        Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $FolderPath -File -Force -ErrorAction SilentlyContinue
    }

    $touchedDrives = New-Object System.Collections.Generic.HashSet[string]

    foreach ($f in $files) {
        try {
            SecureDelete-File -Path $f.FullName -Algorithm $Algorithm -Passes $Passes -UltraSecure:$UltraSecure -Verify:$Verify -RenameCount $RenameCount -Output $Output
            $drv = Get-DriveLetterFromPath -FullPath $f.FullName
            if ($drv) { [void]$touchedDrives.Add($drv) }
        } catch {
            Write-Log "❌ File delete failed: $($f.FullName) => $($_.Exception.Message)" $Output
        }
    }

    # Remove dirs bottom-up
    $dirs = if ($Recurse) {
        Get-ChildItem -LiteralPath $FolderPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    } else { @() }

    foreach ($d in $dirs) {
        try {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    try {
        Remove-Item -LiteralPath $FolderPath -Force -ErrorAction SilentlyContinue
        Write-Log "✔ Folder removed: $FolderPath" $Output
        $drv = Get-DriveLetterFromPath -FullPath $FolderPath
        if ($drv) { [void]$touchedDrives.Add($drv) }
    } catch {
        Write-Log "⚠ Could not remove folder (in use or not empty): $FolderPath" $Output
    }

    if ($WipeFreeSpace -and $touchedDrives.Count -gt 0) {
        foreach ($drive in $touchedDrives) {
            Invoke-FreeSpaceWipe -DriveLetter $drive -Output $Output
            if ($Trim) { Invoke-ReTrim -DriveLetter $drive -Output $Output }
        }
    }
}

# --- Wipe de l’espace libre ---
function Invoke-FreeSpaceWipe {
    param(
        [Parameter(Mandatory=$true)][ValidatePattern("^[A-Z]$")][string]$DriveLetter,
        [System.Windows.Forms.TextBox]$Output
    )
    $root = "$DriveLetter`:\"
    Write-Log "Wiping free space on $root ..." $Output

    # NTFS ? -> cipher /w: sinon fallback “fichier de remplissage”
    $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    $isNTFS = $false
    if ($vol -and $vol.FileSystem -eq 'NTFS') { $isNTFS = $true }

    if ($isNTFS) {
        try {
            Start-Process -FilePath "$env:SystemRoot\System32\cipher.exe" -ArgumentList "/w:$root" -Wait -NoNewWindow
            Write-Log "✔ cipher /w completed on $root" $Output
            return
        } catch {
            Write-Log "cipher /w failed on $root, fallback to fill-file method. Reason: $($_.Exception.Message)" $Output
        }
    }

    # Fallback: remplir l’espace libre
    $wipeFile = Join-Path $root "__wipe_free_space__.bin"
    try {
        $fs = [System.IO.File]::Open($wipeFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buf = New-Object byte[] (8MB)
        # On écrit des zéros (suffisant pour clear l’espace libre)
        $wrote = 0
        try {
            while ($true) {
                $fs.Write($buf, 0, $buf.Length)
                $wrote += $buf.Length
                if (($wrote % (512MB)) -eq 0) { Write-Log ("... wrote {0:N0} MB" -f ($wrote/1MB)) $Output }
            }
        } catch {
            # Arrive quand disque plein
        } finally {
            $fs.Flush($true)
            $fs.Close()
        }
    } catch { Write-Log "⚠ Fallback write failed: $($_.Exception.Message)" $Output }
    finally {
        try { Remove-Item -LiteralPath $wipeFile -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-Log "✔ free space wipe (fallback) completed on $root" $Output
}

# --- TRIM/ReTrim ---
function Invoke-ReTrim {
    param(
        [Parameter(Mandatory=$true)][ValidatePattern("^[A-Z]$")][string]$DriveLetter,
        [System.Windows.Forms.TextBox]$Output
    )
    try {
        Optimize-Volume -DriveLetter $DriveLetter -ReTrim -Verbose -ErrorAction Stop | Out-Null
        Write-Log "✔ ReTrim done on $DriveLetter:`\" $Output
    } catch {
        Write-Log "⚠ ReTrim failed on $DriveLetter:`\" $Output
    }
}

# --- GUI identique à avant (tu peux l’enrichir pour exposer UltraSecure) ---
function Start-ShredderGUI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Secure File Shredder"
    $form.Size = New-Object System.Drawing.Size(620,460)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(10,10)
    $listBox.Size = New-Object System.Drawing.Size(580,200)
    $listBox.SelectionMode = "MultiExtended"
    $form.Controls.Add($listBox)

    $buttonSelect = New-Object System.Windows.Forms.Button
    $buttonSelect.Location = New-Object System.Drawing.Point(10,220)
    $buttonSelect.Size = New-Object System.Drawing.Size(120,30)
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

    $labelAlgorithm = New-Object System.Windows.Forms.Label
    $labelAlgorithm.Location = New-Object System.Drawing.Point(10,260)
    $labelAlgorithm.Text = "Deletion algorithm:"
    $form.Controls.Add($labelAlgorithm)

    $comboBoxAlgorithm = New-Object System.Windows.Forms.ComboBox
    $comboBoxAlgorithm.Location = New-Object System.Drawing.Point(10,280)
    $comboBoxAlgorithm.Size = New-Object System.Drawing.Size(220,20)
    $comboBoxAlgorithm.Items.Add("UltraSecure (Pro)")
    $comboBoxAlgorithm.Items.Add("Gutmann (35 passes)")
    $comboBoxAlgorithm.Items.Add("DoD 5220.22-M (3 passes)")
    $comboBoxAlgorithm.SelectedIndex = 0
    $form.Controls.Add($comboBoxAlgorithm)

    $checkVerify = New-Object System.Windows.Forms.CheckBox
    $checkVerify.Location = New-Object System.Drawing.Point(250,280)
    $checkVerify.Text = "Verify last pass"
    $checkVerify.Checked = $true
    $form.Controls.Add($checkVerify)

    $labelIterations = New-Object System.Windows.Forms.Label
    $labelIterations.Location = New-Object System.Drawing.Point(10,305)
    $labelIterations.Text = "Gutmann iterations:"
    $form.Controls.Add($labelIterations)

    $numericUpDownIterations = New-Object System.Windows.Forms.NumericUpDown
    $numericUpDownIterations.Location = New-Object System.Drawing.Point(150,303)
    $numericUpDownIterations.Minimum = 1
    $numericUpDownIterations.Maximum = 100
    $numericUpDownIterations.Value = 35
    $form.Controls.Add($numericUpDownIterations)

    $labelRename = New-Object System.Windows.Forms.Label
    $labelRename.Location = New-Object System.Drawing.Point(250,305)
    $labelRename.Text = "Random renames:"
    $form.Controls.Add($labelRename)

    $numericRename = New-Object System.Windows.Forms.NumericUpDown
    $numericRename.Location = New-Object System.Drawing.Point(360,303)
    $numericRename.Minimum = 0
    $numericRename.Maximum = 10
    $numericRename.Value = 3
    $form.Controls.Add($numericRename)

    $textBoxProgress = New-Object System.Windows.Forms.TextBox
    $textBoxProgress.Location = New-Object System.Drawing.Point(10,335)
    $textBoxProgress.Size = New-Object System.Drawing.Size(580,80)
    $textBoxProgress.Multiline = $true
    $textBoxProgress.ScrollBars = "Vertical"
    $form.Controls.Add($textBoxProgress)

    $buttonDelete = New-Object System.Windows.Forms.Button
    $buttonDelete.Location = New-Object System.Drawing.Point(140,220)
    $buttonDelete.Size = New-Object System.Drawing.Size(120,30)
    $buttonDelete.Text = "Delete"
    $buttonDelete.Add_Click({
        $items = @($listBox.SelectedItems)
        if ($items.Count -eq 0) { Write-Log "⚠ No file selected." $textBoxProgress; return }

        foreach ($item in $items) {
            if (-not (Test-Path -LiteralPath $item)) {
                Write-Log "⚠ Not found: $item" $textBoxProgress
                continue
            }
            $choice = $comboBoxAlgorithm.SelectedItem
            switch -Wildcard ($choice) {
                "UltraSecure*" {
                    SecureDelete-File -Path $item -UltraSecure -Verify:$($checkVerify.Checked) -RenameCount ([int]$numericRename.Value) -Output $textBoxProgress
                }
                "Gutmann*" {
                    SecureDelete-File -Path $item -Algorithm Gutmann -Passes ([int]$numericUpDownIterations.Value) -RenameCount ([int]$numericRename.Value) -Output $textBoxProgress
                }
                "DoD*" {
                    SecureDelete-File -Path $item -Algorithm DoD -RenameCount ([int]$numericRename.Value) -Output $textBoxProgress
                }
            }
            $listBox.Items.Remove($item)
        }
    })
    $form.Controls.Add($buttonDelete)

    $comboBoxAlgorithm.add_SelectedIndexChanged({
        $numericUpDownIterations.Enabled = ($comboBoxAlgorithm.SelectedItem -like "Gutmann*")
        $checkVerify.Enabled = ($comboBoxAlgorithm.SelectedItem -like "UltraSecure*")
    })

    $form.ShowDialog() | Out-Null
}

# --- Entrée : CLI vs GUI ---
if ($NoUI) {
    if (-not $Path) { throw "In CLI mode (-NoUI), provide -Path (file or folder)." }

    if ($Confirm) {
        $q = Read-Host "DELETE '$Path' using $(if($UltraSecure){'UltraSecure'}else{$Algorithm})? (Y/N)"
        if ($q -notin @('Y','y','O','o')) { Write-Host "Cancelled."; exit 0 }
    }

    $touchedDrives = New-Object System.Collections.Generic.HashSet[string]

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        SecureDelete-File -Path $Path -Algorithm $Algorithm -Passes $Passes -UltraSecure:$UltraSecure -Verify:$Verify -RenameCount $RenameCount
        $drv = Get-DriveLetterFromPath -FullPath $Path
        if ($drv) { [void]$touchedDrives.Add($drv) }
    } elseif (Test-Path -LiteralPath $Path -PathType Container) {
        SecureDelete-Folder -FolderPath $Path -Algorithm $Algorithm -Passes $Passes -UltraSecure:$UltraSecure -Verify:$Verify -RenameCount $RenameCount -Recurse:$Recurse -WipeFreeSpace:$WipeFreeSpace -Trim:$Trim
        $drv = Get-DriveLetterFromPath -FullPath $Path
        if ($drv) { [void]$touchedDrives.Add($drv) }
    } else {
        throw "Path not found: $Path"
    }

    # Si l’utilisateur demande WipeFreeSpace/Trim pour fichier isolé
    if ((-not (Test-Path -LiteralPath $Path -PathType Container)) -and $WipeFreeSpace -and $touchedDrives.Count -gt 0) {
        foreach ($drive in $touchedDrives) {
            Invoke-FreeSpaceWipe -DriveLetter $drive
            if ($Trim) { Invoke-ReTrim -DriveLetter $drive }
        }
    }
} else {
    Start-ShredderGUI
}