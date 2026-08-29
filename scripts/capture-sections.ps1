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

function Save-CdpScreenshot {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Name
    )

    $screenshot = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Page.captureScreenshot' -Parameters @{
        format = 'png'
        fromSurface = $true
        captureBeyondViewport = $false
    }
    $destination = Join-Path $outputDirectory "$Name.png"
    [System.IO.File]::WriteAllBytes(
        $destination,
        [System.Convert]::FromBase64String($screenshot.result.data)
    )
    return $destination
}

function Test-ResourcePages {
    param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

    $checks = @()
    $resourceViewports = @(
        @{ Name = 'desktop'; Width = 1440; Height = 1000; Mobile = $false },
        @{ Name = 'mobile'; Width = 390; Height = 844; Mobile = $true }
    )

    foreach ($viewport in $resourceViewports) {
        Set-Viewport `
            -WebSocket $WebSocket `
            -Width $viewport.Width `
            -Height $viewport.Height `
            -Mobile $viewport.Mobile

        Invoke-CdpCommand -WebSocket $WebSocket -Method 'Page.navigate' -Parameters @{
            url = 'http://127.0.0.1:4173/resources.html'
        } | Out-Null
        Start-Sleep -Milliseconds 700

        $hubEvaluation = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
            expression = @"
(() => {
  const buttons = [...document.querySelectorAll('[data-resource-filters] button')];
  const initialCount = document.querySelectorAll('.resource-card').length;
  const originals = buttons.find((button) => button.textContent.trim() === '180DC Originals');
  originals.click();
  const originalsCount = document.querySelectorAll('.resource-card').length;
  buttons.find((button) => button.textContent.trim() === 'All').click();

  const input = document.querySelector('[data-resource-search]');
  input.value = 'no-resource-can-match-this-query';
  input.dispatchEvent(new Event('input', { bubbles: true }));
  const empty = document.querySelector('[data-resource-empty]');
  const emptyVisible = !empty.hidden && getComputedStyle(empty).display !== 'none';
  const emptyTitle = empty.querySelector('[data-empty-title]').textContent.trim();

  document.querySelector('[data-resource-reset]').click();
  return {
    mainText: document.querySelector('main').innerText.trim().length,
    initialCount,
    originalsCount,
    emptyVisible,
    emptyTitle,
    resetCount: document.querySelectorAll('.resource-card').length,
    internalLinks: document.querySelectorAll('.resource-card__action:not([target])').length,
    officialLinks: document.querySelectorAll('.resource-card__action[target="_blank"]').length,
    documentWidth: document.documentElement.scrollWidth,
    viewportWidth: document.documentElement.clientWidth
  };
})()
"@
            returnByValue = $true
        }
        $hub = $hubEvaluation.result.result.value

        if ($hub.mainText -lt 300) { throw "Resource hub content is missing on $($viewport.Name)." }
        if ($hub.initialCount -ne 12) { throw "Expected 12 initial resources, found $($hub.initialCount)." }
        if ($hub.originalsCount -ne 3) { throw "Expected 3 180DC Originals, found $($hub.originalsCount)." }
        if (-not $hub.emptyVisible -or $hub.emptyTitle -ne 'No matching resources.') { throw 'The curated search empty state did not appear.' }
        if ($hub.resetCount -ne 12) { throw "Resource reset returned $($hub.resetCount) cards instead of 12." }
        if ($hub.internalLinks -ne 3 -or $hub.officialLinks -ne 9) { throw 'Internal and official-source resource actions are misclassified.' }
        if ($hub.documentWidth -ne $viewport.Width -or $hub.viewportWidth -ne $viewport.Width) { throw "Resource hub overflows at $($viewport.Width)px." }

        Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
            expression = 'window.scrollTo(0, 0)'
        } | Out-Null
        $topFile = Save-CdpScreenshot -WebSocket $WebSocket -Name "resource-$($viewport.Name)-top"

        Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
            expression = "document.querySelector('[data-resource-grid]').scrollIntoView({ block: 'start' }); window.scrollBy(0, -92);"
        } | Out-Null
        Start-Sleep -Milliseconds 250
        $gridFile = Save-CdpScreenshot -WebSocket $WebSocket -Name "resource-$($viewport.Name)-grid"

        Invoke-CdpCommand -WebSocket $WebSocket -Method 'Page.navigate' -Parameters @{
            url = 'http://127.0.0.1:4173/resources/guesstimation-101.html'
        } | Out-Null
        Start-Sleep -Milliseconds 700

        $guideEvaluation = Invoke-CdpCommand -WebSocket $WebSocket -Method 'Runtime.evaluate' -Parameters @{
            expression = @"
(() => ({
  title: document.querySelector('h1')?.textContent.trim() || '',
  sections: document.querySelectorAll('.guide-content > section').length,
  mainText: document.querySelector('main').innerText.trim().length,
  documentWidth: document.documentElement.scrollWidth,
  viewportWidth: document.documentElement.clientWidth
}))()
"@
            returnByValue = $true
        }
        $guide = $guideEvaluation.result.result.value

        if ($guide.title -ne 'Guesstimation 101' -or $guide.sections -ne 4 -or $guide.mainText -lt 500) { throw 'The original guide content is incomplete.' }
        if ($guide.documentWidth -ne $viewport.Width -or $guide.viewportWidth -ne $viewport.Width) { throw "Guide page overflows at $($viewport.Width)px." }
        $guideFile = Save-CdpScreenshot -WebSocket $WebSocket -Name "guide-$($viewport.Name)-top"

        $checks += [PSCustomObject]@{
            Viewport = $viewport.Name
            HubWidth = $hub.documentWidth
            InitialCards = $hub.initialCount
            OriginalCards = $hub.originalsCount
            EmptyState = $hub.emptyVisible
            ResetCards = $hub.resetCount
            GuideWidth = $guide.documentWidth
            TopCapture = $topFile
            GridCapture = $gridFile
            GuideCapture = $guideFile
        }
    }

    return $checks
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

        foreach ($section in @('home', 'services', 'learning', 'approach', 'leadership', 'join', 'contact')) {
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
    $resourceChecks = Test-ResourcePages -WebSocket $socket
    $captures | Format-Table -AutoSize
    $carouselChecks | Format-Table -AutoSize
    $autoplayCheck | Format-List
    $resourceChecks | Format-Table -AutoSize
}
finally {
    if ($socket) {
        $socket.Dispose()
    }
    if ($edgeProcess -and -not $edgeProcess.HasExited) {
        Stop-Process -Id $edgeProcess.Id -Force
    }
}
