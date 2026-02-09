# Prerequisites & Installation Guide (Windows)

This guide outlines the steps to prepare a Windows environment for running the `Datastore_MPP_Changer.ps1` script.

## 1. System Requirements

*   **Operating System**: Windows 10, Windows 11, or Windows Server 2016+
*   **PowerShell Version**:
    *   Windows PowerShell 5.1 (Built-in)
    *   **Recommended**: PowerShell Core 7+ (Cross-platform)
*   **Internet Access**: Required to download modules from the PowerShell Gallery.
*   **Network Access**: Connectivity to your vCenter Server on port 443 (HTTPS).

## 2. Install PowerShell Core (Optional but Recommended)

While the script works with Windows PowerShell 5.1, PowerShell Core offers better performance and modern features.

1.  Download the latest installer from the [GitHub releases page](https://github.com/PowerShell/PowerShell/releases).
2.  Run the `.msi` installer and follow the prompts.

## 3. Install VMware PowerCLI Module

The script requires the `VMware.PowerCLI` module to interact with vCenter.

1.  Open PowerShell as **Administrator**:
    *   Right-click the PowerShell icon and select **Run as Administrator**.
2.  Run the following command to install the module:

    ```powershell
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser
    ```

    *   *Note: If prompted to install the NuGet provider or trust the repository, type `Y` and press Enter.*

3.  Verify the installation:

    ```powershell
    Get-Module -Name VMware.PowerCLI -ListAvailable
    ```

## 4. Configuration

### Execution Policy
By default, Windows restricts running scripts. You need to allow script execution.

Run the following command in your Administrator PowerShell window:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
*   *Type `Y` or `A` to confirm if prompted.*

### SSL Certificate Validation (Optional)
If your vCenter uses self-signed certificates (common in labs), you may need to ignore invalid certificate errors.

Run this command:

```powershell
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

### CEIP (Customer Experience Improvement Program)
To disable the data collection prompt:

```powershell
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false
```

## 5. Running the Script

1.  Navigate to the directory containing `Datastore_MPP_Changer.ps1`.
2.  Run the script:

    ```powershell
    .\Datastore_MPP_Changer.ps1
    ```
