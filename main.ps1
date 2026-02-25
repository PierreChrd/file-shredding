[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$false)]
    [string]$Path,

    [ValidateSet("Gutmann","DoD")]
    [string]$Algorithm = "Gutmann",

    [int]$Passes = 35,

    [switch]$Recurse,

    [switch]$NoUI,

    [switch]$Confirm
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------
# Utility: Safe logging (UI + Console)
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
    } else {
        Write-Host $line
    }
}

# -----------------------------
# Random overwrite (cryptographically strong)
# -----------------------------
function Overwrite-RandomData {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    try {
        $fileSize = (Get-Item -LiteralPath $Path -Force).Length
        if ($fileSize -le 0) { return }

        $randomData = New-Object byte[] $fileSize
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($randomData)

        [System.IO.File]::WriteAllBytes($Path, $randomData)
    } catch {
        throw "Overwrite-RandomData failed for '$Path': $($_.Exception.Message)"
    }
}

# -----------------------------
# DoD 5220.22-M (3 passes)
# Pass 1: 0x00, Pass 2: 0xFF, Pass 3: random
# -----------------------------
function SecureDelete-DoD {
    param (
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "SecureDelete-DoD expects a file. Got directory: $Path" }

    $fileSize = $item.Length
    $patterns = @(0x00, 0xFF, $null)
    for ($i = 0; $i -lt $patterns.Count; $i++) {
        $pattern = $patterns[$i]
        if ($pattern -eq $null) {
            Write-Log "DoD pass $($i+1)/3 (random) on $Path..." $Output
            Overwrite-RandomData -Path $Path
        } else {
            Write-Log ("DoD pass {0}/3 (pattern 0x{1:X2}) on {2}..." -f ($i+1), $pattern, $Path) $Output
            $buffer = New-Object byte[] $fileSize
            [byte[]]::Fill($buffer, [byte]$pattern)
            [System.IO.File]::WriteAllBytes($Path, $buffer)
        }
    }

    Remove-Item -LiteralPath $Path -Force
    Write-Log "✔ Deleted (DoD): $Path" $Output
}

# -----------------------------
# Gutmann (N passes - configurable)
# -----------------------------
function SecureDelete-Gutmann {
    param (
        [string]$Path,
        [int]$Iterations = 35,
        [System.Windows.Forms.TextBox]$Output
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "SecureDelete-Gutmann expects a file. Got directory: $Path" }

    for ($i = 1; $i -le $Iterations; $i++) {
        Write-Log "Gutmann pass $i/$Iterations on $Path..." $Output
        Overwrite-RandomData -Path $Path
    }

    Remove-Item -LiteralPath $Path -Force
    Write-Log "✔ Deleted (Gutmann $Iterations passes): $Path" $Output
}

# -----------------------------
# ADS handling (NTFS) - list streams (excluding default)
# -----------------------------
function Get-AlternateStreams {
    param([string]$Path)
    try {
        $streams = Get-Item -LiteralPath $Path -Force -Stream * -ErrorAction Stop |
                   Where-Object { $_.Stream -ne '::$DATA' }
        return $streams
    } catch {
        return @() # Non-NTFS or no streams
    }
}

function Remove-ADS-Secure {
    param(
        [string]$Path,
        [string]$Algorithm = "DoD",
        [int]$Passes = 35,
        [System.Windows.Forms.TextBox]$Output
    )
    $adsList = Get-AlternateStreams -Path $Path
    foreach ($ads in $adsList) {
        $adsPath = "$Path`:$($ads.Stream)"
        try {
            # On ne peut pas toujours écrire via [File]::WriteAllBytes sur ADS. Utilisons Set-Content/Out-File en binaire quand possible.
            # Fallback: klarifier que l’effacement des ADS peut échouer selon l’outil/ACL.
            Write-Log "Processing ADS '$($ads.Stream)' on $Path" $Output
            switch ($Algorithm) {
                "Gutmann" {
                    for ($i=1; $i -le $Passes; $i++) {
                        Overwrite-RandomData -Path $adsPath
                    }
                }
                "DoD" {
                    # 0x00, 0xFF, random
                    $len = ($ads).Length
                    $buf0 = New-Object byte[] $len; [byte[]]::Fill($buf0, 0x00)
                    $buf1 = New-Object byte[] $len; [byte[]]::Fill($buf1, 0xFF)
                    [System.IO.File]::WriteAllBytes($adsPath, $buf0)
                    [System.IO.File]::WriteAllBytes($adsPath, $buf1)
                    Overwrite-RandomData -Path $adsPath
                }
            }
            Remove-Item -LiteralPath $adsPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "⚠ ADS wipe failed for $adsPath : $($_.Exception.Message)" $Output
        }
    }
}

