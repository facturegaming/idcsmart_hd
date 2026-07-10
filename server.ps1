param(
    [int]$Port = 17808,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebRoot = Join-Path $ScriptRoot 'web'
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
} catch {}

function New-ResponseBytes {
    param([string]$Text)
    return [System.Text.Encoding]::UTF8.GetBytes($Text)
}

function Send-Text {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Body
    )

    $bytes = New-ResponseBytes $Body
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Json {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [object]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 30 -Compress
    Send-Text -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $json
}

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.js' { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        default { 'text/plain; charset=utf-8' }
    }
}

function Normalize-Target {
    param([string]$RawTarget)

    $value = ($RawTarget | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Please enter target site.'
    }

    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = 'https://' + $value
    }

    try {
        $uri = [System.Uri]$value
    } catch {
        throw 'Invalid target site format.'
    }

    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        throw 'Only http and https are supported.'
    }

    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'Target site host is missing.'
    }

    $origin = ('{0}://{1}' -f $uri.Scheme, $uri.Authority).TrimEnd('/')
    return [ordered]@{
        input = $RawTarget
        origin = $origin
        host = $uri.Host
        scheme = $uri.Scheme
    }
}

function Invoke-TextRequest {
    param(
        [string]$Url,
        [int]$TimeoutSec = 12
    )

    $timeoutMs = [Math]::Max(1, $TimeoutSec) * 1000
    $request = [System.Net.WebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Timeout = $timeoutMs

    if ($request -is [System.Net.HttpWebRequest]) {
        $request.ReadWriteTimeout = $timeoutMs
        $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) idcsmart-hd/1.0'
        $request.Accept = 'text/html,application/json;q=0.9,*/*;q=0.8'
        $request.AllowAutoRedirect = $true
        try {
            $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        } catch {}
    }

    $response = $null
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        if ($null -eq $_.Exception.Response) { throw }
        $response = $_.Exception.Response
    }

    try {
        $stream = $response.GetResponseStream()
        $encoding = [System.Text.Encoding]::UTF8
        if ($response -is [System.Net.HttpWebResponse] -and -not [string]::IsNullOrWhiteSpace($response.CharacterSet)) {
            try { $encoding = [System.Text.Encoding]::GetEncoding($response.CharacterSet) } catch {}
        }
        $reader = New-Object System.IO.StreamReader($stream, $encoding, $true)
        try {
            $body = $reader.ReadToEnd()
        } finally {
            $reader.Close()
        }

        $statusCode = 200
        $finalUrl = $Url
        if ($response -is [System.Net.HttpWebResponse]) {
            $statusCode = [int]$response.StatusCode
            if ($null -ne $response.ResponseUri) {
                $finalUrl = $response.ResponseUri.AbsoluteUri
            }
        }

        return [ordered]@{
            url = $Url
            finalUrl = $finalUrl
            statusCode = $statusCode
            body = [string]$body
        }
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
}

function Get-PropertyValue {
    param(
        [object]$Node,
        [string]$Name
    )

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Name)) { return $Node[$Name] }
        return $null
    }

    $property = $Node.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Read-Ids {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $items = $Text -split '[,，\s\r\n]+' | Where-Object { $_ -match '^\d{1,10}$' }
    return @($items | Select-Object -Unique)
}

function Find-CandidateIds {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) { return @() }

    $patterns = @(
        'pids(?:%5B|\[)\d*(?:%5D|\])\s*=\s*(\d{1,10})',
        '(?:pid|product_id|productId|goods_id|goodsId)\s*["'']?\s*[:=]\s*["'']?(\d{1,10})',
        'data-(?:pid|product-id|product_id|goods-id|goods_id)\s*=\s*["''](\d{1,10})["'']',
        'href\s*=\s*["''][^"'']*(?:pid|product_id|goods_id)=(\d{1,10})',
        '(?:/product/|/goods/|/cart/product/)(\d{1,10})(?:[/?#"'']|$)'
    )

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $patterns) {
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            if ($match.Groups.Count -gt 1) {
                $ids.Add($match.Groups[1].Value)
            }
        }
    }

    return @($ids | Select-Object -Unique)
}

