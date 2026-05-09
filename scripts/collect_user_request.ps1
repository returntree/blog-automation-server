$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot "inputs\request.json"
$ahkPath = Join-Path $projectRoot "ahk\upload_from_package_v2.ahk"
$coordToolPath = Join-Path $projectRoot "ahk\find_mouse_position.ahk"
$historyScriptPath = Join-Path $projectRoot "scripts\review_generated_packages.ps1"
$profilePath = Join-Path $projectRoot "presets\writing_profiles.json"
$clientSettingsPath = Join-Path $projectRoot "config\client_settings.json"
$PythonExe = "python"

function U([string]$value) {
    return [System.Text.RegularExpressions.Regex]::Unescape($value)
}

function Set-WindowSafePosition($window, [int]$margin = 16) {
    $window.WindowStartupLocation = 'Manual'
    $window.Add_ContentRendered({
        param($sender, $args)
        $workArea = [System.Windows.SystemParameters]::WorkArea

        $targetWidth = [Math]::Min([double]$sender.Width, [double]$workArea.Width - ($margin * 2))
        $targetHeight = [Math]::Min([double]$sender.Height, [double]$workArea.Height - ($margin * 2))

        if ($targetWidth -lt 760) { $targetWidth = [Math]::Max(760, [double]$workArea.Width - ($margin * 2)) }
        if ($targetHeight -lt 560) { $targetHeight = [Math]::Max(560, [double]$workArea.Height - ($margin * 2)) }

        $sender.Width = $targetWidth
        $sender.Height = $targetHeight
        $sender.Left = [Math]::Max($workArea.Left + $margin, $workArea.Left + (($workArea.Width - $sender.Width) / 2))
        $sender.Top = [Math]::Max($workArea.Top + $margin, $workArea.Top + (($workArea.Height - $sender.Height) / 2))
    })
}

$xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="960"
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
            <Setter Property="Margin" Value="0,6,0,0"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="White"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,8,20,0"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,6,0,0"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
        </Style>
        <Style x:Key="SectionTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="22"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#102A43"/>
        </Style>
        <Style x:Key="LabelText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#243B53"/>
            <Setter Property="Margin" Value="0,0,0,2"/>
        </Style>
        <Style x:Key="HelperText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Foreground" Value="#7B8794"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>
    </Window.Resources>

    <DockPanel LastChildFill="True">
        <Border DockPanel.Dock="Top" Background="#102A43" Padding="22,16">
            <StackPanel>
                <TextBlock x:Name="HeaderTitle" FontSize="28" FontWeight="Bold" Foreground="White"/>
                <TextBlock x:Name="HeaderSubtitle" Margin="0,8,0,0" FontSize="14" Foreground="#D9E2EC"/>
            </StackPanel>
        </Border>

        <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#D8E0EA" BorderThickness="1,1,0,0" Padding="20,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="BottomGuideText" Grid.Column="0" VerticalAlignment="Center" FontSize="13" Foreground="#52606D"/>
                <Button x:Name="HistoryButton" Grid.Column="1" Width="150"/>
                <Button x:Name="ResumeButton" Grid.Column="2" Width="240"/>
                <Button x:Name="CancelButton" Grid.Column="3" Width="120"/>
                <Button x:Name="SaveButton" Grid.Column="4" Width="150" Style="{StaticResource PrimaryButton}"/>
            </Grid>
        </Border>

        <ScrollViewer x:Name="MainScrollViewer" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="18">
                                <Border Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="0,0,0,16">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <StackPanel Grid.Row="0" Grid.ColumnSpan="4">
                            <TextBlock x:Name="ProfileTitle" Style="{StaticResource SectionTitle}"/>
                            <TextBlock x:Name="ProfileGuideText" Margin="0,6,0,12" Foreground="#52606D" TextWrapping="Wrap"/>
                        </StackPanel>
                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,14,0">
                            <TextBlock x:Name="ProfileNameLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ProfileNameHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="ProfileNameBox"/>
                        </StackPanel>
                        <Button x:Name="LoadProfileButton" Grid.Row="1" Grid.Column="1" Width="120" VerticalAlignment="Bottom"/>
                        <Button x:Name="SaveProfileButton" Grid.Row="1" Grid.Column="2" Width="120" VerticalAlignment="Bottom"/>
                        <Button x:Name="ListProfileButton" Grid.Row="1" Grid.Column="3" Width="120" VerticalAlignment="Bottom" Style="{StaticResource PrimaryButton}"/>
                    </Grid>
                </Border>
                <Border Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="0,0,0,16">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Grid.ColumnSpan="2">
                            <TextBlock x:Name="ClientModeTitle" Style="{StaticResource SectionTitle}"/>
                            <TextBlock x:Name="ClientModeGuideText" Margin="0,6,0,12" Foreground="#52606D" TextWrapping="Wrap"/>
                        </StackPanel>

                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,12,0">
                            <TextBlock x:Name="ClientModeLabel" Style="{StaticResource LabelText}"/>
                            <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                                <RadioButton x:Name="LocalClientModeRadio" Margin="0,0,18,0"/>
                                <RadioButton x:Name="ServerClientModeRadio"/>
                            </StackPanel>
                        </StackPanel>

                        <StackPanel Grid.Row="1" Grid.Column="1" Margin="12,0,0,0">
                            <TextBlock x:Name="LicenseCheckLabel" Style="{StaticResource LabelText}"/>
                            <CheckBox x:Name="LicenseCheckCheck" Margin="0,8,0,0"/>
                        </StackPanel>

                        <StackPanel Grid.Row="2" Grid.Column="0" Margin="0,12,12,0">
                            <TextBlock x:Name="ServerBaseUrlLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ServerBaseUrlHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="ServerBaseUrlBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="2" Grid.Column="1" Margin="12,12,0,0">
                            <TextBlock x:Name="AuthTokenLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="AuthTokenHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="AuthTokenBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="3" Grid.Column="0" Margin="0,12,12,0">
                            <TextBlock x:Name="ServerUsernameLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ServerUsernameHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="ServerUsernameBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="3" Grid.Column="1" Margin="12,12,0,0">
                            <TextBlock x:Name="ServerPasswordLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ServerPasswordHelp" Style="{StaticResource HelperText}"/>
                            <PasswordBox x:Name="ServerPasswordBox" Margin="0,6,0,0" Padding="10,8" FontSize="14" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Background="White"/>
                        </StackPanel>

                        <StackPanel Grid.Row="4" Grid.Column="0" Margin="0,12,12,0">
                            <TextBlock x:Name="ServerLoginStatusText" Style="{StaticResource HelperText}" TextWrapping="Wrap"/>
                            <TextBlock x:Name="ServerSubscriptionDetailText" Style="{StaticResource HelperText}" Margin="0,6,0,0" TextWrapping="Wrap"/>
                        </StackPanel>

                        <StackPanel Grid.Row="4" Grid.Column="1" Margin="12,12,0,0" HorizontalAlignment="Left">
    <StackPanel Orientation="Horizontal">
        <Button x:Name="ServerLoginButton" Width="170" Style="{StaticResource PrimaryButton}"/>
        <Button x:Name="ServerStatusButton" Width="120" Margin="10,0,0,0"/>
        <Button x:Name="ServerLogoutButton" Width="100" Margin="10,0,0,0"/>
    </StackPanel>
</StackPanel>
                    </Grid>
                </Border>
<Border Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <TextBlock x:Name="BasicInfoTitle" Grid.ColumnSpan="2" Style="{StaticResource SectionTitle}"/>

                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,14,12,0">
                            <TextBlock x:Name="BusinessNameLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="BusinessNameHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="BusinessNameBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="1" Grid.Column="1" Margin="12,14,0,0">
                            <TextBlock x:Name="TopicLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="TopicHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="TopicBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="2" Grid.Column="0" Margin="0,12,12,0">
                            <TextBlock x:Name="StyleLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="StyleHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="StyleBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="2" Grid.Column="1" Margin="12,12,0,0">
                            <TextBlock x:Name="RegionLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="RegionHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="RegionBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="3" Grid.Column="0" Margin="0,12,12,0">
                            <TextBlock x:Name="AudienceLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="AudienceHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="AudienceBox"/>
                        </StackPanel>

                        <StackPanel Grid.Row="3" Grid.Column="1" Margin="12,12,0,0">
                            <TextBlock x:Name="ImageCountLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ImageCountHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="ImageCountBox" Width="140"/>
                        </StackPanel>

                        <StackPanel Grid.Row="4" Grid.Column="0" Margin="0,12,12,0">
                            <TextBlock x:Name="ImageStyleLabel" Style="{StaticResource LabelText}"/>
                            <ComboBox x:Name="ImageStyleCombo" Margin="0,6,0,0" Height="40" FontSize="14" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                                <ComboBoxItem x:Name="ImageStyleNone"/>
                                <ComboBoxItem x:Name="ImageStyle01"/>
                                <ComboBoxItem x:Name="ImageStyle02"/>
                                <ComboBoxItem x:Name="ImageStyle03"/>
                                <ComboBoxItem x:Name="ImageStyle04"/>
                                <ComboBoxItem x:Name="ImageStyle05"/>
                                <ComboBoxItem x:Name="ImageStyle06"/>
                                <ComboBoxItem x:Name="ImageStyle07"/>
                                <ComboBoxItem x:Name="ImageStyle08"/>
                                <ComboBoxItem x:Name="ImageStyle09"/>
                                <ComboBoxItem x:Name="ImageStyle10"/>
                            </ComboBox>
                        </StackPanel>

                        <StackPanel Grid.Row="4" Grid.Column="1" Margin="12,12,0,0">
                            <TextBlock x:Name="ImageStyleGuideLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ImageStyleGuideText" Margin="0,12,0,0" TextWrapping="Wrap" Foreground="#52606D" FontSize="13"/>
                        </StackPanel>

                        <StackPanel Grid.Row="5" Grid.ColumnSpan="2" Margin="0,12,0,0">
                            <TextBlock x:Name="AdditionalRequestLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="AdditionalRequestHelp" Style="{StaticResource HelperText}"/>
                            <TextBox x:Name="AdditionalRequestBox" Height="92" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                        </StackPanel>

                        <StackPanel Grid.Row="6" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,14,0,0">
                            <CheckBox x:Name="ThumbnailCheck" IsChecked="True"/>
                            <CheckBox x:Name="BodyTextCheck" IsChecked="False"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Grid Margin="0,16,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="1.15*"/>
                        <ColumnDefinition Width="0.85*"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="0,0,8,0">
                        <StackPanel>
                            <TextBlock x:Name="SourceTitle" Style="{StaticResource SectionTitle}"/>
                            <TextBlock x:Name="SourceGuideText" Margin="0,6,0,12" Foreground="#52606D"/>

                            <StackPanel Margin="0,0,0,10">
                                <RadioButton x:Name="NoneRadio"/>
                                <RadioButton x:Name="AutopostOnlyRadio"/>
                                <RadioButton x:Name="DraftRadio"/>
                                <RadioButton x:Name="ImageRadio"/>
                            </StackPanel>

                            <Border x:Name="DraftPanel" Background="#F8FAFC" BorderBrush="#D8E0EA" BorderThickness="1" CornerRadius="14" Padding="14" Visibility="Collapsed">
                                <StackPanel>
                                    <TextBlock x:Name="ManualTitleLabel" Style="{StaticResource LabelText}"/>
                                    <TextBox x:Name="ManualTitleBox"/>
                                    <TextBlock x:Name="ManualBodyLabel" Style="{StaticResource LabelText}" Margin="0,14,0,2"/>
                                    <TextBox x:Name="ManualBodyBox" Height="120" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                                    <TextBlock x:Name="ManualTagsLabel" Style="{StaticResource LabelText}" Margin="0,14,0,2"/>
                                    <TextBox x:Name="ManualTagsBox"/>
                                </StackPanel>
                            </Border>

                            <Border x:Name="ImagePanel" Background="#F8FAFC" BorderBrush="#D8E0EA" BorderThickness="1" CornerRadius="14" Padding="14" Visibility="Collapsed">
                                <StackPanel>
                                    <DockPanel LastChildFill="False">
                                        <TextBlock x:Name="ImageFileLabel" DockPanel.Dock="Left" Style="{StaticResource LabelText}"/>
                                        <Button x:Name="SelectImageButton" DockPanel.Dock="Right" Width="110" Style="{StaticResource PrimaryButton}"/>
                                    </DockPanel>
                                    <TextBlock x:Name="ImageFileGuideText" Margin="0,6,0,10" Foreground="#52606D"/>
                                    <ListBox x:Name="ImageListBox" Height="150" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </Border>

                    <Border Grid.Column="1" Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="8,0,0,0">
                        <StackPanel>
                            <TextBlock x:Name="OptionTitle" Style="{StaticResource SectionTitle}"/>
                            <TextBlock x:Name="OptionGuideText" Margin="0,6,0,12" Foreground="#52606D"/>
                            <CheckBox x:Name="ImageReviewCheck"/>
                            <CheckBox x:Name="DraftReviewCheck"/>
                            <CheckBox x:Name="TopicOptionsCheck"/>
                            <CheckBox x:Name="AutoPostingCheck"/>

                            <Border Margin="0,16,0,0" Padding="12" Background="#F0FDF4" CornerRadius="12" BorderBrush="#A7F3D0" BorderThickness="1">
                                <TextBlock x:Name="OptionHintText" TextWrapping="Wrap" Foreground="#166534"/>
                            </Border>
                        </StackPanel>
                    </Border>
                </Grid>

                <Border Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Margin="0,16,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <TextBlock x:Name="CoordTitle" Grid.ColumnSpan="2" Style="{StaticResource SectionTitle}"/>

                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,14,12,0">
                            <TextBlock x:Name="ImageCoordLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="ImageCoordHelp" Style="{StaticResource HelperText}"/>
                            <StackPanel Orientation="Horizontal">
                                <TextBox x:Name="ImageCoordXBox" Width="120"/>
                                <TextBox x:Name="ImageCoordYBox" Width="120"/>
                            </StackPanel>
                        </StackPanel>

                        <StackPanel Grid.Row="1" Grid.Column="1" Margin="12,14,0,0">
                            <TextBlock x:Name="SaveCoordLabel" Style="{StaticResource LabelText}"/>
                            <TextBlock x:Name="SaveCoordHelp" Style="{StaticResource HelperText}"/>
                            <StackPanel Orientation="Horizontal">
                                <TextBox x:Name="SaveCoordXBox" Width="120"/>
                                <TextBox x:Name="SaveCoordYBox" Width="120"/>
                            </StackPanel>
                        </StackPanel>

                        <DockPanel Grid.Row="2" Grid.ColumnSpan="2" Margin="0,14,0,0" LastChildFill="False">
                            <TextBlock x:Name="CoordGuideText" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="#52606D" FontSize="13"/>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="SaveCoordButton" Width="130"/>
                                <Button x:Name="OpenCoordToolButton" Width="170" Style="{StaticResource PrimaryButton}"/>
                            </StackPanel>
                        </DockPanel>
                    </Grid>
                </Border>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
"@

$startupLoginXamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560"
        Height="420"
        MinWidth="520"
        MinHeight="380"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        FontFamily="Malgun Gothic"
        Background="#F4F7FB">
    <Window.Resources>
        <SolidColorBrush x:Key="PanelBrush" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#D8E0EA"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#0F766E"/>
        <Style TargetType="TextBox">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Margin" Value="0,6,0,0"/>
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
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
        </Style>
    </Window.Resources>
    <DockPanel LastChildFill="True">
        <Border DockPanel.Dock="Top" Background="#102A43" Padding="22,18">
            <StackPanel>
                <TextBlock x:Name="StartupLoginTitleText" FontSize="28" FontWeight="Bold" Foreground="White"/>
                <TextBlock x:Name="StartupLoginSubtitleText" Margin="0,8,0,0" FontSize="14" Foreground="#D9E2EC" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#D8E0EA" BorderThickness="1,1,0,0" Padding="18,14">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="StartupCancelButton" Width="120"/>
                <Button x:Name="StartupLoginButton" Width="160" Style="{StaticResource PrimaryButton}"/>
            </StackPanel>
        </Border>
        <Grid Margin="18">
            <Border Background="{StaticResource PanelBrush}" CornerRadius="18" Padding="18" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0">
                        <TextBlock x:Name="StartupServerBaseUrlLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                        <TextBox x:Name="StartupServerBaseUrlBox"/>
                    </StackPanel>
                    <StackPanel Grid.Row="1" Margin="0,12,0,0">
                        <TextBlock x:Name="StartupServerUsernameLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                        <TextBox x:Name="StartupServerUsernameBox"/>
                    </StackPanel>
                    <StackPanel Grid.Row="2" Margin="0,12,0,0">
                        <TextBlock x:Name="StartupServerPasswordLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                        <PasswordBox x:Name="StartupServerPasswordBox" Margin="0,6,0,0" Padding="10,8" FontSize="14" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Background="White"/>
                    </StackPanel>
                    <TextBlock x:Name="StartupLoginGuideText" Grid.Row="3" Margin="0,14,0,0" Foreground="#52606D" TextWrapping="Wrap"/>
                    <Border Grid.Row="4" Margin="0,16,0,0" Padding="14" Background="#F8FAFC" BorderBrush="#D8E0EA" BorderThickness="1" CornerRadius="12">
                        <TextBlock x:Name="StartupLoginStatusText" Foreground="#475569" TextWrapping="Wrap"/>
                    </Border>
                </Grid>
            </Border>
        </Grid>
    </DockPanel>
</Window>
"@

[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$script:MainWindow = $window
Set-WindowSafePosition $script:MainWindow

$window.Title = U("\ube14\ub85c\uadf8 \uc790\ub3d9\ud654 \uc694\uccad \uc124\uc815")

$namedControls = @(
    "HeaderTitle","HeaderSubtitle","BottomGuideText","MainScrollViewer",
    "ProfileTitle","ProfileGuideText","ProfileNameLabel","ProfileNameHelp","ProfileNameBox","LoadProfileButton","SaveProfileButton","ListProfileButton",
    "ClientModeTitle","ClientModeGuideText","ClientModeLabel","LocalClientModeRadio","ServerClientModeRadio","LicenseCheckLabel","LicenseCheckCheck","ServerBaseUrlLabel","ServerBaseUrlHelp","ServerBaseUrlBox","AuthTokenLabel","AuthTokenHelp","AuthTokenBox","ServerUsernameLabel","ServerUsernameHelp","ServerUsernameBox","ServerPasswordLabel","ServerPasswordHelp","ServerPasswordBox","ServerLoginStatusText","ServerSubscriptionDetailText","ServerLoginButton","ServerStatusButton","ServerLogoutButton",
    "BasicInfoTitle","BusinessNameLabel","BusinessNameHelp","TopicLabel","TopicHelp","StyleLabel","StyleHelp","RegionLabel","RegionHelp","AudienceLabel","AudienceHelp","ImageCountLabel","ImageCountHelp",
    "ImageStyleLabel","ImageStyleGuideLabel","ImageStyleGuideText","AdditionalRequestLabel",
    "AdditionalRequestHelp",
    "ThumbnailCheck","BodyTextCheck",
    "SourceTitle","SourceGuideText","NoneRadio","AutopostOnlyRadio","DraftRadio","ImageRadio",
    "ManualTitleLabel","ManualBodyLabel","ManualTagsLabel","ImageFileLabel","SelectImageButton","ImageFileGuideText",
    "OptionTitle","OptionGuideText","ImageReviewCheck","DraftReviewCheck","TopicOptionsCheck","AutoPostingCheck","OptionHintText",
    "BusinessNameBox","TopicBox","StyleBox","RegionBox","AudienceBox","AdditionalRequestBox","ImageCountBox",
    "ImageStyleCombo","DraftPanel","ImagePanel","ManualTitleBox","ManualBodyBox","ManualTagsBox",
    "ImageListBox","HistoryButton","ResumeButton","CancelButton","SaveButton",
    "CoordTitle","ImageCoordLabel","ImageCoordHelp","SaveCoordLabel","SaveCoordHelp","CoordGuideText","SaveCoordButton","OpenCoordToolButton",
    "ImageCoordXBox","ImageCoordYBox","SaveCoordXBox","SaveCoordYBox"
)

foreach ($name in $namedControls) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

$HeaderTitle.Text = U("\ube14\ub85c\uadf8 \uc790\ub3d9\ud654 \uc694\uccad \uc124\uc815")
$HeaderSubtitle.Text = U("\uc5c5\uccb4 \uc815\ubcf4, \ubcf4\uc720 \uc790\ub8cc, \uc9c4\ud589 \uc635\uc158\uc744 \ud55c \ubc88\uc5d0 \uc815\ub9ac\ud569\ub2c8\ub2e4.")
$BottomGuideText.Text = ""
$BottomGuideText.Visibility = [System.Windows.Visibility]::Collapsed
$HistoryButton.Content = U("\uc0dd\uc131 \uc774\ub825 \ubcf4\uae30")
$ResumeButton.Content = U("\uc774\uc804 \uc9c4\ud589\ubd80\ud130 \uc774\uc5b4\uc11c \uc2e4\ud589")
$CancelButton.Content = U("\ucde8\uc18c")
$SaveButton.Content = U("\uc800\uc7a5 \ud6c4 \uc9c4\ud589")

$ProfileTitle.Text = U("\uc791\uc131 \ud504\ub85c\ud544")
$ProfileGuideText.Text = U("\uc790\uc8fc \uc4f0\ub294 \uc5c5\uccb4\ub098 \uae00 \uc2a4\ud0c0\uc77c\uc744 \uc774\ub984\uc73c\ub85c \uc800\uc7a5\ud558\uace0 \ub2e4\uc2dc \ubd88\ub7ec\uc635\ub2c8\ub2e4. \uc5c5\uccb4\uc6a9, \ub9db\uc9d1, \uc5ec\ud589, \uc815\ubcf4\uae00 \ub4f1 \uc5b4\ub5a4 \uc774\ub984\uc774\ub4e0 \uac00\ub2a5\ud569\ub2c8\ub2e4.")
$ProfileNameLabel.Text = U("\ud504\ub85c\ud544 \uc774\ub984")
$ProfileNameHelp.Text = ""
$ProfileNameHelp.Visibility = [System.Windows.Visibility]::Collapsed
$LoadProfileButton.Content = U("\ubd88\ub7ec\uc624\uae30")
$SaveProfileButton.Content = U("\uc800\uc7a5\ud558\uae30")
$ListProfileButton.Content = U("\ubaa9\ub85d \ubcf4\uae30")

$ClientModeTitle.Text = U("\ud074\ub77c\uc774\uc5b8\ud2b8 \uc5f0\uacb0 \uc124\uc815")
$ClientModeGuideText.Text = U("\uc0c1\ud488\ud654 \ubc30\ud3ec\ub97c \uc704\ud574 \ub85c\uceec \ubaa8\ub4dc\uc640 \uc11c\ubc84 \ubaa8\ub4dc, \uc778\uc99d \ud1a0\ud070 \uc0ac\uc6a9 \uc5ec\ubd80\ub97c \uc5ec\uae30\uc11c \uad00\ub9ac\ud569\ub2c8\ub2e4.")
$ClientModeLabel.Text = U("\uc5f0\uacb0 \ubaa8\ub4dc")
$LocalClientModeRadio.Content = U("\ub85c\uceec \ubaa8\ub4dc")
$ServerClientModeRadio.Content = U("\uc11c\ubc84 \ubaa8\ub4dc")
$LicenseCheckLabel.Text = U("\ub77c\uc774\uc120\uc2a4 \ud655\uc778")
$LicenseCheckCheck.Content = U("\uc2dc\uc791 \uc2dc \uc11c\ubc84 \uad6c\ub3c5/\ub77c\uc774\uc120\uc2a4 \uc0c1\ud0dc \ud655\uc778")
$ServerBaseUrlLabel.Text = U("\uc11c\ubc84 API \uc8fc\uc18c")
$ServerBaseUrlHelp.Text = U("\uc608: https://api.yourservice.com \ud615\uc2dd\uc73c\ub85c \uc785\ub825\ud558\uba74 \ub429\ub2c8\ub2e4.")
$AuthTokenLabel.Text = U("\uc778\uc99d \ud1a0\ud070")
$AuthTokenHelp.Text = U("\ub85c\uadf8\uc778 \ud6c4 \ubc1c\uae09\ub41c \ud1a0\ud070\uc744 \ub123\uc73c\uba74 \uc11c\ubc84 \ubaa8\ub4dc\uc5d0\uc11c \uad8c\ud55c \ud655\uc778\uc5d0 \uc0ac\uc6a9\ub429\ub2c8\ub2e4.")
$ServerUsernameLabel.Text = U("\uc11c\ubc84 \uacc4\uc815 \uc544\uc774\ub514")
$ServerUsernameHelp.Text = U("\uad6c\ub3c5 \uc0ac\uc6a9 \uacc4\uc815\uc758 \ub85c\uadf8\uc778 \uc544\uc774\ub514\ub97c \uc785\ub825\ud558\uc138\uc694.")
$ServerPasswordLabel.Text = U("\uc11c\ubc84 \uacc4\uc815 \ube44\ubc00\ubc88\ud638")
$ServerPasswordHelp.Text = U("\uc2dc\uc791 \ub85c\uadf8\uc778 \ucc3d\uc5d0\uc11c\ub9cc \uc785\ub825\ud569\ub2c8\ub2e4.")
$ServerLoginButton.Content = U("\ub2e4\uc2dc \ub85c\uadf8\uc778")
$ServerStatusButton.Content = U("\uc0c1\ud0dc \ud655\uc778")
$ServerLogoutButton.Content = U("\ub85c\uadf8\uc544\uc6c3")

$BasicInfoTitle.Text = U("\uae30\ubcf8 \uc815\ubcf4")
$BusinessNameLabel.Text = U("\uc5c5\uccb4\uba85")
$BusinessNameHelp.Text = U("\ud3ec\uc2a4\ud305\uc744 \uc4f0\ub294 \uc8fc\uccb4\uc790\ub97c \uc785\ub825\ud558\uc138\uc694. \uc5c5\uccb4\uba85, \uc0c1\ud638\uba85, \ube0c\ub79c\ub4dc\uba85\uc744 \uc801\uc73c\uba74 \ub429\ub2c8\ub2e4.")
$TopicLabel.Text = U("\ud3ec\uc2a4\ud305 \uc18c\uc7ac")
$TopicHelp.Text = U("\uc774\ubc88 \uae00\uc5d0\uc11c \ub2e4\ub8f0 \uc8fc\uc81c\ub098 \ud575\uc2ec \uc18c\uc7ac\ub97c \uc801\uc5b4\uc8fc\uc138\uc694.")
$StyleLabel.Text = U("\uae00 \uc2a4\ud0c0\uc77c")
$StyleHelp.Text = U("\uc804\ubb38\uc801, \uce5c\uadfc\ud55c, \ud6c4\uae30\ud615 \uac19\uc740 \ubb38\uccb4\ub098 \ub290\ub08c\uc744 \uc801\uc5b4\uc8fc\uc138\uc694.")
$RegionLabel.Text = U("\uc9c0\uc5ed")
$RegionHelp.Text = U("\uc8fc\uc694 \ud65c\ub3d9 \uc9c0\uc5ed\uc774\ub098 \ud3ec\uc2a4\ud305\uc5d0 \ud3ec\ud568\ud560 \uc9c0\uc5ed\uba85\uc744 \uc801\uc5b4\uc8fc\uc138\uc694.")
$AudienceLabel.Text = U("\uc8fc\uc694 \ub3c5\uc790")
$AudienceHelp.Text = U("\uc774 \uae00\uc744 \uc8fc\ub85c \uc77d\uc744 \uc0ac\ub78c\uc774 \ub204\uad6c\uc778\uc9c0 \uc801\uc5b4\uc8fc\uc138\uc694.")
$ImageCountLabel.Text = U("\uc774\ubbf8\uc9c0 \uac1c\uc218")
$ImageCountHelp.Text = U("\uc0dd\uc131\ud558\uace0 \uc2f6\uc740 \uc774\ubbf8\uc9c0 \ucd1d \uac1c\uc218\ub97c \uc22b\uc790\ub85c \uc785\ub825\ud558\uc138\uc694.")
$ImageStyleLabel.Text = U("\uc774\ubbf8\uc9c0 \uc2a4\ud0c0\uc77c")
$ImageStyleGuideLabel.Text = U("\uc774\ubbf8\uc9c0 \uc2a4\ud0c0\uc77c \uc548\ub0b4")
$ImageStyleGuideText.Text = U("\uc120\ud0dd\ud55c \uc2a4\ud0c0\uc77c\uc740 \uc378\ub124\uc77c\uacfc \ubcf8\ubb38 \uc774\ubbf8\uc9c0 \ud504\ub86c\ud504\ud2b8\uc5d0 \ud568\uaed8 \ubc18\uc601\ub429\ub2c8\ub2e4. \uac19\uc740 \uc2a4\ud0c0\uc77c \uc548\uc5d0\uc11c\ub3c4 \uc7a5\uba74\uacfc \uad6c\ub3c4\ub294 \ub2e4\uc591\ud558\uac8c \ub098\ub204\uc5b4 \uc0dd\uc131\ud569\ub2c8\ub2e4.")
$AdditionalRequestLabel.Text = U("\ucd94\uac00\uc694\uccad \uc0ac\ud56d")
$AdditionalRequestHelp.Text = U("\uaf2d \ubc18\uc601\ud558\uace0 \uc2f6\uc740 \ud3ec\uc778\ud2b8, \uae08\uc9c0 \ud45c\ud604, \uac15\uc870 \ubb38\uad6c \ub4f1\uc744 \uc801\uc5b4\uc8fc\uc138\uc694.")
$ThumbnailCheck.Content = U("\uc378\ub124\uc77c \ud14d\uc2a4\ud2b8 \ud5c8\uc6a9")
$BodyTextCheck.Content = U("\ubcf8\ubb38 \uc774\ubbf8\uc9c0 \ud14d\uc2a4\ud2b8 \ud5c8\uc6a9")

$SourceTitle.Text = U("\ubcf4\uc720 \uc790\ub8cc")
$SourceGuideText.Text = U("\ud604\uc7ac \uac00\uc9c0\uace0 \uc788\ub294 \uc790\ub8cc\ub97c \uae30\uc900\uc73c\ub85c \uc0dd\uc131 \ud750\ub984\uc744 \ubcc0\uacbd\ud569\ub2c8\ub2e4.")
$NoneRadio.Content = U("\uc5c6\uc74c - \uc6d0\uace0\uc640 \uc774\ubbf8\uc9c0\ub97c \ubaa8\ub450 \uc0dd\uc131")
$AutopostOnlyRadio.Content = U("\ucd5c\uc2e0 \uc0dd\uc131 \uc790\ub8cc\ub85c \uc790\ub3d9\ud3ec\uc2a4\ud305\ub9cc \uc2e4\ud589")
$DraftRadio.Content = U("\uc6d0\uace0 \ubcf4\uc720 - \ubcf4\uc720 \uc6d0\uace0\ub85c \uc774\ubbf8\uc9c0 \uc0dd\uc131 \ud6c4 \ud3ec\uc2a4\ud305")
$ImageRadio.Content = U("\uc774\ubbf8\uc9c0 \ubcf4\uc720 - \ubcf4\uc720 \uc774\ubbf8\uc9c0\ub85c \uc6d0\uace0 \uc0dd\uc131 \ud6c4 \ud3ec\uc2a4\ud305")
$ManualTitleLabel.Text = U("\ubcf4\uc720 \uc6d0\uace0 \uc81c\ubaa9")
$ManualBodyLabel.Text = U("\ubcf4\uc720 \uc6d0\uace0 \ubcf8\ubb38")
$ManualTagsLabel.Text = U("\ubcf4\uc720 \ud0dc\uadf8")
$ImageFileLabel.Text = U("\ubcf4\uc720 \uc774\ubbf8\uc9c0 \ud30c\uc77c")
$SelectImageButton.Content = U("\uc774\ubbf8\uc9c0 \uc120\ud0dd")
$ImageFileGuideText.Text = U("\uccab \ubc88\uc9f8 \uc774\ubbf8\uc9c0\ub294 \uc378\ub124\uc77c \uc0dd\uc131 \ucc38\uace0\uc6a9\uc73c\ub85c \uc0ac\uc6a9\ub429\ub2c8\ub2e4.")

$OptionTitle.Text = U("\uc2e4\ud589 \uc635\uc158")
$OptionGuideText.Text = U("\uac80\ud1a0 \ub2e8\uacc4\uc640 \uc790\ub3d9\ud3ec\uc2a4\ud305 \uc5ec\ubd80\ub97c \uc120\ud0dd\ud569\ub2c8\ub2e4.")
$ImageReviewCheck.Content = U("\ubf51\ud78c \uc774\ubbf8\uc9c0 \ud655\uc778")
$DraftReviewCheck.Content = U("\uc6d0\uace0 \ud655\uc778")
$TopicOptionsCheck.Content = U("\uad00\ub828 \uc18c\uc7ac/\uc81c\ubaa9 5\uac1c \ubf51\uc544\uc11c \uc120\ud0dd")
$AutoPostingCheck.Content = U("\uc790\ub3d9\ud3ec\uc2a4\ud305 \ud3ec\ud568")
$OptionHintText.Text = U("\uc544\ubb34 \uac83\ub3c4 \uccb4\ud06c\ud558\uc9c0 \uc54a\uc73c\uba74 \uba48\ucda4 \uc5c6\uc774 \uc804\uccb4 \uc9c4\ud589\ud569\ub2c8\ub2e4.\n\uc774\ubbf8\uc9c0/\uc6d0\uace0 \ud655\uc778\uc744 \ucf1c\uba74 \uc0dd\uc131 \ud6c4 \uac80\ud1a0 \ub2e8\uacc4\ub97c \uac70\uce69\ub2c8\ub2e4.\n\uc790\ub3d9\ud3ec\uc2a4\ud305\uc744 \ub044\uba74 \uc6d0\uace0\uc640 \uc774\ubbf8\uc9c0\ub9cc \ub9cc\ub4e4\uace0 \uc885\ub8cc\ud569\ub2c8\ub2e4.")
$CoordTitle.Text = U("\uc790\ub3d9\ud3ec\uc2a4\ud305 \uc88c\ud45c \uc124\uc815")
$ImageCoordLabel.Text = U("\uc0ac\uc9c4 \ubc84\ud2bc \uc88c\ud45c")
$ImageCoordHelp.Text = U("\ud604\uc7ac \uc0ac\uc6a9 \uc911\uc778 \uc0ac\uc9c4 \ucd94\uac00 \ubc84\ud2bc\uc758 X, Y \uac12\uc785\ub2c8\ub2e4.")
$SaveCoordLabel.Text = U("\uc800\uc7a5 \ubc84\ud2bc \uc88c\ud45c")
$SaveCoordHelp.Text = U("\ud604\uc7ac \uc0ac\uc6a9 \uc911\uc778 \uc784\uc2dc\uc800\uc7a5 \ubc84\ud2bc\uc758 X, Y \uac12\uc785\ub2c8\ub2e4.")
$CoordGuideText.Text = U("\uc88c\ud45c \uc218\uc815\uc774 \ud544\uc694\ud558\uba74 \uc88c\ud45c \ud655\uc778 \ub3c4\uad6c\ub97c \uc5f4\uace0, \uc0c8 \uac12\uc744 \uc785\ub825\ud55c \ub4a4 \uc800\uc7a5 \ud6c4 \uc9c4\ud589\uc744 \ub204\ub974\uc138\uc694.")
$SaveCoordButton.Content = U("\uc88c\ud45c \uc800\uc7a5")
$OpenCoordToolButton.Content = U("\uc88c\ud45c \ud655\uc778 \ub3c4\uad6c \uc5f4\uae30")

$window.FindName("ImageStyleNone").Content = U("\uc2a4\ud0c0\uc77c \uc801\uc6a9\uc548\ud568")
$window.FindName("ImageStyle01").Content = U("\uc2e4\uc0ac\ud48d \ube14\ub85c\uadf8 \uc0ac\uc9c4")
$window.FindName("ImageStyle02").Content = U("\ubc18\uc2e4\uc0ac \ucef4\ub9ac\uc158")
$window.FindName("ImageStyle03").Content = U("\ud074\ub9b0 \ube0c\ub79c\ub4dc \uc5d0\ub514\ud1a0\ub9ac\uc5bc")
$window.FindName("ImageStyle04").Content = U("\ub530\ub73b\ud55c \ud6c4\uae30\ud615 \uac10\uc131 \uc0ac\uc9c4")
$window.FindName("ImageStyle05").Content = U("\ud604\uc7a5\uac10 \uc788\ub294 \ub2e4\ud050\uba58\ud130\ub9ac")
$window.FindName("ImageStyle06").Content = U("\uc0b0\uc5c5\uc6a9 \uc804\ubb38 \uc2e4\uc0ac")
$window.FindName("ImageStyle07").Content = U("\uc138\ub828\ub41c \uce74\ud398\u00b7\ub9e4\uc7a5 \ud6c4\uae30\ud615")
$window.FindName("ImageStyle08").Content = U("\ud50c\ub7ab \uc77c\ub7ec\uc2a4\ud2b8")
$window.FindName("ImageStyle09").Content = U("\ubd80\ub4dc\ub7ec\uc6b4 \ub77c\uc774\ud504\uc2a4\ud0c0\uc77c")
$window.FindName("ImageStyle10").Content = U("\uace0\uae09\uc2a4\ub7ec\uc6b4 \uc5d0\ub514\ud1a0\ub9ac\uc5bc")

$ImageStyleCombo.SelectedIndex = 0

$placeholderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(148, 163, 184))
$textBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(16, 42, 67))

