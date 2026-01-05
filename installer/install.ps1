#Requires -RunAsAdministrator
<#
.SYNOPSIS
    PDev Live Self-Hosted Installer for Windows

.DESCRIPTION
    Installs PDev Live with all dependencies (Node.js, PostgreSQL, PM2)

.PARAMETER InstallDir
    Installation directory (default: C:\pdev-live)

.PARAMETER Port
    Server port (default: 3016)

.PARAMETER NonInteractive
    Run without prompts

.PARAMETER AcceptAll
    Auto-accept all prompts

.EXAMPLE
    .\install.ps1
    .\install.ps1 -AcceptAll
    .\install.ps1 -InstallDir "D:\pdev" -Port 3020

.NOTES
    Version: 1.0.0
    Requires: Windows 10/11 or Windows Server 2019+
#>

param(
    [string]$InstallDir = "C:\pdev-live",
    [int]$Port = 3016,
    [switch]$NonInteractive,
    [switch]$AcceptAll,
    [string]$DbName = "pdev_live",
    [string]$DbUser = "pdev_app"
)

$ErrorActionPreference = "Stop"
$Version = "1.0.0"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
function Write-Header {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Text)
    Write-Host "[ERROR] $Text" -ForegroundColor Red
}

function Prompt-User {
    param(
        [string]$Question,
        [string]$Default = "N"
    )

    if ($NonInteractive) {
        return $AcceptAll
    }

    $prompt = if ($Default -eq "Y") { "[Y/n]" } else { "[y/N]" }
    $response = Read-Host "$Question $prompt"

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Default -eq "Y"
    }

    return $response -match "^[Yy]"
}

function Generate-SecurePassword {
    param([int]$Length = 32)

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $password = -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $password
}

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================
function Test-NodeInstalled {
    try {
        $version = & node -v 2>$null
        if ($version) {
            $major = [int]($version -replace 'v(\d+)\..*', '$1')
            if ($major -ge 18) {
                Write-Success "Node.js $version found"
                return $true
            }
            Write-Warning "Node.js $version found but v18+ required"
        }
    } catch {}
    return $false
}

function Test-PostgreSQLInstalled {
    try {
        $version = & psql --version 2>$null
        if ($version) {
            $major = [int]($version -replace '.*(\d+)\..*', '$1')
            if ($major -ge 14) {
                Write-Success "PostgreSQL $major found"
                return $true
            }
            Write-Warning "PostgreSQL $major found but v14+ required"
        }
    } catch {}
    return $false
}

function Test-PM2Installed {
    try {
        $version = & pm2 -v 2>$null
        if ($version) {
            Write-Success "PM2 $version found"
            return $true
        }
    } catch {}
    return $false
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================
function Install-Chocolatey {
    if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Header "Installing Chocolatey"
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        Write-Success "Chocolatey installed"
    }
}

function Install-NodeJS {
    Write-Header "Installing Node.js"
    Install-Chocolatey
    choco install nodejs-lts -y
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Success "Node.js installed"
}

function Install-PostgreSQL {
    Write-Header "Installing PostgreSQL"
    Install-Chocolatey

    # Generate secure random password for postgres user
    $PostgresAdminPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_})

    Write-Host "Installing PostgreSQL with secure admin password..."
    Write-Host ""
    Write-Warning "IMPORTANT: Save this PostgreSQL admin password securely:"
    Write-Host "PostgreSQL 'postgres' user password: $PostgresAdminPassword" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Press any key after saving password to continue..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    choco install postgresql16 -y --params "/Password:$PostgresAdminPassword"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    # Wait for PostgreSQL to start
    Start-Sleep -Seconds 5
    Write-Success "PostgreSQL installed with secure password"

    # Store password for later use in script
    $global:PostgresAdminPassword = $PostgresAdminPassword
}

function Install-PM2 {
    Write-Header "Installing PM2"
    npm install -g pm2
    npm install -g pm2-windows-startup
    Write-Success "PM2 installed"
}

