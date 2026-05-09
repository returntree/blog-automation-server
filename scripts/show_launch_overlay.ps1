$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function U([string]$value) {
    return [System.Text.RegularExpressions.Regex]::Unescape($value)
}

function Set-WindowSafePosition($window, [int]$margin = 12) {
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

$titleText = U "\ube14\ub85c\uadf8 \ud3ec\uc2a4\ud305 \uc790\ub3d9\ud654 v4"
$subtitleText = U "\uc6d0\uace0 \uc0dd\uc131, \uc774\ubbf8\uc9c0 \uc815\ub9ac, \uac80\ud1a0, \uc790\ub3d9\ud3ec\uc2a4\ud305\uae4c\uc9c0 \ud55c \ubc88\uc5d0 \uc774\uc5b4\uc9d1\ub2c8\ub2e4"

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="700"
        Height="300"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        Topmost="True"
        WindowStartupLocation="CenterScreen">
    <Grid>
        <Border CornerRadius="28" Background="#081A2E" Margin="20">
            <Border.Effect>
                <DropShadowEffect BlurRadius="28" ShadowDepth="0" Color="#111827" Opacity="0.35"/>
            </Border.Effect>
        </Border>
        <Border CornerRadius="28" Margin="20" BorderThickness="1" BorderBrush="#1D4E89">
            <Grid>
                <Grid.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#102A43" Offset="0"/>
                        <GradientStop Color="#123B66" Offset="0.6"/>
                        <GradientStop Color="#0F766E" Offset="1"/>
                    </LinearGradientBrush>
                </Grid.Background>
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <Border Width="96" Height="96" CornerRadius="48" Background="#FFFFFF14" BorderBrush="#FFFFFF22" BorderThickness="1" Margin="0,0,0,22">
                        <Grid>
                            <TextBlock Text="V4" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe UI Semibold" FontSize="28" Foreground="White"/>
                        </Grid>
                    </Border>
                    <TextBlock x:Name="TitleBlock" HorizontalAlignment="Center" FontFamily="Malgun Gothic" FontSize="30" FontWeight="Bold" Foreground="White"/>
                    <TextBlock x:Name="SubTitleBlock" Margin="0,14,0,0" HorizontalAlignment="Center" FontFamily="Malgun Gothic" FontSize="14" Foreground="#D9E2EC"/>
                    <Border Margin="0,28,0,0" Width="220" Height="6" CornerRadius="3" Background="#FFFFFF1E">
                        <Border x:Name="ProgressBar" Width="40" Height="6" CornerRadius="3" Background="White" HorizontalAlignment="Left"/>
                    </Border>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
Set-WindowSafePosition $window
$progressBar = $window.FindName("ProgressBar")
$window.FindName("TitleBlock").Text = $titleText
$window.FindName("SubTitleBlock").Text = $subtitleText

$animation = New-Object System.Windows.Media.Animation.DoubleAnimation
$animation.From = 40
$animation.To = 220
$animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1800))
$animation.AutoReverse = $false
$animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
$progressBar.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $animation)

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(2100)
$timer.Add_Tick({
    $timer.Stop()
    $window.Close()
})
$timer.Start()

[void]$window.ShowDialog()
