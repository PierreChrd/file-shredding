param(
    [Parameter(Mandatory = $false)]
    [string]$Path,
    [ValidateSet("Gutmann", "DoD")]
    [string]$Algorithm = "Gutmann",
    [int]$Passes = 35,
    [switch]$Recurse,
    [switch]$NoUI,
    [switch]$AskConfirmation
)


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-Log {
    param(
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

function Update-ProgressStep {
    if (Get-Variable -Name __TotalSteps -Scope Global -ErrorAction SilentlyContinue) {
        $global:__ProgStep = [Math]::Min($global:__ProgStep + 1, $global:__TotalSteps)
        if (Get-Variable -Name __ProgressBar -Scope Global -ErrorAction SilentlyContinue) {
            try { $global:__ProgressBar.Value = $global:__ProgStep } catch {}
        }
    }
}

function Overwrite-RandomData {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $size = (Get-Item -LiteralPath $Path -Force).Length
        if ($size -le 0) { return }
        $buf = New-Object byte[] $size
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($buf)
        [System.IO.File]::WriteAllBytes($Path, $buf)
        Update-ProgressStep
    }
    catch {
        throw "Overwrite-RandomData failed for '$Path': $($_.Exception.Message)"
    }
}

function SecureDelete-DoD {
    param(
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "SecureDelete-DoD expects a file." }
    $size = $item.Length
    $patterns = @(0x00, 0xFF, $null)
    for ($i = 0; $i -lt 3; $i++) {
        $pattern = $patterns[$i]
        if ($pattern -eq $null) {
            Write-Log "DoD pass $($i+1)/3 (random) on $Path..." $Output
            Overwrite-RandomData -Path $Path
        }
        else {
            Write-Log "DoD pass $($i+1)/3 (pattern 0x{0:X2}) on $Path..." -f $pattern $Output
            $buf = New-Object byte[] $size
            for ($j = 0; $j -lt $size; $j++) { $buf[$j] = [byte]$pattern }
            [System.IO.File]::WriteAllBytes($Path, $buf)
            Update-ProgressStep
        }
    }
    Remove-Item -LiteralPath $Path -Force
    Update-ProgressStep
    Write-Log "✔ Deleted (DoD): $Path" $Output
}

function SecureDelete-Gutmann {
    param(
        [string]$Path,
        [int]$Iterations = 35,
        [System.Windows.Forms.TextBox]$Output
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "SecureDelete-Gutmann expects a file." }
    for ($i = 1; $i -le $Iterations; $i++) {
        Write-Log "Gutmann pass $i/$Iterations on $Path..." $Output
        Overwrite-RandomData -Path $Path
        Update-ProgressStep
    }
    Remove-Item -LiteralPath $Path -Force
    Update-ProgressStep
    Write-Log "✔ Deleted (Gutmann $Iterations passes): $Path" $Output
}

function Get-AlternateStreams {
    param([string]$Path)
    try {
        Get-Item -LiteralPath $Path -Force -Stream * -ErrorAction Stop |
        Where-Object { $_.Stream -notin @('::$DATA', ':$DATA', '$DATA') }
    }
    catch { return @() }
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
        Write-Log "Processing ADS '$($ads.Stream)' on $Path" $Output
        try {
            switch ($Algorithm) {
                "Gutmann" {
                    for ($i = 1; $i -le $Passes; $i++) {
                        Overwrite-RandomData -Path $adsPath
                        Update-ProgressStep
                    }
                }
                "DoD" {
                    $len = $ads.Length
                    $buf0 = New-Object byte[] $len
                    $buf1 = New-Object byte[] $len
                    for ($j = 0; $j -lt $len; $j++) {
                        $buf0[$j] = 0x00
                        $buf1[$j] = 0xFF
                    }
                    [IO.File]::WriteAllBytes($adsPath, $buf0)
                    Update-ProgressStep
                    [IO.File]::WriteAllBytes($adsPath, $buf1)
                    Update-ProgressStep
                    Overwrite-RandomData -Path $adsPath
                }
            }
            Remove-Item -LiteralPath $adsPath -Force -ErrorAction SilentlyContinue
            Update-ProgressStep
        }
        catch {
            Write-Log "⚠ ADS wipe failed for $adsPath : $($_.Exception.Message)" $Output
        }
    }
}

