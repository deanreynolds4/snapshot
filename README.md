# Azure VM snapshot-and-rebuild toolkit

Move an Azure VM from a size **without** a local temp disk to a size **with** one
(`Standard_E8s_v5` → `Standard_E8ds_v5`), keeping backups, patching, licensing, monitoring,
identity and networking intact — or telling you plainly where it cannot.

---

## Why this exists

Azure will not let you resize a Windows VM across the temp-disk boundary. From the
Limitations section of *Resize a virtual machine*:

> Resizing between VM sizes that have a local temp disk and VM sizes that have no local
> temp disk is supported for Linux VMs. For Windows VMs, only the following resize
> combinations are allowed: VM (with local temp disk) → VM (with local temp disk); and
> VM (with no local temp disk) → VM (with no local temp disk).

Attempting it anyway returns HTTP 409 `OperationNotAllowed`:

> Unable to resize the VM since changing from resource disk to non-resource disk VM size
> and vice-versa is not allowed.

Microsoft's own documented workaround is exactly this toolkit's approach:

> The work-around can be used to resize a VM with no local temp disk to VM with a local
> temp disk. You create a snapshot of the VM with no local temp disk > create a disk from
> the snapshot > create VM from the disk with appropriate VM size that supports VMs with a
> local temp disk.

**Note for Linux:** the restriction does not apply. On Linux, deallocate and resize in
place — do not use this toolkit.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows PowerShell 5.1 | PowerShell 7 also works. The scripts avoid `?:`, `??`, `&&`/`\|\|`, `ConvertFrom-Json -Depth` and `-AsHashtable`, none of which exist in 5.1. |
| .NET Framework 4.7.2+ | Required for the Az modules on Windows PowerShell 5.1. |
| Az PowerShell modules | See below. |

```powershell
Install-Module -Name Az.Accounts, Az.Compute, Az.Network -Scope CurrentUser -Repository PSGallery -Force

# Needed for the corresponding manifest sections; each is optional and degrades gracefully.
Install-Module -Name Az.RecoveryServices, Az.SqlVirtualMachine, Az.Maintenance, Az.Monitor, Az.Resources, Az.ResourceGraph -Scope CurrentUser -Repository PSGallery -Force
```

A missing optional module is reported as `Skipped` in the manifest rather than silently
producing an empty section — but a skipped section is **not** replayed, so install them all
before a real migration.

Permissions: Contributor on the VM's resource group, plus Backup Contributor on the
Recovery Services vault (which is often in a different resource group).

---

## The files

| File | Role |
|---|---|
| `save-vm-snapshot-manifest.ps1` | **Capture.** Snapshots the disks and writes a full fidelity manifest plus a raw JSON archive. |
| `release-vm-network-address.ps1` | **IP handover.** Moves the source NIC to a parking address so the replacement can claim the original IP. Reversible. |
| `new-vm-from-snapshot-manifest.ps1` | **Rebuild.** Creates the replacement VM and replays everything it can. |
| `compare-vm-fidelity.ps1` | **Verify.** Diffs the replacement against the manifest and reports what did not carry over. Read-only. |
| `vm-rebuild-common.ps1` | Shared helpers. Dot-sourced; not run directly. |

Every script supports `-WhatIf` and `-Confirm`. Every script that changes anything is
idempotent to the extent of refusing to overwrite something that already exists.

---

## The one decision you have to make: `-RestoreMode`

This is the most important choice in the whole migration, and it is about **patching**.

A VM created by attaching a specialized OS disk has **no `osProfile`**. Azure rejects it on
that create path (`Parameter 'osProfile' is not allowed`, HTTP 400) and refuses to add it
afterwards (`Changing property 'osProfile' is not allowed`, HTTP 409
`PropertyChangeNotAllowed`). Every guest patch setting — `patchMode`, `assessmentMode`,
`enableHotpatching`, `bypassPlatformSafetyChecksOnUserSchedule` — lives inside `osProfile`.
Microsoft documents the consequence as a known issue: *"the prerequisite for scheduled
patching isn't set correctly ... for specialized, generalized and restored VMs."*

