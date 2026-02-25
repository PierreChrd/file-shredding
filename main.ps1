Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------
# Utility: Safe logging
# -----------------------------
function Write-LogUI {
    param (
        [System.Windows.Forms.TextBox]$textBox,
        [string]$message
    )
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $textBox.AppendText("[$timestamp] $message" + [Environment]::NewLine)
    $textBox.ScrollToCaret()
}

# -----------------------------
# Overwrite with cryptographically strong random data
# -----------------------------
function Overwrite-RandomData {
    param ([string]$Path)

    if (-not (Test-Path $Path)) { return }

    $fileSize = (Get-Item $Path).Length
    if ($fileSize -le 0) { return }

    $randomData = New-Object byte[] $fileSize
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($randomData)

    [System.IO.File]::WriteAllBytes($Path, $randomData)
}

# -----------------------------
# Gutmann Secure Erase
# -----------------------------
function SecureDelete-Gutmann {
    param (
        [string]$Path,
        [int]$Iterations,
        [System.Windows.Forms.TextBox]$Output
    )

    for ($i = 1; $i -le $Iterations; $i++) {
        Write-LogUI $Output "Gutmann pass $i/$Iterations..."
        Overwrite-RandomData -Path $Path
    }

    Remove-Item $Path -Force
    Write-LogUI $Output "✔ File deleted using Gutmann ($Iterations passes)."
}

# -----------------------------
# DoD 5220.22-M (3 passes)
# -----------------------------
function SecureDelete-DoD {
    param (
        [string]$Path,
        [System.Windows.Forms.TextBox]$Output
    )

    $fileSize = (Get-Item $Path).Length

    $patterns = @(
        (0x00), # Pass 1 : zeros
        (0xFF), # Pass 2 : ones
        $null   # Pass 3 : random
    )

    for ($i = 0; $i -lt $patterns.Count; $i++) {
        $pattern = $patterns[$i]

        if ($pattern -eq $null) {
            Write-LogUI $Output "DoD pass $($i+1)/3 (random)..."
            Overwrite-RandomData -Path $Path
        } else {
            Write-LogUI $Output "DoD pass $($i+1)/3 (pattern 0x{0:X2})..." -f $pattern
            $buffer = New-Object byte[] $fileSize
            [byte[]]::Fill($buffer, [byte]$pattern)
            [System.IO.File]::WriteAllBytes($Path, $buffer)
        }
    }

    Remove-Item $Path -Force
    Write-LogUI $Output "✔ File deleted using DoD 5220.22-M."
}

# -----------------------------
# UI Setup
# -----------------------------
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
$comboBoxAlgorithm.Size = New-Object System.Drawing.Size(200,20)
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
    if ($items.Count -eq 0) {
        Write-LogUI $textBoxProgress "⚠ No file selected."
        return
    }

    foreach ($file in $items) {
        if (-not (Test-Path $file)) {
            Write-LogUI $textBoxProgress "⚠ File not found: $file"
            continue
        }

        switch ($comboBoxAlgorithm.SelectedItem) {
            "Gutmann (35 passes)" {
                SecureDelete-Gutmann -Path $file -Iterations $numericUpDownIterations.Value -Output $textBoxProgress
            }
            "DoD 5220.22-M (3 passes)" {
                SecureDelete-DoD -Path $file -Output $textBoxProgress
            }
        }
        $listBox.Items.Remove($file)
    }
})
$form.Controls.Add($buttonDelete)

$comboBoxAlgorithm.add_SelectedIndexChanged({
    $numericUpDownIterations.Enabled = ($comboBoxAlgorithm.SelectedItem -like "Gutmann*")
})

$form.ShowDialog() | Out-Null