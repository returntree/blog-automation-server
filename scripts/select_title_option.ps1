$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

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
$optionsPath = Join-Path $projectRoot "research\title_options.json"
$requestPath = Join-Path $projectRoot "inputs\request.json"
$titleGeneratorScript = Join-Path $projectRoot "scripts\generate_title_options.py"
$pythonExe = Resolve-PythonExe

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

if (-not (Test-Path $optionsPath)) {
    throw (U("\ud0c0\uc774\ud2c0 \ud6c4\ubcf4 \ud30c\uc77c\uc744 \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4."))
}
if (-not (Test-Path $requestPath)) {
    throw (U("request.json \ud30c\uc77c\uc744 \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4."))
}

$optionsData = Get-Content -LiteralPath $optionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$requestData = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$options = @($optionsData.title_options)

if ($options.Count -lt 1) {
    throw (U("\uc120\ud0dd\ud560 \uc81c\ubaa9 \ud6c4\ubcf4\uac00 \uc5c6\uc2b5\ub2c8\ub2e4."))
}

if ($options.Count -eq 1) {
    $selectedTitle = [string]$options[0]
    $requestData | Add-Member -NotePropertyName selected_title -NotePropertyValue $selectedTitle -Force
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $jsonText = $requestData | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($requestPath, $jsonText, $utf8Bom)
    Write-Host ((U("\uc120\ud0dd \uc81c\ubaa9 \uc790\ub3d9 \uc800\uc7a5 \uc644\ub8cc")) + ": $selectedTitle") -ForegroundColor Green
    exit 0
}

$xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="920"
        Height="700"
        MinWidth="820"
        MinHeight="620"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        FontFamily="Malgun Gothic"
        Background="#F4F7FB">
    <Window.Resources>
        <SolidColorBrush x:Key="PanelBrush" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#D8E0EA"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#0F766E"/>
        <Style TargetType="TextBox">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="White"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
        </Style>
    </Window.Resources>
    <DockPanel LastChildFill="True">
        <Border DockPanel.Dock="Top" Background="#102A43" Padding="22,16">
            <StackPanel>
                <TextBlock x:Name="HeaderTitle" FontSize="26" FontWeight="Bold" Foreground="White"/>
                <TextBlock x:Name="HeaderSubtitle" Margin="0,8,0,0" FontSize="14" Foreground="#D9E2EC"/>
            </StackPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#D8E0EA" BorderThickness="1,1,0,0" Padding="18,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="BottomGuide" Grid.Column="0" VerticalAlignment="Center" FontSize="13" Foreground="#52606D"/>
                <Button x:Name="CancelButton" Grid.Column="1" Width="100"/>
                <Button x:Name="RegenerateButton" Grid.Column="2" Width="120"/>
                <Button x:Name="ApplyExtraButton" Grid.Column="3" Width="140"/>
                <Button x:Name="ContinueButton" Grid.Column="4" Width="160" Style="{StaticResource PrimaryButton}"/>
            </Grid>
        </Border>
        <Grid Margin="18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.2*"/>
                <ColumnDefinition Width="1*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="0,0,8,0">
                <DockPanel LastChildFill="True">
                    <TextBlock x:Name="ListTitle" DockPanel.Dock="Top" FontSize="22" FontWeight="SemiBold" Foreground="#102A43"/>
                    <TextBlock x:Name="ListGuide" DockPanel.Dock="Top" Margin="0,8,0,14" Foreground="#52606D" TextWrapping="Wrap"/>
                    <ListBox x:Name="TitleListBox" FontSize="15" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1"/>
                </DockPanel>
            </Border>
            <Border Grid.Column="1" Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="8,0,0,0">
                <StackPanel>
                    <TextBlock x:Name="ExtraTitle" FontSize="22" FontWeight="SemiBold" Foreground="#102A43"/>
                    <TextBlock x:Name="ExtraGuide" Margin="0,8,0,14" Foreground="#52606D" TextWrapping="Wrap"/>
                    <TextBox x:Name="ExtraRequestBox" Height="110" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                    <Border Margin="0,18,0,0" Background="#F0FDF4" BorderBrush="#A7F3D0" BorderThickness="1" CornerRadius="12" Padding="12">
                        <TextBlock x:Name="HintText" TextWrapping="Wrap" Foreground="#166534"/>
                    </Border>
                </StackPanel>
            </Border>
        </Grid>
    </DockPanel>
</Window>
"@

