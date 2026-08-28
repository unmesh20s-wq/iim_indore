$ErrorActionPreference = 'Stop'

$edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$workspace = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $workspace 'qa\cdp'
$profileDirectory = Join-Path $env:TEMP '180dc-edge-cdp'
$debugPort = 9331

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$edgeArguments = @(
    '--headless=new'
    '--disable-gpu'
    '--hide-scrollbars'
    '--no-first-run'
    '--no-default-browser-check'
    "--remote-debugging-port=$debugPort"
    '--remote-allow-origins=*'
    "--user-data-dir=$profileDirectory"
    'about:blank'
)

$edgeProcess = Start-Process `
    -FilePath $edgePath `
    -ArgumentList $edgeArguments `
    -WindowStyle Hidden `
    -PassThru

$socket = $null
$script:commandId = 0

function Receive-CdpMessage {
    param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

    $buffer = New-Object byte[] 65536
    $stream = [System.IO.MemoryStream]::new()
    try {
        do {
            $segment = [System.ArraySegment[byte]]::new($buffer)
            $result = $WebSocket.ReceiveAsync(
                $segment,
                [System.Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()
            $stream.Write($buffer, 0, $result.Count)
        } while (-not $result.EndOfMessage)

        return [System.Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory = $true)][System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Parameters = @{}
    )

    $script:commandId++
    $requestId = $script:commandId
    $message = @{
        id = $requestId
        method = $Method
        params = $Parameters
    } | ConvertTo-Json -Depth 20 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $WebSocket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None
    ).GetAwaiter().GetResult() | Out-Null

    do {
        $response = Receive-CdpMessage -WebSocket $WebSocket
    } while ($response.id -ne $requestId)

    if ($response.error) {
        throw "CDP $Method failed: $($response.error.message)"
    }

    return $response
}

function Set-Viewport {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [int]$Width,
        [int]$Height,
        [bool]$Mobile
    )

    Invoke-CdpCommand -WebSocket $WebSocket -Method 'Emulation.setDeviceMetricsOverride' -Parameters @{
        width = $Width
        height = $Height
        deviceScaleFactor = 1
        mobile = $Mobile
        screenWidth = $Width
        screenHeight = $Height
    } | Out-Null

    Invoke-CdpCommand -WebSocket $WebSocket -Method 'Emulation.setEmulatedMedia' -Parameters @{
        features = @(
            @{ name = 'prefers-reduced-motion'; value = 'reduce' }
        )
    } | Out-Null
}

function Capture-Section {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Device,
        [string]$Section,
        [int]$Width,
        [int]$Height
    )

    $selector = if ($Section -eq 'home') { '#home' } else { "#$Section" }
    $expression = @"
(async () => {
  const target = document.querySelector('$selector');
  document.documentElement.style.scrollBehavior = 'auto';
  if (target) target.scrollIntoView({ block: 'start' });
  await new Promise((resolve) => setTimeout(resolve, 250));
  const offenders = [...document.querySelectorAll('body *')]
    .filter((element) => element.getBoundingClientRect().right > $Width + 1 || element.getBoundingClientRect().left < -1)
    .slice(0, 12)
    .map((element) => ({ tag: element.tagName, className: element.className, left: element.getBoundingClientRect().left, right: element.getBoundingClientRect().right }));
  return {
    section: '$Section',
    viewportWidth: document.documentElement.clientWidth,
    documentWidth: document.documentElement.scrollWidth,
    scrollY: window.scrollY,
    offenders
  };
})()
"@

    $metrics = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
        expression = $expression
        awaitPromise = $true
        returnByValue = $true
    }

    $screenshot = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Page.captureScreenshot' -Parameters @{
        format = 'png'
        fromSurface = $true
        captureBeyondViewport = $false
    }

    $destination = Join-Path $outputDirectory "$Device-$Section.png"
    [System.IO.File]::WriteAllBytes(
        $destination,
        [System.Convert]::FromBase64String($screenshot.result.data)
    )

    [PSCustomObject]@{
        Capture = "$Device-$Section"
        Viewport = "$Width x $Height"
        ScrollY = $metrics.result.result.value.scrollY
        DocumentWidth = $metrics.result.result.value.documentWidth
        OverflowCount = @($metrics.result.result.value.offenders).Count
        File = $destination
    }
}

try {
    $target = $null
    foreach ($attempt in 1..50) {
        try {
            $pages = Invoke-RestMethod "http://127.0.0.1:$debugPort/json/list"
            $target = $pages | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
            if ($target) { break }
        }
        catch {
            Start-Sleep -Milliseconds 150
        }
    }

    if (-not $target) {
        throw 'Edge debugging endpoint did not become available.'
    }

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.ConnectAsync(
        [System.Uri]$target.webSocketDebuggerUrl,
        [System.Threading.CancellationToken]::None
    ).GetAwaiter().GetResult() | Out-Null

    Invoke-CdpCommand -WebSocket $socket -Method 'Page.enable' | Out-Null
    Invoke-CdpCommand -WebSocket $socket -Method 'Runtime.enable' | Out-Null
    Invoke-CdpCommand -WebSocket $socket -Method 'Network.enable' | Out-Null
    Invoke-CdpCommand -WebSocket $socket -Method 'Network.setCacheDisabled' -Parameters @{
        cacheDisabled = $true
    } | Out-Null

    $captures = @()
    $viewports = @(
        @{ Name = 'desktop'; Width = 1440; Height = 1000; Mobile = $false },
        @{ Name = 'tablet'; Width = 1024; Height = 768; Mobile = $false },
        @{ Name = 'mobile-small'; Width = 320; Height = 568; Mobile = $true },
        @{ Name = 'mobile'; Width = 390; Height = 844; Mobile = $true }
    )

    foreach ($viewport in $viewports) {
        Set-Viewport `
            -WebSocket $socket `
            -Width $viewport.Width `
            -Height $viewport.Height `
            -Mobile $viewport.Mobile

        Invoke-CdpCommand -WebSocket $socket -Method 'Page.navigate' -Parameters @{
            url = 'http://127.0.0.1:4173/'
        } | Out-Null
        Start-Sleep -Milliseconds 700

        foreach ($section in @('home', 'services', 'approach', 'leadership', 'join', 'contact')) {
            $captures += Capture-Section `
                -WebSocket $socket `
                -Device $viewport.Name `
                -Section $section `
                -Width $viewport.Width `
                -Height $viewport.Height
        }

        if ($viewport.Name -eq 'mobile') {
            Invoke-CdpCommand -WebSocket $socket -Method 'Runtime.evaluate' -Parameters @{
                expression = "window.scrollTo(0, 0); document.querySelector('[data-menu-toggle]').click();"
            } | Out-Null
            Start-Sleep -Milliseconds 200
            $menuShot = Invoke-CdpCommand -WebSocket $socket -Method 'Page.captureScreenshot' -Parameters @{
                format = 'png'
                fromSurface = $true
                captureBeyondViewport = $false
            }
            [System.IO.File]::WriteAllBytes(
                (Join-Path $outputDirectory 'mobile-menu.png'),
                [System.Convert]::FromBase64String($menuShot.result.data)
            )
        }
    }

    $captures | Format-Table -AutoSize
}
finally {
    if ($socket) {
        $socket.Dispose()
    }
    if ($edgeProcess -and -not $edgeProcess.HasExited) {
        Stop-Process -Id $edgeProcess.Id -Force
    }
}