function Set-Placeholder {
    param(
        [System.Windows.Controls.TextBox]$TextBox,
        [string]$Placeholder
    )

    $TextBox.Tag = $Placeholder
    $TextBox.Text = $Placeholder
    $TextBox.Foreground = $placeholderBrush

    $TextBox.Add_GotFocus({
        if ($this.Text -eq [string]$this.Tag -and $this.Foreground.Color -eq $placeholderBrush.Color) {
            $this.Text = ""
            $this.Foreground = $textBrush
        }
    })

    $TextBox.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text = [string]$this.Tag
            $this.Foreground = $placeholderBrush
        }
        else {
            $this.Foreground = $textBrush
        }
    })
}

function Get-RealText {
    param([System.Windows.Controls.TextBox]$TextBox)

    $value = $TextBox.Text
    if ($value -eq [string]$TextBox.Tag -and $TextBox.Foreground.Color -eq $placeholderBrush.Color) {
        return ""
    }
    return $value.Trim()
}

function Set-RealText {
    param(
        [System.Windows.Controls.TextBox]$TextBox,
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    $TextBox.Text = $text
    $TextBox.Foreground = $textBrush
}

function Set-CheckValue {
    param(
        [System.Windows.Controls.Primitives.ToggleButton]$Control,
        [AllowNull()][object]$Value
    )

    if ($null -ne $Value) {
        $Control.IsChecked = [bool]$Value
    }
}

function Select-ComboValue {
    param(
        [System.Windows.Controls.ComboBox]$ComboBox,
        [AllowNull()][object]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        $ComboBox.SelectedIndex = 0
        return
    }

    foreach ($item in $ComboBox.Items) {
        if ([string]$item.Content -eq $text) {
            $ComboBox.SelectedItem = $item
            return
        }
    }
}

function Load-PreviousRequestValues {
    param([pscustomobject]$Previous)

    Set-RealText -TextBox $BusinessNameBox -Value $Previous.business_name
    Set-RealText -TextBox $TopicBox -Value $Previous.topic
    Set-RealText -TextBox $StyleBox -Value $Previous.writing_style
    Set-RealText -TextBox $RegionBox -Value $Previous.region
    Set-RealText -TextBox $AudienceBox -Value $Previous.target_audience
    Set-RealText -TextBox $ImageCountBox -Value $Previous.image_count
    Set-RealText -TextBox $ManualTitleBox -Value $Previous.manual_title
    Set-RealText -TextBox $ManualBodyBox -Value $Previous.manual_body
    Set-RealText -TextBox $ManualTagsBox -Value $Previous.manual_tags

    $requestLines = @()
    if ($Previous.additional_request) {
        foreach ($item in $Previous.additional_request) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                $requestLines += [string]$item
            }
        }
    }
    elseif ($Previous.must_include) {
        foreach ($item in $Previous.must_include) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                $requestLines += [string]$item
            }
        }
    }
    if ($requestLines.Count -gt 0) {
        Set-RealText -TextBox $AdditionalRequestBox -Value ($requestLines -join "`r`n")
    }

    Select-ComboValue -ComboBox $ImageStyleCombo -Value $Previous.image_style
    Set-CheckValue -Control $ThumbnailCheck -Value $Previous.thumbnail_text_allowed
    Set-CheckValue -Control $BodyTextCheck -Value $Previous.body_text_allowed
    Set-CheckValue -Control $ImageReviewCheck -Value $Previous.review_images_enabled
    Set-CheckValue -Control $DraftReviewCheck -Value $Previous.review_draft_enabled
    Set-CheckValue -Control $TopicOptionsCheck -Value $Previous.topic_options_enabled
    Set-CheckValue -Control $AutoPostingCheck -Value $Previous.auto_posting_enabled

    switch ([string]$Previous.input_mode) {
        "autopost_only" { $AutopostOnlyRadio.IsChecked = $true }
        "draft" { $DraftRadio.IsChecked = $true }
        "image" { $ImageRadio.IsChecked = $true }
        default { $NoneRadio.IsChecked = $true }
    }

    $ImageListBox.Items.Clear()
    if ($Previous.selected_image_paths) {
        foreach ($path in $Previous.selected_image_paths) {
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                [void]$ImageListBox.Items.Add([string]$path)
            }
        }
    }

    if ($Previous.image_button_x) { $ImageCoordXBox.Text = [string]$Previous.image_button_x }
    if ($Previous.image_button_y) { $ImageCoordYBox.Text = [string]$Previous.image_button_y }
    if ($Previous.save_button_x) { $SaveCoordXBox.Text = [string]$Previous.save_button_x }
    if ($Previous.save_button_y) { $SaveCoordYBox.Text = [string]$Previous.save_button_y }

    Update-SourceModeUi
}

