param(
    [string]$PackageDir
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BitmapPreviewNative {
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);
}
"@

$projectRoot = Split-Path -Parent $PSScriptRoot

function Test-PythonExecutable {
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    if ($Candidate -like "*\Microsoft\WindowsApps\python*.exe") { return $false }
    try {
        $output = & $Candidate --version 2>&1
        return ($LASTEXITCODE -eq 0 -and (($output -join " ") -match "Python\s+3\."))
    } catch {
        return $false
    }
}

function Resolve-PythonExe {
    $candidates = New-Object System.Collections.Generic.List[string]
    $settingsPath = Join-Path $projectRoot "installer\local_installer_settings.json"
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.python_path) { [void]$candidates.Add([string]$settings.python_path) }
        } catch {
        }
    }

    foreach ($name in @("py.exe", "python.exe", "py", "python")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { [void]$candidates.Add($command.Source) }
        else { [void]$candidates.Add($name) }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-PythonExecutable $candidate) { return $candidate }
    }

    throw "Python 실행 파일을 찾지 못했습니다. 설치 마법사에서 'Python 설치/다운로드'를 눌러 Python 3을 설치한 뒤 '환경 확인'을 다시 눌러 주세요."
}
$jobsDir = Join-Path $projectRoot "jobs"
$selectedPackage = $null
if (-not [string]::IsNullOrWhiteSpace($PackageDir)) {
    $resolvedPackageDir = [System.IO.Path]::GetFullPath($PackageDir)
    if (-not (Test-Path -LiteralPath $resolvedPackageDir)) {
        throw "지정한 업로드 패키지를 찾지 못했습니다: $resolvedPackageDir"
    }
    $selectedPackage = Get-Item -LiteralPath $resolvedPackageDir
} else {
    $selectedPackage = Get-ChildItem -LiteralPath $jobsDir -Directory -Filter "upload_package_*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $selectedPackage) { throw "최신 업로드 패키지를 찾지 못했습니다." }
$imagesDir = Join-Path $selectedPackage.FullName "images"
$promptsPath = Join-Path $selectedPackage.FullName "image_prompts.json"
$actionPath = Join-Path $projectRoot "inputs\image_review_action.json"
$regenScript = Join-Path $projectRoot "scripts\regenerate_package_image.py"

function U([string]$value) {
    return [System.Text.RegularExpressions.Regex]::Unescape($value)
}

function Set-WindowSafePosition($window, [int]$margin = 16) {
    $window.WindowStartupLocation = 'Manual'
    $window.Add_ContentRendered({
        param($sender, $args)
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $sender.Width = [Math]::Min([double]$sender.Width, [double]$workArea.Width - ($margin * 2))
        $sender.Height = [Math]::Min([double]$sender.Height, [double]$workArea.Height - ($margin * 2))
        $sender.Left = [Math]::Max($workArea.Left + $margin, $workArea.Left + (($workArea.Width - $sender.Width) / 2))
        $sender.Top = [Math]::Max($workArea.Top + $margin, $workArea.Top + (($workArea.Height - $sender.Height) / 2))
    })
}

$promptData = Get-Content -LiteralPath $promptsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($promptData.items)

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1120"
        Height="780"
        MinWidth="940"
        MinHeight="680"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        FontFamily="Malgun Gothic"
        Background="#F4F7FB">
    <Window.Resources>
        <SolidColorBrush x:Key="PanelBrush" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#D8E0EA"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#0F766E"/>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#102A43"/></Style>
        <Style TargetType="Button">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Top" Background="#102A43" Padding="28,20">
            <StackPanel>
                <TextBlock x:Name="HeaderTitle" FontSize="28" FontWeight="Bold" Foreground="White"/>
                <TextBlock x:Name="HeaderSubTitle" Margin="0,8,0,0" FontSize="14" Foreground="#D9E2EC"/>
            </StackPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#D8E0EA" BorderThickness="1,1,0,0" Padding="24,18">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Grid.Column="0" VerticalAlignment="Center" FontSize="13" Foreground="#52606D"/>
                <Button x:Name="OpenButton" Grid.Column="1" Width="190"/>
                <Button x:Name="CancelButton" Grid.Column="2" Width="110"/>
                <Button x:Name="RegenButton" Grid.Column="3" Width="220"/>
                <Button x:Name="ContinueButton" Grid.Column="4" Width="150" Background="#0F766E" Foreground="White" BorderBrush="#0F766E"/>
            </Grid>
        </Border>
        <Grid Margin="24">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="260"/>
                <ColumnDefinition Width="20"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                <DockPanel>
                    <TextBlock x:Name="ListTitle" DockPanel.Dock="Top" FontSize="22" FontWeight="SemiBold"/>
                    <ListBox x:Name="ImageList" Margin="0,18,0,0" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1"/>
                </DockPanel>
            </Border>
            <Border Grid.Column="2" Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock x:Name="PreviewTitle" FontSize="22" FontWeight="SemiBold"/>
                    <Border Grid.Row="1" Margin="0,18,0,0" Background="#F8FAFC" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="12">
                        <Image x:Name="PreviewImage" Stretch="Uniform"/>
                    </Border>
                    <TextBlock x:Name="InstructionLabel" Grid.Row="2" Margin="0,18,0,0" FontSize="14" FontWeight="SemiBold"/>
                    <TextBox x:Name="InstructionBox" Grid.Row="3" Margin="0,8,0,0" Height="90" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                </Grid>
            </Border>
        </Grid>
    </DockPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
Set-WindowSafePosition $window
$window.Title = U "\uc774\ubbf8\uc9c0 \ud655\uc778 \ubc0f \uc7ac\uc0dd\uc131"
$window.FindName("HeaderTitle").Text = U "\uc774\ubbf8\uc9c0 \ud655\uc778 \ubc0f \uc7ac\uc0dd\uc131"
$window.FindName("HeaderSubTitle").Text = U "\uc0dd\uc131\ub41c \uc774\ubbf8\uc9c0\ub97c \ud655\uc778\ud558\uace0, \ud544\uc694\ud558\uba74 \uc120\ud0dd\ud55c \uc774\ubbf8\uc9c0\ub9cc \ub2e4\uc2dc \ub9cc\ub4ed\ub2c8\ub2e4."
$window.FindName("ListTitle").Text = U "\uc774\ubbf8\uc9c0 \ubaa9\ub85d"
$window.FindName("PreviewTitle").Text = U "\ubbf8\ub9ac\ubcf4\uae30"
$window.FindName("InstructionLabel").Text = U "\uc7ac\uc0dd\uc131 \uc694\uccad"
$window.FindName("StatusText").Text = U "\uc774\ubbf8\uc9c0\ub97c \ud655\uc778\ud55c \ub4a4 \uadf8\ub300\ub85c \uc9c4\ud589\ud558\uac70\ub098, \uc7ac\uc0dd\uc131 \ud6c4 \ub2e4\uc2dc \ud655\uc778\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4."
$window.FindName("OpenButton").Content = U "\uc120\ud0dd \uc774\ubbf8\uc9c0 \uc5f4\uae30"
$window.FindName("CancelButton").Content = U "\ucde8\uc18c"
$window.FindName("RegenButton").Content = U "\uc120\ud0dd \uc774\ubbf8\uc9c0 \uc7ac\uc0dd\uc131"
$window.FindName("ContinueButton").Content = U "\uacc4\uc18d\uc9c4\ud589"

$listBox = $window.FindName("ImageList")
$previewImage = $window.FindName("PreviewImage")
$instructionBox = $window.FindName("InstructionBox")
$statusText = $window.FindName("StatusText")
$openButton = $window.FindName("OpenButton")
$cancelButton = $window.FindName("CancelButton")
$regenButton = $window.FindName("RegenButton")
$continueButton = $window.FindName("ContinueButton")

foreach ($item in $items) { [void]$listBox.Items.Add([string]$item.file_name) }
$listBox.SelectedIndex = 0

function Show-SelectedImage {
    if ($listBox.SelectedItem -eq $null) { return }
    $selected = [string]$listBox.SelectedItem
    $file = Get-ChildItem -LiteralPath $imagesDir -File | Where-Object { $_.BaseName -eq $selected } | Select-Object -First 1
    if ($file) {
        $previewImage.Source = $null
        $drawingBitmap = $null
        $hBitmap = [IntPtr]::Zero
        try {
            $drawingBitmap = New-Object System.Drawing.Bitmap($file.FullName)
            $hBitmap = $drawingBitmap.GetHbitmap()
            $bitmapSource = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
                $hBitmap,
                [IntPtr]::Zero,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )
            $bitmapSource.Freeze()
            $previewImage.Source = $bitmapSource
        }
        finally {
            if ($hBitmap -ne [IntPtr]::Zero) { [void][BitmapPreviewNative]::DeleteObject($hBitmap) }
            if ($drawingBitmap) { $drawingBitmap.Dispose() }
        }
    }
}

