# Local GitHub Actions Setup with `act` for d-flows

This guide provides a complete setup for running GitHub Actions workflows locally using the `act` tool in the d-flows repository.

## 📋 Prerequisites

### Required Software
- **Docker Desktop** - Required for running Ubuntu containers
- **PowerShell** - For Windows command execution
- **WinGet** - Package manager (built into Windows 11/updated Windows 10)

### Verify Prerequisites
```powershell
# Check Docker installation
docker --version

# Check WinGet availability  
winget --version
```

## 🚀 Installation

### 1. Install Docker Desktop (if not already installed)
Download and install Docker Desktop from [docker.com](https://www.docker.com/products/docker-desktop).

### 2. Install `act` using WinGet
```powershell
# Install act using WinGet
winget install nektos.act

# Alternative installation methods:
# Chocolatey: choco install act-cli
# Scoop: scoop install act
```

### 3. Verify Installation
After installation, restart your PowerShell session or create an alias:

```powershell
# Create alias if PATH not updated yet
Set-Alias -Name act -Value "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WinGet\Packages\nektos.act_Microsoft.Winget.Source_8wekyb3d8bbwe\act.exe"

# Test installation
act --version
```

## ⚙️ Configuration

### 1. Repository Configuration (.actrc)
The repository includes an `.actrc` file with optimized settings:

```ini
# Use catthehacker images for better GitHub Actions compatibility
-P ubuntu-latest=catthehacker/ubuntu:act-latest

# Enable container architecture specification
--container-architecture=linux/amd64

# Artifacts server for artifact upload/download testing
--artifact-server-path ./.artifacts

# Pull policy - set to false if you want to use local images
--pull=true
```

### 2. Secrets Management
Create a `.secrets` file in the repository root (use `.secrets.template` as reference):

```bash
# Copy template and customize
cp .secrets.template .secrets

# Edit .secrets file with your actual values
# GITHUB_TOKEN=your_github_token_here
# DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/your_webhook_url_here
```

**🔒 Security Note**: Never commit `.secrets` to git! It's already in `.gitignore`.

### 3. Event Files for Testing
Use the provided `pr-event.json` for testing pull request workflows:

```json
{
  "pull_request": {
    "number": 123,
    "head": { "ref": "feature/test-branch" },
    "base": { "ref": "main" },
    "html_url": "https://github.com/test/repo/pull/123",
    "user": { "login": "testuser" }
  },
  "act": true
}
```

## 🎯 Usage Examples

### List Available Workflows
```powershell
# List all workflows and jobs
act --list

# List workflows for specific events
act --list pull_request
act --list workflow_dispatch
```

### Run Specific Workflows

#### 1. Step Summary Workflow (Manual Testing)
```powershell
act workflow_dispatch --job set-summary --input title="Test Summary" --input markdown="# Test Content" --input overwrite=true
```

#### 2. PR CI Workflow (Pull Request Validation)
```powershell
# Run syntax validation only
act pull_request --job validate-syntax -e pr-event.json

# Run complete PR CI workflow
act pull_request -e pr-event.json
```

#### 3. Version Bump Workflow
```powershell
act workflow_dispatch --job calculate-and-release --input bump_type=patch --input target_branch=main -W .github/workflows/bump-version.yml
```

#### 4. Release Workflow
```powershell
act workflow_dispatch --job create-release --input version=1.0.0 -W .github/workflows/release.yml
```

### Run with Secrets
```powershell
# Using secrets file
act pull_request --secret-file .secrets -e pr-event.json

# Using environment variables
act pull_request -s GITHUB_TOKEN="$env:GITHUB_TOKEN" -e pr-event.json

# Interactive secret input
act pull_request -s GITHUB_TOKEN -e pr-event.json
```

### Advanced Usage
```powershell
# Run with different runner image
act -P ubuntu-latest=ubuntu:22.04 pull_request -e pr-event.json

# Run in offline mode (use cached actions)
act --action-offline-mode pull_request -e pr-event.json

# Run with verbose output
act --verbose pull_request -e pr-event.json

# Run specific job only
act pull_request --job validate-syntax -e pr-event.json
```

## 🔧 Troubleshooting

### Common Issues

#### 1. Docker Connection Issues
```powershell
# Check Docker is running
docker ps

# Restart Docker Desktop if needed
```

#### 2. Path Issues (Act not found)
```powershell
# Find act installation
Get-ChildItem "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WinGet\Packages\" -Recurse -Name "act.exe"

# Create persistent alias in PowerShell profile
echo 'Set-Alias -Name act -Value "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WinGet\Packages\nektos.act_Microsoft.Winget.Source_8wekyb3d8bbwe\act.exe"' >> $PROFILE
```

#### 3. Container Image Issues
```powershell
# Pull required images manually
docker pull catthehacker/ubuntu:act-latest

# Run with no pull to use local images
act --pull=false pull_request -e pr-event.json
```

#### 4. Reusable Workflow Issues
Some workflows use `workflow_call` events which may have limitations in local execution. Test individual jobs when needed:

```powershell
# Test individual components
act workflow_dispatch --job send-notification -W .github/workflows/discord-notify.yml
```

### Performance Optimization

#### 1. Use Offline Mode
```powershell
# Add to .actrc for permanent offline mode
echo "--action-offline-mode" >> .actrc
```

#### 2. Use Local Images
```powershell
# Disable pulling for faster execution
echo "--pull=false" >> .actrc
```

#### 3. Cache Docker Images
```powershell
# Pre-pull commonly used images
docker pull catthehacker/ubuntu:act-latest
docker pull catthehacker/ubuntu:act-22.04
```

## 📚 Additional Resources

- [Act Official Documentation](https://nektosact.com/)
- [Act GitHub Repository](https://github.com/nektos/act)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [catthehacker Docker Images](https://github.com/catthehacker/docker_images)

## 🔄 Workflow-Specific Notes

### PR CI Workflow (`pr-ci.yml`)
- Downloads and runs `actionlint` for syntax validation
- Calls reusable workflows for notifications and step summaries
- Uses Discord webhook for notifications (optional)

### Discord Notification (`discord-notify.yml`)
- Reusable workflow for sending Discord notifications
- Requires `DISCORD_WEBHOOK_URL` secret for actual notifications
- Fails gracefully if webhook is not configured

### Step Summary (`step-summary.yml`)
- Reusable workflow for adding content to GitHub step summary
- Works locally but output is only visible in logs

### Bump Version (`bump-version.yml`)
- Complex workflow for version bumping
- Requires GitHub token for API access
- May need manual testing due to git operations

### Release (`release.yml`)
- Creates GitHub releases
- Requires GitHub token and write permissions
- Best tested in dry-run mode locally

## 🔐 Security Best Practices

1. **Never commit secrets** - Use `.secrets` file and keep it in `.gitignore`
2. **Use minimal permissions** - Create GitHub tokens with only required scopes
3. **Test with dummy data** - Use mock webhooks and test repositories
4. **Review before running** - Always understand what a workflow does before execution
5. **Use environment isolation** - Act runs in containers, but be aware of mounted volumes

---

*This guide was generated for the d-flows repository. Adapt the examples and configuration as needed for your specific use case.*