function Check-ResidualArtifacts {
    param(
        [string]$OriginalPath,
        [System.Windows.Forms.TextBox]$Output
    )
    Write-Log "🔍 Vérification résiduelle : $OriginalPath" $Output
    if (Test-Path -LiteralPath $OriginalPath) {
        Write-Log "❌ Le fichier existe encore !" $Output
        return $false
    }
    try {
        $streams = Get-Item -LiteralPath $OriginalPath -Force -Stream * -ErrorAction Stop |
        Where-Object { $_.Stream -notin @('::$DATA', ':$DATA', '$DATA') }
        if ($streams.Count -gt 0) {
            Write-Log "❌ ADS résiduels détectés :" $Output
            foreach ($s in $streams) { Write-Log "   → $($s.Stream)" $Output }
            return $false
        }
    }
    catch {}
    try {
        $parent = Split-Path $OriginalPath -Parent
        $tmp = Join-Path $parent ".__shredder_lock_test"
        [IO.File]::WriteAllText($tmp, "x")
        Remove-Item $tmp -Force -EA SilentlyContinue
    }
    catch {
        Write-Log "⚠ Handle verrouillant le dossier parent." $Output
        return $false
    }
    Write-Log "✔ Aucun résidu détecté." $Output
    return $true
}

function Prepare-FileForDeletion {
    param(
        [string]$Path,
        [switch]$RandomizeName
    )
    try {
        Attrib -R -S -H -A -I -O -U -P -Q -Y -LiteralPath $Path *> $null
    }
    catch {}
    if ($RandomizeName) {
        try {
            $dir = Split-Path $Path -Parent
            $name = Split-Path $Path -Leaf
            $ext = [IO.Path]::GetExtension($name)
            $len = $name.Length - $ext.Length
            $rand = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count ([Math]::Min($len, 40)) | % { [char]$_ })
            $new = if ($ext) { "$rand$ext" } else { $rand }
            $newPath = Join-Path $dir $new
            Rename-Item -LiteralPath $Path -NewName $new -Force
            return $newPath
        }
        catch { return $Path }
    }
    return $Path
}

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
        "DoD" { SecureDelete-DoD -Path $path2 -Output $Output }
    }
    Check-ResidualArtifacts -OriginalPath $Path -Output $Output
}

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
    $folderItem = Get-Item -LiteralPath $FolderPath -Force
    if ($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log "⚠ Skipping reparse point: $FolderPath" $Output
        return
    }
    Write-Log "Scanning folder: $FolderPath" $Output
    $files = if ($Recurse) {
        Get-ChildItem $FolderPath -Recurse -File -Force
    }
    else {
        Get-ChildItem $FolderPath -File -Force
    }
    foreach ($f in $files) {
        SecureDelete-File -Path $f.FullName -Algorithm $Algorithm -Passes $Passes -Output $Output
    }
    $dirs = if ($Recurse) {
        Get-ChildItem $FolderPath -Recurse -Directory -Force | Sort-Object FullName -Descending
    }
    foreach ($d in $dirs) {
        if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item $d.FullName -Force -EA SilentlyContinue
        }
    }
    Remove-Item $FolderPath -Force -EA SilentlyContinue
    Write-Log "✔ Folder removed: $FolderPath" $Output
    Check-ResidualArtifacts -OriginalPath $FolderPath -Output $Output
}