function Resolve-CartPageUrl {
    param(
        [string]$Origin,
        [string]$Href
    )

    if ([string]::IsNullOrWhiteSpace($Href)) { return $null }

    $value = $Href.Trim()
    try { $value = [System.Net.WebUtility]::HtmlDecode($value).Trim() } catch {}

    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    if ($value.StartsWith('#')) { return $null }
    if ($value -match '^(javascript|mailto|tel):') { return $null }

    try {
        $originUri = [System.Uri]$Origin
    } catch {
        return $null
    }

    if ($value -match '^//') {
        $value = $originUri.Scheme + ':' + $value
    } elseif ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        if ($value.StartsWith('/')) {
            $value = $Origin.TrimEnd('/') + $value
        } else {
            $value = $Origin.TrimEnd('/') + '/' + $value.TrimStart([char[]]@('.', '/'))
        }
    }

    try {
        $uri = [System.Uri]$value
    } catch {
        return $null
    }

    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $null }
    if ($uri.Host -ne $originUri.Host) { return $null }

    $path = $uri.AbsolutePath.TrimEnd('/')
    if ($path -ne '/cart') { return $null }

    if ([string]::IsNullOrWhiteSpace($uri.Query)) {
        return $Origin.TrimEnd('/') + '/cart'
    }

    return $Origin.TrimEnd('/') + '/cart' + $uri.Query
}

function Find-CartPageUrls {
    param(
        [string]$Origin,
        [string]$Html
    )

    if ([string]::IsNullOrWhiteSpace($Html)) { return @() }

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, 'href\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if ($match.Groups.Count -le 1) { continue }
        $url = Resolve-CartPageUrl -Origin $Origin -Href $match.Groups[1].Value
        if ($null -eq $url) { continue }

        try {
            $uri = [System.Uri]$url
            if ($uri.Query -match '(^|[?&])(fid|gid)=') {
                $urls.Add($url)
            }
        } catch {}
    }

    return @($urls | Select-Object -Unique)
}

function Discover-CartMap {
    param([string]$Origin)

    $paths = @('/cart', '/cart/')
    $scanned = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $seenIds = @{}
    $seenPages = @{}
    $ids = New-Object System.Collections.Generic.List[string]
    $cartPages = New-Object System.Collections.Generic.List[string]
    $source = $null

    foreach ($path in $paths) {
        $url = Resolve-CartPageUrl -Origin $Origin -Href $path
        if ($null -eq $url) { continue }

        try {
            $response = Invoke-TextRequest -Url $url -TimeoutSec 6
            $pageIds = @(Find-CandidateIds -Html $response.body)
            $pageLinks = @(Find-CartPageUrls -Origin $Origin -Html $response.body)

            if ($null -eq $source) { $source = $url }

            foreach ($id in $pageIds) {
                if (-not $seenIds.ContainsKey($id)) {
                    $ids.Add($id)
                    $seenIds[$id] = $true
                }
            }

            foreach ($link in @($url) + $pageLinks) {
                if (-not $seenPages.ContainsKey($link)) {
                    $cartPages.Add($link)
                    $seenPages[$link] = $true
                }
            }

            $scanned.Add([ordered]@{
                url = $url
                statusCode = $response.statusCode
                candidateCount = $pageIds.Count
                discoveredCartPageCount = $pageLinks.Count
            })
        } catch {
            $errors.Add([ordered]@{
                url = $url
                message = $_.Exception.Message
            })
        }
    }

    return [ordered]@{
        ids = $ids.ToArray()
        source = $source
        cartPages = $cartPages.ToArray()
        cartPageCount = $cartPages.Count
        scanned = $scanned.ToArray()
        errors = $errors.ToArray()
    }
}

