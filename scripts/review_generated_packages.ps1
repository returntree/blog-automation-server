$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$projectRoot = Split-Path -Parent $PSScriptRoot
$jobsRoot = Join-Path $projectRoot "jobs"
$continueScriptPath = Join-Path $projectRoot "scripts\continue_from_package.ps1"
$continueRequestPath = Join-Path $projectRoot "inputs\continue_from_history.json"
$script:StartedContinue = $false

function U([string]$value) {
    return [System.Text.RegularExpressions.Regex]::Unescape($value)
}

function Set-WindowSafePosition($window, [int]$margin = 20) {
    $window.WindowStartupLocation = "Manual"
    $window.Add_ContentRendered({
        param($sender, $args)
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $targetWidth = [Math]::Min([double]$sender.Width, [double]$workArea.Width - ($margin * 2))
        $targetHeight = [Math]::Min([double]$sender.Height, [double]$workArea.Height - ($margin * 2))

        if ($targetWidth -lt 760) { $targetWidth = [Math]::Max(760, [double]$workArea.Width - ($margin * 2)) }
        if ($targetHeight -lt 520) { $targetHeight = [Math]::Max(520, [double]$workArea.Height - ($margin * 2)) }

        $sender.Width = $targetWidth
        $sender.Height = $targetHeight
        $sender.Left = [Math]::Max($workArea.Left + $margin, $workArea.Left + (($workArea.Width - $sender.Width) / 2))
        $sender.Top = [Math]::Max($workArea.Top + $margin, $workArea.Top + (($workArea.Height - $sender.Height) / 2))
    })
}

function Get-PackageTimestampText([System.IO.DirectoryInfo]$Directory) {
    if ($Directory.Name -match '^upload_package_(\d{8})_(\d{6})$') {
        $dateText = $matches[1]
        $timeText = $matches[2]
        return "{0}-{1}-{2} {3}:{4}:{5}" -f `
            $dateText.Substring(0, 4), `
            $dateText.Substring(4, 2), `
            $dateText.Substring(6, 2), `
            $timeText.Substring(0, 2), `
            $timeText.Substring(2, 2), `
            $timeText.Substring(4, 2)
    }

    return $Directory.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
}

function Get-PackageTitle([System.IO.DirectoryInfo]$Directory) {
    $titlePath = Join-Path $Directory.FullName "title.txt"
    if (-not (Test-Path -LiteralPath $titlePath)) {
        return (U("\uc81c\ubaa9 \ud30c\uc77c \uc5c6\uc74c"))
    }

    try {
        $title = [System.IO.File]::ReadAllText($titlePath, [System.Text.UTF8Encoding]::new($true)).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            return (U("\uc81c\ubaa9 \uc5c6\uc74c"))
        }
        return $title
    }
    catch {
        return (U("\uc81c\ubaa9 \uc77d\uae30 \uc2e4\ud328"))
    }
}

function Read-Utf8TextFile([string]$Path, [string]$FallbackText) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $FallbackText
    }

    try {
        $encoding = [System.Text.UTF8Encoding]::new($true)
        $content = [System.IO.File]::ReadAllText($Path, $encoding).Trim()
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $FallbackText
        }
        return $content
    }
    catch {
        return $FallbackText
    }
}

$xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1180"
        Height="760"
        MinWidth="980"
        MinHeight="620"
        FontFamily="Malgun Gothic"
        Background="#F4F7FB">
    <Window.Resources>
        <SolidColorBrush x:Key="PanelBrush" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#D8E0EA"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#0F766E"/>
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
        <Border DockPanel.Dock="Top" Background="#102A43" Padding="22,16">
            <StackPanel>
                <TextBlock x:Name="HeaderTitle" FontSize="28" FontWeight="Bold" Foreground="White"/>
                <TextBlock x:Name="HeaderSubtitle" Margin="0,8,0,0" FontSize="14" Foreground="#D9E2EC" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>

        <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#D8E0EA" BorderThickness="1,1,0,0" Padding="18,14">
            <DockPanel LastChildFill="False">
                <TextBlock x:Name="BottomText" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="#52606D" FontSize="13"/>
                <Button x:Name="ContinueButton" DockPanel.Dock="Right" Width="150" Style="{StaticResource PrimaryButton}"/>
                <Button x:Name="RefreshButton" DockPanel.Dock="Right" Width="120"/>
                <Button x:Name="CloseButton" DockPanel.Dock="Right" Width="120" Style="{StaticResource PrimaryButton}"/>
            </DockPanel>
        </Border>

        <Grid Margin="18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="0.95*"/>
                <ColumnDefinition Width="1.45*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="18" Padding="18" Margin="0,0,10,0">
                <DockPanel LastChildFill="True">
                    <TextBlock x:Name="ListGuideText" DockPanel.Dock="Top" Margin="0,0,0,12" Foreground="#52606D" FontSize="13" TextWrapping="Wrap"/>
                    <ListView x:Name="PackageListView" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1">
                        <ListView.View>
                            <GridView>
                                <GridViewColumn Width="155" DisplayMemberBinding="{Binding CreatedAt}">
                                    <GridViewColumn.Header>
                                        <TextBlock x:Name="CreatedHeader"/>
                                    </GridViewColumn.Header>
                                </GridViewColumn>
                                <GridViewColumn Width="290" DisplayMemberBinding="{Binding Title}">
                                    <GridViewColumn.Header>
                                        <TextBlock x:Name="TitleHeader"/>
                                    </GridViewColumn.Header>
                                </GridViewColumn>
                            </GridView>
                        </ListView.View>
                    </ListView>
                </DockPanel>
            </Border>

            <Border Grid.Column="1" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="18" Padding="18" Margin="10,0,0,0">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <TextBlock x:Name="DetailGuideText" Grid.Row="0" Foreground="#52606D" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,12"/>

                        <StackPanel Grid.Row="1">
                            <TextBlock x:Name="DetailTitleLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                            <TextBox x:Name="DetailTitleBox" Margin="0,6,0,12" FontSize="14" Padding="10,8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Background="#FFFFFF" MinHeight="64"/>

                            <TextBlock x:Name="DetailTagsLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                            <TextBox x:Name="DetailTagsBox" Margin="0,6,0,12" FontSize="13" Padding="10,8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Background="#FFFFFF" MinHeight="74"/>

                            <TextBlock x:Name="DetailPathLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                            <TextBox x:Name="DetailPathBox" Margin="0,6,0,12" FontSize="12" Padding="10,8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Background="#FFFFFF" MinHeight="60"/>
                        </StackPanel>

                        <StackPanel Grid.Row="2" Margin="0,4,0,8">
                            <TextBlock x:Name="DetailPostLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53"/>
                        </StackPanel>

                        <Grid Grid.Row="3" Margin="0,0,0,14">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="0.48*"/>
                                <ColumnDefinition Width="1.52*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0" Margin="0,0,12,0">
                                <TextBlock x:Name="DetailImageListLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53" Margin="0,0,0,8"/>
                                <ListBox x:Name="ImageListBox" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Height="340"/>
                            </StackPanel>

                            <StackPanel Grid.Column="1">
                                <TextBlock x:Name="DetailImagePreviewLabel" FontSize="14" FontWeight="SemiBold" Foreground="#243B53" Margin="0,0,0,8"/>
                                <Border BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="12" Background="#F8FAFC" Padding="12" Height="340">
                                    <Grid>
                                        <Image x:Name="PreviewImage" Stretch="Uniform"/>
                                        <TextBlock x:Name="PreviewEmptyText" Foreground="#7B8794" FontSize="13" TextWrapping="Wrap" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Grid>
                                </Border>
                            </StackPanel>
                        </Grid>

                        <TextBox x:Name="DetailPostBox" Grid.Row="4" FontSize="14" Padding="10,10" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" Background="#FFFFFF" MinHeight="380"/>
                    </Grid>
                </ScrollViewer>
            </Border>
        </Grid>
    </DockPanel>
</Window>
"@