# -----------------------------
# Pre-delete prep: attributes, rename (optional)
# -----------------------------
function Prepare-FileForDeletion {
    param(
        [string]$Path,
        [switch]$RandomizeName
    )
    try {
        Attrib -R -S -H -A -I -O -U -P -Q -Y -LiteralPath $Path *>$null
    } catch { }

    if ($RandomizeName) {
        try {
            $dir  = Split-Path -LiteralPath $Path -Parent
            $name = Split-Path -LiteralPath $Path -Leaf
            $ext  = [System.IO.Path]::GetExtension($name)
            $len  = [Math]::Max(1, ($name.Length - $ext.Length))
            $random = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count ([Math]::Min($len, 40)) | ForEach-Object {[char]$_})
            $newName = if ($ext) { "$random$ext" } else { $random }
            $newPath = Join-Path $dir $newName
            Rename-Item -LiteralPath $Path -NewName $newName -Force
            return $newPath
        } catch {
            return $Path
        }
    } else {
        return $Path
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
        [System.Windows.Forms.TextBox]$Output
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log "⚠ File not found: $Path" $Output
        return
    }

    $path2 = Prepare-FileForDeletion -Path $Path -RandomizeName
    Remove-ADS-Secure -Path $path2 -Algorithm $Algorithm -Passes $Passes -Output $Output

    switch ($Algorithm) {
        "Gutmann" { SecureDelete-Gutmann -Path $path2 -Iterations $Passes -Output $Output }
        "DoD"     { SecureDelete-DoD     -Path $path2 -Output $Output }
        default   { throw "Unknown algorithm: $Algorithm" }
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
        [switch]$Recurse,
        [System.Windows.Forms.TextBox]$Output
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        Write-Log "⚠ Folder not found: $FolderPath" $Output
        return
    }

    # Ne pas suivre reparse points (jonctions) si possible
    $folderItem = Get-Item -LiteralPath $FolderPath -Force
    if ($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log "⚠ Skipping reparse point: $FolderPath" $Output
        return
    }

    Write-Log "Scanning folder: $FolderPath (Recurse=$Recurse)" $Output

    # Récupération de la liste de fichiers
    $files = @()
    if ($Recurse) {
        $files = Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction SilentlyContinue
    } else {
        $files = Get-ChildItem -LiteralPath $FolderPath -File -Force -ErrorAction SilentlyContinue
    }

    foreach ($f in $files) {
        try {
            SecureDelete-File -Path $f.FullName -Algorithm $Algorithm -Passes $Passes -Output $Output
        } catch {
            Write-Log "❌ File delete failed: $($f.FullName) => $($_.Exception.Message)" $Output
        }
    }

    # Supprimer les répertoires vides du bas vers le haut
    $dirs = if ($Recurse) {
        Get-ChildItem -LiteralPath $FolderPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    } else { @() }

    foreach ($d in $dirs) {
        try {
            # ignorer reparse points
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    try {
        Remove-Item -LiteralPath $FolderPath -Force -ErrorAction SilentlyContinue
        Write-Log "✔ Folder removed: $FolderPath" $Output
    } catch {
        Write-Log "⚠ Could not remove folder (still in use or not empty): $FolderPath" $Output
    }
}

# -----------------------------
# GUI (from previous improved version), only if NoUI is not set
# -----------------------------
function Start-ShredderGUI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Secure File Shredder"
    $form.Size = New-Object System.Drawing.Size(600,420)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(10,10)
    $listBox.Size = New-Object System.Drawing.Size(560,200)
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
    $comboBoxAlgorithm.Items.Add("Gutmann (35 passes)")
    $comboBoxAlgorithm.Items.Add("DoD 5220.22-M (3 passes)")
    $comboBoxAlgorithm.SelectedIndex = 0
    $form.Controls.Add($comboBoxAlgorithm)

    $labelIterations = New-Object System.Windows.Forms.Label
    $labelIterations.Location = New-Object System.Drawing.Point(250,260)
    $labelIterations.Text = "Gutmann iterations:"
    $form.Controls.Add($labelIterations)

    $numericUpDownIterations = New-Object System.Windows.Forms.NumericUpDown
    $numericUpDownIterations.Location = New-Object System.Drawing.Point(250,280)
    $numericUpDownIterations.Minimum = 1
    $numericUpDownIterations.Maximum = 100
    $numericUpDownIterations.Value = 35
    $form.Controls.Add($numericUpDownIterations)

    $textBoxProgress = New-Object System.Windows.Forms.TextBox
    $textBoxProgress.Location = New-Object System.Drawing.Point(10,310)
    $textBoxProgress.Size = New-Object System.Drawing.Size(560,70)
    $textBoxProgress.Multiline = $true
    $textBoxProgress.ScrollBars = "Vertical"
    $form.Controls.Add($textBoxProgress)

    $buttonDelete = New-Object System.Windows.Forms.Button
    $buttonDelete.Location = New-Object System.Drawing.Point(150,220)
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
            $algo = if ($comboBoxAlgorithm.SelectedItem -like "Gutmann*") {"Gutmann"} else {"DoD"}
            $passes = if ($algo -eq "Gutmann") { [int]$numericUpDownIterations.Value } else { 3 }
            SecureDelete-File -Path $item -Algorithm $algo -Passes $passes -Output $textBoxProgress
            $listBox.Items.Remove($item)
        }
    })
    $form.Controls.Add($buttonDelete)

    $comboBoxAlgorithm.add_SelectedIndexChanged({
        $numericUpDownIterations.Enabled = ($comboBoxAlgorithm.SelectedItem -like "Gutmann*")
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
        $q = Read-Host "DELETE '$Path' using $Algorithm? (Y/N)"
        if ($q -notin @('Y','y','O','o')) { Write-Host "Cancelled."; exit 0 }
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        SecureDelete-File -Path $Path -Algorithm $Algorithm -Passes $Passes
    } elseif (Test-Path -LiteralPath $Path -PathType Container) {
        SecureDelete-Folder -FolderPath $Path -Algorithm $Algorithm -Passes $Passes -Recurse:$Recurse
    } else {
        throw "Path not found: $Path"
    }
} else {
    Start-ShredderGUI
}