function Discover-ProductIds {
    param(
        [string]$Origin,
        [int]$MaxPages = 200
    )

    $cartMap = Discover-CartMap -Origin $Origin
    $seenIds = @{}
    $allIds = New-Object System.Collections.Generic.List[string]
    $scanned = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($id in @($cartMap.ids)) {
        if (-not $seenIds.ContainsKey($id)) {
            $allIds.Add($id)
            $seenIds[$id] = $true
        }
    }

    $pages = @($cartMap.cartPages | Select-Object -First $MaxPages)
    foreach ($url in $pages) {
        try {
            $response = Invoke-TextRequest -Url $url -TimeoutSec 6
            $ids = @(Find-CandidateIds -Html $response.body)
            $newIdCount = 0

            foreach ($id in $ids) {
                if (-not $seenIds.ContainsKey($id)) {
                    $allIds.Add($id)
                    $seenIds[$id] = $true
                    $newIdCount += 1
                }
            }

            $scanned.Add([ordered]@{
                url = $url
                statusCode = $response.statusCode
                candidateCount = $ids.Count
                newProductCount = $newIdCount
            })
        } catch {
            $errors.Add([ordered]@{
                url = $url
                message = $_.Exception.Message
            })
        }
    }

    return [ordered]@{
        ids = $allIds.ToArray()
        source = $cartMap.source
        cartPages = $cartMap.cartPages
        cartPageCount = $cartMap.cartPageCount
        scanned = $scanned.ToArray()
        errors = (@($cartMap.errors) + @($errors)).ToArray()
        pagesScanned = $scanned.Count
        pagesQueued = $cartMap.cartPageCount
        limited = ($cartMap.cartPageCount -gt $MaxPages)
    }
}

function Read-CartPageProductIds {
    param(
        [string]$Origin,
        [string]$Page
    )

    $url = Resolve-CartPageUrl -Origin $Origin -Href $Page
    if ($null -eq $url) {
        throw 'Invalid cart category page.'
    }

    $response = Invoke-TextRequest -Url $url -TimeoutSec 6
    $ids = @(Find-CandidateIds -Html $response.body)

    return [ordered]@{
        url = $url
        statusCode = $response.statusCode
        ids = $ids
        total = $ids.Count
    }
}

function Build-ProdetailUrl {
    param(
        [string]$Origin,
        [string[]]$Ids
    )

    $query = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Ids.Count; $i++) {
        $query.Add(('pids%5B{0}%5D={1}' -f $i, [System.Uri]::EscapeDataString($Ids[$i])))
    }

    return $Origin + '/api/product/prodetail?' + ($query -join '&')
}