| Mode | How it works | Patching outcome | Cost |
|---|---|---|---|
| `AttachOsDisk` *(default)* | Attaches the restored OS disk directly. | **Scheduled patching cannot be re-established.** On-demand assessment and patching still work. | Simplest, fastest. |
| `ImageFirstSwap` | Creates a throwaway VM from the source's *original platform image* (so it has a real `osProfile` carrying the source's patch settings), deallocates it, then swaps the restored OS disk in. | **Patch settings preserved.** | ~15–20 min extra, plus a few constraints. |

`ImageFirstSwap` requires:

- the manifest to have recorded an `ImageReference` (absent if the source VM was *itself*
  built from a specialized disk — the script tells you and stops);
- the restored OS disk and the placeholder disk to be the **same size** (handled
  automatically);
- matching Hyper-V generation and security type (checked in preflight).

A caveat worth knowing before you choose it: after the swap the VM model's `computerName`
and `adminUsername` describe the throwaway placeholder, not the running guest. Both are
create-time-only properties and cannot be corrected. It is cosmetic — the guest keeps its
real name from the restored disk — but it will look odd in the portal forever.

**If Azure Update Manager scheduled patching matters to you, use `ImageFirstSwap`.**
Attaching a maintenance configuration to an `AttachOsDisk` VM *appears* to succeed and then
fails at run time with *"The prerequisites to patch your machine were not met."* Seeing the
assignment in the portal is not evidence that patching works.

---

## The cutover runbook

Side-by-side: the replacement is built under a **new name** while the original stays intact
as the rollback. The original's IP is handed over so nothing downstream has to be re-pointed.

**The rule that governs every step: the two VMs must never be running at the same time.**
They share a hostname, an Active Directory computer account, SQL Server's `@@SERVERNAME`,
and often a licence. The scripts enforce this and refuse to proceed by default.

### Step 0 — Rehearse (no downtime, no risk)

```powershell
.\save-vm-snapshot-manifest.ps1 -VmName SQLPROD01 -SubscriptionId <guid> -SkipSnapshots
```

Inventories the VM, writes the manifest, and prints the fidelity gaps specific to *your* VM.
Creates nothing billable. Read the gap list before going further.

Optionally rehearse the whole rebuild on a live VM without an outage:

```powershell
.\save-vm-snapshot-manifest.ps1 -VmName SQLPROD01 -ConsistencyMode RestorePoint
```

A VM restore point captures all disks as one set while the VM keeps running. Good for a
dry run into an isolated subnet; **not** what you cut over from.

### Step 1 — Pre-cutover checks (in the guest, before the window)

- Record the drive letter → LUN map (`Get-Disk`, `Get-Partition`).
- Confirm the page file is **not** on a drive letter that could move.
- Confirm you hold the BitLocker recovery keys if the disks are encrypted.
- Note where SQL Server's TempDB currently lives.

### Step 2 — Capture (start of the outage)

```powershell
.\save-vm-snapshot-manifest.ps1 -VmName SQLPROD01 -SubscriptionId <guid> -DeallocateVm
```

Deallocates the VM, then snapshots every disk while nothing is writing. This is the only
consistency mode safe to cut over from — snapshotting a running multi-disk SQL VM one disk
at a time produces disks seconds or minutes apart, and a data file newer than its own log.

Snapshots are incremental by default (much cheaper for large SQL data disks). Use
`-FullSnapshot` to override.

### Step 3 — Release the IP

```powershell
.\release-vm-network-address.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-<stamp>.json -WhatIf
.\release-vm-network-address.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-<stamp>.json
```

A private IP stays owned by its NIC — deallocating the VM does not release it. This moves
the source NIC's primary IP configuration to a free parking address in the same subnet,
which frees the original immediately while leaving the source VM intact and bootable.

It writes a handover record. To undo:

```powershell
.\release-vm-network-address.ps1 -Rollback -HandoverPath .\SQLPROD01-ip-handover-<stamp>.json
```

Add `-DetachPublicIp` if you also need the public IP moved.

### Step 4 — Preflight the rebuild

