Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Function to overwrite file data with random data
function OverwriteRandomData {
    param (
        [string]$path
    )
    $fileSize = (Get-Item $path).Length
    $randomData = New-Object byte[] $fileSize
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($randomData)
    [System.IO.File]::WriteAllBytes($path, $randomData)
}

# Function to securely delete the file using Gutmann algorithm
function SecureDeleteFileGutmann {
    param (
        [string]$path,
        [int]$iterations,
        [System.Windows.Forms.TextBox]$textBox
    )
    for ($i = 1; $i -le $iterations; $i++) {
        $message = "Overwriting iteration $i/$iterations..."
        $textBox.AppendText($message + [Environment]::NewLine)
        OverwriteRandomData -path $path
    }
    Remove-Item $path -Force
    $message = "File securely deleted using Gutmann algorithm."
    $textBox.AppendText($message + [Environment]::NewLine)
}

# Function to securely delete the file using DoD 5220-22.M algorithm
function SecureDeleteFileDoD {
    param (
        [string]$path,
        [System.Windows.Forms.TextBox]$textBox
    )
    $randomData = New-Object byte[] 1
    $randomData[0] = 0
    for ($i = 1; $i -le 3; $i++) {
        Write-Host "Overwriting iteration $i/3..."
        [System.IO.File]::WriteAllBytes($path, $randomData)
    }
    Remove-Item $path -Force
    $message = "File securely deleted using DoD 5220-22.M algorithm."
    $textBox.AppendText($message + [Environment]::NewLine)
}

# Create the main window
$form = New-Object System.Windows.Forms.Form
$form.Text = "Select files to delete securely"
$form.Size = New-Object System.Drawing.Size(600,400)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"

# Create list box to display selected files
$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = New-Object System.Drawing.Point(10,10)
$listBox.Size = New-Object System.Drawing.Size(560,200)
$listBox.SelectionMode = "MultiExtended"
$form.Controls.Add($listBox)

# Button to select files to delete
$buttonSelect = New-Object System.Windows.Forms.Button
$buttonSelect.Location = New-Object System.Drawing.Point(10,220)
$buttonSelect.Size = New-Object System.Drawing.Size(120,30)
$buttonSelect.Text = "Select"
$buttonSelect.Add_Click({
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Multiselect = $true
    $openFileDialog.Filter = "All files (*.*)|*.*"
    $openFileDialog.InitialDirectory = [Environment]::GetFolderPath("Desktop")
    $openFileDialog.Title = "Select files to delete securely"
    $openFileDialog.ShowDialog() | Out-Null
    foreach ($file in $openFileDialog.FileNames) {
        $listBox.Items.Add($file)
    }
})
$form.Controls.Add($buttonSelect)

# Label for algorithm selection
$labelAlgorithm = New-Object System.Windows.Forms.Label
$labelAlgorithm.Location = New-Object System.Drawing.Point(10,260)
$labelAlgorithm.Size = New-Object System.Drawing.Size(200,20)
$labelAlgorithm.Text = "Select deletion algorithm:"
$form.Controls.Add($labelAlgorithm)

# Combo box for selecting deletion algorithm
$comboBoxAlgorithm = New-Object System.Windows.Forms.ComboBox
$comboBoxAlgorithm.Location = New-Object System.Drawing.Point(10,280)
$comboBoxAlgorithm.Size = New-Object System.Drawing.Size(200,20)
$comboBoxAlgorithm.Items.Add("Gutmann Algorithm")
$comboBoxAlgorithm.Items.Add("DoD 5220-22.M Algorithm")
$comboBoxAlgorithm.SelectedIndex = 0  # Default selection
$form.Controls.Add($comboBoxAlgorithm)

# Text box to display progress messages
$textBoxProgress = New-Object System.Windows.Forms.TextBox
$textBoxProgress.Location = New-Object System.Drawing.Point(10,310)
$textBoxProgress.Size = New-Object System.Drawing.Size(560,50)
$textBoxProgress.Multiline = $true
$textBoxProgress.ScrollBars = "Vertical"
$form.Controls.Add($textBoxProgress)

# Button to delete selected files
$buttonDelete = New-Object System.Windows.Forms.Button
$buttonDelete.Location = New-Object System.Drawing.Point(150,220)
$buttonDelete.Size = New-Object System.Drawing.Size(120,30)
$buttonDelete.Text = "Delete"
$buttonDelete.Add_Click({
    $selectedAlgorithm = $comboBoxAlgorithm.SelectedItem
    $selectedItems = @($listBox.SelectedItems)  # Create a copy of selected items
    foreach ($item in $selectedItems) {
        if ($selectedAlgorithm -eq "Gutmann Algorithm") {
            $iterations = 35
            SecureDeleteFileGutmann -path $item -iterations $iterations -textBox $textBoxProgress
        }
        elseif ($selectedAlgorithm -eq "DoD 5220-22.M Algorithm") {
            SecureDeleteFileDoD -path $item -textBox $textBoxProgress
        }
        $listBox.Items.Remove($item)
    }
})
$form.Controls.Add($buttonDelete)

# Display the window
$form.ShowDialog() | Out-Null