Set-Placeholder -TextBox $ProfileNameBox -Placeholder (U("\uc800\uc7a5\ud558\uac70\ub098 \ubd88\ub7ec\uc62c \ud504\ub85c\ud544 \uc774\ub984"))
Set-Placeholder -TextBox $ServerBaseUrlBox -Placeholder (U("https://api.yourservice.com"))
Set-Placeholder -TextBox $AuthTokenBox -Placeholder (U("\ubc1c\uae09\ubc1b\uc740 \ud1a0\ud070\uc744 \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $ServerUsernameBox -Placeholder (U("\uc11c\ubc84 \uacc4\uc815 \uc544\uc774\ub514"))
Set-Placeholder -TextBox $BusinessNameBox -Placeholder (U("\uc5c5\uccb4\uba85\uc744 \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $TopicBox -Placeholder (U("\ud3ec\uc2a4\ud305 \uc8fc\uc81c\ub97c \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $StyleBox -Placeholder (U("\uc6d0\ud558\ub294 \uae00 \uc2a4\ud0c0\uc77c\uc744 \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $RegionBox -Placeholder (U("\uc9c0\uc5ed\uba85\uc744 \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $AudienceBox -Placeholder (U("\uc8fc\uc694 \ub3c5\uc790\ub97c \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $ImageCountBox -Placeholder (U("\uc774\ubbf8\uc9c0 \uac1c\uc218"))
Set-Placeholder -TextBox $AdditionalRequestBox -Placeholder (U("\ucd94\uac00 \uc694\uccad \uc0ac\ud56d\uc744 \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $ManualTitleBox -Placeholder (U("\ubcf4\uc720 \uc6d0\uace0 \uc81c\ubaa9\uc744 \uc785\ub825\ud558\uc138\uc694."))
Set-Placeholder -TextBox $ManualBodyBox -Placeholder (U("\ubcf4\uc720 \uc6d0\uace0 \ubcf8\ubb38\uc744 \ubd99\uc5ec\ub123\uc5b4 \uc8fc\uc138\uc694."))
Set-Placeholder -TextBox $ManualTagsBox -Placeholder (U("\ud0dc\uadf8\ub97c \uc785\ub825\ud558\uc138\uc694."))

function Get-AhkCoordinateValue {
    param(
        [string]$Content,
        [string]$Name
    )

    $match = [regex]::Match($Content, "global\s+$Name\s+:=\s+(\d+)")
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function Update-AhkCoordinates {
    param(
        [string]$ScriptPath,
        [int]$ImageX,
        [int]$ImageY,
        [int]$SaveX,
        [int]$SaveY
    )

    $content = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $content = $content -replace 'global imageButtonX := \d+', "global imageButtonX := $ImageX"
    $content = $content -replace 'global imageButtonY := \d+', "global imageButtonY := $ImageY"
    $content = $content -replace 'global saveButtonX := \d+', "global saveButtonX := $SaveX"
    $content = $content -replace 'global saveButtonY := \d+', "global saveButtonY := $SaveY"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ScriptPath, $content, $utf8Bom)
}

function Save-RequestPayload {
    $additionalRequest = @()
    foreach ($line in ((Get-RealText $AdditionalRequestBox) -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) { $additionalRequest += $trimmed }
    }

    $imageCoordX = 0
    $imageCoordY = 0
    $saveCoordX = 0
    $saveCoordY = 0
    if (-not [int]::TryParse($ImageCoordXBox.Text.Trim(), [ref]$imageCoordX)) { throw (U("\uc0ac\uc9c4 \ubc84\ud2bc X \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4.")) }
    if (-not [int]::TryParse($ImageCoordYBox.Text.Trim(), [ref]$imageCoordY)) { throw (U("\uc0ac\uc9c4 \ubc84\ud2bc Y \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4.")) }
    if (-not [int]::TryParse($SaveCoordXBox.Text.Trim(), [ref]$saveCoordX)) { throw (U("\uc800\uc7a5 \ubc84\ud2bc X \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4.")) }
    if (-not [int]::TryParse($SaveCoordYBox.Text.Trim(), [ref]$saveCoordY)) { throw (U("\uc800\uc7a5 \ubc84\ud2bc Y \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4.")) }

    $inputMode = "none"
    if ($AutopostOnlyRadio.IsChecked) { $inputMode = "autopost_only" }
    elseif ($DraftRadio.IsChecked) { $inputMode = "draft" }
    elseif ($ImageRadio.IsChecked) { $inputMode = "image" }

    $selectedImagePaths = @()
    foreach ($item in $ImageListBox.Items) { $selectedImagePaths += [string]$item }

    $imageCountText = Get-RealText $ImageCountBox
    $imageCount = 8
    if ([string]::IsNullOrWhiteSpace($imageCountText)) {
        if ($inputMode -eq "image") { $imageCount = [Math]::Max(1, $selectedImagePaths.Count) }
        elseif ($inputMode -eq "autopost_only") { $imageCount = 0 }
    }
    elseif (-not [int]::TryParse($imageCountText, [ref]$imageCount)) {
        throw (U("\uc774\ubbf8\uc9c0 \uac1c\uc218\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4."))
    }

    $anyProcessChecked = [bool]$ImageReviewCheck.IsChecked -or [bool]$DraftReviewCheck.IsChecked -or [bool]$TopicOptionsCheck.IsChecked -or [bool]$AutoPostingCheck.IsChecked
    $autoPostingEnabled = if ($inputMode -eq "autopost_only") { $true } elseif ($anyProcessChecked) { [bool]$AutoPostingCheck.IsChecked } else { $true }

    $imageStyle = $ImageStyleCombo.Text.Trim()
    if ($imageStyle -eq (U("\uc2a4\ud0c0\uc77c \uc801\uc6a9\uc548\ud568"))) { $imageStyle = "" }

    $payload = [ordered]@{
        business_name = Get-RealText $BusinessNameBox
        topic = Get-RealText $TopicBox
        writing_style = Get-RealText $StyleBox
        image_style = $imageStyle
        region = Get-RealText $RegionBox
        target_audience = Get-RealText $AudienceBox
        additional_request = $additionalRequest
        must_include = $additionalRequest
        image_count = $imageCount
        thumbnail_text_allowed = [bool]$ThumbnailCheck.IsChecked
        body_text_allowed = [bool]$BodyTextCheck.IsChecked
        input_mode = $inputMode
        manual_title = Get-RealText $ManualTitleBox
        manual_body = Get-RealText $ManualBodyBox
        manual_tags = Get-RealText $ManualTagsBox
        selected_image_paths = $selectedImagePaths
        review_images_enabled = [bool]$ImageReviewCheck.IsChecked
        review_draft_enabled = [bool]$DraftReviewCheck.IsChecked
        topic_options_enabled = [bool]$TopicOptionsCheck.IsChecked
        title_option_count = $(if ($TopicOptionsCheck.IsChecked) { 5 } else { 1 })
        auto_posting_enabled = $autoPostingEnabled
        image_button_x = $imageCoordX
        image_button_y = $imageCoordY
        save_button_x = $saveCoordX
        save_button_y = $saveCoordY
    }

    $clientSettings = Get-CurrentClientSettings
    if ($clientSettings.mode -eq 'server' -and [string]::IsNullOrWhiteSpace($clientSettings.server_base_url)) {
        throw (U("\uc11c\ubc84 \ubaa8\ub4dc\uc5d0\uc11c\ub294 API \uc8fc\uc18c\ub97c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4."))
    }

    if ($inputMode -ne "autopost_only" -and [string]::IsNullOrWhiteSpace($payload.business_name)) { throw (U("\uc5c5\uccb4\uba85\uc740 \ube44\uc6cc\ub458 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.")) }
    if ($inputMode -eq "none" -and [string]::IsNullOrWhiteSpace($payload.topic)) { throw (U("\ud3ec\uc2a4\ud305 \uc18c\uc7ac\ub294 \ube44\uc6cc\ub458 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.")) }
    if ($inputMode -eq "draft" -and [string]::IsNullOrWhiteSpace($payload.manual_body)) { throw (U("\ubcf4\uc720 \uc6d0\uace0 \ubcf8\ubb38\uc744 \uc785\ub825\ud574 \uc8fc\uc138\uc694.")) }
    if ($inputMode -eq "image" -and $selectedImagePaths.Count -lt 1) { throw (U("\ubcf4\uc720 \uc774\ubbf8\uc9c0 \ud30c\uc77c\uc744 1\uac1c \uc774\uc0c1 \uc120\ud0dd\ud574 \uc8fc\uc138\uc694.")) }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $jsonText = $payload | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($outputPath, $jsonText, $utf8Bom)
    Write-ClientSettings -Settings $clientSettings
    Update-AhkCoordinates -ScriptPath $ahkPath -ImageX $imageCoordX -ImageY $imageCoordY -SaveX $saveCoordX -SaveY $saveCoordY
    Write-Host ((U("\uc785\ub825 \uc800\uc7a5 \uc644\ub8cc")) + ": $outputPath") -ForegroundColor Green
    Write-Host ((U("\ud074\ub77c\uc774\uc5b8\ud2b8 \uc124\uc815 \uc800\uc7a5 \uc644\ub8cc")) + ": $clientSettingsPath") -ForegroundColor DarkGreen
    return $outputPath
}

function Add-ProgressLine {
    param([System.Windows.Controls.TextBox]$TextBox, [string]$Message)
    if (-not $TextBox) {
        Write-Host ("[$(Get-Date -Format 'HH:mm:ss')] $Message") -ForegroundColor Yellow
        return
    }
    try {
        $TextBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
        $TextBox.ScrollToEnd()
    }
    catch {
        Write-Host ("[$(Get-Date -Format 'HH:mm:ss')] $Message") -ForegroundColor Yellow
    }
}

function Convert-PipelineLogToSummary {
    param([string]$Raw)

    $items = New-Object System.Collections.Generic.List[string]
    function Add-SummaryLine([string]$Text) {
        if (-not [string]::IsNullOrWhiteSpace($Text) -and -not $items.Contains($Text)) {
            [void]$items.Add($Text)
        }
    }
    function Add-StageSummary([string]$StartPattern, [string]$NextPattern, [string]$DoingText, [string]$DoneText) {
        if ($Raw -match $StartPattern) {
            if (-not [string]::IsNullOrWhiteSpace($NextPattern) -and $Raw -match $NextPattern) {
                Add-SummaryLine $DoneText
            }
            else {
                Add-SummaryLine $DoingText
            }
        }
    }

    Add-StageSummary '==\s*1\.' '==\s*2\.' (U("\uc628\ub77c\uc778 \ub9ac\uc11c\uce58 \uc218\uc9d1 \uc911...")) (U("\uc628\ub77c\uc778 \ub9ac\uc11c\uce58 \uc644\ub8cc"))
    Add-StageSummary '==\s*2\.' '==\s*3\.' (U("\uc81c\ubaa9 \ud6c4\ubcf4 \uc0dd\uc131 \uc911...")) (U("\uc81c\ubaa9 \ud6c4\ubcf4 \uc0dd\uc131 \uc644\ub8cc"))
    Add-StageSummary '==\s*4\.' '==\s*5\.' (U("\uc6d0\uace0 \uc791\uc131 \uc911...")) (U("\uc6d0\uace0 \uc791\uc131 \uc644\ub8cc"))
    Add-StageSummary '==\s*8\.' '==\s*9\.' (U("\uc774\ubbf8\uc9c0 \uc0dd\uc131 \uc911...")) (U("\uc774\ubbf8\uc9c0 \uc0dd\uc131 \uc644\ub8cc"))
    Add-StageSummary '==\s*10\.' '' (U("\uc790\ub3d9\ud3ec\uc2a4\ud305 \uc900\ube44 \uc911...")) (U("\uc790\ub3d9\ud3ec\uc2a4\ud305 \uc900\ube44 \uc644\ub8cc"))
    Add-StageSummary '==\s*11\.' '' (U("\uc790\ub3d9\ud3ec\uc2a4\ud305 \uc2e4\ud589 \uc911...")) (U("\uc790\ub3d9\ud3ec\uc2a4\ud305 \uc644\ub8cc"))

    $imageIndex = 0
    foreach ($line in ($Raw -split "`r?`n")) {
        if ($line -match ':\s*((?:\d{2}_thumb)|(?:\d{2}))\.png' -and $line -notmatch ',') {
            $imageIndex++
            Add-SummaryLine ((U("\uc774\ubbf8\uc9c0")) + " $imageIndex " + (U("\uc644\ub8cc")))
        }
    }

    if ($Raw -match '(?m)^\s*실패 원인:\s*(.+)$') {
        Add-SummaryLine ((U("\uc2e4\ud328 \uc6d0\uc778")) + ": " + $Matches[1])
    }
    elseif ($Raw -match 'insufficient_quota') {
        Add-SummaryLine (U("OpenAI API \ud06c\ub808\ub527\uc774 \ubd80\uc871\ud574 \uc911\ub2e8\ub410\uc2b5\ub2c8\ub2e4."))
    }

    if ($items.Count -eq 0) { Add-SummaryLine (U("\uc791\uc5c5 \uc900\ube44 \uc911...")) }
    $status = $items[$items.Count - 1]
    return [pscustomobject]@{ Text = ($items -join "`r`n"); Status = $status }
}
function Show-InWindowProgress {
    param([string]$RunLogPath)

    $windowRef = $script:MainWindow
    if (-not $windowRef) { throw (U("\uc9c4\ud589\ucc3d \uae30\uc900 \uc708\ub3c4\uc6b0\ub97c \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")) }

    function Get-ProgressControl([string]$Name) {
        $value = Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if (-not $value -and $script:MainWindow) { $value = $script:MainWindow.FindName($Name) }
        if (-not $value) { throw ((U("\ud654\uba74 \ucee8\ud2b8\ub864\uc744 \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4")) + ": " + $Name) }
        return $value
    }

    $headerTitleCtrl = Get-ProgressControl "HeaderTitle"
    $headerSubtitleCtrl = Get-ProgressControl "HeaderSubtitle"
    $bottomGuideCtrl = Get-ProgressControl "BottomGuideText"
    $historyButtonCtrl = Get-ProgressControl "HistoryButton"
    $resumeButtonCtrl = Get-ProgressControl "ResumeButton"
    $saveButtonCtrl = Get-ProgressControl "SaveButton"
    $cancelButtonCtrl = Get-ProgressControl "CancelButton"
    $mainScrollViewerCtrl = Get-ProgressControl "MainScrollViewer"

    $windowRef.Title = U("\ube14\ub85c\uadf8 \uc790\ub3d9\ud654 \uc9c4\ud589 \uc911")
    $headerTitleCtrl.Text = U("\ube14\ub85c\uadf8 \uc790\ub3d9\ud654 \uc9c4\ud589 \uc911")
    $headerSubtitleCtrl.Text = U("\uc785\ub825\ud55c \uc124\uc815\uc744 \uae30\uc900\uc73c\ub85c \uc791\uc5c5\uc744 \uc9c4\ud589\ud569\ub2c8\ub2e4.")
    $bottomGuideCtrl.Text = U("\uc9c4\ud589 \uc911\uc785\ub2c8\ub2e4. \uc644\ub8cc\ub418\uba74 \uc774 \ud654\uba74\uc5d0 \uacb0\uacfc\uac00 \ud45c\uc2dc\ub429\ub2c8\ub2e4.")
    $historyButtonCtrl.Visibility = [System.Windows.Visibility]::Collapsed
    $resumeButtonCtrl.Visibility = [System.Windows.Visibility]::Collapsed
    $saveButtonCtrl.Visibility = [System.Windows.Visibility]::Collapsed
    $cancelButtonCtrl.Content = U("\uc9c4\ud589 \uc911")
    $cancelButtonCtrl.IsEnabled = $false

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Object System.Windows.Thickness(18)

    $card = New-Object System.Windows.Controls.Border
    $card.Background = [System.Windows.Media.Brushes]::White
    $card.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(216,224,234))
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(18)
    $card.Padding = New-Object System.Windows.Thickness(24)

    $inner = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = U("\uc2e4\ud589 \uc0c1\ud0dc")
    $title.FontSize = 28
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(16,42,67))

    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = U("\uc900\ube44 \uc911...")
    $status.FontSize = 18
    $status.Margin = New-Object System.Windows.Thickness(0,16,0,8)
    $status.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(15,118,110))

    $progress = New-Object System.Windows.Controls.ProgressBar
    $progress.Height = 18
    $progress.IsIndeterminate = $true
    $progress.Margin = New-Object System.Windows.Thickness(0,0,0,18)

    $logLabel = New-Object System.Windows.Controls.TextBlock
    $logLabel.Text = U("\uc2e4\ud589 \ub85c\uadf8")
    $logLabel.FontSize = 16
    $logLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
    $logLabel.Margin = New-Object System.Windows.Thickness(0,8,0,6)

    $logBox = New-Object System.Windows.Controls.TextBox
    $logBox.Height = 430
    $logBox.AcceptsReturn = $true
    $logBox.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $logBox.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $logBox.IsReadOnly = $true
    $logBox.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $logBox.FontSize = 13
    $logBox.Text = ""

    $pathText = New-Object System.Windows.Controls.TextBlock
    $pathText.Text = "Log: $RunLogPath"
    $pathText.FontSize = 12
    $pathText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(82,96,109))
    $pathText.Margin = New-Object System.Windows.Thickness(0,14,0,0)
    $pathText.TextWrapping = [System.Windows.TextWrapping]::Wrap

    $logButtonPanel = New-Object System.Windows.Controls.StackPanel
    $logButtonPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $logButtonPanel.Margin = New-Object System.Windows.Thickness(0,12,0,0)

    $openLogButton = New-Object System.Windows.Controls.Button
    $openLogButton.Content = U("\uc0c1\uc138 \ub85c\uadf8 \uc5f4\uae30")
    $openLogButton.Width = 150
    $openLogButton.Height = 36
    $openLogButton.Margin = New-Object System.Windows.Thickness(0,0,10,0)
    $openLogButton.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $RunLogPath)) {
                [System.Windows.MessageBox]::Show((U("\uc544\uc9c1 \ub85c\uadf8 \ud30c\uc77c\uc774 \uc0dd\uc131\ub418\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4.")), (U("\ub85c\uadf8 \ud655\uc778"))) | Out-Null
                return
            }
            Start-Process -FilePath "notepad.exe" -ArgumentList @($RunLogPath) | Out-Null
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, (U("\ub85c\uadf8 \uc5f4\uae30 \uc2e4\ud328"))) | Out-Null
        }
    })

    $openLogFolderButton = New-Object System.Windows.Controls.Button
    $openLogFolderButton.Content = U("\ub85c\uadf8 \ud3f4\ub354 \uc5f4\uae30")
    $openLogFolderButton.Width = 160
    $openLogFolderButton.Height = 36
    $openLogFolderButton.Add_Click({
        try {
            $logFolder = Split-Path -Parent $RunLogPath
            if (Test-Path -LiteralPath $RunLogPath) {
                Start-Process -FilePath "explorer.exe" -ArgumentList @("/select,`"$RunLogPath`"") | Out-Null
            }
            elseif (Test-Path -LiteralPath $logFolder) {
                Start-Process -FilePath "explorer.exe" -ArgumentList @("`"$logFolder`"") | Out-Null
            }
            else {
                [System.Windows.MessageBox]::Show((U("\ub85c\uadf8 \ud3f4\ub354\ub97c \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")), (U("\ub85c\uadf8 \ud655\uc778"))) | Out-Null
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, (U("\ub85c\uadf8 \ud3f4\ub354 \uc5f4\uae30 \uc2e4\ud328"))) | Out-Null
        }
    })

    [void]$logButtonPanel.Children.Add($openLogButton)
    [void]$logButtonPanel.Children.Add($openLogFolderButton)

    [void]$inner.Children.Add($title)
    [void]$inner.Children.Add($status)
    [void]$inner.Children.Add($progress)
    [void]$inner.Children.Add($logLabel)
    [void]$inner.Children.Add($logBox)
    [void]$inner.Children.Add($pathText)
    [void]$inner.Children.Add($logButtonPanel)
    $card.Child = $inner
    [void]$panel.Children.Add($card)
    $mainScrollViewerCtrl.Content = $panel
    $mainScrollViewerCtrl.ScrollToTop()

    return [pscustomobject]@{ Status = $status; Progress = $progress; LogBox = $logBox; BottomGuide = $bottomGuideCtrl; CancelButton = $cancelButtonCtrl }
}
function Report-UiException {
    param($ErrorRecord, [string]$Title)
    try {
        $logsDir = Join-Path $projectRoot "logs"
        if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        $uiErrorLog = Join-Path $logsDir ("ui_error_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
        $detail = @(
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Title",
            $ErrorRecord.Exception.ToString(),
            "",
            "ScriptStackTrace:",
            $ErrorRecord.ScriptStackTrace
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($uiErrorLog, $detail, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ((U("\ud654\uba74 \uc624\ub958 \ub85c\uadf8")) + ": " + $uiErrorLog) -ForegroundColor Yellow
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }

    [void][System.Windows.MessageBox]::Show(
        ($ErrorRecord.Exception.Message + "`n`n" + (U("\uc790\uc138\ud55c \ub0b4\uc6a9\uc740 logs \ud3f4\ub354\uc758 ui_error \ub85c\uadf8\ub97c \ud655\uc778\ud574 \uc8fc\uc138\uc694."))),
        $Title
    )
}
function Start-InWindowPipeline {
    try {
        Save-RequestPayload | Out-Null
    }
    catch {
        [void][System.Windows.MessageBox]::Show($_.Exception.Message, (U("\uc785\ub825 \ud655\uc778")))
        return
    }

    $logsDir = Join-Path $projectRoot "logs"
    if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $runLogPath = Join-Path $logsDir ("in_window_pipeline_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    $runScript = Join-Path $projectRoot "scripts\run_full_pipeline.ps1"
    $progressUi = Show-InWindowProgress -RunLogPath $runLogPath
    $script:InWindowRunLogPath = $runLogPath
    $script:InWindowProgressUi = $progressUi
    Add-ProgressLine -TextBox $script:InWindowProgressUi.LogBox -Message (U("\uc791\uc5c5\uc744 \uc2dc\uc791\ud569\ub2c8\ub2e4."))

    $script:PipelineHandled = $true
    $script:PipelineRunning = $true
    $script:PipelineExitCode = 41
    $arguments = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$runScript`"",
        "-SkipRequestInput", "-NoPause",
        "-ExternalRunLogPath", "`"$runLogPath`""
    )
    try {
        $script:PipelineProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru
    }
    catch {
        $script:PipelineRunning = $false
        $script:PipelineExitCode = 41
        $script:InWindowProgressUi.Status.Text = U("\uc2e4\ud589 \uc2dc\uc791 \uc2e4\ud328")
        Add-ProgressLine -TextBox $script:InWindowProgressUi.LogBox -Message $_.Exception.Message
        $script:InWindowProgressUi.CancelButton.Content = U("\ub2eb\uae30")
        $script:InWindowProgressUi.CancelButton.IsEnabled = $true
        return
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(900)
    $script:LastProgressText = ""
    $timer.Add_Tick({
        try {
            try {
                if (-not [string]::IsNullOrWhiteSpace($script:InWindowRunLogPath) -and (Test-Path -LiteralPath $script:InWindowRunLogPath)) {
                    $raw = Get-Content -LiteralPath $script:InWindowRunLogPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($raw -and $raw -ne $script:LastProgressText) {
                        $script:LastProgressText = $raw
                        $summary = Convert-PipelineLogToSummary -Raw $raw
                        if ($script:InWindowProgressUi -and $script:InWindowProgressUi.Status) { $script:InWindowProgressUi.Status.Text = $summary.Status }
                        if ($script:InWindowProgressUi -and $script:InWindowProgressUi.LogBox) {
                            $script:InWindowProgressUi.LogBox.Text = $summary.Text
                            $script:InWindowProgressUi.LogBox.ScrollToEnd()
                        }
                    }
                }
            }
            catch {
                # 진행 표시 자체의 문제는 사용자 화면에 반복 노출하지 않고, 프로세스 종료 여부 확인은 계속 진행합니다.
            }

            if ($script:PipelineProcess -and $script:PipelineProcess.HasExited) {
                $script:InWindowProgressTimer.Stop()
                $script:PipelineRunning = $false
                if ($script:PipelineProcess.ExitCode -eq 0) {
                    $script:PipelineExitCode = 40
                    $script:InWindowProgressUi.Progress.IsIndeterminate = $false
                    $script:InWindowProgressUi.Progress.Value = 100
                    $script:InWindowProgressUi.Status.Text = U("\uc644\ub8cc\ub410\uc2b5\ub2c8\ub2e4")
                    $script:InWindowProgressUi.BottomGuide.Text = U("\uc791\uc5c5\uc774 \uc644\ub8cc\ub410\uc2b5\ub2c8\ub2e4. \ub2eb\uae30\ub97c \ub204\ub974\uba74 \uc885\ub8cc\ud569\ub2c8\ub2e4.")
                    Add-ProgressLine -TextBox $script:InWindowProgressUi.LogBox -Message (U("\uc804\uccb4 \uc791\uc5c5\uc774 \uc644\ub8cc\ub410\uc2b5\ub2c8\ub2e4."))
                }
                else {
                    $script:PipelineExitCode = 41
                    $script:InWindowProgressUi.Progress.IsIndeterminate = $false
                    $script:InWindowProgressUi.Progress.Value = 0
                    $script:InWindowProgressUi.Status.Text = U("\uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4")
                    $script:InWindowProgressUi.BottomGuide.Text = U("\uc791\uc5c5\uc774 \uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4. \ub85c\uadf8\uc758 \uc2e4\ud328 \uc6d0\uc778\uc744 \ud655\uc778\ud574 \uc8fc\uc138\uc694.")
                    Add-ProgressLine -TextBox $script:InWindowProgressUi.LogBox -Message ((U("\uc2e4\ud328 \ucf54\ub4dc")) + ": " + $script:PipelineProcess.ExitCode)
                }
                $script:InWindowProgressUi.CancelButton.Content = U("\ub2eb\uae30")
                $script:InWindowProgressUi.CancelButton.IsEnabled = $true
            }
        }
        catch {
            try {
                if ($script:InWindowProgressTimer) { $script:InWindowProgressTimer.Stop() }
                $script:PipelineRunning = $false
                $script:PipelineExitCode = 41
                if ($script:InWindowProgressUi) {
                    if ($script:InWindowProgressUi.Progress) {
                        $script:InWindowProgressUi.Progress.IsIndeterminate = $false
                        $script:InWindowProgressUi.Progress.Value = 0
                    }
                    if ($script:InWindowProgressUi.Status) { $script:InWindowProgressUi.Status.Text = U("\uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4") }
                    if ($script:InWindowProgressUi.BottomGuide) { $script:InWindowProgressUi.BottomGuide.Text = U("\uc791\uc5c5\uc774 \uc911\ub2e8\ub410\uc2b5\ub2c8\ub2e4. \ub2eb\uae30\ub97c \ub204\ub974\uba74 \uc885\ub8cc\ud569\ub2c8\ub2e4.") }
                    if ($script:InWindowProgressUi.LogBox) { $script:InWindowProgressUi.LogBox.Text = U("\uc791\uc5c5\uc774 \uc911\ub2e8\ub410\uc2b5\ub2c8\ub2e4.") }
                    if ($script:InWindowProgressUi.CancelButton) {
                        $script:InWindowProgressUi.CancelButton.Content = U("\ub2eb\uae30")
                        $script:InWindowProgressUi.CancelButton.IsEnabled = $true
                    }
                }
            }
            catch {
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
        }
    })
    $timer.Start()
}

function Stop-InWindowPipeline {
    try {
        if ($script:InWindowProgressTimer) {
            $script:InWindowProgressTimer.Stop()
        }
        if ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited) {
            try {
                Stop-Process -Id $script:PipelineProcess.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
    }
    finally {
        $script:PipelineRunning = $false
        $script:PipelineExitCode = 41
        if ($script:InWindowProgressUi) {
            if ($script:InWindowProgressUi.Progress) {
                $script:InWindowProgressUi.Progress.IsIndeterminate = $false
                $script:InWindowProgressUi.Progress.Value = 0
            }
            if ($script:InWindowProgressUi.Status) {
                $script:InWindowProgressUi.Status.Text = U("\uc911\ub2e8\ub410\uc2b5\ub2c8\ub2e4")
            }
            if ($script:InWindowProgressUi.BottomGuide) {
                $script:InWindowProgressUi.BottomGuide.Text = U("\uc791\uc5c5\uc774 \uc911\ub2e8\ub410\uc2b5\ub2c8\ub2e4. \ub2eb\uae30\ub97c \ub204\ub974\uba74 \uc885\ub8cc\ud569\ub2c8\ub2e4.")
            }
            if ($script:InWindowProgressUi.LogBox) {
                $script:InWindowProgressUi.LogBox.Text = U("\uc791\uc5c5\uc774 \uc911\ub2e8\ub410\uc2b5\ub2c8\ub2e4.")
            }
            if ($script:InWindowProgressUi.CancelButton) {
                $script:InWindowProgressUi.CancelButton.Content = U("\ub2eb\uae30")
                $script:InWindowProgressUi.CancelButton.IsEnabled = $true
            }
        }
    }
}

function Confirm-StopInWindowPipeline {
    $answer = [System.Windows.MessageBox]::Show(
        (U("\uc791\uc5c5\uc774 \uc9c4\ud589 \uc911\uc785\ub2c8\ub2e4. \uc911\ub2e8\ud558\uace0 \ub2eb\uc744\uae4c\uc694?")),
        (U("\uc791\uc5c5 \uc911\ub2e8")),
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        Stop-InWindowPipeline
        return $true
    }
    return $false
}


function Ensure-ProfileStorage {
    $profileDir = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $empty = [ordered]@{ profiles = @() } | ConvertTo-Json -Depth 6
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($profilePath, $empty, $utf8Bom)
    }
}

function Read-WritingProfiles {
    Ensure-ProfileStorage
    try { $data = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $data = [pscustomobject]@{ profiles = @() } }
    if ($null -eq $data.profiles) { return @() }
    if ($data.profiles -is [System.Array]) { return @($data.profiles) }
    return @($data.profiles)
}

function Write-WritingProfiles {
    param([array]$Profiles)
    Ensure-ProfileStorage
    $data = [ordered]@{ profiles = @($Profiles) }
    $json = $data | ConvertTo-Json -Depth 8
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($profilePath, $json, $utf8Bom)
}

function Get-DefaultClientSettings {
    return [ordered]@{
        mode = 'local'
        client_mode = 'local'
        server_base_url = ''
        api_auth_token = ''
        username = ''
        license_check_on_start = $true
        plan_name = ''
        account_status = ''
        account_expires_at = ''
    }
}

function Read-ClientSettings {
    $defaults = Get-DefaultClientSettings
    if (-not (Test-Path -LiteralPath $clientSettingsPath)) {
        return [pscustomobject]$defaults
    }

    try {
        $raw = Get-Content -LiteralPath $clientSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]$defaults
    }

    foreach ($key in @($defaults.Keys)) {
        if ($null -eq $raw.$key) {
            $raw | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }

    $resolvedMode = [string]($raw.client_mode)
    if ([string]::IsNullOrWhiteSpace($resolvedMode)) {
        $resolvedMode = [string]($raw.mode)
    }
    if ([string]::IsNullOrWhiteSpace($resolvedMode)) {
        $resolvedMode = 'local'
    }
    $raw.mode = $resolvedMode
    $raw.client_mode = $resolvedMode
    return $raw
}

function Write-ClientSettings {
    param([psobject]$Settings)

    $defaults = Get-DefaultClientSettings
    $data = [ordered]@{}
    foreach ($key in @($defaults.Keys)) {
        $value = $defaults[$key]
        if ($null -ne $Settings -and $null -ne $Settings.$key) {
            $value = $Settings.$key
        }
        $data[$key] = $value
    }

    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $json = $data | ConvertTo-Json -Depth 6
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($clientSettingsPath, $json, $utf8Bom)
}

function Update-ServerLoginStatus {
    param(
        [string]$Message,
        [ValidateSet('info','success','warning','error')]
        [string]$Level = 'info'
    )

    $brushMap = @{
        info = [System.Windows.Media.Brushes]::SlateGray
        success = [System.Windows.Media.Brushes]::ForestGreen
        warning = [System.Windows.Media.Brushes]::DarkOrange
        error = [System.Windows.Media.Brushes]::Firebrick
    }

    $ServerLoginStatusText.Text = $Message
    $ServerLoginStatusText.Foreground = $brushMap[$Level]
}

function Update-ServerSubscriptionDetail {
    param(
        [string]$Message = ''
    )

    if ($null -ne $ServerSubscriptionDetailText) {
        $ServerSubscriptionDetailText.Text = $Message
    }
}

function Update-ProceedButtonState {
    param(
        [bool]$Blocked = $false,
        [string]$Reason = ''
    )

    if ($null -eq $SaveButton) {
        return
    }

    $isServerMode = ($null -ne $ServerClientModeRadio -and [bool]$ServerClientModeRadio.IsChecked)
    if (-not $isServerMode) {
        $SaveButton.IsEnabled = $true
        $SaveButton.ToolTip = $null
        return
    }

    $token = Get-RealText $AuthTokenBox
    if ([string]::IsNullOrWhiteSpace($token)) {
        $SaveButton.IsEnabled = $false
        $SaveButton.ToolTip = U("시작 로그인 창에서 먼저 로그인해 주세요.")
        return
    }

    if ($Blocked) {
        $SaveButton.IsEnabled = $false
        $SaveButton.ToolTip = $Reason
        return
    }

    $SaveButton.IsEnabled = $true
    $SaveButton.ToolTip = $null
}

function Set-ServerActionButtonsEnabled {
    param([bool]$Enabled)

    foreach ($button in @($ServerLoginButton, $ServerStatusButton, $ServerLogoutButton)) {
        if ($null -ne $button) {
            $button.IsEnabled = $Enabled
        }
    }
}

function Get-ServerStatusSummary {
    param([string[]]$OutputLines)

    $pairs = @{}
    foreach ($line in $OutputLines) {
        if ($line -match '^([A-Z_]+):\s*(.*)$') {
            $pairs[$matches[1]] = $matches[2]
        }
    }

    $status = ($pairs['STATUS'] | ForEach-Object { $_.Trim().ToLower() })
    $username = ($pairs['USERNAME'] | ForEach-Object { $_.Trim() })
    $plan = ($pairs['PLAN'] | ForEach-Object { $_.Trim() })
    $expiresAt = ($pairs['EXPIRES_AT'] | ForEach-Object { $_.Trim() })
    $message = ($pairs['MESSAGE'] | ForEach-Object { $_.Trim() })
    $daysUntilExpiry = ($pairs['DAYS_UNTIL_EXPIRY'] | ForEach-Object { $_.Trim() })
    $draftsRemaining = ($pairs['DRAFTS_REMAINING'] | ForEach-Object { $_.Trim() })
    $imagesRemaining = ($pairs['IMAGES_REMAINING'] | ForEach-Object { $_.Trim() })
    $isExpired = ($pairs['IS_EXPIRED'] | ForEach-Object { $_.Trim().ToLower() })
    $warningParts = @()
    $blockReason = ''

    if (-not [string]::IsNullOrWhiteSpace($daysUntilExpiry) -and $daysUntilExpiry -match '^-?\d+$') {
        $expiryDaysValue = [int]$daysUntilExpiry
        if ($expiryDaysValue -lt 0) {
            $blockReason = U("구독이 만료되어 진행할 수 없습니다. 관리자에게 연장을 요청해 주세요.")
        }
        elseif ($expiryDaysValue -le 7) {
            $warningParts += ((U("만료 임박 ")) + $expiryDaysValue + (U("일")))
        }
    }
    elseif ($isExpired -eq 'true') {
        $blockReason = U("구독이 만료되어 진행할 수 없습니다. 관리자에게 연장을 요청해 주세요.")
    }

    if (-not [string]::IsNullOrWhiteSpace($draftsRemaining) -and $draftsRemaining -match '^\d+$') {
        if ([int]$draftsRemaining -le 3) {
            $warningParts += ((U("초안 잔여 적음 ")) + $draftsRemaining)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($imagesRemaining) -and $imagesRemaining -match '^\d+$') {
        if ([int]$imagesRemaining -le 5) {
            $warningParts += ((U("이미지 잔여 적음 ")) + $imagesRemaining)
        }
    }

    $detailParts = @()
    if (-not [string]::IsNullOrWhiteSpace($plan)) { $detailParts += ((U("플랜: ")) + $plan) }
    if (-not [string]::IsNullOrWhiteSpace($daysUntilExpiry) -and $daysUntilExpiry -match '^-?\d+$') {
        if ([int]$daysUntilExpiry -ge 0) {
            $detailParts += ((U("만료까지 ")) + $daysUntilExpiry + (U("일")))
        }
        else {
            $detailParts += U("만료됨")
        }
    }
    elseif ($isExpired -eq 'true') {
        $detailParts += U("만료됨")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($expiresAt)) {
        $detailParts += ((U("만료일: ")) + $expiresAt)
    }
    if (-not [string]::IsNullOrWhiteSpace($draftsRemaining)) {
        $detailParts += ((U("초안 남음: ")) + $draftsRemaining)
    }
    if (-not [string]::IsNullOrWhiteSpace($imagesRemaining)) {
        $detailParts += ((U("이미지 남음: ")) + $imagesRemaining)
    }
    foreach ($warningPart in $warningParts) {
        $detailParts += $warningPart
    }
    $detailMessage = ($detailParts -join ' | ')

    if ($status -eq 'active') {
        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($username)) { $parts += $username }
        if ($parts.Count -eq 0) {
            return @{
                Message = U("서버 로그인 상태가 정상입니다.")
                Detail = $detailMessage
                Level = $(if ($warningParts.Count -gt 0) { 'warning' } else { 'success' })
                BlockReason = $blockReason
            }
        }
        return @{
            Message = ((U("로그인 완료: ")) + ($parts -join ' / '))
            Detail = $detailMessage
            Level = $(if ($warningParts.Count -gt 0) { 'warning' } else { 'success' })
            BlockReason = $blockReason
        }
    }

    if ($status -eq 'inactive') {
        return @{
            Message = U("계정이 비활성화되어 있습니다. 관리자에게 문의해 주세요.")
            Detail = $detailMessage
            Level = 'warning'
            BlockReason = U("계정이 비활성화되어 진행할 수 없습니다.")
        }
    }

    if ($status -eq 'missing') {
        return @{
            Message = U("저장된 로그인 정보가 없습니다.")
            Detail = ''
            Level = 'warning'
            BlockReason = U("로그인 후 다시 진행해 주세요.")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($message)) {
        return @{
            Message = $message
            Detail = $detailMessage
            Level = 'warning'
            BlockReason = $blockReason
        }
    }

    return @{
        Message = U("서버 로그인 상태를 확인할 수 없습니다.")
        Detail = $detailMessage
        Level = 'warning'
        BlockReason = $blockReason
    }
}

function Update-ClientModeUi {
    $isServer = [bool]$ServerClientModeRadio.IsChecked
    $visibility = if ($isServer) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    foreach ($control in @($ServerLoginStatusText, $ServerSubscriptionDetailText, $ServerLoginButton, $ServerStatusButton, $ServerLogoutButton)) {
        if ($null -ne $control) {
            $control.Visibility = $visibility
        }
    }
    foreach ($control in @(
        $ServerBaseUrlLabel, $ServerBaseUrlHelp, $ServerBaseUrlBox,
        $AuthTokenLabel, $AuthTokenHelp, $AuthTokenBox,
        $ServerUsernameLabel, $ServerUsernameHelp, $ServerUsernameBox,
        $ServerPasswordLabel, $ServerPasswordHelp, $ServerPasswordBox
    )) {
        if ($null -ne $control) {
            $control.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }

    if (-not $isServer) {
        Set-ServerActionButtonsEnabled -Enabled $false
        Update-ServerLoginStatus -Message (U("\ub85c\uceec \ubaa8\ub4dc\uc5d0\uc11c\ub294 \uc11c\ubc84 \ub85c\uadf8\uc778 \uc5c6\uc774 \uadf8\ub300\ub85c \uc0ac\uc6a9\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.")) -Level info
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $false
        return
    }

    Set-ServerActionButtonsEnabled -Enabled $true
    $token = Get-RealText $AuthTokenBox
    $username = Get-RealText $ServerUsernameBox
    $baseUrl = Get-RealText $ServerBaseUrlBox
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $false
        if ([string]::IsNullOrWhiteSpace($username)) {
            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
                Update-ServerLoginStatus -Message (U("\uc11c\ubc84 \ud1a0\ud070\uc774 \uc800\uc7a5\ub418\uc5b4 \uc788\uc2b5\ub2c8\ub2e4.")) -Level success
            }
            else {
                Update-ServerLoginStatus -Message (((U("\uc11c\ubc84 \uc5f0\uacb0 \uc900\ube44 \uc644\ub8cc: ")) + $baseUrl)) -Level success
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
                Update-ServerLoginStatus -Message (((U("\ub85c\uadf8\uc778 \uc644\ub8cc: ")) + $username)) -Level success
            }
            else {
                Update-ServerLoginStatus -Message (((U("\ub85c\uadf8\uc778 \uc644\ub8cc: ")) + $username + ' @ ' + $baseUrl)) -Level success
            }
        }
    }
    else {
        Update-ServerLoginStatus -Message (U("\uc11c\ubc84 \ubaa8\ub4dc\ub97c \uc4f8 \ub54c\ub294 \uc2dc\uc791 \ub85c\uadf8\uc778 \ucc3d\uc5d0\uc11c \uba3c\uc800 \ub85c\uadf8\uc778\ud574 \uc8fc\uc138\uc694.")) -Level warning
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $true -Reason (U("시작 로그인 창에서 먼저 로그인해 주세요."))
    }
}

function Apply-ClientSettings {
    param([psobject]$Settings)

    if ($null -eq $Settings) {
        $Settings = Read-ClientSettings
    }

    $mode = [string]($Settings.client_mode)
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = [string]($Settings.mode)
    }
    if ($mode -eq 'server') {
        $ServerClientModeRadio.IsChecked = $true
    }
    else {
        $LocalClientModeRadio.IsChecked = $true
    }

    Set-CheckValue -Control $LicenseCheckCheck -Value $(if ($null -eq $Settings.license_check_on_start) { $true } else { [bool]$Settings.license_check_on_start })
    Set-RealText -TextBox $ServerBaseUrlBox -Value $Settings.server_base_url
    Set-RealText -TextBox $AuthTokenBox -Value $Settings.api_auth_token
    Set-RealText -TextBox $ServerUsernameBox -Value $Settings.username
    if ($ServerPasswordBox) {
        $ServerPasswordBox.Password = ''
    }
    Update-ClientModeUi
}

function Get-CurrentClientSettings {
    $existing = Read-ClientSettings
    $mode = if ($ServerClientModeRadio.IsChecked) { 'server' } else { 'local' }
    $existing.mode = $mode
    $existing.client_mode = $mode
    $existing.server_base_url = Get-RealText $ServerBaseUrlBox
    $existing.api_auth_token = Get-RealText $AuthTokenBox
    $existing.username = Get-RealText $ServerUsernameBox
    $existing.license_check_on_start = [bool]$LicenseCheckCheck.IsChecked
    return $existing
}

function Invoke-ServerLoginCore {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $loginScript = Join-Path $PSScriptRoot 'client_login.py'
    $output = & $PythonExe $loginScript '--server-base-url' $BaseUrl '--username' $Username '--password' $Password 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $message = ($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = U("\ub85c\uadf8\uc778 \uc911 \uc54c \uc218 \uc5c6\ub294 \uc624\ub958\uac00 \ubc1c\uc0dd\ud588\uc2b5\ub2c8\ub2e4.")
        }
        return [pscustomobject]@{
            Success  = $false
            ExitCode = $exitCode
            Message  = $message
            Settings = $null
        }
    }

    $updated = Read-ClientSettings
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = U("\ub85c\uadf8\uc778 \uc644\ub8cc. \ud1a0\ud070\uc744 \uc800\uc7a5\ud588\uc2b5\ub2c8\ub2e4.")
    }
    return [pscustomobject]@{
        Success  = $true
        ExitCode = 0
        Message  = $message
        Settings = $updated
    }
}

function Invoke-ServerLogin {
    if (-not $ServerClientModeRadio.IsChecked) {
        Update-ServerLoginStatus -Message (U("\ub85c\uceec \ubaa8\ub4dc\uc5d0\uc11c\ub294 \ub85c\uadf8\uc778\uc774 \ud544\uc694 \uc5c6\uc2b5\ub2c8\ub2e4.")) -Level info
        return
    }

    $settings = Get-CurrentClientSettings
    Update-ServerLoginStatus -Message (U("\uc2dc\uc791 \ub85c\uadf8\uc778 \ucc3d\uc744 \uc5ec\ub294 \uc911...")) -Level info
    $ServerLoginButton.IsEnabled = $false
    try {
        $loginSucceeded = Show-StartupServerLoginWindow -Settings $settings
        if (-not $loginSucceeded) {
            Update-ServerLoginStatus -Message (U("\ub85c\uadf8\uc778\uc744 \ucde8\uc18c\ud588\uc2b5\ub2c8\ub2e4.")) -Level warning
            return
        }

        $updatedSettings = Read-ClientSettings
        Apply-ClientSettings -Settings $updatedSettings
        $username = [string]($updatedSettings.server_username)
        if ([string]::IsNullOrWhiteSpace($username)) {
            Update-ServerLoginStatus -Message (U("\ub2e4\uc2dc \ub85c\uadf8\uc778 \uc644\ub8cc. \ud1a0\ud070\uc774 \uc800\uc7a5\ub418\uc5c8\uc2b5\ub2c8\ub2e4.")) -Level success
        }
        else {
            Update-ServerLoginStatus -Message (((U("\ub2e4\uc2dc \ub85c\uadf8\uc778 \uc644\ub8cc: ")) + $username)) -Level success
        }
        Invoke-ServerStatusRefresh
    }
    finally {
        $ServerLoginButton.IsEnabled = $true
    }
}

function Show-StartupServerLoginWindow {
    param(
        [Parameter(Mandatory = $true)]$Settings
    )

    [xml]$startupLoginXaml = $startupLoginXamlText
    $startupReader = New-Object System.Xml.XmlNodeReader $startupLoginXaml
    $startupWindow = [Windows.Markup.XamlReader]::Load($startupReader)
    if (-not $startupWindow) {
        throw (U("\uc2dc\uc791 \ub85c\uadf8\uc778 \ucc3d\uc744 \uc0dd\uc131\ud558\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4."))
    }

    Set-WindowSafePosition $startupWindow

    $startupTitleText = $startupWindow.FindName('StartupLoginTitleText')
    $startupSubtitleText = $startupWindow.FindName('StartupLoginSubtitleText')
    $startupServerBaseUrlLabel = $startupWindow.FindName('StartupServerBaseUrlLabel')
    $startupServerBaseUrlBox = $startupWindow.FindName('StartupServerBaseUrlBox')
    $startupServerUsernameLabel = $startupWindow.FindName('StartupServerUsernameLabel')
    $startupServerUsernameBox = $startupWindow.FindName('StartupServerUsernameBox')
    $startupServerPasswordLabel = $startupWindow.FindName('StartupServerPasswordLabel')
    $startupServerPasswordBox = $startupWindow.FindName('StartupServerPasswordBox')
    $startupLoginGuideText = $startupWindow.FindName('StartupLoginGuideText')
    $startupLoginStatusText = $startupWindow.FindName('StartupLoginStatusText')
    $startupCancelButton = $startupWindow.FindName('StartupCancelButton')
    $startupLoginButton = $startupWindow.FindName('StartupLoginButton')

    $startupTitleText.Text = U("\uc11c\ubc84 \ub85c\uadf8\uc778")
    $startupSubtitleText.Text = U("\ud074\ub77c\uc774\uc5b8\ud2b8\uc6a9 \uc0ac\uc6a9 \uad8c\ud55c\uc744 \ud655\uc778\ud55c \ub4a4 \uba54\uc778 \uc785\ub825 \ud654\uba74\uc73c\ub85c \uc9c4\uc785\ud569\ub2c8\ub2e4.")
    $startupServerBaseUrlLabel.Text = U("\uc11c\ubc84 API \uc8fc\uc18c")
    $startupServerUsernameLabel.Text = U("\uc11c\ubc84 \uacc4\uc815 ID")
    $startupServerPasswordLabel.Text = U("\uc11c\ubc84 \ube44\ubc00\ubc88\ud638")
    $startupLoginGuideText.Text = U("\ub85c\uceec \ubaa8\ub4dc\uac00 \uc544\ub2cc \uc11c\ubc84 \ubaa8\ub4dc\uc5d0\uc11c\ub294 \uba3c\uc800 \ub85c\uadf8\uc778\uc774 \ud544\uc694\ud569\ub2c8\ub2e4.")
    $startupLoginStatusText.Text = U("\ub85c\uadf8\uc778 \ub300\uae30 \uc911")
    $startupCancelButton.Content = U("\ucde8\uc18c")
    $startupLoginButton.Content = U("\ub85c\uadf8\uc778 \ud6c4 \uc2dc\uc791")

    if ($startupServerBaseUrlBox) { $startupServerBaseUrlBox.Text = "$($Settings.server_base_url)" }
    if ($startupServerUsernameBox) { $startupServerUsernameBox.Text = "$($Settings.username)" }

    $setStartupStatus = {
        param([string]$Message, [string]$Color)
        if ($startupLoginStatusText) {
            $startupLoginStatusText.Text = $Message
            $startupLoginStatusText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
        }
    }

    $startupCancelButton.Add_Click({
        $startupWindow.DialogResult = $false
        $startupWindow.Close()
    })

    $startupLoginButton.Add_Click({
        $baseUrl = if ($startupServerBaseUrlBox) { $startupServerBaseUrlBox.Text.Trim() } else { '' }
        $username = if ($startupServerUsernameBox) { $startupServerUsernameBox.Text.Trim() } else { '' }
        $password = if ($startupServerPasswordBox) { $startupServerPasswordBox.Password.Trim() } else { '' }

        if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            & $setStartupStatus (U("\uc11c\ubc84 API \uc8fc\uc18c\ub97c \uc785\ub825\ud574 \uc8fc\uc138\uc694.")) '#B91C1C'
            return
        }
        if ([string]::IsNullOrWhiteSpace($username)) {
            & $setStartupStatus (U("\uc11c\ubc84 \uacc4\uc815 ID\ub97c \uc785\ub825\ud574 \uc8fc\uc138\uc694.")) '#B91C1C'
            return
        }
        if ([string]::IsNullOrWhiteSpace($password)) {
            & $setStartupStatus (U("\uc11c\ubc84 \ube44\ubc00\ubc88\ud638\ub97c \uc785\ub825\ud574 \uc8fc\uc138\uc694.")) '#B91C1C'
            return
        }

        $startupLoginButton.IsEnabled = $false
        & $setStartupStatus (U("\ub85c\uadf8\uc778 \uc694\uccad \uc911...")) '#B45309'
        try {
            $loginResult = Invoke-ServerLoginCore -BaseUrl $baseUrl -Username $username -Password $password
            if (-not $loginResult.Success) {
                & $setStartupStatus $loginResult.Message '#B91C1C'
                return
            }

            Apply-ClientSettings -Settings $loginResult.Settings
            if ($startupServerPasswordBox) {
                $startupServerPasswordBox.Password = ''
            }
            & $setStartupStatus $loginResult.Message '#047857'
            $startupWindow.DialogResult = $true
            $startupWindow.Close()
        }
        finally {
            $startupLoginButton.IsEnabled = $true
        }
    })

    return [bool]$startupWindow.ShowDialog()
}

function Invoke-ServerStatusRefresh {
    $baseUrl = Get-RealText $ServerBaseUrlBox
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        Update-ServerLoginStatus -Message (U("\uc11c\ubc84 API URL\uc744 \uba3c\uc800 \uc785\ub825\ud574 \uc8fc\uc138\uc694.")) -Level warning
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $true -Reason (U("서버 API 주소를 먼저 입력해 주세요."))
        return
    }

    try {
        Set-ServerActionButtonsEnabled -Enabled $false
        Update-ServerLoginStatus -Message (U("\ub85c\uadf8\uc778 \uc0c1\ud0dc\ub97c \ud655\uc778 \uc911\uc785\ub2c8\ub2e4...")) -Level info

        $statusScript = Join-Path $PSScriptRoot 'client_status.py'
        $output = & $PythonExe $statusScript --base-url $baseUrl 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }

        $summary = Get-ServerStatusSummary -OutputLines $output
        Update-ServerLoginStatus -Message $summary.Message -Level $summary.Level
        Update-ServerSubscriptionDetail -Message $summary.Detail
        Update-ProceedButtonState -Blocked (-not [string]::IsNullOrWhiteSpace($summary.BlockReason)) -Reason $summary.BlockReason
    }
    catch {
        Update-ServerLoginStatus -Message (((U("\uc0c1\ud0dc \ud655\uc778 \uc2e4\ud328: ")) + $_.Exception.Message)) -Level error
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $false
    }
    finally {
        Set-ServerActionButtonsEnabled -Enabled $true
    }
}