function Start-ShredderGUI {

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Secure File Shredder"
    $form.Size = New-Object System.Drawing.Size(1100, 650)
    $form.MinimumSize = "1100,650"
    $form.StartPosition = "CenterScreen"
    $form.BackColor = "#313338"
    $form.ForeColor = "#FFFFFF"
    $form.Font = New-Object Drawing.Font("Segoe UI", 10)

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = "10,10"
    $listBox.Size = "780,250"
    $listBox.Anchor = "Top,Left,Right"
    $listBox.BackColor = "#1E1F22"
    $listBox.ForeColor = "#B9BBBE"
    $listBox.SelectionMode = "MultiExtended"
    $listBox.HorizontalScrollbar = $true
    $listBox.BorderStyle = "FixedSingle"
    $listBox.AllowDrop = $true
    $form.Controls.Add($listBox)

    $listBox.Add_DragEnter({
            if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = "Copy" }
        })
    $listBox.Add_DragDrop({
            $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
            foreach ($f in $files) { if (-not $listBox.Items.Contains($f)) { $listBox.Items.Add($f) } }
            Update-Summary
        })

    function New-DiscordBtn($text, $color) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.BackColor = $color
        $b.ForeColor = "White"
        $b.FlatStyle = "Flat"
        $b.FlatAppearance.BorderSize = 0
        $b.Font = $form.Font
        return $b
    }

    $btnAdd = New-DiscordBtn "Add files..." "#5865F2"
    $btnAdd.Location = "10,280"
    $btnAdd.Size = "150,40"
    $form.Controls.Add($btnAdd)

    $btnDelete = New-DiscordBtn "Delete securely" "#ED4245"
    $btnDelete.Location = "170,280"
    $btnDelete.Size = "150,40"
    $form.Controls.Add($btnDelete)

    $btnClearLogs = New-DiscordBtn "Clear logs" "#4F545C"
    $btnClearLogs.Location = "330,280"
    $btnClearLogs.Size = "120,40"
    $form.Controls.Add($btnClearLogs)

    $comboBoxAlgorithm = New-Object System.Windows.Forms.ComboBox
    $comboBoxAlgorithm.Location = "10,330"
    $comboBoxAlgorithm.Size = "260,30"
    $comboBoxAlgorithm.BackColor = "#1E1F22"
    $comboBoxAlgorithm.ForeColor = "White"
    $comboBoxAlgorithm.Items.Add("Gutmann (35 passes)")
    $comboBoxAlgorithm.Items.Add("DoD 5220.22-M (3 passes)")
    $comboBoxAlgorithm.SelectedIndex = 0
    $form.Controls.Add($comboBoxAlgorithm)

    $numericUpDownIterations = New-Object System.Windows.Forms.NumericUpDown
    $numericUpDownIterations.Location = "280,330"
    $numericUpDownIterations.Minimum = 1
    $numericUpDownIterations.Maximum = 100
    $numericUpDownIterations.Value = 35
    $numericUpDownIterations.BackColor = "#1E1F22"
    $numericUpDownIterations.ForeColor = "White"
    $form.Controls.Add($numericUpDownIterations)

    $comboBoxAlgorithm.Add_SelectedIndexChanged({
            $numericUpDownIterations.Enabled = ($comboBoxAlgorithm.SelectedItem -like "Gutmann*")
        })

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = "10,370"
    $progressBar.Size = "780,20"
    $progressBar.Style = "Continuous"
    $progressBar.Anchor = "Top,Left,Right"
    $form.Controls.Add($progressBar)

    $textBoxProgress = New-Object System.Windows.Forms.TextBox
    $textBoxProgress.Location = "10,400"
    $textBoxProgress.Size = "780,210"
    $textBoxProgress.Multiline = $true
    $textBoxProgress.ScrollBars = "Vertical"
    $textBoxProgress.BackColor = "#1E1F22"
    $textBoxProgress.ForeColor = "#B9BBBE"
    $textBoxProgress.Anchor = "Top,Left,Right,Bottom"
    $form.Controls.Add($textBoxProgress)

    $btnClearLogs.Add_Click({ $textBoxProgress.Clear() })

    $btnAdd.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Multiselect = $true
            if ($dlg.ShowDialog() -eq "OK") {
                foreach ($f in $dlg.FileNames) {
                    if (-not $listBox.Items.Contains($f)) { $listBox.Items.Add($f) }
                }
                Update-Summary
            }
        })

    $sidebar = New-Object System.Windows.Forms.Panel
    $sidebar.Location = "800,10"
    $sidebar.Size = "280,600"
    $sidebar.Anchor = "Top,Right,Bottom"
    $sidebar.BackColor = "#2B2D31"
    $sidebar.BorderStyle = "FixedSingle"
    $form.Controls.Add($sidebar)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Summary"
    $lblTitle.Font = New-Object Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "10,10"
    $lblTitle.ForeColor = "White"
    $sidebar.Controls.Add($lblTitle)

    $labelCount = New-Object System.Windows.Forms.Label
    $labelCount.Location = "10,50"
    $labelCount.ForeColor = "White"
    $sidebar.Controls.Add($labelCount)

    $labelSize = New-Object System.Windows.Forms.Label
    $labelSize.Location = "10,80"
    $labelSize.ForeColor = "White"
    $sidebar.Controls.Add($labelSize)

    $labelCredit = New-Object System.Windows.Forms.Label
    $labelCredit.Text = "Created by Pierre CHAUSSARD"
    $labelCredit.Font = New-Object Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $labelCredit.ForeColor = "#B9BBBE"
    $labelCredit.AutoSize = $true
    $labelCredit.Location = New-Object System.Drawing.Point(10, 540)
    $sidebar.Controls.Add($labelCredit)

    $linkGitHub = New-Object System.Windows.Forms.LinkLabel
    $linkGitHub.Text = "github.com/PierreChrd"
    $linkGitHub.LinkColor = "#00AFF4"
    $linkGitHub.ActiveLinkColor = "#3BA55D"
    $linkGitHub.VisitedLinkColor = "#7289DA"
    $linkGitHub.Location = New-Object System.Drawing.Point(10, 560)
    $linkGitHub.AutoSize = $true
    $linkGitHub.Add_LinkClicked({ Start-Process "https://github.com/PierreChrd" })
    $sidebar.Controls.Add($linkGitHub)

    function Update-Summary {
        $count = $listBox.Items.Count
        $labelCount.Text = "Files: $count"
        $size = 0
        foreach ($f in $listBox.Items) { if (Test-Path $f) { $size += (Get-Item $f).Length } }
        $labelSize.Text = "Total size: {0:N0} bytes" -f $size
    }

    $btnDelete.Add_Click({

            $items = @($listBox.SelectedItems)
            if ($items.Count -eq 0) {
                Write-Log "⚠ No file selected." $textBoxProgress
                return
            }

            $global:__ProgressBar = $progressBar
            $global:__ProgStep = 0
            $global:__TotalSteps = 0

            foreach ($i in $items) {
                $p = ($comboBoxAlgorithm.SelectedItem -like "Gutmann*") ? $numericUpDownIterations.Value : 3
                $global:__TotalSteps += ($p + 3)
            }

            $progressBar.Minimum = 0
            $progressBar.Maximum = [Math]::Max($global:__TotalSteps, 1)
            $progressBar.Value = 0

            Write-Log "Processing $($items.Count) files..." $textBoxProgress

            foreach ($item in $items) {
                $algo = if ($comboBoxAlgorithm.SelectedItem -like "Gutmann*") { "Gutmann" } else { "DoD" }
                $p = if ($algo -eq "Gutmann") { [int]$numericUpDownIterations.Value } else { 3 }
                SecureDelete-File -Path $item -Algorithm $algo -Passes $p -Output $textBoxProgress
                $listBox.Items.Remove($item)
            }

            $global:__ProgStep = $global:__TotalSteps
            $progressBar.Value = $global:__TotalSteps

            Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PBState {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
            [PBState]::SendMessage($progressBar.Handle, 0x0410, 1, 0)

            Write-Log "✔ Completed." $textBoxProgress
            Update-Summary
        })

    $form.ShowDialog()
}


if ($NoUI) {
    if (-not $Path) { throw "In CLI mode, you must provide -Path." }
    if ($AskConfirmation) {
        $q = Read-Host "DELETE '$Path' using $Algorithm ? (Y/N)"
        if ($q -notin @('Y','y','O','o')) { Write-Host "Cancelled."; exit }
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        SecureDelete-File -Path $Path -Algorithm $Algorithm -Passes $Passes
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        SecureDelete-Folder -FolderPath $Path -Algorithm $Algorithm -Passes $Passes -Recurse:$Recurse
    }
    else {
        throw "Path not found: $Path"
    }
}
else {
    Start-ShredderGUI
}