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

function Inspect-CarouselState {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Device,
        [int]$Width
    )

    $expression = @"
(() => {
  const carousel = document.querySelector('[data-carousel]');
  const slides = [...carousel.querySelectorAll('[data-carousel-slide]')];
  const activeSlides = slides.filter((slide) => slide.classList.contains('is-active'));
  const visuallyVisibleSlides = slides.filter((slide) => {
    const styles = getComputedStyle(slide);
    return styles.visibility !== 'hidden' && Number(styles.opacity) > 0.01;
  });
  const activeSlide = activeSlides[0];
  const image = activeSlide?.querySelector('img');
  return {
    activeCount: activeSlides.length,
    visibleCount: visuallyVisibleSlides.length,
    activeName: activeSlide?.dataset.leaderName || '',
    imageReady: Boolean(image?.complete && image?.naturalWidth),
    documentWidth: document.documentElement.scrollWidth,
    buttonCount: carousel.querySelectorAll('button').length,
    numberLabelCount: carousel.querySelectorAll('.leader-slide__number, [data-carousel-status], [data-carousel-index]').length
  };
})()
"@

    $evaluation = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
        expression = $expression
        returnByValue = $true
    }
    $value = $evaluation.result.result.value

    [PSCustomObject]@{
        Device = $Device
        ActiveName = $value.activeName
        ActiveSlides = $value.activeCount
        VisibleSlides = $value.visibleCount
        ImageReady = $value.imageReady
        NoOverflow = $value.documentWidth -eq $Width
        NoButtons = $value.buttonCount -eq 0
        NoNumberLabels = $value.numberLabelCount -eq 0
    }
}

function Test-CarouselAutoplay {
    param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

    Invoke-CdpCommand -WebSocket $WebSocket -Method 'Emulation.setDeviceMetricsOverride' -Parameters @{
        width = 1440
        height = 1000
        deviceScaleFactor = 1
        mobile = $false
        screenWidth = 1440
        screenHeight = 1000
    } | Out-Null
    Invoke-CdpCommand -WebSocket $WebSocket -Method 'Emulation.setEmulatedMedia' -Parameters @{
        features = @(
            @{ name = 'prefers-reduced-motion'; value = 'no-preference' }
        )
    } | Out-Null
    Invoke-CdpCommand -WebSocket $WebSocket -Method 'Page.navigate' -Parameters @{
        url = 'http://127.0.0.1:4173/'
    } | Out-Null
    Start-Sleep -Milliseconds 700

    $initial = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
        expression = @"
(async () => {
  const carousel = document.querySelector('[data-carousel]');
  carousel.scrollIntoView({ block: 'center' });
  await new Promise((resolve) => setTimeout(resolve, 400));
  carousel.dispatchEvent(new MouseEvent('mouseenter'));
  const activeSlide = carousel.querySelector('[data-carousel-slide].is-active');
  return {
    name: activeSlide.dataset.leaderName,
    buttons: carousel.querySelectorAll('button').length,
    transitionDuration: getComputedStyle(activeSlide).transitionDuration
  };
})()
"@
        awaitPromise = $true
        returnByValue = $true
    }

    Start-Sleep -Milliseconds 6000
    $afterAdvance = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
        expression = @"
(() => {
  const carousel = document.querySelector('[data-carousel]');
  const slides = [...carousel.querySelectorAll('[data-carousel-slide]')];
  const activeSlides = slides.filter((slide) => slide.classList.contains('is-active'));
  return {
    name: activeSlides[0]?.dataset.leaderName || '',
    activeSlides: activeSlides.length,
    visibleSlides: slides.filter((slide) => {
      const styles = getComputedStyle(slide);
      return styles.visibility !== 'hidden' && Number(styles.opacity) > 0.01;
    }).length,
    inactiveSlidesAreInert: slides
      .filter((slide) => !slide.classList.contains('is-active'))
      .every((slide) => slide.inert && slide.getAttribute('aria-hidden') === 'true')
  };
})()
"@
        returnByValue = $true
    }

    [PSCustomObject]@{
        InitialPresidents = $initial.result.result.value.name -eq 'Atharv Verma and Jagannath Athmaraman'
        ControlFree = $initial.result.result.value.buttons -eq 0
        SmoothTransition = $initial.result.result.value.transitionDuration -match '0.9s'
        RotatesWhileHovered = $afterAdvance.result.result.value.name -eq 'Shrenik Vaidya'
        AdvancedToShrenik = $afterAdvance.result.result.value.name -eq 'Shrenik Vaidya'
        SingleActiveSlide = $afterAdvance.result.result.value.activeSlides -eq 1
        SingleVisibleSlide = $afterAdvance.result.result.value.visibleSlides -eq 1
        InactiveSlidesAreInert = $afterAdvance.result.result.value.inactiveSlidesAreInert
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
    $carouselChecks = @()
    $viewports = @(
        @{ Name = 'desktop'; Width = 1440; Height = 1000; Mobile = $false },
        @{ Name = 'tablet'; Width = 1024; Height = 768; Mobile = $false },
        @{ Name = 'tablet-edge'; Width = 821; Height = 900; Mobile = $false },
        @{ Name = 'mobile-narrow'; Width = 300; Height = 653; Mobile = $true },
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

        $carouselChecks += Inspect-CarouselState `
            -WebSocket $socket `
            -Device $viewport.Name `
            -Width $viewport.Width

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

    $autoplayCheck = Test-CarouselAutoplay -WebSocket $socket
    $captures | Format-Table -AutoSize
    $carouselChecks | Format-Table -AutoSize
    $autoplayCheck | Format-List
}
finally {
    if ($socket) {
        $socket.Dispose()
    }
    if ($edgeProcess -and -not $edgeProcess.HasExited) {
        Stop-Process -Id $edgeProcess.Id -Force
    }
}
