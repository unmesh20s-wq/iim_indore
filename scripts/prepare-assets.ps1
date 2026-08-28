$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$workspace = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $workspace 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null

function Export-ResizedJpeg {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int]$MaxWidth,
        [int]$Quality = 86
    )

    $sourceImage = [System.Drawing.Image]::FromFile($Source)
    try {
        $scale = [Math]::Min(1.0, [double]$MaxWidth / [double]$sourceImage.Width)
        $width = [Math]::Round($sourceImage.Width * $scale)
        $height = [Math]::Round($sourceImage.Height * $scale)
        $bitmap = [System.Drawing.Bitmap]::new([int]$width, [int]$height)
        try {
            $bitmap.SetResolution(96, 96)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.Clear([System.Drawing.Color]::White)
                $graphics.DrawImage($sourceImage, 0, 0, $width, $height)
            }
            finally {
                $graphics.Dispose()
            }

            $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' }
            $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
            $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                [System.Drawing.Imaging.Encoder]::Quality,
                [long]$Quality
            )
            try {
                $bitmap.Save($Destination, $jpegCodec, $encoderParameters)
            }
            finally {
                $encoderParameters.Dispose()
            }
        }
        finally {
            $bitmap.Dispose()
        }
    }
    finally {
        $sourceImage.Dispose()
    }
}

Export-ResizedJpeg `
    -Source 'C:\Users\Unmesh\Downloads\image.png' `
    -Destination (Join-Path $assets 'golden-arches.jpg') `
    -MaxWidth 2048 `
    -Quality 88

Export-ResizedJpeg `
    -Source 'C:\Users\Unmesh\Downloads\RM506752.JPG' `
    -Destination (Join-Path $assets 'chapter-team.jpg') `
    -MaxWidth 2200 `
    -Quality 84

Copy-Item `
    -LiteralPath 'C:\Users\Unmesh\Downloads\WhatsApp Image 2026-08-24 at 5.04.54 PM.jpeg' `
    -Destination (Join-Path $assets 'co-presidents.jpeg') `
    -Force

Copy-Item `
    -LiteralPath 'C:\Users\Unmesh\Downloads\1784053634509.jpg' `
    -Destination (Join-Path $assets '180dc-iim-indore-logo.jpg') `
    -Force

Get-ChildItem -LiteralPath $assets | Select-Object Name, Length