function Invoke-ServerLogout {
    $baseUrl = Get-RealText $ServerBaseUrlBox
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        Update-ServerLoginStatus -Message (U("\uc11c\ubc84 API URL\uc744 \uba3c\uc800 \uc785\ub825\ud574 \uc8fc\uc138\uc694.")) -Level warning
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $true -Reason (U("서버 API 주소를 먼저 입력해 주세요."))
        return
    }

    try {
        Set-ServerActionButtonsEnabled -Enabled $false
        Update-ServerLoginStatus -Message (U("\ub85c\uadf8\uc544\uc6c3 \ucc98\ub9ac \uc911\uc785\ub2c8\ub2e4...")) -Level info

        $logoutScript = Join-Path $PSScriptRoot 'client_logout.py'
        $output = & $PythonExe $logoutScript --base-url $baseUrl 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }

        $AuthTokenBox.Text = ''
        Set-PlaceholderState -TextBox $AuthTokenBox -PlaceholderText $AuthTokenPlaceholder
        Update-ServerLoginStatus -Message (U("\ub85c\uadf8\uc544\uc6c3\ud588\uc2b5\ub2c8\ub2e4. \ub2e4\uc2dc \ub85c\uadf8\uc778\ud558\uba74 \uc0c8 \ud1a0\ud070\uc774 \uc800\uc7a5\ub429\ub2c8\ub2e4.")) -Level success
        Update-ServerSubscriptionDetail -Message ''
        Update-ProceedButtonState -Blocked $true -Reason (U("다시 로그인 후 진행해 주세요."))
    }
    catch {
        Update-ServerLoginStatus -Message (((U("\ub85c\uadf8\uc544\uc6c3 \uc2e4\ud328: ")) + $_.Exception.Message)) -Level error
    }
    finally {
        Set-ServerActionButtonsEnabled -Enabled $true
    }
}
function Get-SelectedImagePathList {
    $paths = @()
    foreach ($item in $ImageListBox.Items) { $paths += [string]$item }
    return $paths
}

