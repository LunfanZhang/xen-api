---
Title: SMAPIv3 Migration with Snapshots - Design Brief
---

- [Overview](#overview)
- [Why Current SMAPIv3 Migration Fails with Snapshots](#why-current-smapiv3-migration-fails-with-snapshots)
  - [The snapshot chain problem](#the-snapshot-chain-problem)
  - [Loss of snapshot bases](#loss-of-snapshot-bases)
  - [Broken metadata relationships](#broken-metadata-relationships)
  - [Impact on migrated VMs](#impact-on-migrated-vms)
- [New SMAPIv3 Migration Mechanism](#new-smapiv3-migration-mechanism)
  - [Design overview](#design-overview)
  - [Migration phases](#migration-phases)
    - [Phase 1: Discovery](#phase-1-discovery)
    - [Phase 2: Sequential snapshot mirroring](#phase-2-sequential-snapshot-mirroring)
    - [Phase 3: Leaf VDI mirroring](#phase-3-leaf-vdi-mirroring)
    - [Phase 4: Metadata restoration](#phase-4-metadata-restoration)
  - [Complete migration flow](#complete-migration-flow)

## Overview

This document provides a high-level design overview of the SMAPIv3 snapshot migration 
enhancement. It explains the fundamental problem with the original SMAPIv3 migration 
when handling VMs with snapshots and describes the architectural approach taken to 
solve this problem.

The enhancement enables SMAPIv3 to migrate complete snapshot chains, preserving both 
the snapshot data and the structural relationships between snapshots and their parent 
VDIs. This ensures that migrated VMs retain full snapshot functionality on the 
destination host.

## Why Current SMAPIv3 Migration Fails with Snapshots

### The snapshot chain problem

When a VM has snapshots, its storage is not a single VDI but a chain of related VDIs. 
Each snapshot captures the state of the disk at a particular point in time, and these 
snapshots form a hierarchical structure from oldest (base) to newest (leaf).

Consider a typical snapshot scenario:

```
Source SR Storage Structure (Nested Parent-Child):

                V3 (original base)
               /  \
              V2   S1 (snapshot, taken at T2)
             /  \ 
    (leaf) V1    S2 (snapshot, taken at T1)

Snapshot Chain (XAPI's View):
    V1 (leaf) → S2 (snapshot of V3) → S1 (snapshot of S2)
```

In this structure:
- Storage hierarchy (nested): `V3` is the original base (root) with children `V2` 
  and `S1`. `V2` is a parent node with children `V1` (the leaf) and `S2` (snapshot). 
  This structure exists in the storage backend but is not visible to XAPI.
- `V1` is the current leaf VDI receiving new writes from the running VM.
- Snapshot chain (XAPI's view): `V1` (leaf) → `S2` (taken at T1) → `S1` (taken at T2). 
  XAPI can only see the leaf and its snapshots, not the parent nodes V2 and V3.
- Storage dependencies: To read full bootable data from image to disk, the backend must traverse: `V1` → `S2` → `S1`

The nested storage structure represents the actual VDI parent-child relationships in 
the storage backend (not visible to XAPI), while the snapshot chain represents XAPI's 
view of the leaf and its snapshots. During migration, XAPI works with the snapshot chain 
to ensure all snapshot data and metadata are preserved, even though it cannot see the 
underlying storage hierarchy.

### Loss of snapshot bases

The original SMAPIv3 migration mechanism was designed for live VM migration, mirroring 
the active leaf VDI. When a VM with snapshots was migrated, XAPI would transfer the 
visible VDIs (leaf and snapshots) but the underlying storage hierarchy was not preserved.

When a VM with snapshots was migrated, the following occurred:

```
Original SMAPIv3 Migration:

Source SR                           Destination SR
---------                           --------------

      V3  [LOST]                          
     /  \                                  
    V2   S1 ------copy-------→              S1' (copied)
   /  \                                   
 V1   S2  ------copy------→     V1' (mirrored)    S2' (copied)
  │
  └──mirror  ----------→

What gets transferred:
  V1 (leaf) -----mirrored-----→  V1'
  S1 (snapshot) -----copied-----→   S1'
  S2 (snapshot) -----copied-----→   S2'

What is LOST:
  V2 (parent node) - not transferred
  V3 (base node) - not transferred
```

The critical problem is that While `V1` (leaf) is mirrored and `S1`, `S2` (snapshots) are 
copied to the destination, the parent nodes `V2` and `V3` from the storage backend 
hierarchy are **not transferred**. This breaks the storage structure because, the snapshots S1' and S2' on the destination have no parent nodes to reference. The storage backend expects the nested hierarchy but only receives isolated VDIs.

Although S1' and S2' physically exist on the destination, they cannot function properly without the base nodes they depend on, assume it is only a reference which only includes limited metadata.

This created several severe issues:

1. Even though S1', S2', and V1' exist on the destination, 
   the missing parent nodes (V2, V3) break the storage backend's nested hierarchy. The 
   backend cannot properly traverse the VDI dependencies, so the VM naturally fails to start, as the when VM boot, the tapdisk will fail to find the parent nodes.

2. Snapshot VMs may fail, Snapshot VMs referencing S1' and S2' may fail to start or 
   access data correctly because the storage structure is incomplete.

3. Without the complete storage hierarchy, any operations on 
   the snapshots could lead to data corruption or unexpected behavior, as the storage 
   backend cannot resolve the full dependency chain.

### Impact on migrated VMs

The practical impact on users was severe:

```
Before Migration (Source):

Main VM --VBD--> V1 (leaf)                    ✓ Working
     |                Complete chain: V1 → V2 → V3 (full disk data)
     └─→ Snapshots:
          Snapshot VM 1 --VBD--> S2           ✓ Working
          Snapshot VM 2 --VBD--> S1           ✓ Working


After Migration (Destination):

Main VM --VBD--> V1'                          ✗ CRASH on boot!

Destination has: V1', S2', S1' (all transferred)
BUT: V1' only contains delta data, parent nodes V2, V3 (with base data) are MISSING!

When VM boots:
  1. Tapdisk opens V1' (leaf image)
  2. V1' only contains recent writes (delta)
  3. Tapdisk tries to traverse to parent: V1' → V2 [NOT FOUND]
  4. Cannot access base data in V2, V3
  5. Disk is incomplete and not bootable
  6. VM fails to start - CRASH

Snapshot VMs have the same problem:
     Snapshot VM 1 --VBD--> S2'   ✗ CRASH (S2' needs parent V3)
     Snapshot VM 2 --VBD--> S1'   ✗ CRASH (S1' needs parent S2, then V3)
```

Users discovered that:
- The main VM failed to boot after migration with tapdisk errors, Tapdisk could not find parent VDIs due to incomplete disk chain
- The migrated V1' only contained delta data, not a complete bootable disk
- VM becomes completely non-functional on the destination

This made SMAPIv3 migration can not work for any production environment where 
snapshots were used. even worse, it leads the data lost after migration.

### How SMAPIv1 handles snapshot migration

SMAPIv1 migration does not suffer from the same problem because it uses a fundamentally 
different approach: it creates a snapshot first, then copies the snapshot data. This 
creates a complete, self-contained disk image on the destination.

#### SMAPIv1 mirroring approach

The key difference between SMAPIv1 and SMAPIv3 is that SMAPIv1 takes a snapshot before 
migration to create a difference image that accepts new writes, then copies the snapshot 
which contains the complete disk data.

The SMAPIv1 migration process works as follows:

```
Before Migration:
                V3 (original base)
               /  \
              V2   S1
             /  \ 
     (leaf)V1   S2

Step 1: Copy snapshot to Destination
   copy S1 S2 into the destination SR, when copying, it will try to find the similar VDI in the destination SR, if found, it will use the similar VDI, if not, it will create a new VDI.
   
   The copying process (using sparse_dd) reads all blocks and flattens them into a 
   complete image on the destination.

Step 2: mirror the leaf to the destination
   during mirror, the first step is take the snapshot base on the leaf. it turn the nested storage into below:
   before mirror:
                V3 (original base)
               /  \
              V2   S1
             /  \ 
           V1`   S2
          /  \
   (leaf) V1  dummy (snapshot for migration)

   - mirror the leaf V1 to the destination.
   - copy the dummy to the destination.
   - compose the snapshot.

Step 3: Result on Destination
                             V3 (original base)
                           /  \
             V2`          V2   S1
           /               \ 
         V1                S2
   
   The destination VDI is fully bootable as V2' contains ALL the base data.
```

Why this works: By taking a snapshot first, SMAPIv1 creates a read-only copy of the 
entire disk state which is V2`. When this snapshot is copied to the destination, the copy operation 
composes/flattens all data from the parent chain into a single complete image. The 
destination receives a full, bootable disk that doesn't depend on missing parent nodes.
the snapshot branch becomes separated, which looks 
unusual but is out scope of this design, I will not extend more details here.

The key point: SMAPIv1 migration creates a complete disk copy, so the destination VDI 
is fully functional and bootable, even though the storage structure looks different. 
This is why SMAPIv1 migration worked for VMs with snapshots, albeit slower than the 
direct mirroring approach of SMAPIv3.

but as for current SMAPIv3, it will has droped the step of take snapshot when mirrorring the leaf,
because QEMU mirror(blockdev-mirror) is able to full carry a wirtable/active node from one SR to another,
which result V1 has no parent, it works when there is no snapshot as mirror one active node is enough for this case,
but it will result base missing when there is snapshot, as the mirror will not copy the parent nodes.

Why this fails with snapshots: SMAPIv3 mirrors the writable node as-is, transferring 
only the delta data in the leaf. It does not copy or transfer the parent nodes. When 
the leaf is a delta image that depends on parent nodes for base data, the destination 
receives an incomplete disk that cannot boot.

The direct mirror approach is fast and efficient for VMs without snapshots (where the 
leaf contains the complete disk), but fails when the leaf is only a delta depending on 
parent nodes for the full disk data.

The fundamental difference:
- SMAPIv1: snapshot → compose/flatten → transfer complete data → functional
- SMAPIv3: direct mirror → transfer delta only → missing base data → crash

## New SMAPIv3 Migration Mechanism

### Design overview

The enhanced SMAPIv3 migration introduces a **snapshot-aware migration process** that 
preserves complete snapshot chains. The fundamental insight is that we can reuse the 
same NBD mirroring mechanism that works for the leaf VDI to also mirror each snapshot 
in the chain, one at a time, in the correct order.

The new SMAPIv3 migration process will following below steps:

1. Mirror each snapshot VDI individually, from oldest to 
   newest (base-to-leaf order), it also require Storage API include mrirror and activate to make some change
    to support when mirror a leaf mirror the leaf itself.
   when mirror the snapshot, mirror it`s parent.

2. After mirroring each snapshot's data into a 
   temporary destination VDI, take a snapshot to preserve that state

3. Track the mapping between source and destination snapshot 
   VDIs along with temporal metadata

4. After all VDIs are migrated, restore the snapshot 
   relationships on the destination

5. Update all snapshot VM VBD references to point to the new 
   destination snapshot VDIs

### V3 SXM

#### Phase 1: Discovery

Before migration begins, the system discovers the complete snapshot chain for each 
VDI being migrated:

```
Discovery Phase:

Source Database Query:
    V1 (leaf VDI)
     ↓ query: get_snapshots
     ↓
    [S2, S1]  ← snapshot references
     ↓
    Retrieve metadata for each:
      S2: { uuid: "s2-uuid", snapshot_time: "2024-01-15T10:30:00Z" }  (older)
      S1: { uuid: "s1-uuid", snapshot_time: "2024-01-16T14:20:00Z" }  (newer)

Result: [(s2-uuid, 2024-01-15T10:30:00Z), (s1-uuid, 2024-01-16T14:20:00Z)]
         ↑ Base-to-leaf order (S2 first, then S1)
```

The discovery process:
- Queries the database for all snapshots of the leaf VDI
- Extracts both the snapshot UUID and the original creation timestamp
- Orders snapshots from oldest to newest (base-to-leaf)
- Returns a list of snapshot metadata to process

#### Phase 2: Sequential snapshot mirroring

Each snapshot is then mirrored in sequence, from oldest to newest. For each snapshot:

```
Snapshot Mirroring (Example: S2, the oldest snapshot):

Step 1: Start NBD Proxy
    Source SR                    Destination SR
    ---------                    --------------
    S2 (attach read-only)   <--- NBD Proxy <--- Mirror VDI (activated read-only)
                                     
                                     
Step 2: Mirror Operation
    Source SR                    Destination SR
    ---------                    --------------
    S2 -------- QEMU Mirror ---> Mirror VDI (receives S2 data)
    (read blocks)                (write blocks)
    
Step 3: Snapshot Destination
    Source SR                    Destination SR
    ---------                    --------------
    S2                           Mirror VDI (has S2 data)
                                      ↓ VDI.snapshot
                                    S2' (snapshot of mirror VDI)
                                    
Step 4: Record Mapping
    Mapping Table: {
      S2 (source) ↔ S2' (dest), timestamp: 2024-01-15T10:30:00Z
    }
```

The process repeats for each snapshot in order:

```
Complete Snapshot Migration Sequence:

Source SR                                    Destination SR
---------                                    --------------

Iteration 1:
    S1 (oldest)  ---- mirror ----->          Mirror VDI (receives S1 data)
                                                  ↓ snapshot
                                                 S1'

                                                
                                                V3 (Top base)
Iteration 2:                                  /           ↓ snapshot
S2 (newer)   ---- mirror ----->              V2`              S1'
                                               ↓ snapshot
                                                 S2'
Mapping Table After Completion:
    S2 ↔ S2', timestamp: 2024-01-15T10:30:00Z
    S1 ↔ S1', timestamp: 2024-01-16T14:20:00Z
```

The critical aspect is that each snapshot is mirrored into the same destination 
mirror VDI, and a snapshot is taken after each mirror to preserve that state. This 
creates a chain of destination snapshots that mirrors the source chain structure.

#### Phase 3: Leaf VDI mirroring

After all snapshots are mirrored, the destination VDI is switched from read-only to 
read-write mode, and the leaf VDI mirroring proceeds as in the original SMAPIv3 design:

```
Leaf VDI Mirroring:

Source SR                                    Destination SR
---------                                    --------------

    V1 (leaf)                                Mirror VDI
    | active                                      ↑
    | receives VM writes                    V3 (Top base)
    |                                      /           ↓ snapshot
    |                                     V2`              S2'
    |                                     |  ↓ snapshot
    |                                     |   S1'
    |  -- qemu mirror (continuous) ----> V1`    
                                          ↓
                                    receives writes
                                    (read-write mode)

At migration finish:
    V1 becomes V1' on destination
```

This phase is identical to the original SMAPIv3 migration, but now occurs **after** 
all snapshots have been migrated, ensuring the complete chain is preserved.

#### Phase 4: Metadata restoration

After all VDIs are migrated, the system restores snapshot metadata and relationships. from storage layer pespective, relationship has been built since the snapshot was created,
but from toolstack perspective, relationship has not been built, so we need to restore the relationship:

```
Metadata Restoration:

Step 1: Retrieve Mapping Table
    S2 ↔ S2', timestamp: 2024-01-15T10:30:00Z
    S1 ↔ S1', timestamp: 2024-01-16T14:20:00Z
    V1 ↔ V1'

Step 2: Establish Relationships on Destination
    For each snapshot mapping:
      SET S2'.snapshot_of = V1'
      SET S2'.snapshot_time = 2024-01-15T10:30:00Z
      SET S2'.is_a_snapshot = true
      
      SET S1'.snapshot_of = V1'
      SET S1'.snapshot_time = 2024-01-16T14:20:00Z
      SET S1'.is_a_snapshot = true

Step 3: Update VBD References
    Snapshot VM 1:
      VBD.VDI: S2 → S2'  (update reference)
      
    Snapshot VM 2:
      VBD.VDI: S1 → S1'  (update reference)

Final Result:
    Main VM --VBD--> V1'              ✓ Working
         |
         └─→ Snapshots:
              Snapshot VM 1 --VBD--> S2'   ✓ Working
              Snapshot VM 2 --VBD--> S1'   ✓ Working
```

The metadata restoration ensures that all snapshot timestamps are preserved (maintaining temporal history), snapshot relationships point to the correct destination leaf VDI,
all snapshot VMs have their VBDs updated to reference destination snapshot VDIs, the complete snapshot chain structure is intact on the destination.

### Complete migration flow

The complete migration flow can be as below:

```
Complete SMAPIv3 Snapshot Migration Flow:

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 1: DISCOVERY                                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Source SR:                                                         │
│      V1 (leaf)                                                      │
│       ↓                                                             │
│  Query snapshots → [S2, S1]                                         │
│  Order: base-to-leaf → [(S2, T1), (S1, T2)]                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 2: SNAPSHOT MIRRORING (Sequential)                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Source SR              Destination SR                              │
│  ----------             --------------                              │
│                                                                     │
│  Round 1:                                                           │
│    S2 ------mirror----→ Mirror VDI --snapshot--→ S2'                │
│                                                                     │
│  Round 2:                                                           │
│    S1 ------mirror----→ Mirror VDI --snapshot--→ S1'                │
│                                                                     │
│  Mapping: S2→S2'(T1), S1→S1'(T2)                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 3: LEAF MIRRORING (Continuous)                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Source SR              Destination SR                              │
│  ----------             --------------                              │
│                                                                     │
│    V1 ------mirror-----→ Mirror VDI (becomes V1')                   │
│ (active,live VM)         receives ongoing writes                    │
│                                                                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Phase 4: METADATA RESTORATION                                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Destination SR Metadata:                                           │
│                                                                     │
│    S2': snapshot_of=V1', snapshot_time=T1, is_a_snapshot=true       │
│    S1': snapshot_of=V1', snapshot_time=T2, is_a_snapshot=true       │
│                                                                     │
│  VBD Updates:                                                       │
│    Snapshot VM 1: VBD.VDI = S2 → S2'                                │
│    Snapshot VM 2: VBD.VDI = S1 → S1'                                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

Final Destination State:

    V1' (leaf VDI)
    ↑
    ├-→ S2' (snapshot, time=T1)
    │   └─→ Snapshot VM 1 (VBD → S2')  ✓
    │
    └-→ S1' (snapshot, time=T2)
        └─→ Snapshot VM 2 (VBD → S1')  ✓

Main VM (VBD → V1')  ✓
```

This design ensures the snapshot migration is fully accurate while reusing the existing 
SMAPIv3 mirroring infrastructure. The key innovation is the sequential processing of 
snapshots with destination snapshot creation after each mirror, building up the 
destination chain incrementally and preserving all metadata and relationships.

The result is that users experience seamless migration of VMs with snapshots, with 
all snapshot functionality fully preserved on the destination host, including the 
ability to start snapshot VMs, view snapshot history, and perform rollback operations.

## Implementation Approach

This section describes how the snapshot migration mechanism integrates into the existing SMAPIv3 migration code. The implementation touches several layers of the storage stack, from the RPC interface down to the migration orchestration logic.

### Storage Interface Layer

We need a new RPC call for restoring snapshot relationships after migration. The interface lives in `storage_interface.ml` where other SR operations are defined. Looking at existing snapshot operations like `SR.update_snapshot_info_dest`, we can follow the same pattern. The RPC takes a list of relations, where each relation is a tuple of (snapshot VDI, leaf VDI, timestamp string). After xapi finishes mirroring all snapshots, it calls this RPC to tell the storage layer "these VDIs on the destination are snapshots of that leaf VDI, and here are their timestamps."

### Storage Multiplexer Layer

The actual implementation goes in `storage_mux.ml`. This is straightforward - iterate through the relations list and for each one, update three database fields:

```ocaml
Db.VDI.set_snapshot_of ~__context ~self:snapshot_ref ~value:leaf_ref
Db.VDI.set_snapshot_time ~__context ~self:snapshot_ref ~value:timestamp
Db.VDI.set_is_a_snapshot ~__context ~self:snapshot_ref ~value:true
```

The existing `update_snapshot_info_dest` function does something similar. We just need the simpler version that works for both SMAPIv1 and SMAPIv3 backends without special cases.

### Storage Migration Helper

During migration, we need somewhere to store the snapshot mappings temporarily. The `storage_migrate_helper.ml` module already has state management for mirrors using a mutex-protected hashtable. We add another hashtable here with the same pattern:

```ocaml
let snapshot_mappings_table : (string, (vdi * vdi * string) list) Hashtbl.t
```

The key is the mirror ID, the value is the list of (source snapshot, dest snapshot, timestamp) tuples. Three simple functions: `set_snapshot_mappings` to store, `get_snapshot_mappings` to retrieve, and `remove_snapshot_mappings` to clean up. The existing code in this module shows exactly how to do mutex-protected hashtable operations.

### SMAPIv3 Migration Logic

This is where most of the work happens. The file `storage_smapiv3_migrate.ml` contains the `MIRROR` module that handles the actual mirroring process. We need to extend it in several places.

First, add a function to discover snapshots and extract their metadata. This queries the database for all snapshots of the VDI and returns them sorted oldest-first with their timestamps in ISO8601 format using `Date.to_rfc3339`:

```ocaml
let get_snapshot_chain ~__context ~vdi =
  let snapshot_refs = Db.VDI.get_snapshots ~__context ~self:vdi in
  List.map (fun snap_ref ->
    let uuid = Db.VDI.get_uuid ~__context ~self:snap_ref in
    let time = Db.VDI.get_snapshot_time ~__context ~self:snap_ref in
    (uuid, Date.to_rfc3339 time)
  ) snapshot_refs
  |> List.sort (fun (_, t1) (_, t2) -> compare t1 t2)
```

Second, add helper functions to keep the code clean. The snapshot mirroring process involves several steps that repeat for each snapshot, so factor them into helpers: one to attach/detach snapshots in readonly mode, another to wait for mirror completion with polling, another to create the destination snapshot, and a main function that orchestrates mirroring a single snapshot into the existing destination VDI. Add a key function `mirror_snapshot_into_existing_dest` does the full sequence: attach source snapshot readonly, start the mirror, wait for completion, detach, then call remote `VDI.snapshot` to preserve the state. It returns the destination snapshot VDI info.

Third, modify `send_start` to process snapshots before the leaf. At the start of `send_start`, call `get_snapshot_chain` to get the list. If there are snapshots, process them one by one using the helper functions. For each snapshot, the NBD proxy needs to be restarted fresh. After all snapshots are mirrored, switch the destination VDI from readonly to writable using `Remote.VDI.deactivate` followed by `Remote.VDI.activate3`. Then start the NBD proxy for the leaf and proceed with the leaf VDI mirror exactly as the current code does. Track the snapshot mappings (source, dest, timestamp) as you go.

Fourth, after the leaf mirror completes in `send_start`, store the mappings:

```ocaml
State.set_snapshot_mappings mirror_id snapshot_mappings
```

Addtionallym, before `send_start`, update `receive_start` to activate the initial destination VDI in readonly mode instead of writable. This is because we need to mirror snapshots into it first before switching to writable for the leaf. Change `Remote.VDI.activate3` to `Remote.VDI.activate_readonly`.

### VM Migration Orchestration

The `xapi_vm_migrate.ml` file orchestrates the whole migration. In the `vdi_copy_fun` function, after `mirror_to_remote` completes, we need to retrieve the snapshot mappings using the mirror ID, call the new RPC to restore snapshot relationships on the destination, create mirror records for the snapshot VDIs (similar to the main VDI mirror record) so the continuation function can update VBD references, then clean up the stored mappings.

There's also logic in `migrate_send'` that determines which VDIs need explicit copying beyond the main VDI. The `extra_vdis` list normally includes both suspend VDIs and snapshot VDIs. We need to detect when any VDI is on an SMAPIv3 SR and has snapshots - in that case, exclude snapshot VDIs from the copy list since they're now handled through the mirror path. Suspend VDIs still need explicit copying.

```ocaml
let extra_vdis =
  if has_smapiv3_snapshots then (
   debug "excluding SMAPIv3 snapshots from copy list (already mirrored)" ;
    suspends_vdis
   ) else
    suspends_vdis @ snapshots_vdis
```

### Skeleton and Wrapper Layers

The RPC plumbing needs stubs in `storage_skeleton.ml` and forwarding logic in `storage_smapiv1_wrapper.ml`. Just follow what `update_snapshot_info_dest` does - these are mechanical changes.

### Error Handling

Snapshot discovery failures should log but return an empty list, letting the migration proceed without snapshots. If a snapshot mirror fails, stop immediately with a clear error - we don't want partial snapshot migration. Metadata restoration failures get logged as warnings but don't block the migration, since the data is already copied. VBD updates are best-effort per snapshot. Cleanup operations use try-catch and never raise errors.
