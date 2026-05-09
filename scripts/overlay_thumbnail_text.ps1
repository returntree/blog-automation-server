param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$Text,

    [string]$FontPath = "C:\Windows\Fonts\malgun.ttf"
)

Add-Type -AssemblyName System.Drawing

function Get-FittedFont {
    param(
        [System.Drawing.Graphics]$Graphics,
        [string]$Text,
        [System.Drawing.FontFamily]$FontFamily,
        [System.Drawing.RectangleF]$Bounds
    )

    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $format.Trimming = [System.Drawing.StringTrimming]::Word
    $format.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit

    for ($size = [single]([Math]::Floor($Bounds.Width / 10)); $size -ge 28; $size -= 2) {
        $font = New-Object System.Drawing.Font($FontFamily, $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $measured = $Graphics.MeasureString($Text, $font, [System.Drawing.SizeF]::new($Bounds.Width, 10000), $format)
        if ($measured.Width -le ($Bounds.Width * 1.02) -and $measured.Height -le $Bounds.Height) {
            return @{
                Font = $font
                Format = $format
            }
        }
        $font.Dispose()
    }

    $fallbackFont = New-Object System.Drawing.Font($FontFamily, 28, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    return @{
        Font = $fallbackFont
        Format = $format
    }
}

$sourceImage = [System.Drawing.Image]::FromFile($ImagePath)
$bitmap = New-Object System.Drawing.Bitmap $sourceImage.Width, $sourceImage.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$graphics.DrawImage($sourceImage, 0, 0, $sourceImage.Width, $sourceImage.Height)

$overlayHeight = [int]($sourceImage.Height * 0.38)
$overlayY = $sourceImage.Height - $overlayHeight
$overlayRect = New-Object System.Drawing.Rectangle 0, $overlayY, $sourceImage.Width, $overlayHeight
$overlayBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(185, 8, 20, 36))
$graphics.FillRectangle($overlayBrush, $overlayRect)

$fontCollection = New-Object System.Drawing.Text.PrivateFontCollection
$fontCollection.AddFontFile($FontPath)
$fontFamily = $fontCollection.Families[0]

$marginX = [int]($sourceImage.Width * 0.07)
$textRect = New-Object System.Drawing.RectangleF $marginX, ($overlayY + [int]($overlayHeight * 0.12)), ($sourceImage.Width - ($marginX * 2)), ([int]($overlayHeight * 0.76))
$fit = Get-FittedFont -Graphics $graphics -Text $Text -FontFamily $fontFamily -Bounds $textRect
$font = $fit.Font
$format = $fit.Format
$shadowFont = New-Object System.Drawing.Font($fontFamily, $font.Size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

$shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 0, 0, 0))
$textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
$shadowRect = New-Object System.Drawing.RectangleF ($textRect.X + 3), ($textRect.Y + 3), $textRect.Width, $textRect.Height

$graphics.DrawString($Text, $shadowFont, $shadowBrush, $shadowRect, $format)
$graphics.DrawString($Text, $font, $textBrush, $textRect, $format)

$tempPath = [System.IO.Path]::ChangeExtension($ImagePath, ".overlay.png")
$bitmap.Save($tempPath, [System.Drawing.Imaging.ImageFormat]::Png)

$textBrush.Dispose()
$shadowBrush.Dispose()
$overlayBrush.Dispose()
$shadowFont.Dispose()
$font.Dispose()
$format.Dispose()
$fontCollection.Dispose()
$graphics.Dispose()
$bitmap.Dispose()
$sourceImage.Dispose()

Move-Item -LiteralPath $tempPath -Destination $ImagePath -Force
