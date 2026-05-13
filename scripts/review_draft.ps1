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
$resultPath = Join-Path $projectRoot "jobs\latest_result.json"
$actionPath = Join-Path $projectRoot "inputs\draft_review_action.json"
$saveScript = Join-Path $projectRoot "scripts\save_manual_draft_edit.py"
$reviseScript = Join-Path $projectRoot "scripts\revise_blog_draft.py"

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

function Get-DraftState {
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $bodyText = (($result.paragraphs | ForEach-Object { $_.text }) -join "`r`n`r`n")
    $tagsText = (($result.tags | ForEach-Object { if ($_ -match '^#') { $_ } else { "#$_" } }) -join " ")
    return @{
        Title = [string]$result.title
        Body  = $bodyText
        Tags  = $tagsText
    }
}

function New-ReviewWindow {
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1040"
        Height="760"
        MinWidth="900"
        MinHeight="660"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        FontFamily="Malgun Gothic"
        Background="#F4F7FB">
    <Window.Resources>
        <SolidColorBrush x:Key="PanelBrush" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#D8E0EA"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#0F766E"/>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#102A43"/>
        </Style>
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
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="Background" Value="#FFFFFF"/>
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
                <Button x:Name="CancelButton" Grid.Column="1" Width="100"/>
                <Button x:Name="AiButton" Grid.Column="2" Width="150"/>
                <Button x:Name="SaveButton" Grid.Column="3" Width="120"/>
                <Button x:Name="ContinueButton" Grid.Column="4" Width="120" Background="#0F766E" Foreground="White" BorderBrush="#0F766E"/>
            </Grid>
        </Border>
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="24">
                <Border Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="22" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock x:Name="TitleLabel" FontSize="14" FontWeight="SemiBold"/>
                        <TextBox x:Name="TitleBox" Grid.Row="1" Height="38" Margin="0,8,0,0"/>
                        <TextBlock x:Name="BodyLabel" Grid.Row="2" Margin="0,18,0,0" FontSize="14" FontWeight="SemiBold"/>
                        <TextBox x:Name="BodyBox" Grid.Row="3" Margin="0,8,0,0" Height="360" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                        <StackPanel Grid.Row="4" Margin="0,18,0,0">
                            <TextBlock x:Name="TagsLabel" FontSize="14" FontWeight="SemiBold"/>
                            <TextBox x:Name="TagsBox" Margin="0,8,0,0" Height="38"/>
                            <TextBlock x:Name="AiLabel" Margin="0,18,0,0" FontSize="14" FontWeight="SemiBold"/>
                            <TextBox x:Name="AiBox" Margin="0,8,0,0" Height="86" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                        </StackPanel>
                        <Border Grid.Row="5" Margin="0,18,0,0" Background="#F8FAFC" BorderBrush="#D8E0EA" BorderThickness="1" CornerRadius="12" Padding="14">
                            <StackPanel>
                                <TextBlock x:Name="GuideText" TextWrapping="Wrap" FontSize="13" Foreground="#52606D"/>
                                <ProgressBar x:Name="BusyBar" Margin="0,12,0,0" Height="10" IsIndeterminate="True" Visibility="Collapsed" Foreground="#0F766E"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

while ($true) {
    $state = Get-DraftState
$window = New-ReviewWindow
Set-WindowSafePosition $window

    $window.Title = U "\uc6d0\uace0 \ud655\uc778 \ubc0f \uc218\uc815"
    $window.FindName("HeaderTitle").Text = U "\uc6d0\uace0 \ud655\uc778 \ubc0f \uc218\uc815"
    $window.FindName("HeaderSubTitle").Text = U "\uc6d0\uace0\ub97c \ud655\uc778\ud558\uace0, \uc9c1\uc811 \uc218\uc815\ud558\uac70\ub098 AI \uc218\uc815 \uc694\uccad\uc744 \ubcf4\ub0bc \uc218 \uc788\uc2b5\ub2c8\ub2e4."
    $window.FindName("TitleLabel").Text = U "\uc81c\ubaa9"
    $window.FindName("BodyLabel").Text = U "\ubcf8\ubb38 \uc9c1\uc811 \uc218\uc815"
    $window.FindName("TagsLabel").Text = U "\ud0dc\uadf8"
    $window.FindName("AiLabel").Text = U "AI \uc218\uc815 \uc694\uccad"
    $window.FindName("GuideText").Text = U "\uc6d0\uace0\ub97c \ud655\uc778\ud55c \ub4a4 \uacc4\uc18d \uc9c4\ud589\ud558\uac70\ub098, \uc9c1\uc811 \uc218\uc815 \ub610\ub294 AI \uc218\uc815 \uc694\uccad\uc744 \ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4."
    $window.FindName("StatusText").Text = U "\uc6d0\uace0 \uac80\ud1a0 \ub300\uae30 \uc911"
    $window.FindName("CancelButton").Content = U "\ucde8\uc18c"
    $window.FindName("AiButton").Content = U "AI\uc218\uc815\uc694\uccad \ud558\uae30"
    $window.FindName("SaveButton").Content = U "\uc218\uc815 \uc800\uc7a5"
    $window.FindName("ContinueButton").Content = U "\uacc4\uc18d\uc9c4\ud589"

    $titleBox = $window.FindName("TitleBox")
    $bodyBox = $window.FindName("BodyBox")
    $tagsBox = $window.FindName("TagsBox")
    $aiBox = $window.FindName("AiBox")
    $statusText = $window.FindName("StatusText")
    $busyBar = $window.FindName("BusyBar")
    $cancelButton = $window.FindName("CancelButton")
    $aiButton = $window.FindName("AiButton")
    $saveButton = $window.FindName("SaveButton")
    $continueButton = $window.FindName("ContinueButton")

    $titleBox.Text = $state.Title
    $bodyBox.Text = $state.Body
    $tagsBox.Text = $state.Tags

    function Set-BusyState {
        param(
            [bool]$IsBusy,
            [string]$Message
        )

        $statusText.Text = $Message
        $busyBar.Visibility = if ($IsBusy) { "Visible" } else { "Collapsed" }

        $cancelButton.IsEnabled = -not $IsBusy
        $aiButton.IsEnabled = -not $IsBusy
        $saveButton.IsEnabled = -not $IsBusy
        $continueButton.IsEnabled = -not $IsBusy

        $titleBox.IsReadOnly = $IsBusy
        $bodyBox.IsReadOnly = $IsBusy
        $tagsBox.IsReadOnly = $IsBusy
        $aiBox.IsReadOnly = $IsBusy

        $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
    }

    function Invoke-ExternalPython {
        param(
            [string]$ScriptPath,
            [string]$BusyMessage,
            [int]$TimeoutSeconds = 0
        )

        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        $pythonPath = Resolve-PythonExe

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $pythonPath
        $psi.Arguments = '"' + $ScriptPath + '"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        [void]$process.Start()

        $frames = @("|", "/", "-", "\")
        $index = 0
        $startedAt = Get-Date
        $timedOut = $false
        while (-not $process.HasExited) {
            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                try { $process.Kill() } catch {}
                try { [void]$process.WaitForExit(5000) } catch {}
                break
            }
            $statusText.Text = "$BusyMessage $($frames[$index])"
            $index = ($index + 1) % $frames.Count
            $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 180
        }

        if ($timedOut -and -not $process.HasExited) {
            return [pscustomobject]@{
                ExitCode = -1
                StdOut   = ""
                StdErr   = (U "AI \uc218\uc815 \uc2dc\uac04\uc774 \ucd08\uacfc\ub418\uc5c8\uc2b5\ub2c8\ub2e4. \uc7a0\uc2dc \ud6c4 \ub2e4\uc2dc \uc2dc\ub3c4\ud574 \uc8fc\uc138\uc694.")
                TimedOut = $true
            }
        }

        try { $stdout = $process.StandardOutput.ReadToEnd() } catch { $stdout = "" }
        try { $stderr = $process.StandardError.ReadToEnd() } catch { $stderr = "" }
        if ($timedOut) {
            $stderr = (($stderr + [Environment]::NewLine + (U "AI \uc218\uc815 \uc2dc\uac04\uc774 \ucd08\uacfc\ub418\uc5c8\uc2b5\ub2c8\ub2e4. \uc7a0\uc2dc \ud6c4 \ub2e4\uc2dc \uc2dc\ub3c4\ud574 \uc8fc\uc138\uc694.")).Trim())
        }

        return [pscustomobject]@{
            ExitCode = $(if ($timedOut) { -1 } else { $process.ExitCode })
            StdOut   = $stdout
            StdErr   = $stderr
            TimedOut = $timedOut
        }
    }

    $cancelButton.Add_Click({
        $window.Tag = "cancel"
        $window.Close()
    })

    $continueButton.Add_Click({
        $window.Tag = "continue"
        $window.Close()
    })

    $saveButton.Add_Click({
        $payload = [ordered]@{
            title = $titleBox.Text
            body = $bodyBox.Text
            tags = $tagsBox.Text
            ai_instruction = ""
        }
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($actionPath, ($payload | ConvertTo-Json -Depth 4), $utf8Bom)

        Set-BusyState -IsBusy $true -Message (U "\uc9c1\uc811 \uc218\uc815 \ub0b4\uc6a9\uc744 \uc800\uc7a5\ud558\ub294 \uc911\uc785\ub2c8\ub2e4...")
        $processResult = Invoke-ExternalPython -ScriptPath $saveScript -BusyMessage (U "\uc9c1\uc811 \uc218\uc815 \uc800\uc7a5 \uc911")
        if ($processResult.ExitCode -ne 0) {
            Set-BusyState -IsBusy $false -Message (U "\uc9c1\uc811 \uc218\uc815 \uc800\uc7a5\uc5d0 \uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4.")
            $errorText = ($processResult.StdErr + [Environment]::NewLine + $processResult.StdOut).Trim()
            [void][System.Windows.MessageBox]::Show($errorText, (U "\uc6d0\uace0 \uc800\uc7a5 \uc2e4\ud328"))
            return
        }
        Set-BusyState -IsBusy $false -Message (U "\uc9c1\uc811 \uc218\uc815 \uc800\uc7a5 \uc644\ub8cc. \ubc14\ub85c \ub2e4\uc74c \ub2e8\uacc4\ub85c \uc9c4\ud589\ud569\ub2c8\ub2e4.")
        [void][System.Windows.MessageBox]::Show((U "\uc9c1\uc811 \uc218\uc815 \ub0b4\uc6a9\uc774 \uc800\uc7a5\ub418\uc5c8\uc2b5\ub2c8\ub2e4. \ubc14\ub85c \ub2e4\uc74c \ub2e8\uacc4\ub85c \uc9c4\ud589\ud569\ub2c8\ub2e4."), (U "\uc6d0\uace0 \uc800\uc7a5 \uc644\ub8cc"))
        $window.Tag = "continue"
        $window.Close()
    })

    $aiButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($aiBox.Text)) {
            [void][System.Windows.MessageBox]::Show((U "AI \uc218\uc815 \uc694\uccad \ub0b4\uc6a9\uc744 \uc785\ub825\ud574 \uc8fc\uc138\uc694."), (U "AI \uc218\uc815 \uc694\uccad"))
            return
        }

        $payload = [ordered]@{
            title = $titleBox.Text
            body = $bodyBox.Text
            tags = $tagsBox.Text
            ai_instruction = $aiBox.Text
        }
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($actionPath, ($payload | ConvertTo-Json -Depth 4), $utf8Bom)

        Set-BusyState -IsBusy $true -Message (U "AI\uac00 \uc6d0\uace0\ub97c \uc218\uc815\ud558\ub294 \uc911\uc785\ub2c8\ub2e4...")
        $processResult = Invoke-ExternalPython -ScriptPath $reviseScript -BusyMessage (U "AI \uc218\uc815 \uc801\uc6a9 \uc911") -TimeoutSeconds 240
        if ($processResult.TimedOut) {
            Set-BusyState -IsBusy $false -Message (U "AI \uc218\uc815 \uc2dc\uac04\uc774 \ucd08\uacfc\ub418\uc5c8\uc2b5\ub2c8\ub2e4.")
            $errorText = ($processResult.StdErr + [Environment]::NewLine + $processResult.StdOut).Trim()
            [void][System.Windows.MessageBox]::Show($errorText, (U "AI \uc218\uc815 \uc2dc\uac04 \ucd08\uacfc"))
            return
        }
        if ($processResult.ExitCode -ne 0) {
            Set-BusyState -IsBusy $false -Message (U "AI \uc218\uc815\uc5d0 \uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4.")
            $errorText = ($processResult.StdErr + [Environment]::NewLine + $processResult.StdOut).Trim()
            [void][System.Windows.MessageBox]::Show($errorText, (U "AI \uc218\uc815 \uc2e4\ud328"))
            return
        }
        Set-BusyState -IsBusy $false -Message (U "AI \uc218\uc815 \uc644\ub8cc. \ubc18\uc601\ub41c \uc6d0\uace0\ub97c \ub2e4\uc2dc \ud655\uc778\ud574 \uc8fc\uc138\uc694.")
        [void][System.Windows.MessageBox]::Show((U "AI \uc218\uc815\uc774 \ubc18\uc601\ub418\uc5c8\uc2b5\ub2c8\ub2e4. \uc218\uc815\ub41c \uc6d0\uace0\ub97c \ub2e4\uc2dc \ud655\uc778\ud55c \ub4a4 \uc9c4\ud589 \uc5ec\ubd80\ub97c \uc120\ud0dd\ud574 \uc8fc\uc138\uc694."), (U "AI \uc218\uc815 \uc644\ub8cc"))
        $window.Tag = "reload"
        $window.Close()
    })

    [void]$window.ShowDialog()
    $action = [string]$window.Tag

    if ($action -eq "reload") { continue }
    if ($action -eq "continue") {
        Write-Host (U "\uc6d0\uace0\ub97c \ud655\uc778 \ud6c4 \uadf8\ub300\ub85c \uc9c4\ud589\ud569\ub2c8\ub2e4.") -ForegroundColor Green
        exit 0
    }

    Write-Host (U "\uc6d0\uace0 \uac80\ud1a0\ub97c \ucde8\uc18c\ud588\uc2b5\ub2c8\ub2e4.") -ForegroundColor Yellow
    exit 1
}
