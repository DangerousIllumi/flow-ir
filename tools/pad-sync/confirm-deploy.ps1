# confirm-deploy.ps1 — MessageBox dialog; exit 0 when the user confirms, exit 1 when cancelled
param([string]$Title, [string]$Msg)
Add-Type -AssemblyName System.Windows.Forms
$r = [System.Windows.Forms.MessageBox]::Show($Msg, $Title,
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { exit 0 } else { exit 1 }