[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
Set-WindowSafePosition $window

$window.Title = U("\uc0dd\uc131 \uc774\ub825 \ubcf4\uae30")
$HeaderTitle = $window.FindName("HeaderTitle")
$HeaderSubtitle = $window.FindName("HeaderSubtitle")
$BottomText = $window.FindName("BottomText")
$ContinueButton = $window.FindName("ContinueButton")
$RefreshButton = $window.FindName("RefreshButton")
$CloseButton = $window.FindName("CloseButton")
$ListGuideText = $window.FindName("ListGuideText")
$PackageListView = $window.FindName("PackageListView")
$CreatedHeader = $window.FindName("CreatedHeader")
$TitleHeader = $window.FindName("TitleHeader")
$DetailGuideText = $window.FindName("DetailGuideText")
$DetailTitleLabel = $window.FindName("DetailTitleLabel")
$DetailTitleBox = $window.FindName("DetailTitleBox")
$DetailTagsLabel = $window.FindName("DetailTagsLabel")
$DetailTagsBox = $window.FindName("DetailTagsBox")
$DetailPathLabel = $window.FindName("DetailPathLabel")
$DetailPathBox = $window.FindName("DetailPathBox")
$DetailImageListLabel = $window.FindName("DetailImageListLabel")
$DetailImagePreviewLabel = $window.FindName("DetailImagePreviewLabel")
$ImageListBox = $window.FindName("ImageListBox")
$PreviewImage = $window.FindName("PreviewImage")
$PreviewEmptyText = $window.FindName("PreviewEmptyText")
$DetailPostLabel = $window.FindName("DetailPostLabel")
$DetailPostBox = $window.FindName("DetailPostBox")

$HeaderTitle.Text = U("\uc0dd\uc131 \uc774\ub825 \ubcf4\uae30")
$HeaderSubtitle.Text = U("\uc9c0\uae08\uae4c\uc9c0 \ub9cc\ub4e0 \uc5c5\ub85c\ub4dc \ud328\ud0a4\uc9c0\ub97c \uc81c\ubaa9\uacfc \ud568\uaed8 \ud655\uc778\ud569\ub2c8\ub2e4.")
$BottomText.Text = U("\uc120\ud0dd\ud55c \ud328\ud0a4\uc9c0\ub97c \ubcf4\uac70\ub098, \uc774\uc5b4\uc11c \uc791\uc5c5 \ud750\ub984\uc73c\ub85c \ub118\uae38 \uc218 \uc788\uc2b5\ub2c8\ub2e4.")
$ContinueButton.Content = U("\uc774\uc5b4\uc11c \uc791\uc5c5")
$RefreshButton.Content = U("\uc0c8\ub85c\uace0\uce68")
$CloseButton.Content = U("\ub2eb\uae30")
$ListGuideText.Text = U("jobs \ud3f4\ub354\uc758 upload_package_* \ud328\ud0a4\uc9c0\ub97c \ucd5c\uc2e0 \uc21c\uc11c\ub85c \ubd88\ub7ec\uc635\ub2c8\ub2e4. \ubaa9\ub85d\uc5d0\uc11c \ud56d\ubaa9\uc744 \ub204\ub974\uba74 \uc624\ub978\ucabd\uc5d0 \uc6d0\uace0 \ubbf8\ub9ac\ubcf4\uae30\uac00 \ud45c\uc2dc\ub429\ub2c8\ub2e4.")
$CreatedHeader.Text = U("\uc0dd\uc131\uc77c\uc2dc")
$TitleHeader.Text = U("\uc81c\ubaa9")
$DetailGuideText.Text = U("\ud328\ud0a4\uc9c0\ub97c \uc120\ud0dd\ud558\uba74 \uc81c\ubaa9, \ud0dc\uadf8, \ud3f4\ub354 \uacbd\ub85c, \uc774\ubbf8\uc9c0, \ubcf8\ubb38 \ubbf8\ub9ac\ubcf4\uae30\uac00 \ud45c\uc2dc\ub429\ub2c8\ub2e4.")
$DetailTitleLabel.Text = U("\uc81c\ubaa9")
$DetailTagsLabel.Text = U("\ud0dc\uadf8")
$DetailPathLabel.Text = U("\ud328\ud0a4\uc9c0 \uacbd\ub85c")
$DetailImageListLabel.Text = U("\uc774\ubbf8\uc9c0 \ubaa9\ub85d")
$DetailImagePreviewLabel.Text = U("\uc774\ubbf8\uc9c0 \ubbf8\ub9ac\ubcf4\uae30")
$DetailPostLabel.Text = U("\ubcf8\ubb38 \ubbf8\ub9ac\ubcf4\uae30")

function Clear-ImagePreview {
    $ImageListBox.Items.Clear()
    $PreviewImage.Source = $null
    $PreviewEmptyText.Text = (U("\uc774\ubbf8\uc9c0\ub294 \ud328\ud0a4\uc9c0 \uc120\ud0dd \ud6c4 \uc5ec\uae30\uc5d0 \ud45c\uc2dc\ub429\ub2c8\ub2e4."))
}

function Show-ImagePreview {
    param($Item)

    if ($null -eq $Item) {
        $PreviewImage.Source = $null
        $PreviewEmptyText.Text = (U("\uc774\ubbf8\uc9c0\ub97c \uc120\ud0dd\ud558\uba74 \ud070 \ubbf8\ub9ac\ubcf4\uae30\uac00 \uc5ec\uae30\uc5d0 \ud45c\uc2dc\ub429\ub2c8\ub2e4."))
        return
    }

    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = [System.Uri]::new([string]$Item.ImagePath)
        $bitmap.EndInit()
        $bitmap.Freeze()
        $PreviewImage.Source = $bitmap
        $PreviewEmptyText.Text = ""
    }
    catch {
        $PreviewImage.Source = $null
        $PreviewEmptyText.Text = (U("\uc774\ubbf8\uc9c0 \ubbf8\ub9ac\ubcf4\uae30 \ub85c\ub4dc\uc5d0 \uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4."))
    }
}