function Get-CurrentProfileData {
    $imageStyle = $ImageStyleCombo.Text.Trim()
    if ($imageStyle -eq (U("\uc2a4\ud0c0\uc77c \uc801\uc6a9\uc548\ud568"))) { $imageStyle = "" }
    $inputMode = "none"
    if ($AutopostOnlyRadio.IsChecked) { $inputMode = "autopost_only" }
    elseif ($DraftRadio.IsChecked) { $inputMode = "draft" }
    elseif ($ImageRadio.IsChecked) { $inputMode = "image" }
    return [ordered]@{
        business_name = Get-RealText $BusinessNameBox
        topic = Get-RealText $TopicBox
        writing_style = Get-RealText $StyleBox
        image_style = $imageStyle
        region = Get-RealText $RegionBox
        target_audience = Get-RealText $AudienceBox
        additional_request_text = Get-RealText $AdditionalRequestBox
        image_count = Get-RealText $ImageCountBox
        thumbnail_text_allowed = [bool]$ThumbnailCheck.IsChecked
        body_text_allowed = [bool]$BodyTextCheck.IsChecked
        input_mode = $inputMode
        manual_title = Get-RealText $ManualTitleBox
        manual_body = Get-RealText $ManualBodyBox
        manual_tags = Get-RealText $ManualTagsBox
        selected_image_paths = Get-SelectedImagePathList
        review_images_enabled = [bool]$ImageReviewCheck.IsChecked
        review_draft_enabled = [bool]$DraftReviewCheck.IsChecked
        topic_options_enabled = [bool]$TopicOptionsCheck.IsChecked
        auto_posting_enabled = [bool]$AutoPostingCheck.IsChecked
    }
}