```powershell
.\new-vm-from-snapshot-manifest.ps1 `
    -ManifestPath .\SQLPROD01-snapshot-manifest-<stamp>.json `
    -TargetVmName SQLPROD01-ds -TargetVmSize Standard_E8ds_v5 `
    -RestoreMode ImageFirstSwap -UseSourcePrivateIp -PreflightOnly
```

Creates nothing. Verifies among other things that the target size exists in the region and
zone, that it **actually has a temp disk** (`MaxResourceVolumeMB > 0` — otherwise the whole
migration is pointless and it blocks), that it supports premium storage / encryption at host
/ Trusted Launch as required, that the disk controller type is compatible, that the names
are free, and that the source VM is deallocated.

Resolve every **BLOCKER**. Read every **WARNING**.

### Step 5 — Build

```powershell
.\new-vm-from-snapshot-manifest.ps1 `
    -ManifestPath .\SQLPROD01-snapshot-manifest-<stamp>.json `
    -TargetVmName SQLPROD01-ds -TargetVmSize Standard_E8ds_v5 `
    -RestoreMode ImageFirstSwap -UseSourcePrivateIp
```

The replacement is created **stopped**. It prints a numbered manual checklist of everything
it could not do for you.

### Step 6 — First boot and in-guest work

Start it only once the source is confirmed deallocated. Then, in the guest:

1. **Check drive letters.** Windows persists its letter-to-volume bindings in
   `HKLM\SYSTEM\MountedDevices` on the OS disk, which is carried over, so the new temp disk
   normally takes the first *free* letter rather than displacing anything. Verify rather
   than assume.
2. **Set up TempDB on the ephemeral disk** — see the SQL Server section below.
3. Confirm domain trust, SQL Server startup, and application connectivity.

### Step 7 — Verify

```powershell
.\compare-vm-fidelity.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-<stamp>.json `
    -TargetVmName SQLPROD01-ds -OutputPath .\fidelity-report.json