function Find-NodeByProductId {
    param(
        [object]$Node,
        [string]$ProductId,
        [int]$Depth = 0
    )

    if ($null -eq $Node -or $Depth -gt 10) { return $null }

    if ($Node -is [System.Array]) {
        foreach ($item in $Node) {
            $found = Find-NodeByProductId -Node $item -ProductId $ProductId -Depth ($Depth + 1)
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    if ($Node -is [string] -or $Node.GetType().IsPrimitive) { return $null }

    $direct = Get-PropertyValue -Node $Node -Name $ProductId
    if ($null -ne $direct) { return $direct }

    $idKeys = @('id', 'pid', 'product_id', 'productId', 'goods_id', 'goodsId')
    foreach ($key in $idKeys) {
        $value = Get-PropertyValue -Node $Node -Name $key
        if ($null -ne $value -and ([string]$value) -eq $ProductId) {
            return $Node
        }
    }

    foreach ($property in $Node.PSObject.Properties) {
        $found = Find-NodeByProductId -Node $property.Value -ProductId $ProductId -Depth ($Depth + 1)
        if ($null -ne $found) { return $found }
    }

    return $null
}

function Get-FirstProperty {
    param(
        [object]$Node,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-PropertyValue -Node $Node -Name $name
        if ($null -ne $value) { return $value }
    }

    return $null
}

function Read-UpstreamResults {
    param(
        [string]$Body,
        [string[]]$Ids
    )

    $rawContainsKey = $Body -like '*upstream_product_shopping_url*'
    $parsed = $null
    try {
        $parsed = $Body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $parsed = $null
    }

    $fallbackUrls = New-Object System.Collections.Generic.List[string]
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Body, 'upstream_product_shopping_url["'']?\s*[:=]\s*["'']([^"'']*)["'']?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if ($match.Groups.Count -gt 1) { $fallbackUrls.Add($match.Groups[1].Value) }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($id in $Ids) {
        $node = $null
        if ($null -ne $parsed) {
            $node = Find-NodeByProductId -Node $parsed -ProductId $id
        }

        $upstream = Get-FirstProperty -Node $node -Names @('upstream_product_shopping_url', 'upstreamProductShoppingUrl')
        $name = Get-FirstProperty -Node $node -Names @('name', 'product_name', 'productName', 'title')
        $exists = $null -ne $node

        if ($null -eq $upstream -and $fallbackUrls.Count -gt 0 -and $Ids.Count -eq 1) {
            $upstream = $fallbackUrls[0]
        }

        $results.Add([ordered]@{
            productId = $id
            productName = if ($null -eq $name) { '' } else { [string]$name }
            exists = [bool]$exists
            hasUpstream = -not [string]::IsNullOrWhiteSpace([string]$upstream)
            upstreamUrl = if ($null -eq $upstream) { '' } else { [string]$upstream }
        })
    }

    return [ordered]@{
        rawContainsKey = [bool]$rawContainsKey
        results = $results.ToArray()
    }
}

function Read-UpstreamProductsByOrigin {
    param(
        [string]$Origin,
        [string[]]$Ids,
        [int]$BatchSize = 20
    )

    $products = New-Object System.Collections.Generic.List[object]
    $requests = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    for ($offset = 0; $offset -lt $Ids.Count; $offset += $BatchSize) {
        $last = [Math]::Min($offset + $BatchSize - 1, $Ids.Count - 1)
        $batchIds = @($Ids[$offset..$last])
        $apiUrl = Build-ProdetailUrl -Origin $Origin -Ids $batchIds

        try {
            $apiResponse = Invoke-TextRequest -Url $apiUrl -TimeoutSec 18
            if ($apiResponse.statusCode -ge 400) {
                throw ('HTTP {0}' -f $apiResponse.statusCode)
            }
            $readResult = Read-UpstreamResults -Body $apiResponse.body -Ids $batchIds
            foreach ($item in @($readResult.results)) { $products.Add($item) }
            $requests.Add([ordered]@{
                apiUrl = $apiUrl
                statusCode = $apiResponse.statusCode
                ids = $batchIds
            })
        } catch {
            $errors.Add([ordered]@{
                apiUrl = $apiUrl
                ids = $batchIds
                message = $_.Exception.Message
            })
        }
    }

    return [ordered]@{
        products = $products.ToArray()
        requests = $requests.ToArray()
        errors = $errors.ToArray()
    }
}

function Resolve-UpstreamShoppingUrl {
    param([string]$RawUrl)

    if ([string]::IsNullOrWhiteSpace($RawUrl)) { return $null }

    $value = $RawUrl.Trim()
    try { $value = [System.Net.WebUtility]::HtmlDecode($value).Trim() } catch {}

    if ($value -match '^//') { $value = 'https:' + $value }
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { return $null }

    try {
        $uri = [System.Uri]$value
    } catch {
        return $null
    }

    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $null }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) { return $null }

    return [ordered]@{
        url = $uri.AbsoluteUri
        origin = ('{0}://{1}' -f $uri.Scheme, $uri.Authority).TrimEnd('/')
        host = $uri.Host
    }
}

function Read-QueryValues {
    param(
        [System.Uri]$Uri,
        [string[]]$Names
    )

    $values = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Uri -or [string]::IsNullOrWhiteSpace($Uri.Query)) {
        return $values.ToArray()
    }

    $nameMap = @{}
    foreach ($name in $Names) { $nameMap[$name.ToLowerInvariant()] = $true }

    foreach ($pair in $Uri.Query.TrimStart('?') -split '&') {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        try { $key = [System.Uri]::UnescapeDataString($parts[0]).ToLowerInvariant() } catch { $key = $parts[0].ToLowerInvariant() }
        if (-not $nameMap.ContainsKey($key)) { continue }

        $rawValue = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        try { $decoded = [System.Uri]::UnescapeDataString($rawValue.Replace('+', ' ')) } catch { $decoded = $rawValue }
        foreach ($id in @(Read-Ids -Text $decoded)) { $values.Add($id) }
    }

    return @($values | Select-Object -Unique)
}