function Load-PackageImages {
    param([string]$FolderPath)

    Clear-ImagePreview

    $imagesPath = Join-Path $FolderPath "images"
    if (-not (Test-Path -LiteralPath $imagesPath)) {
        $PreviewEmptyText.Text = (U("\uc774 \ud328\ud0a4\uc9c0\uc5d0\ub294 images \ud3f4\ub354\uac00 \uc5c6\uc2b5\ub2c8\ub2e4."))
        return
    }

    $imageFiles = Get-ChildItem -LiteralPath $imagesPath -File |
        Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|webp|bmp)$' } |
        Sort-Object Name

    if ($imageFiles.Count -eq 0) {
        $PreviewEmptyText.Text = (U("\ud655\uc778\ud560 \uc774\ubbf8\uc9c0 \ud30c\uc77c\uc774 \uc5c6\uc2b5\ub2c8\ub2e4."))
        return
    }

    foreach ($file in $imageFiles) {
        $item = [PSCustomObject]@{
            ImageName = $file.Name
            ImagePath = $file.FullName
        }
        [void]$ImageListBox.Items.Add($item)
    }

    $ImageListBox.DisplayMemberPath = "ImageName"
    $ImageListBox.SelectedIndex = 0
}

function Clear-PackageDetail {
    $DetailTitleBox.Text = (U("\uc67c\ucabd \ubaa9\ub85d\uc5d0\uc11c \ud655\uc778\ud560 \ud328\ud0a4\uc9c0\ub97c \uc120\ud0dd\ud574 \uc8fc\uc138\uc694."))
    $DetailTagsBox.Text = (U("\ud0dc\uadf8 \uc815\ubcf4\uac00 \uc5ec\uae30\uc5d0 \ud45c\uc2dc\ub429\ub2c8\ub2e4."))
    $DetailPathBox.Text = (U("\ud328\ud0a4\uc9c0 \uacbd\ub85c\uac00 \uc5ec\uae30\uc5d0 \ud45c\uc2dc\ub429\ub2c8\ub2e4."))
    $DetailPostBox.Text = (U("\ubcf8\ubb38 \ubbf8\ub9ac\ubcf4\uae30\ub294 \ud56d\ubaa9 \uc120\ud0dd \ud6c4 \uc5ec\uae30\uc5d0 \ub098\uc635\ub2c8\ub2e4."))
    Clear-ImagePreview
}

