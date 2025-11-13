# Quick Start Script for d-flows Act Setup
# Run this script in PowerShell to verify your act installation

Write-Host "🚀 d-flows Act Setup Verification" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan

# Check prerequisites
Write-Host "`n📋 Checking Prerequisites..." -ForegroundColor Yellow

# Check Docker
try {
    $dockerVersion = docker --version
    Write-Host "✅ Docker: $dockerVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Docker not found. Please install Docker Desktop." -ForegroundColor Red
    exit 1
}

# Check Act
try {
    $actPath = "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WinGet\Packages\nektos.act_Microsoft.Winget.Source_8wekyb3d8bbwe\act.exe"
    if (Test-Path $actPath) {
        Set-Alias -Name act -Value $actPath -Scope Global
        $actVersion = & $actPath --version
        Write-Host "✅ Act: $actVersion" -ForegroundColor Green
    } else {
        Write-Host "❌ Act not found. Please install with: winget install nektos.act" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "❌ Act not working properly." -ForegroundColor Red
    exit 1
}

# Check repository
if (Test-Path ".github/workflows") {
    Write-Host "✅ GitHub workflows directory found" -ForegroundColor Green
} else {
    Write-Host "❌ Not in a GitHub Actions repository root" -ForegroundColor Red
    exit 1
}

# Check configuration
if (Test-Path ".actrc") {
    Write-Host "✅ Act configuration found" -ForegroundColor Green
} else {
    Write-Host "⚠️  Act configuration not found. Using defaults." -ForegroundColor Yellow
}

Write-Host "`n🧪 Running Test Workflow..." -ForegroundColor Yellow

# Test basic workflow
try {
    Write-Host "Testing step-summary workflow..." -ForegroundColor Cyan
    & $actPath workflow_dispatch --job set-summary --input title="Setup Test" --input markdown="✅ Act is working correctly!" --input overwrite=true --quiet
    Write-Host "✅ Basic workflow test passed" -ForegroundColor Green
} catch {
    Write-Host "❌ Workflow test failed" -ForegroundColor Red
    exit 1
}

Write-Host "`n📚 Quick Commands:" -ForegroundColor Yellow
Write-Host "List workflows:     act --list" -ForegroundColor Cyan
Write-Host "Test PR workflow:   act pull_request -e pr-event.json" -ForegroundColor Cyan
Write-Host "Run specific job:   act workflow_dispatch --job JOBNAME" -ForegroundColor Cyan
Write-Host "Use offline mode:   act --action-offline-mode" -ForegroundColor Cyan

Write-Host "`n🎉 Setup verification complete! Act is ready to use." -ForegroundColor Green
Write-Host "📖 See ACT_SETUP_GUIDE.md for detailed usage instructions." -ForegroundColor Blue