function Apply-WritingProfile {
    param([pscustomobject]$Profile)
    if ($null -eq $Profile) { return }
    Set-RealText -TextBox $BusinessNameBox -Value $Profile.business_name
    Set-RealText -TextBox $TopicBox -Value $Profile.topic
    Set-RealText -TextBox $StyleBox -Value $Profile.writing_style
    Set-RealText -TextBox $RegionBox -Value $Profile.region
    Set-RealText -TextBox $AudienceBox -Value $Profile.target_audience
    Set-RealText -TextBox $ImageCountBox -Value $Profile.image_count
    Set-RealText -TextBox $AdditionalRequestBox -Value $Profile.additional_request_text
    Set-RealText -TextBox $ManualTitleBox -Value $Profile.manual_title
    Set-RealText -TextBox $ManualBodyBox -Value $Profile.manual_body
    Set-RealText -TextBox $ManualTagsBox -Value $Profile.manual_tags
    Select-ComboValue -ComboBox $ImageStyleCombo -Value $Profile.image_style
    Set-CheckValue -Control $ThumbnailCheck -Value $Profile.thumbnail_text_allowed
    Set-CheckValue -Control $BodyTextCheck -Value $Profile.body_text_allowed
    Set-CheckValue -Control $ImageReviewCheck -Value $Profile.review_images_enabled
    Set-CheckValue -Control $DraftReviewCheck -Value $Profile.review_draft_enabled
    Set-CheckValue -Control $TopicOptionsCheck -Value $Profile.topic_options_enabled
    Set-CheckValue -Control $AutoPostingCheck -Value $Profile.auto_posting_enabled
    switch ([string]$Profile.input_mode) {
        "autopost_only" { $AutopostOnlyRadio.IsChecked = $true }
        "draft" { $DraftRadio.IsChecked = $true }
        "image" { $ImageRadio.IsChecked = $true }
        default { $NoneRadio.IsChecked = $true }
    }
    $ImageListBox.Items.Clear()
    if ($Profile.selected_image_paths) {
        foreach ($imagePath in $Profile.selected_image_paths) {
            if (-not [string]::IsNullOrWhiteSpace([string]$imagePath)) { [void]$ImageListBox.Items.Add([string]$imagePath) }
        }
    }
    Update-SourceModeUi
}

function Find-WritingProfileByName {
    param([string]$Name)
    foreach ($profile in (Read-WritingProfiles)) {
        if ([string]$profile.name -eq $Name) { return $profile }
    }
    return $null
}

function Save-CurrentWritingProfile {
    $name = Get-RealText $ProfileNameBox
    if ([string]::IsNullOrWhiteSpace($name)) {
        [void][System.Windows.MessageBox]::Show((U("\ud504\ub85c\ud544 \uc774\ub984\uc744 \uc785\ub825\ud574 \uc8fc\uc138\uc694.")), (U("\uc791\uc131 \ud504\ub85c\ud544")))
        return
    }
    $profiles = @(Read-WritingProfiles)
    $existing = $profiles | Where-Object { [string]$_.name -eq $name } | Select-Object -First 1
    if ($existing) {
        $answer = [System.Windows.MessageBox]::Show(((U("\uac19\uc740 \uc774\ub984\uc758 \ud504\ub85c\ud544\uc774 \uc788\uc2b5\ub2c8\ub2e4. \ub36e\uc5b4\uc4f0\uae30\ud560\uae4c\uc694?")) + "`n`n$name"), (U("\ud504\ub85c\ud544 \ub36e\uc5b4\uc4f0\uae30")), [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $profiles = @($profiles | Where-Object { [string]$_.name -ne $name })
    }
    $profileData = Get-CurrentProfileData
    $profile = [pscustomobject]([ordered]@{
        name = $name
        updated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        business_name = $profileData.business_name
        topic = $profileData.topic
        writing_style = $profileData.writing_style
        image_style = $profileData.image_style
        region = $profileData.region
        target_audience = $profileData.target_audience
        additional_request_text = $profileData.additional_request_text
        image_count = $profileData.image_count
        thumbnail_text_allowed = $profileData.thumbnail_text_allowed
        body_text_allowed = $profileData.body_text_allowed
        input_mode = $profileData.input_mode
        manual_title = $profileData.manual_title
        manual_body = $profileData.manual_body
        manual_tags = $profileData.manual_tags
        selected_image_paths = $profileData.selected_image_paths
        review_images_enabled = $profileData.review_images_enabled
        review_draft_enabled = $profileData.review_draft_enabled
        topic_options_enabled = $profileData.topic_options_enabled
        auto_posting_enabled = $profileData.auto_posting_enabled
    })
    $profiles = @($profiles) + @($profile)
    $profiles = @($profiles | Sort-Object name)
    Write-WritingProfiles -Profiles $profiles
    [void][System.Windows.MessageBox]::Show(((U("\ud504\ub85c\ud544 \uc800\uc7a5 \uc644\ub8cc")) + "`n`n$name"), (U("\uc791\uc131 \ud504\ub85c\ud544")))
}

function Load-WritingProfileFromName {
    $name = Get-RealText $ProfileNameBox
    if ([string]::IsNullOrWhiteSpace($name)) {
        [void][System.Windows.MessageBox]::Show((U("\ubd88\ub7ec\uc62c \ud504\ub85c\ud544 \uc774\ub984\uc744 \uc785\ub825\ud574 \uc8fc\uc138\uc694.")), (U("\uc791\uc131 \ud504\ub85c\ud544")))
        return
    }
    $profile = Find-WritingProfileByName -Name $name
    if (-not $profile) {
        [void][System.Windows.MessageBox]::Show(((U("\ud574\ub2f9 \uc774\ub984\uc758 \ud504\ub85c\ud544\uc744 \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")) + "`n`n$name"), (U("\uc791\uc131 \ud504\ub85c\ud544")))
        return
    }
    Apply-WritingProfile -Profile $profile
    [void][System.Windows.MessageBox]::Show(((U("\ud504\ub85c\ud544 \ubd88\ub7ec\uc624\uae30 \uc644\ub8cc")) + "`n`n$name"), (U("\uc791\uc131 \ud504\ub85c\ud544")))
}

function Show-WritingProfileList {
    $profiles = @(Read-WritingProfiles)
    if ($profiles.Count -lt 1) {
        [void][System.Windows.MessageBox]::Show((U("\uc544\uc9c1 \uc800\uc7a5\ub41c \ud504\ub85c\ud544\uc774 \uc5c6\uc2b5\ub2c8\ub2e4.")), (U("\uc791\uc131 \ud504\ub85c\ud544")))
        return
    }
    $listWindow = New-Object System.Windows.Window
    $listWindow.Title = U("\uc791\uc131 \ud504\ub85c\ud544 \ubaa9\ub85d")
    $listWindow.Width = 520
    $listWindow.Height = 520
    $listWindow.MinWidth = 420
    $listWindow.MinHeight = 360
    $listWindow.WindowStartupLocation = 'CenterOwner'
    $listWindow.Owner = $window
    $listWindow.FontFamily = New-Object System.Windows.Media.FontFamily("Malgun Gothic")
    $listWindow.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(244, 247, 251))
    $panel = New-Object System.Windows.Controls.DockPanel
    $panel.Margin = New-Object System.Windows.Thickness(18)
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = U("\ubd88\ub7ec\uc62c \ud504\ub85c\ud544\uc744 \uc120\ud0dd\ud558\uc138\uc694")
    $title.FontSize = 22
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.Margin = New-Object System.Windows.Thickness(0,0,0,12)
    [System.Windows.Controls.DockPanel]::SetDock($title, 'Top')
    [void]$panel.Children.Add($title)
    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = New-Object System.Windows.Thickness(0,14,0,0)
    [System.Windows.Controls.DockPanel]::SetDock($buttonPanel, 'Bottom')
    $selectButton = New-Object System.Windows.Controls.Button
    $selectButton.Content = U("\uc120\ud0dd")
    $selectButton.Width = 110
    $selectButton.Height = 42
    $selectButton.Margin = New-Object System.Windows.Thickness(0,0,8,0)
    $closeButton = New-Object System.Windows.Controls.Button
    $closeButton.Content = U("\ub2eb\uae30")
    $closeButton.Width = 110
    $closeButton.Height = 42
    [void]$buttonPanel.Children.Add($selectButton)
    [void]$buttonPanel.Children.Add($closeButton)
    [void]$panel.Children.Add($buttonPanel)
    $listBox = New-Object System.Windows.Controls.ListBox
    $listBox.FontSize = 15
    foreach ($profile in ($profiles | Sort-Object name)) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = [string]$profile.name
        $item.Tag = $profile
        [void]$listBox.Items.Add($item)
    }
    [void]$panel.Children.Add($listBox)
    $selectAction = {
        if ($listBox.SelectedItem) {
            $selectedProfile = $listBox.SelectedItem.Tag
            Set-RealText -TextBox $ProfileNameBox -Value $selectedProfile.name
            Apply-WritingProfile -Profile $selectedProfile
            $listWindow.DialogResult = $true
            $listWindow.Close()
        }
    }
    $selectButton.Add_Click($selectAction)
    $listBox.Add_MouseDoubleClick($selectAction)
    $closeButton.Add_Click({ $listWindow.DialogResult = $false; $listWindow.Close() })
    $listWindow.Content = $panel
    [void]$listWindow.ShowDialog()
}
function Save-CoordinateSettings {
    $imageCoordX = 0
    $imageCoordY = 0
    $saveCoordX = 0
    $saveCoordY = 0

    if (-not [int]::TryParse($ImageCoordXBox.Text.Trim(), [ref]$imageCoordX)) {
        throw (U("\uc0ac\uc9c4 \ubc84\ud2bc X \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4."))
    }
    if (-not [int]::TryParse($ImageCoordYBox.Text.Trim(), [ref]$imageCoordY)) {
        throw (U("\uc0ac\uc9c4 \ubc84\ud2bc Y \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4."))
    }
    if (-not [int]::TryParse($SaveCoordXBox.Text.Trim(), [ref]$saveCoordX)) {
        throw (U("\uc800\uc7a5 \ubc84\ud2bc X \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4."))
    }
    if (-not [int]::TryParse($SaveCoordYBox.Text.Trim(), [ref]$saveCoordY)) {
        throw (U("\uc800\uc7a5 \ubc84\ud2bc Y \uc88c\ud45c\ub294 \uc22b\uc790\ub85c \uc785\ub825\ud574\uc57c \ud569\ub2c8\ub2e4."))
    }

    Update-AhkCoordinates -ScriptPath $ahkPath -ImageX $imageCoordX -ImageY $imageCoordY -SaveX $saveCoordX -SaveY $saveCoordY

    return @{
        ImageX = $imageCoordX
        ImageY = $imageCoordY
        SaveX = $saveCoordX
        SaveY = $saveCoordY
    }
}

