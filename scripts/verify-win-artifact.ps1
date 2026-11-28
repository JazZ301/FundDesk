param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$IconOutput = ""
)

$full = (Resolve-Path $Path).Path
$stream = [System.IO.File]::OpenRead($full)
try {
  $reader = New-Object System.IO.BinaryReader($stream)
  $stream.Position = 0x3c
  $peOffset = $reader.ReadInt32()
  $stream.Position = $peOffset + 4
  $machine = $reader.ReadUInt16()
} finally {
  $stream.Dispose()
}

$architecture = switch ($machine) {
  0x8664 { "x86_64" }
  0xaa64 { "arm64" }
  0x014c { "x86" }
  default { "unknown(0x{0:x4})" -f $machine }
}

$signature = Get-AuthenticodeSignature $full
[PSCustomObject]@{
  Path = $full
  Bytes = (Get-Item $full).Length
  Architecture = $architecture
  SignatureStatus = $signature.Status
  Signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "" }
} | Format-List

if ($IconOutput) {
  Add-Type -AssemblyName System.Drawing
  $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($full)
  $bitmap = $icon.ToBitmap()
  $bitmap.Save($IconOutput, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  $icon.Dispose()
  Write-Output "icon=$IconOutput"
}