$listBox.Add_SelectionChanged({ Show-SelectedImage })
Show-SelectedImage

$openButton.Add_Click({
    if ($listBox.SelectedItem -ne $null) {
        $selected = [string]$listBox.SelectedItem
        $file = Get-ChildItem -LiteralPath $imagesDir -File | Where-Object { $_.BaseName -eq $selected } | Select-Object -First 1
        if ($file) { Start-Process $file.FullName | Out-Null }
    }
})

$cancelButton.Add_Click({
    $window.Tag = "cancel"
    $window.Close()
})

$continueButton.Add_Click({
    $window.Tag = "continue"
    $window.Close()
})

$regenButton.Add_Click({
    if ($listBox.SelectedItem -eq $null) {
        [void][System.Windows.MessageBox]::Show((U "\uc7ac\uc0dd\uc131\ud560 \uc774\ubbf8\uc9c0\ub97c \uc120\ud0dd\ud574 \uc8fc\uc138\uc694."), (U "\uc774\ubbf8\uc9c0 \uc7ac\uc0dd\uc131"))
        return
    }
    if ([string]::IsNullOrWhiteSpace($instructionBox.Text)) {
        [void][System.Windows.MessageBox]::Show((U "\uc7ac\uc0dd\uc131 \uc694\uccad \ub0b4\uc6a9\uc744 \uc785\ub825\ud574 \uc8fc\uc138\uc694."), (U "\uc774\ubbf8\uc9c0 \uc7ac\uc0dd\uc131"))
        return
    }

    $payload = [ordered]@{
        package_dir = $selectedPackage.FullName
        file_name = [string]$listBox.SelectedItem
        instruction = $instructionBox.Text
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($actionPath, ($payload | ConvertTo-Json -Depth 4), $utf8Bom)

    $statusText.Text = U "\uc774\ubbf8\uc9c0\ub97c \uc7ac\uc0dd\uc131\ud558\ub294 \uc911\uc785\ub2c8\ub2e4..."
    $pythonExe = Resolve-PythonExe
    $regenOutput = & $pythonExe $regenScript 2>&1
    if ($LASTEXITCODE -ne 0) {
        $statusText.Text = U "\uc774\ubbf8\uc9c0 \uc7ac\uc0dd\uc131\uc5d0 \uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4."
        [void][System.Windows.MessageBox]::Show(($regenOutput -join [Environment]::NewLine), (U "\uc774\ubbf8\uc9c0 \uc7ac\uc0dd\uc131 \uc2e4\ud328"))
        return
    }

    Start-Sleep -Milliseconds 300
    Show-SelectedImage
    $instructionBox.Text = ""
    $statusText.Text = U "\uc7ac\uc0dd\uc131 \uc644\ub8cc. \uc0c8 \uc774\ubbf8\uc9c0\ub97c \ub2e4\uc2dc \ud655\uc778\ud55c \ub4a4 \uc9c4\ud589 \uc5ec\ubd80\ub97c \uc120\ud0dd\ud574 \uc8fc\uc138\uc694."
    [void][System.Windows.MessageBox]::Show((U "\uc774\ubbf8\uc9c0\ub97c \ub2e4\uc2dc \uc0dd\uc131\ud588\uc2b5\ub2c8\ub2e4. \ubbf8\ub9ac\ubcf4\uae30\ub97c \ud655\uc778\ud55c \ub4a4 \uadf8\ub300\ub85c \uc9c4\ud589\ud558\uac70\ub098 \ud55c \ubc88 \ub354 \uc7ac\uc0dd\uc131\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4."), (U "\uc774\ubbf8\uc9c0 \uc7ac\uc0dd\uc131 \uc644\ub8cc"))
})

[void]$window.ShowDialog()

if ($window.Tag -eq "cancel" -or [string]::IsNullOrWhiteSpace([string]$window.Tag)) {
    Write-Host (U "\uc774\ubbf8\uc9c0 \uac80\ud1a0\ub97c \ucde8\uc18c\ud588\uc2b5\ub2c8\ub2e4.") -ForegroundColor Yellow
    exit 1
}

if ($window.Tag -eq "continue") {
    Write-Host (U "\uc774\ubbf8\uc9c0\ub97c \uadf8\ub300\ub85c \uc720\uc9c0\ud558\uace0 \uc9c4\ud589\ud569\ub2c8\ub2e4.") -ForegroundColor Green
    exit 0
}
exit 0