[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
Set-WindowSafePosition $window

$namedControls = @(
    "HeaderTitle","HeaderSubtitle","BottomGuide","CancelButton","RegenerateButton","ApplyExtraButton","ContinueButton",
    "ListTitle","ListGuide","TitleListBox","ExtraTitle","ExtraGuide","ExtraRequestBox","HintText"
)
foreach ($name in $namedControls) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

$window.Title = U("\uc81c\ubaa9 \ud6c4\ubcf4 \uc120\ud0dd")
$HeaderTitle.Text = U("\uc81c\ubaa9 \ud6c4\ubcf4 \uc120\ud0dd")
$HeaderSubtitle.Text = U("\ud6c4\ubcf4\ub97c \uace0\ub974\uac70\ub098 \ucd94\uac00 \uc694\uccad\uc744 \ub123\uc5b4 \ub2e4\uc2dc \ubf51\uc744 \uc218 \uc788\uc2b5\ub2c8\ub2e4.")
$BottomGuide.Text = U("\ud55c \ubc88 \ub354 \uc870\uc815\ud558\uace0 \uc2f6\uc73c\uba74 \ucd94\uac00\uc694\uccad\uc744 \uc785\ub825\ud55c \ub4a4 \ub2e4\uc2dc\ubf51\uae30\ub97c \ub204\ub974\uc138\uc694.")
$CancelButton.Content = U("\ucde8\uc18c")
$RegenerateButton.Content = U("\ub2e4\uc2dc\ubf51\uae30")
$ApplyExtraButton.Content = U("AI\uc694\uccad \uc801\uc6a9")
$ContinueButton.Content = U("\uc774 \uc81c\ubaa9\uc73c\ub85c \uacc4\uc18d")
$ListTitle.Text = U("\uc81c\ubaa9 \ubaa9\ub85d")
$ListGuide.Text = U("\uc0dd\uc131\ub41c \uc81c\ubaa9 \ud6c4\ubcf4 \uc911 \ud558\ub098\ub97c \uace8\ub77c \uc6d0\uace0 \uc0dd\uc131\uc744 \uacc4\uc18d\ud569\ub2c8\ub2e4.")
$ExtraTitle.Text = U("\ucd94\uac00\uc694\uccad \uc0ac\ud56d")
$ExtraGuide.Text = U("\uc81c\ubaa9 \ub290\ub08c, \ud3ec\ud568\ud560 \ud0a4\uc6cc\ub4dc, \ube7c\uace0 \uc2f6\uc740 \ud45c\ud604 \ub4f1\uc744 \uc790\uc720\ub86d\uac8c \uc801\uc5b4\uc8fc\uc138\uc694.")
$HintText.Text = U("\u2018AI\uc694\uccad \uc801\uc6a9\u2019 \ub610\ub294 \u2018\ub2e4\uc2dc\ubf51\uae30\u2019\ub97c \ub204\ub974\uba74 \ucd94\uac00\uc694\uccad\uc744 request.json\uc5d0 \uc800\uc7a5\ud558\uace0, \ud30c\uc774\ud504\ub77c\uc778\uc740 \uc81c\ubaa9 \ud6c4\ubcf4 \uc0dd\uc131\ubd80\ud130 \ub2e4\uc2dc \uc9c4\ud589\ud569\ub2c8\ub2e4.")

foreach ($option in $options) {
    [void]$TitleListBox.Items.Add([string]$option)
}
$TitleListBox.SelectedIndex = 0

if ($requestData.PSObject.Properties.Name -contains 'title_extra_request') {
    $ExtraRequestBox.Text = [string]$requestData.title_extra_request
}

$script:resultMode = 'cancel'

$saveRequest = {
    param([string]$mode)
    $requestData | Add-Member -NotePropertyName title_extra_request -NotePropertyValue ($ExtraRequestBox.Text.Trim()) -Force
    if ($mode -eq 'continue') {
        $selectedTitle = [string]$TitleListBox.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selectedTitle)) {
            throw (U("\uc120\ud0dd\ub41c \uc81c\ubaa9\uc774 \uc5c6\uc2b5\ub2c8\ub2e4."))
        }
        $requestData | Add-Member -NotePropertyName selected_title -NotePropertyValue $selectedTitle -Force
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $jsonText = $requestData | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($requestPath, $jsonText, $utf8Bom)
    $script:resultMode = $mode
    $window.Close()
}

$ContinueButton.Add_Click({
    & $saveRequest 'continue'
})

$ApplyExtraButton.Add_Click({
    & $saveRequest 'regenerate'
})

$RegenerateButton.Add_Click({
    & $saveRequest 'regenerate'
})

$CancelButton.Add_Click({
    $window.Close()
})

[void]$window.ShowDialog()

switch ($script:resultMode) {
    'continue' {
        Write-Host ((U("\uc120\ud0dd \uc81c\ubaa9 \uc800\uc7a5 \uc644\ub8cc")) + ": " + [string]$requestData.selected_title) -ForegroundColor Green
        exit 0
    }
    'regenerate' {
        Write-Host (U("\ucd94\uac00\uc694\uccad\uc744 \uc800\uc7a5\ud588\uc2b5\ub2c8\ub2e4. \uc81c\ubaa9 \ud6c4\ubcf4\ub97c \ub2e4\uc2dc \uc0dd\uc131\ud569\ub2c8\ub2e4.")) -ForegroundColor Yellow
        exit 10
    }
    default {
        Write-Host (U("\uc81c\ubaa9 \uc120\ud0dd\uc744 \ucde8\uc18c\ud588\uc2b5\ub2c8\ub2e4.")) -ForegroundColor Yellow
        exit 1
    }
}