function Find-AutoHotkeyExecutable {
    $commandCandidates = @("AutoHotkey64.exe", "AutoHotkey.exe", "AutoHotkeyUX.exe", "AutoHotkeyU64.exe")
    foreach ($candidate in $commandCandidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    $pathCandidates = @(
        "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
        "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe",
        "C:\Program Files\AutoHotkey\UX\AutoHotkeyUX.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64_UIA.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyA32.exe"
    )

    foreach ($candidate in $pathCandidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Find-AutoHotkeyV1Executable {
    $commandCandidates = @("AutoHotkeyU64.exe", "AutoHotkeyU64_UIA.exe", "AutoHotkey.exe")
    foreach ($candidate in $commandCandidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    $pathCandidates = @(
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64_UIA.exe",
        "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkey.exe",
        "C:\Program Files\AutoHotkey\AutoHotkeyU64.exe"
    )

    foreach ($candidate in $pathCandidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

if (Test-Path $ahkPath) {
    $ahkContent = Get-Content -LiteralPath $ahkPath -Raw -Encoding UTF8
    $ImageCoordXBox.Text = Get-AhkCoordinateValue -Content $ahkContent -Name "imageButtonX"
    $ImageCoordYBox.Text = Get-AhkCoordinateValue -Content $ahkContent -Name "imageButtonY"
    $SaveCoordXBox.Text = Get-AhkCoordinateValue -Content $ahkContent -Name "saveButtonX"
    $SaveCoordYBox.Text = Get-AhkCoordinateValue -Content $ahkContent -Name "saveButtonY"
}

$LoadProfileButton.Add_Click({ Load-WritingProfileFromName })
$SaveProfileButton.Add_Click({ Save-CurrentWritingProfile })
$ListProfileButton.Add_Click({ Show-WritingProfileList })

$OpenCoordToolButton.Add_Click({
    if (-not (Test-Path $coordToolPath)) {
        $coordScript = @"
#NoEnv
#SingleInstance Force
CoordMode, Mouse, Screen
SetTimer, ShowMousePosition, 50
return

ShowMousePosition:
    MouseGetPos, xpos, ypos
    ToolTip, X: %xpos%`nY: %ypos%`n`nF8: 현재 좌표 복사`nEsc: 종료
return

F8::
    MouseGetPos, xpos, ypos
    Clipboard := "imageButtonX := " . xpos . "`nimageButtonY := " . ypos
    MsgBox, 64, 좌표 복사 완료, 현재 좌표를 클립보드에 복사했습니다.`n`nX: %xpos%`nY: %ypos%
return

Esc::
    ToolTip
    ExitApp
return
"@
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($coordToolPath, $coordScript, $utf8Bom)
    }

    $ahkExe = Find-AutoHotkeyV1Executable
    if (-not $ahkExe) {
        [void][System.Windows.MessageBox]::Show((U("\uc88c\ud45c \ud655\uc778 \ub3c4\uad6c\ub294 AutoHotkey v1 \uc2e4\ud589\uae30\uac00 \ud544\uc694\ud569\ub2c8\ub2e4.")), (U("\uc88c\ud45c \ud655\uc778 \ub3c4\uad6c")))
        return
    }
    Start-Process -FilePath $ahkExe -ArgumentList "`"$coordToolPath`""
})

$SaveCoordButton.Add_Click({
    try {
        $saved = Save-CoordinateSettings
        [void][System.Windows.MessageBox]::Show(
            ((U("\uc88c\ud45c \uc800\uc7a5 \uc644\ub8cc")) + "`n`n" +
             (U("\uc0ac\uc9c4 \ubc84\ud2bc")) + ": X=$($saved.ImageX), Y=$($saved.ImageY)`n" +
             (U("\uc800\uc7a5 \ubc84\ud2bc")) + ": X=$($saved.SaveX), Y=$($saved.SaveY)"),
            (U("\uc88c\ud45c \uc124\uc815"))
        )
    }
    catch {
        [void][System.Windows.MessageBox]::Show($_.Exception.Message, (U("\uc88c\ud45c \uc124\uc815")))
    }
})

$openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
$openFileDialog.Filter = U("\uc774\ubbf8\uc9c0 \ud30c\uc77c|*.png;*.jpg;*.jpeg;*.webp;*.bmp")
$openFileDialog.Multiselect = $true

function Update-SourceModeUi {
    if ($script:DraftRadio.IsChecked) {
        $script:DraftPanel.Visibility = "Visible"
    }
    else {
        $script:DraftPanel.Visibility = "Collapsed"
    }

    if ($script:ImageRadio.IsChecked) {
        $script:ImagePanel.Visibility = "Visible"
    }
    else {
        $script:ImagePanel.Visibility = "Collapsed"
    }
}

$selectionHandler = {
    Update-SourceModeUi
}

$NoneRadio.Add_Checked($selectionHandler)
$AutopostOnlyRadio.Add_Checked($selectionHandler)
$DraftRadio.Add_Checked($selectionHandler)
$ImageRadio.Add_Checked($selectionHandler)

$SelectImageButton.Add_Click({
    if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:ImageListBox.Items.Clear()
        foreach ($file in $openFileDialog.FileNames) {
            [void]$script:ImageListBox.Items.Add($file)
        }
    }
})

$script:HistoryContinue = $false

$HistoryButton.Add_Click({
    if (-not (Test-Path -LiteralPath $historyScriptPath)) {
        [void][System.Windows.MessageBox]::Show(
            (U("\uc0dd\uc131 \uc774\ub825 \ucc3d \uc2a4\ud06c\ub9bd\ud2b8\ub97c \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")),
            (U("\uc0dd\uc131 \uc774\ub825 \ubcf4\uae30"))
        )
        return
    }

    $window.Hide()

    try {
        $historyProcess = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-STA", "-ExecutionPolicy", "Bypass", "-File", $historyScriptPath) `
            -WorkingDirectory $projectRoot `
            -Wait `
            -PassThru

        if ($historyProcess.ExitCode -eq 30) {
            $script:HistoryContinue = $true
            $window.Close()
            return
        }
    }
    finally {
        if (-not $script:HistoryContinue) {
            $window.Show()
            [void]$window.Activate()
        }
    }
})

$script:ResumeOnly = $false

$ResumeButton.Add_Click({
    $script:ResumeOnly = $true
    $window.DialogResult = $true
    $window.Close()
})

$SaveButton.Add_Click({
    try {
        $script:ResumeOnly = $false
        Start-InWindowPipeline
    }
    catch {
        $script:PipelineRunning = $false
        $script:PipelineExitCode = 41
        Report-UiException -ErrorRecord $_ -Title (U("\uc9c4\ud589 \ud654\uba74 \uc804\ud658 \uc2e4\ud328"))
    }
})

$CancelButton.Add_Click({
    if ($script:PipelineHandled) {
        if ($script:PipelineRunning -and -not (Confirm-StopInWindowPipeline)) { return }
        $window.DialogResult = $true
        $window.Close()
        return
    }
    $window.DialogResult = $false
    $window.Close()
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:PipelineRunning) {
        if (-not (Confirm-StopInWindowPipeline)) {
            $eventArgs.Cancel = $true
        }
    }
})

try {
    $existingClientSettings = Read-ClientSettings
    Apply-ClientSettings -Settings $existingClientSettings

    $clientMode = "$($existingClientSettings.client_mode)"
    if ([string]::IsNullOrWhiteSpace($clientMode)) {
        $clientMode = "$($existingClientSettings.mode)"
    }
    $token = "$($existingClientSettings.api_auth_token)"
    if ($clientMode -eq 'server' -and [string]::IsNullOrWhiteSpace($token)) {
        $startupLoginOk = Show-StartupServerLoginWindow -Settings $existingClientSettings
        if (-not $startupLoginOk) {
            Write-Host (U("\uc2dc\uc791 \ub85c\uadf8\uc778\uc774 \ucde8\uc18c\ub418\uc5b4 \ud504\ub85c\uadf8\ub7a8\uc744 \uc885\ub8cc\ud569\ub2c8\ub2e4.")) -ForegroundColor Yellow
            exit 1
        }
        $existingClientSettings = Read-ClientSettings
        Apply-ClientSettings -Settings $existingClientSettings
    }
}
catch {
}

$LocalClientModeRadio.Add_Checked({ Update-ClientModeUi })
$ServerClientModeRadio.Add_Checked({ Update-ClientModeUi })
$ServerLoginButton.Add_Click({ Invoke-ServerLogin })
$ServerStatusButton.Add_Click({ Invoke-ServerStatusRefresh })
$ServerLogoutButton.Add_Click({ Invoke-ServerLogout })
Update-ClientModeUi

if (Test-Path -LiteralPath $outputPath) {
    $loadPrevious = [System.Windows.MessageBox]::Show(
        (U("\uc774\uc804\uc5d0 \uc800\uc7a5\ud55c \uc785\ub825\uac12\uc744 \ubd88\ub7ec\uc624\uaca0\uc2b5\ub2c8\uae4c?")),
        (U("\uc774\uc804 \uc124\uc815\uac12 \ubd88\ub7ec\uc624\uae30")),
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($loadPrevious -eq [System.Windows.MessageBoxResult]::Yes) {
        try {
            $previousRequest = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Load-PreviousRequestValues -Previous $previousRequest
        }
        catch {
            [void][System.Windows.MessageBox]::Show(
                ((U("\uc774\uc804 \uc124\uc815\uac12\uc744 \ubd88\ub7ec\uc624\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")) + "`n`n" + $_.Exception.Message),
                (U("\uc774\uc804 \uc124\uc815\uac12 \ubd88\ub7ec\uc624\uae30"))
            )
        }
    }
}

Update-SourceModeUi
if (-not $script:MainWindow -and $window) { $script:MainWindow = $window }
if (-not $script:MainWindow) { throw (U("\uc785\ub825 \ucc3d\uc744 \uc0dd\uc131\ud558\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")) }
try {
    $result = $script:MainWindow.ShowDialog()
}
catch {
    Report-UiException -ErrorRecord $_ -Title (U("\uc785\ub825 \ucc3d \uc2e4\ud589 \uc624\ub958"))
    exit 1
}

if ($script:PipelineHandled) {
    exit $script:PipelineExitCode
}

if ($script:HistoryContinue) {
    Write-Host (U("\uc0dd\uc131 \uc774\ub825 \ucc3d\uc5d0\uc11c \uc120\ud0dd\ud55c \ud328\ud0a4\uc9c0\ub85c \uc774\uc5b4\uc11c \uc791\uc5c5\uc744 \uc2dc\uc791\ud588\uc2b5\ub2c8\ub2e4.")) -ForegroundColor Yellow
    exit 30
}

if (-not $result) {
    Write-Host (U("\uc785\ub825 \ucc3d\uc5d0\uc11c \ucde8\uc18c\ud588\uc2b5\ub2c8\ub2e4.")) -ForegroundColor Yellow
    exit 1
}

if ($script:ResumeOnly) {
    Write-Host (U("\uae30\uc874 \uc694\uccad\ucfc4 \uc911\uac04 \uc0b0\ucd9c\ubb3c\uc744 \uae30\uc900\uc73c\ub85c \uc774\uc5b4\uc11c \uc2e4\ud589\ud569\ub2c8\ub2e4.")) -ForegroundColor Yellow
    exit 20
}

Save-RequestPayload | Out-Null