function Find-UpstreamProductIds {
    param(
        [string]$ShoppingUrl,
        [string]$Html
    )

    $ids = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $uri = $null
    try { $uri = [System.Uri]$ShoppingUrl } catch {}

    if ($null -ne $uri) {
        foreach ($id in @(Read-QueryValues -Uri $uri -Names @('pid', 'product_id', 'productId', 'goods_id', 'goodsId'))) {
            if (-not $seen.ContainsKey($id)) {
                $ids.Add($id)
                $seen[$id] = $true
            }
        }

        $pathPatterns = @(
            '(?:^|/)(?:product|goods|cart/product)/(\d{1,10})(?:/|$)',
            '(?:^|/)(\d{1,10})\.html(?:/|$)'
        )
        foreach ($pattern in $pathPatterns) {
            foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($uri.AbsolutePath, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                if ($match.Groups.Count -le 1) { continue }
                $id = $match.Groups[1].Value
                if (-not $seen.ContainsKey($id)) {
                    $ids.Add($id)
                    $seen[$id] = $true
                }
            }
        }
    }

    if ($ids.Count -gt 0) {
        return $ids.ToArray()
    }

    foreach ($id in @(Find-CandidateIds -Html $Html)) {
        if (-not $seen.ContainsKey($id)) {
            $ids.Add($id)
            $seen[$id] = $true
        }
    }

    return $ids.ToArray()
}

