$cheminFichier = "your_file_path"

function EcraserDonneesAleatoires {
    param (
        [string]$chemin
    )
    $tailleFichier = (Get-Item $chemin).Length
    $donneesAleatoires = New-Object byte[] $tailleFichier
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($donneesAleatoires)
    [System.IO.File]::WriteAllBytes($chemin, $donneesAleatoires)
}

function SupprimerFichierSecurise {
    param (
        [string]$chemin
    )
    $iterations = 35
    for ($i = 1; $i -le $iterations; $i++) {
        Write-Host "Suppression $i/$iterations..."
        EcraserDonneesAleatoires -chemin $chemin
    }
    Remove-Item $chemin -Force
    Write-Host "File deleted."
}

SupprimerFichierSecurise -chemin $cheminFichier