# =============================================================================
# DATABASE SETUP
# =============================================================================
function Setup-Database {
    Write-Header "Setting up PostgreSQL Database"

    $script:DbPassword = Generate-SecurePassword

    $sql = @"
SELECT 'CREATE DATABASE $DbName' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DbName')\gexec

DO `$`$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DbUser') THEN
        CREATE USER $DbUser WITH PASSWORD '$($script:DbPassword)';
    ELSE
        ALTER USER $DbUser WITH PASSWORD '$($script:DbPassword)';
    END IF;
END
`$`$;

REVOKE ALL ON DATABASE $DbName FROM PUBLIC;
GRANT CONNECT ON DATABASE $DbName TO $DbUser;
"@

    $env:PGPASSWORD = $global:PostgresAdminPassword
    $sql | psql -U postgres -h localhost

    Write-Success "Database $DbName and user $DbUser created"
}

function Run-Migrations {
    Write-Header "Running Database Migrations"

    $migrationFile = Join-Path $PSScriptRoot "migrations\001_create_tables.sql"

    if (!(Test-Path $migrationFile)) {
        Write-Error "Migration file not found: $migrationFile"
        exit 1
    }

    # Run all migrations in order
    $migrationsDir = Join-Path $PSScriptRoot "migrations"
    $migrationFiles = Get-ChildItem -Path $migrationsDir -Filter "*.sql" | Sort-Object Name

    foreach ($migration in $migrationFiles) {
        Write-Host "Applying migration: $($migration.Name)"
        $env:PGPASSWORD = $global:PostgresAdminPassword
        Get-Content $migration.FullName | psql -U postgres -h localhost -d $DbName

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Migration $($migration.Name) failed"
            exit 1
        }
    }

    # Grant privileges after all migrations
    $grants = @"
GRANT USAGE ON SCHEMA public TO $DbUser;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $DbUser;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $DbUser;
GRANT SELECT ON ALL VIEWS IN SCHEMA public TO $DbUser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $DbUser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO $DbUser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON VIEWS TO $DbUser;
"@

    $env:PGPASSWORD = $global:PostgresAdminPassword
    $grants | psql -U postgres -h localhost -d $DbName

    Write-Success "All migrations applied successfully"
}

# =============================================================================
# APPLICATION SETUP
# =============================================================================
function Setup-Application {
    Write-Header "Setting up Application"

    # Create directories
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\logs" | Out-Null
    New-Item -ItemType Directory -Force -Path "$InstallDir\frontend" | Out-Null

    # Copy server files
    $serverDir = Join-Path $PSScriptRoot "..\server"

    if (Test-Path "$serverDir\server.js") {
        Copy-Item "$serverDir\server.js" -Destination $InstallDir
        Copy-Item "$serverDir\package.json" -Destination $InstallDir
        Write-Success "Server files copied"
    } else {
        Write-Error "server.js not found"
        exit 1
    }

    # Generate admin key
    $adminKey = Generate-SecurePassword

    # Create .env file
    $envContent = @"
# PDev Live Configuration
# Generated: $(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")

# Database
PDEV_DB_HOST=localhost
PDEV_DB_PORT=5432
PDEV_DB_NAME=$DbName
PDEV_DB_USER=$DbUser
PDEV_DB_PASSWORD=$($script:DbPassword)

# Server
PORT=$Port
NODE_ENV=production

# Security
PDEV_ADMIN_KEY=$adminKey

# Frontend
PDEV_FRONTEND_DIR=$InstallDir\frontend
"@

    $envContent | Out-File -FilePath "$InstallDir\.env" -Encoding UTF8

    # Set restrictive permissions on .env
    $acl = Get-Acl "$InstallDir\.env"
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "FullControl",
        "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl "$InstallDir\.env" $acl

    Write-Success ".env file created with secure permissions"

    # Install npm dependencies
    Push-Location $InstallDir
    npm install --production
    Pop-Location

    Write-Success "Dependencies installed"
}