function Trace-UpstreamChain {
    param(
        [string]$ShoppingUrl,
        [int]$MaxDepth = 8
    )

    $resolved = Resolve-UpstreamShoppingUrl -RawUrl $ShoppingUrl
    if ($null -eq $resolved) {
        return [ordered]@{
            startUrl = $ShoppingUrl
            maxDepth = $MaxDepth
            levels = @()
            status = 'invalid_url'
            reason = 'Upstream shopping URL is invalid or unsupported.'
            deepestLevel = 0
            checkedProducts = 0
            upstreamCount = 0
        }
    }

    $levels = New-Object System.Collections.Generic.List[object]
    $seenProducts = @{}
    $seenShoppingUrls = @{}
    $currentUrls = @($resolved.url)
    $depth = 1
    $checkedProducts = 0
    $upstreamCount = 0
    $hadErrors = $false
    $cycleDetected = $false
    $finalStatus = 'none'
    $finalReason = 'No further upstream was found.'

    while ($currentUrls.Count -gt 0 -and $depth -le $MaxDepth) {
        $levelSources = New-Object System.Collections.Generic.List[object]
        $levelProducts = New-Object System.Collections.Generic.List[object]
        $levelErrors = New-Object System.Collections.Generic.List[object]
        $nextUrls = New-Object System.Collections.Generic.List[string]
        $nextSeen = @{}
        $originIds = @{}

        foreach ($url in $currentUrls) {
            if ($seenShoppingUrls.ContainsKey($url)) { continue }
            $seenShoppingUrls[$url] = $true

            try {
                $pageResolved = Resolve-UpstreamShoppingUrl -RawUrl $url
                if ($null -eq $pageResolved) {
                    throw 'Invalid upstream page URL.'
                }

                $ids = @(Find-UpstreamProductIds -ShoppingUrl $url -Html '')
                $finalUrl = $url
                $statusCode = 0
                $sourceMode = 'url'

                if ($ids.Count -eq 0) {
                    $pageResponse = Invoke-TextRequest -Url $url -TimeoutSec 10
                    if ($pageResponse.statusCode -ge 400) {
                        throw ('HTTP {0}' -f $pageResponse.statusCode)
                    }
                    $pageResolved = Resolve-UpstreamShoppingUrl -RawUrl $pageResponse.finalUrl
                    if ($null -eq $pageResolved) { $pageResolved = Resolve-UpstreamShoppingUrl -RawUrl $url }
                    $ids = @(Find-UpstreamProductIds -ShoppingUrl $pageResponse.finalUrl -Html $pageResponse.body)
                    $finalUrl = $pageResponse.finalUrl
                    $statusCode = $pageResponse.statusCode
                    $sourceMode = 'page'
                }

                $levelSources.Add([ordered]@{
                    url = $url
                    finalUrl = $finalUrl
                    origin = $pageResolved.origin
                    statusCode = $statusCode
                    mode = $sourceMode
                    candidateCount = $ids.Count
                })

                if (-not $originIds.ContainsKey($pageResolved.origin)) {
                    $originIds[$pageResolved.origin] = New-Object System.Collections.Generic.List[string]
                }
                foreach ($id in $ids) {
                    $key = ($pageResolved.origin.ToLowerInvariant() + '|' + $id)
                    if (-not $seenProducts.ContainsKey($key)) {
                        if (-not $originIds[$pageResolved.origin].Contains($id)) {
                            $originIds[$pageResolved.origin].Add($id)
                        }
                    } else {
                        $cycleDetected = $true
                    }
                }
            } catch {
                $hadErrors = $true
                $levelErrors.Add([ordered]@{
                    url = $url
                    message = $_.Exception.Message
                })
            }
        }

        foreach ($origin in @($originIds.Keys | Sort-Object)) {
            $ids = @($originIds[$origin].ToArray())
            if ($ids.Count -eq 0) { continue }

            $originResult = Read-UpstreamProductsByOrigin -Origin $origin -Ids $ids
            foreach ($error in @($originResult.errors)) {
                $hadErrors = $true
                $levelErrors.Add([ordered]@{
                    url = $error.apiUrl
                    message = $error.message
                })
            }

            foreach ($item in @($originResult.products)) {
                $key = ($origin.ToLowerInvariant() + '|' + $item.productId)
                $seenProducts[$key] = $true
                $checkedProducts += 1
                if ($item.hasUpstream) {
                    $upstreamCount += 1
                    $next = Resolve-UpstreamShoppingUrl -RawUrl $item.upstreamUrl
                    if ($null -ne $next -and -not $seenShoppingUrls.ContainsKey($next.url) -and -not $nextSeen.ContainsKey($next.url)) {
                        $nextUrls.Add($next.url)
                        $nextSeen[$next.url] = $true
                    } elseif ($null -ne $next -and $seenShoppingUrls.ContainsKey($next.url)) {
                        $cycleDetected = $true
                    } elseif ($null -eq $next) {
                        $hadErrors = $true
                        $levelErrors.Add([ordered]@{
                            url = $item.upstreamUrl
                            message = 'Invalid next upstream URL.'
                        })
                    }
                }

                $levelProducts.Add([ordered]@{
                    origin = $origin
                    productId = $item.productId
                    productName = $item.productName
                    exists = $item.exists
                    hasUpstream = $item.hasUpstream
                    upstreamUrl = $item.upstreamUrl
                })
            }
        }

        $levels.Add([ordered]@{
            depth = $depth
            sources = $levelSources.ToArray()
            products = $levelProducts.ToArray()
            errors = $levelErrors.ToArray()
            checked = $levelProducts.Count
            found = @($levelProducts | Where-Object { $_.hasUpstream }).Count
        })

        if ($nextUrls.Count -eq 0) {
            $levelHasUpstream = @($levelProducts | Where-Object { $_.hasUpstream }).Count -gt 0
            $levelHasMissingProducts = @($levelProducts | Where-Object { -not $_.exists }).Count -gt 0
            if ($levelHasUpstream -and $hadErrors) {
                $finalStatus = 'error'
                $finalReason = 'An upstream link was found but could not be resolved or checked.'
            } elseif ($levelHasUpstream -and $cycleDetected) {
                $finalStatus = 'cycle'
                $finalReason = 'The upstream chain points to a previously checked page.'
            } elseif ($levelHasUpstream) {
                $finalStatus = 'unresolved'
                $finalReason = 'An upstream link could not be queued for further checking.'
            } elseif ($cycleDetected) {
                $finalStatus = 'cycle'
                $finalReason = 'The upstream chain returns to a previously checked page or product.'
            } elseif ($levelProducts.Count -eq 0 -and $levelErrors.Count -gt 0) {
                $finalStatus = 'error'
                $finalReason = 'The upstream page could not be resolved or checked.'
            } elseif ($levelProducts.Count -eq 0) {
                $finalStatus = 'unresolved'
                $finalReason = 'The upstream page did not expose a product ID.'
            } elseif ($levelHasMissingProducts) {
                $finalStatus = 'unresolved'
                $finalReason = 'The upstream API did not return one or more detected products.'
            } elseif ($hadErrors) {
                $finalStatus = 'partial'
                $finalReason = 'No further upstream was found in checked products, but some requests failed.'
            }
            break
        }

        if ($depth -ge $MaxDepth) {
            $finalStatus = 'max_depth'
            $finalReason = 'The maximum upstream depth was reached.'
            break
        }

        $currentUrls = $nextUrls.ToArray()
        $depth += 1
    }

    return [ordered]@{
        startUrl = $resolved.url
        maxDepth = $MaxDepth
        levels = $levels.ToArray()
        status = $finalStatus
        reason = $finalReason
        deepestLevel = $levels.Count
        checkedProducts = $checkedProducts
        upstreamCount = $upstreamCount
    }
}