function Show-PackageDetail {
    param($Item)

    if ($null -eq $Item) {
        Clear-PackageDetail
        return
    }

    $folderPath = [string]$Item.FolderPath
    $titlePath = Join-Path $folderPath "title.txt"
    $tagsPath = Join-Path $folderPath "tags.txt"
    $postPath = Join-Path $folderPath "post.md"

    $DetailTitleBox.Text = Read-Utf8TextFile -Path $titlePath -FallbackText (U("\uc81c\ubaa9 \uc815\ubcf4 \uc5c6\uc74c"))
    $DetailTagsBox.Text = Read-Utf8TextFile -Path $tagsPath -FallbackText (U("\ud0dc\uadf8 \uc815\ubcf4 \uc5c6\uc74c"))
    $DetailPathBox.Text = $folderPath
    $DetailPostBox.Text = Read-Utf8TextFile -Path $postPath -FallbackText (U("\ubcf8\ubb38 \ud30c\uc77c \uc5c6\uc74c"))
    Load-PackageImages -FolderPath $folderPath
}

function Load-PackageList {
    $PackageListView.Items.Clear()

    if (-not (Test-Path -LiteralPath $jobsRoot)) {
        return
    }

    $directories = Get-ChildItem -LiteralPath $jobsRoot -Directory |
        Where-Object { $_.Name -like "upload_package_*" } |
        Sort-Object LastWriteTime -Descending

    foreach ($directory in $directories) {
        $item = [PSCustomObject]@{
            CreatedAt = Get-PackageTimestampText -Directory $directory
            Title = Get-PackageTitle -Directory $directory
            FolderName = $directory.Name
            FolderPath = $directory.FullName
        }
        [void]$PackageListView.Items.Add($item)
    }

    if ($PackageListView.Items.Count -gt 0) {
        $PackageListView.SelectedIndex = 0
    }
    else {
        Clear-PackageDetail
    }
}

$RefreshButton.Add_Click({
    Load-PackageList
})

$ContinueButton.Add_Click({
    $selectedItem = $PackageListView.SelectedItem
    if ($null -eq $selectedItem) {
        [void][System.Windows.MessageBox]::Show(
            (U("\uba3c\uc800 \uc774\uc5b4\uc11c \uc791\uc5c5\ud560 \ud328\ud0a4\uc9c0\ub97c \uc120\ud0dd\ud574 \uc8fc\uc138\uc694.")),
            (U("\uc774\uc5b4\uc11c \uc791\uc5c5"))
        )
        return
    }

    if (-not (Test-Path -LiteralPath $continueScriptPath)) {
        [void][System.Windows.MessageBox]::Show(
            (U("\uc774\uc5b4\uc11c \uc791\uc5c5 \uc2a4\ud06c\ub9bd\ud2b8\ub97c \ucc3e\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4.")),
            (U("\uc774\uc5b4\uc11c \uc791\uc5c5"))
        )
        return
    }

    $continuePayload = [ordered]@{
        package_dir = [string]$selectedItem.FolderPath
        requested_at = (Get-Date).ToString("s")
    } | ConvertTo-Json -Depth 3

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($continueRequestPath, $continuePayload, $utf8Bom)

    $script:StartedContinue = $true
    $window.Close()
})

$CloseButton.Add_Click({
    $window.Close()
})

Clear-PackageDetail
$ImageListBox.Add_SelectionChanged({
    Show-ImagePreview -Item $ImageListBox.SelectedItem
})
$PackageListView.Add_SelectionChanged({
    Show-PackageDetail -Item $PackageListView.SelectedItem
})

Load-PackageList
[void]$window.ShowDialog()

if ($script:StartedContinue) {
    exit 30
}