```

Diffs the replacement against the manifest property by property and writes JSON + CSV for
the change record. It also checks that only one of the two VMs is running.

### Step 8 — Decommission (only after a soak period)

Keep the source VM deallocated, not deleted, for as long as your rollback window requires.
Then delete the source VM, its disks and the snapshots. **Check disk `deleteOption` first:**
portal-created VMs default the OS disk to *Delete with VM*.

---

## Rollback

| When | How |
|---|---|
| Before step 5 | Nothing to undo except the IP: `release-vm-network-address.ps1 -Rollback`. |
| After step 5, before starting the new VM | Delete the replacement VM and its disks, then roll back the IP. |
| After the new VM has run | Stop the replacement, roll back the IP, start the source VM. Any data written to the replacement since cutover is lost — the source VM's disks are frozen at snapshot time. |

The source VM, its disks and the snapshots are never touched by any script in this toolkit.

---

## What carries over automatically

Compute size, location, zone, tags, Windows licence type (Azure Hybrid Benefit), marketplace
plan, security type with Secure Boot and vTPM, encryption at host, proximity placement group,
capacity reservation group (when subscription and region are unchanged), user-assigned
managed identities, `userData`, disk controller type, UltraSSD and hibernation capability.

Disks: SKU, size, zone, caching, write accelerator, disk encryption set and encryption type,
performance tier, bursting, provisioned IOPS/throughput, max shares, network access policy,
Hyper-V generation, tags — **all restated explicitly**, because a disk created from a
snapshot inherits nothing but the bytes.

Networking: subnet, NSG, private IP, public IP, accelerated networking, IP forwarding,
DNS servers, and a best-effort reapplication of application security group and load balancer
backend pool membership.

Attached resources: VM extensions (except those noted below), boot diagnostics, Azure Backup
protection, Azure Update Manager VM-scoped maintenance assignments, SQL VM registration with
licence type and management mode, and Azure Monitor data collection rule associations.

---

## What does NOT carry over — the honest list

This is the part that matters. None of it is a bug; it is what Azure permits.

### Permanent, no workaround

| Item | Why | What to do |
|---|---|---|
| **Guest patch settings** in `AttachOsDisk` mode | `osProfile` cannot exist on a specialized-disk VM and cannot be added later. | Use `-RestoreMode ImageFirstSwap`. |
| **System-assigned identity principal ID** | The replacement gets a brand-new principal. | Re-grant every role assignment, Key Vault access policy and database login given to the old identity. Prefer user-assigned identities, which keep their principal IDs. |
| **VM unique ID (`vmId` / SMBIOS UUID)** | Regenerated whenever a VM is built from copied disks. | Check any third-party software node-locked to the machine UUID. |
| **Image provenance (`imageReference`)** in `AttachOsDisk` mode | Read-only, set only at initial creation. | Cosmetic unless something reads it. `ImageFirstSwap` preserves it. |
| **Backup recovery point history** (with a new VM name) | Azure Backup identifies a VM by subscription + resource group + **name**. | See below. |

### Backup history and the name trade-off

Because you are building the replacement under a **new name**, Azure Backup treats it as a
new protected item: it starts a fresh chain with a full initial replica, and the source VM's
existing recovery points stay under the old item — still restorable, still billed, until they
age out per policy.

Microsoft's documented behaviour is that recovery points *"automatically reattach"* only when
the replacement has the **same name, in the same resource group and subscription**. If
preserving backup history matters more than side-by-side safety, the alternative is:
snapshot → delete the source VM (with `deleteOption=Detach` forced on every disk and NIC
first) → rebuild under the identical name. That gives up your rollback VM and your rehearsal
window. It is a real trade-off, not an oversight — the toolkit warns you which one you are
making, and `compare-vm-fidelity.ps1` records it.

Do **not** stop protection with data deletion at any point.

### Needs a manual step

- **Extensions with protected settings.** `protectedSettings` is write-only in Azure and
  cannot be read back. Custom Script (command line, storage key), domain join (password),
  antimalware, Key Vault and hybrid worker extensions must be reinstalled with their secrets.
- **Extensions deliberately skipped.** Domain join (`JsonADDomainExtension`) — the restored
  disk is *already* domain-joined and re-running it can break the secure channel;
  `AADLoginForWindows` — a stale Entra device object with the same hostname causes sign-in
  failure `0x801c0083`; Azure Disk Encryption; and anything owned by the SQL VM resource
  provider or the Recovery Services vault.
- **Azure Monitor Agent.** Microsoft states that cloning a machine with AMA installed is not
  supported. The snapshot carries its cached state. Verify data is actually flowing
  (`Heartbeat | where Category == "Azure Monitor Agent"`) and force a clean reinstall if not —
  a green agent that collects nothing is this migration's most likely silent failure.
- **Data collection rule associations owned by another service** (Defender for Cloud, VM
  Insights, Change Tracking, Sentinel). Re-enable the owning feature; do not hand-create them.
- **Role assignments scoped to the VM resource**, resource locks, secondary NICs, Azure Site
  Recovery replication, Azure Policy guest configuration assignments.
- **Subscription-, resource-group- and tag-scoped Update Manager schedules.** Only VM-scoped
  assignments are visible from the VM. A tag-scoped schedule picks the new VM up only if its
  tags match.
- **SQL VM deep settings**: auto-patching window, auto-backup, storage configuration
  (including TempDB layout), server configuration management, Key Vault credentials. All are
  captured into the manifest but not replayed; several contain write-only secrets that Azure
  never returns.
- **Trusted Launch vTPM-sealed material.** The VM Guest State blob is tied to the OS disk, and
  a disk rebuilt from a snapshot receives a new one. Anything sealed to the vTPM — BitLocker
  above all — can be invalidated. Hold the recovery keys.
- **Private DNS auto-registration** follows the VM *name*, so a renamed replacement gets a
  different A record even though the IP is unchanged.

---

## SQL Server specifics

**TempDB on the ephemeral disk is the point of this migration, and it needs a startup task.**
The temp disk is wiped on every deallocation, so the TempDB folder disappears and SQL Server
will not start (errors 5123 / 17204, OS error 3). The standard pattern is a boot-triggered
scheduled task that runs before the SQL Server service:

1. Find the volume labelled `Temporary Storage` and pin it to the drive letter you want.
2. Create the TempDB folder and set its ACLs for the SQL Server service account.
3. Start `MSSQLSERVER`, then `SQLSERVERAGENT`.

Set both services to **Manual** start first, or SQL Server will race the task and fail on the
first boot after every deallocation.

**Target a v5 size, not v6+.** On `Standard_E8ds_v5` the temp disk arrives pre-formatted NTFS
labelled *Temporary Storage* and is given a letter automatically. On v6 and later families the
local disk is **raw, unformatted NVMe with no drive letter on every boot**, which needs a full
initialize/format/assign script before SQL Server starts. The preflight warns if you pick one.

**Azure Hybrid Benefit for SQL.** Between deleting the old `sqlVirtualMachines` resource and
registering the new one, SQL licensing reverts to the image default — a real billing exposure
if the source was AHUB. The restore script re-reads and asserts the licence type after
registration, and flags a mismatch. Note that AHUB cannot be set at all when the image SKU is
Developer, Express, Web or Evaluation.

**SQL workload (database-level) backup** is a separate registration from VM backup and is not
recreated. If the manifest reports `SqlWorkloadBackup`, re-register the container manually.

---

## Cost

- Snapshots are billed. Incremental (the default) is substantially cheaper than full for
  large disks; snapshots are tagged `vm-rebuild-toolkit=true` so they are easy to find and
  clean up.
- Between step 5 and decommissioning you are paying for **two sets of managed disks**.
- Both VMs exist, but only one runs, so compute is billed once.
- Orphaned backup recovery points under the old item continue to be billed until they age out.

---

## Known errors and what they mean

| Error | Meaning |
|---|---|
| `Unable to resize the VM since changing from resource disk to non-resource disk VM size and vice-versa is not allowed` | The constraint this toolkit exists for. |
| `Parameter 'osProfile' is not allowed` | Something tried to set an OS profile on a specialized-disk create. Expected in `AttachOsDisk` mode. |
| `Changing property 'osProfile' is not allowed` (409) | An attempt to add patch settings to an already-created specialized VM. Not recoverable; rebuild with `ImageFirstSwap`. |
| `The prerequisites to patch your machine were not met` | A maintenance assignment on a VM without `osProfile` patch settings. |
| `UserErrorMigrationFromTrustedLaunchVMToNonTrustedVMNotAllowed` | Security type mismatch when re-protecting in the same vault. Match the source exactly. |
| `disk and VM must be in the same zone` | A restored disk was created regional while the VM is zonal, or vice versa. |
| `VMMarketplaceInvalidInput` | The marketplace `plan` block is missing. |
| `You cannot call a method on a null-valued expression` | The original `new-vm-from-snapshot-manifest.ps1`. Fixed. |

---

## What changed from the original scripts

The original pair had four defects verified by execution on Windows PowerShell 5.1:

1. **Snapshot name collision — silent data loss.** `Get-CleanDiskName` split the disk name on
   `_` and kept the first two parts, so Azure's default `<vm>_DataDisk_0`, `_1`, `_2` all
   collapsed to `<vm>_DataDisk`. Every data disk got the same snapshot name, each overwriting
   the last, and the manifest listed several entries pointing at one snapshot — producing a
   rebuilt VM with duplicate volumes and no error anywhere. Snapshot names are now derived
   from the LUN (unique by definition) and asserted unique before anything is created.
2. **The restore script could not run at all.** It called `ConvertFrom-Json -Depth 20`; that
   parameter does not exist in PowerShell 5.1, so it failed at parameter binding.
3. **`$warnings.Add()` before `$warnings` existed**, which threw for any VM with a capacity
   reservation group.
4. **`$vmConfig.Tags = <PSCustomObject>`**, which cannot be assigned to a property typed
   `IDictionary[string,string]`. Tags are now passed as a hashtable to `New-AzVMConfig -Tags`.

Beyond the fixes, the manifest grew from roughly a dozen fields to full fidelity coverage,
every optional section now carries an explicit capture status so "not configured" is
distinguishable from "could not read it", and each script gained preflight validation,
`-WhatIf`, transcripts and an explicit manual checklist.