function Handle-TraceUpstream {
    param([System.Net.HttpListenerContext]$Context)

    $url = $Context.Request.QueryString['url']
    try {
        $trace = Trace-UpstreamChain -ShoppingUrl $url
        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = ($trace.status -ne 'invalid_url')
            trace = $trace
            reason = $trace.reason
        })
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $false
            reason = $_.Exception.Message
        })
    }
}

function Handle-Discover {
    param([System.Net.HttpListenerContext]$Context)

    $target = $Context.Request.QueryString['target']
    $manualIds = $Context.Request.QueryString['pids']

    try {
        $normalized = Normalize-Target -RawTarget $target
        $ids = @(Read-Ids -Text $manualIds)
        $mode = 'manual'
        $discovery = [ordered]@{
            ids = @()
            source = $null
            cartPages = @()
            cartPageCount = 0
            scanned = @()
            errors = @()
        }

        if ($ids.Count -eq 0) {
            $mode = 'cart'
            $discovery = Discover-CartMap -Origin $normalized.origin
            $ids = @($discovery.ids)
        }

        $cartPages = @($discovery.cartPages)
        if ($ids.Count -eq 0 -and $cartPages.Count -eq 0) {
            Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
                ok = $false
                reason = 'No product category or product ID was detected. Open target /cart and enter product IDs manually.'
                target = $normalized
                mode = $mode
                discovery = $discovery
                ids = @()
                total = 0
                cartPages = @()
                cartPageTotal = 0
            })
            return
        }

        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $true
            target = $normalized
            mode = $mode
            discovery = $discovery
            ids = $ids
            total = $ids.Count
            cartPages = $cartPages
            cartPageTotal = $cartPages.Count
            batchSize = 20
        })
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $false
            reason = $_.Exception.Message
            ids = @()
            total = 0
            cartPages = @()
            cartPageTotal = 0
        })
    }
}

function Handle-DiscoverPage {
    param([System.Net.HttpListenerContext]$Context)

    $target = $Context.Request.QueryString['target']
    $page = $Context.Request.QueryString['page']

    try {
        $normalized = Normalize-Target -RawTarget $target
        $pageResult = Read-CartPageProductIds -Origin $normalized.origin -Page $page

        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $true
            target = $normalized
            page = $pageResult.url
            statusCode = $pageResult.statusCode
            ids = $pageResult.ids
            total = $pageResult.total
        })
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $false
            reason = $_.Exception.Message
            page = $page
            ids = @()
            total = 0
        })
    }
}

function Handle-CheckBatch {
    param([System.Net.HttpListenerContext]$Context)

    $target = $Context.Request.QueryString['target']
    $batchIds = $Context.Request.QueryString['pids']
    $batchIndex = $Context.Request.QueryString['batch']
    $total = $Context.Request.QueryString['total']

    try {
        $normalized = Normalize-Target -RawTarget $target
        $ids = @(Read-Ids -Text $batchIds)

        if ($ids.Count -eq 0) {
            Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
                ok = $false
                reason = 'No product ID was provided for this batch.'
                results = @()
            })
            return
        }

        $apiUrl = Build-ProdetailUrl -Origin $normalized.origin -Ids $ids
        $apiResponse = Invoke-TextRequest -Url $apiUrl -TimeoutSec 18
        $readResult = Read-UpstreamResults -Body $apiResponse.body -Ids $ids

        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $true
            target = $normalized
            batch = if ([string]::IsNullOrWhiteSpace($batchIndex)) { 1 } else { [int]$batchIndex }
            total = if ([string]::IsNullOrWhiteSpace($total)) { $ids.Count } else { [int]$total }
            request = [ordered]@{
                apiUrl = $apiUrl
                statusCode = $apiResponse.statusCode
                rawContainsKey = $readResult.rawContainsKey
            }
            ids = $ids
            results = $readResult.results
        })
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $false
            reason = $_.Exception.Message
            results = @()
        })
    }
}

