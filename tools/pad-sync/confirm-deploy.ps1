# confirm-deploy.ps1 — MessageBox 弹窗，用户确认后 Exit 0，取消 Exit 1
param([string]$Title, [string]$Msg)
Add-Type -AssemblyName System.Windows.Forms
$r = [System.Windows.Forms.MessageBox]::Show($Msg, $Title,
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { exit 0 } else { exit 1 }