function Create-EcosystemConfig {
    Write-Header "Creating PM2 Configuration"

    $config = @"
module.exports = {
  apps: [{
    name: 'pdev-live',
    script: 'server.js',
    cwd: '$($InstallDir -replace '\\', '\\\\')',
    exec_mode: 'fork',
    instances: 1,
    autorestart: true,
    max_restarts: 10,
    min_uptime: '60s',
    exp_backoff_restart_delay: 30000,
    kill_timeout: 5000,
    listen_timeout: 10000,
    env_production: {
      NODE_ENV: 'production'
    },
    error_file: 'logs/error.log',
    out_file: 'logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    max_memory_restart: '500M',
    watch: false
  }]
};
"@

    $config | Out-File -FilePath "$InstallDir\ecosystem.config.js" -Encoding UTF8
    Write-Success "ecosystem.config.js created"
}

# =============================================================================
# DESKTOP APP CONFIGURATION
# =============================================================================
function Setup-DesktopConfig {
    Write-Header "Configuring Desktop App"

    # Windows Electron user data path: %APPDATA%/pdev-live
    $configDir = Join-Path $env:APPDATA "pdev-live"

    # Create directory if not exists
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    # Create config.json pointing to local server
    $configContent = @"
{
  "serverUrl": "http://localhost:$Port"
}
"@

    $configContent | Out-File -FilePath "$configDir\config.json" -Encoding UTF8

    Write-Success "Desktop app configured to use http://localhost:$Port"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================
function Start-PDevService {
    Write-Header "Starting PDev Live Service"

    Push-Location $InstallDir
    pm2 start ecosystem.config.js --env production
    pm2 save
    Pop-Location

    Write-Success "Service started"
}

function Setup-Startup {
    Write-Header "Configuring Startup"
    pm2-startup install
    Write-Success "PM2 startup configured"
}

function Wait-ForHealth {
    param([int]$MaxAttempts = 30, [int]$Delay = 2)

    Write-Host "Waiting for service to be ready..." -NoNewline

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $response = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($response.status -eq "ok") {
                Write-Host ""
                Write-Success "Health check passed!"
                return $true
            }
        } catch {}

        Write-Host "." -NoNewline
        Start-Sleep -Seconds $Delay
    }

    Write-Host ""
    Write-Error "Health check failed after $MaxAttempts attempts"
    pm2 logs pdev-live --lines 20 --nostream
    return $false
}

# =============================================================================
# MAIN
# =============================================================================
function Main {
    Write-Header "PDev Live Self-Hosted Installer v$Version"

    # Check dependencies
    Write-Header "Checking Dependencies"

    if (!(Test-NodeInstalled)) {
        if (Prompt-User "Node.js 18+ not found. Install it?" "Y") {
            Install-NodeJS
        } else {
            Write-Error "Node.js is required. Aborting."
            exit 1
        }
    }

    if (!(Test-PostgreSQLInstalled)) {
        if (Prompt-User "PostgreSQL 14+ not found. Install it?" "Y") {
            Install-PostgreSQL
        } else {
            Write-Error "PostgreSQL is required. Aborting."
            exit 1
        }
    }

    if (!(Test-PM2Installed)) {
        if (Prompt-User "PM2 not found. Install it?" "Y") {
            Install-PM2
        } else {
            Write-Error "PM2 is required. Aborting."
            exit 1
        }
    }

    # Setup
    Setup-Database
    Run-Migrations
    Setup-Application
    Create-EcosystemConfig
    Setup-DesktopConfig
    Start-PDevService

    if (Wait-ForHealth) {
        if (Prompt-User "Configure automatic startup on boot?" "Y") {
            Setup-Startup
        }

        Write-Header "Installation Complete!"
        Write-Host ""
        Write-Success "PDev Live is running at: http://localhost:$Port"
        Write-Success "Health endpoint: http://localhost:$Port/health"
        Write-Success "Installation directory: $InstallDir"
        Write-Host ""
        Write-Host "Useful commands:"
        Write-Host "  pm2 status pdev-live    # Check status"
        Write-Host "  pm2 logs pdev-live      # View logs"
        Write-Host "  pm2 restart pdev-live   # Restart service"
        Write-Host ""
        Write-Success "Desktop app will connect to: http://localhost:$Port"
        Write-Host ""
        Write-Success "Admin key stored in: $InstallDir\.env"
    } else {
        Write-Error "Service failed to start. Check logs above."
        exit 1
    }
}

Main