function Handle-Check {
    param([System.Net.HttpListenerContext]$Context)

    $target = $Context.Request.QueryString['target']
    $manualIds = $Context.Request.QueryString['pids']

    try {
        $normalized = Normalize-Target -RawTarget $target
        $ids = @(Read-Ids -Text $manualIds)
        $mode = 'manual'
        $discovery = [ordered]@{
            ids = @()
            source = $null
            scanned = @()
            errors = @()
        }

        if ($ids.Count -eq 0) {
            $mode = 'cart'
            $discovery = Discover-ProductIds -Origin $normalized.origin
            $ids = @($discovery.ids)
        }

        if ($ids.Count -eq 0) {
            Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
                ok = $false
                reason = 'No product ID was detected. Open target /cart and enter product IDs manually.'
                target = $normalized
                mode = $mode
                discovery = $discovery
            })
            return
        }

        $apiUrl = Build-ProdetailUrl -Origin $normalized.origin -Ids $ids
        $apiResponse = Invoke-TextRequest -Url $apiUrl -TimeoutSec 12
        $readResult = Read-UpstreamResults -Body $apiResponse.body -Ids $ids

        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $true
            target = $normalized
            mode = $mode
            discovery = $discovery
            request = [ordered]@{
                apiUrl = $apiUrl
                statusCode = $apiResponse.statusCode
                rawContainsKey = $readResult.rawContainsKey
            }
            ids = $ids
            results = $readResult.results
        })
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Data ([ordered]@{
            ok = $false
            reason = $_.Exception.Message
        })
    }
}

function Handle-StaticFile {
    param([System.Net.HttpListenerContext]$Context)

    $path = [System.Uri]::UnescapeDataString($Context.Request.Url.AbsolutePath)
    if ($path -eq '/') { $path = '/index.html' }

    $relative = $path.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $filePath = Join-Path $WebRoot $relative
    $fullPath = [System.IO.Path]::GetFullPath($filePath)
    $fullWebRoot = [System.IO.Path]::GetFullPath($WebRoot)

    if (-not $fullPath.StartsWith($fullWebRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text -Context $Context -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body 'Forbidden'
        return
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Send-Text -Context $Context -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'Not Found'
        return
    }

    $body = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    Send-Text -Context $Context -StatusCode 200 -ContentType (Get-ContentType -Path $fullPath) -Body $body
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host ''
    Write-Host 'Failed to start: local port cannot be listened.' -ForegroundColor Red
    Write-Host ('Reason: ' + $_.Exception.Message) -ForegroundColor Yellow
    Write-Host 'Try running start.bat as administrator, or change the port in server.ps1.'
    exit 1
}

Write-Host ''
Write-Host 'IDC Smart upstream detector started.' -ForegroundColor Green
Write-Host ('Open URL: ' + $prefix) -ForegroundColor Cyan
Write-Host 'Close this window to stop the service.'
Write-Host ''

if (-not $NoBrowser) {
    Start-Process $prefix
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $requestPath = $context.Request.Url.AbsolutePath
            if ($requestPath -eq '/api/discover') {
                Handle-Discover -Context $context
            } elseif ($requestPath -eq '/api/discover-page') {
                Handle-DiscoverPage -Context $context
            } elseif ($requestPath -eq '/api/check-batch') {
                Handle-CheckBatch -Context $context
            } elseif ($requestPath -eq '/api/trace-upstream') {
                Handle-TraceUpstream -Context $context
            } elseif ($requestPath -eq '/api/check') {
                Handle-Check -Context $context
            } else {
                Handle-StaticFile -Context $context
            }
        } catch {
            try {
                Send-Json -Context $context -StatusCode 500 -Data ([ordered]@{
                    ok = $false
                    reason = $_.Exception.Message
                })
            } catch {}
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}