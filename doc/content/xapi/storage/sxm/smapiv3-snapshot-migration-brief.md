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
  - [Why a tree, and not a chain](#why-a-tree-and-not-a-chain)
  - [Key design decisions](#key-design-decisions)
  - [Migration phases](#migration-phases)
    - [Phase 1: Snapshot tree discovery](#phase-1-snapshot-tree-discovery)
    - [Phase 2: DFS tree traversal](#phase-2-dfs-tree-traversal)
    - [Phase 3: Live leaf mirroring](#phase-3-live-leaf-mirroring)
    - [Phase 4: Metadata restoration](#phase-4-metadata-restoration)
  - [Complete migration flow](#complete-migration-flow)
- [Implementation Approach](#implementation-approach)
- [Additional Implementation Fixes](#additional-implementation-fixes)

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

Why the destination tree looks "split": SMAPIv1's order is **mirror first, copy 
second**. The leaf is mirrored into a freshly created destination VDI, which has no
parent at that point. When the snapshot copy phase runs next, it asks the destination 
SR for `similar_contents` to find a VDI it can share base data with. Because the 
mirrored leaf was created from scratch a moment ago, `similar_contents` returns 
nothing useful, and each snapshot copy lands as an isolated tree on the destination 
rather than re-using the freshly-mirrored leaf as a shared base. The result is a 
visually separated snapshot branch on the destination — bootable and correct, just 
not topologically identical to the source. This separation is a known SMAPIv1 
behaviour and is out of scope of this design; we mention it only so readers do not 
confuse it with a bug introduced by the SMAPIv3 work described below.

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

The enhanced SMAPIv3 migration introduces a **snapshot-tree-aware migration process**
that reproduces the *full* snapshot topology on the destination — not just a linear
chain, but the tree shape that arises when a user reverts to an earlier snapshot
before taking new ones. We reuse the same NBD-backed QEMU mirror mechanism that
already works for the leaf VDI to also mirror every snapshot in the tree, walking
the tree depth-first and cloning at branch points so that revert-induced side
branches are preserved alongside the main active path.

At a high level, the migration runs in four phases:

1. **Snapshot tree discovery.** Build a snapshot tree for the disk being migrated by
   projecting all snapshot VMs of the live VM onto the single disk slot identified
   by the VBD `userdevice`. The tree's branching structure comes directly from each
   snapshot VM's `parent`/`children` relationships and faithfully captures any
   revert that occurred in the VM's history.

2. **DFS tree traversal.** Walk the tree depth-first. At every node, mirror its
   source snapshot VDI into the current destination *working VDI* and then take a
   destination snapshot to anchor the data. At a branching node — i.e. a node with
   more than one child, meaning a revert happened there — recurse into each
   reverted/inactive subtree on a fresh clone of the just-created anchor, and
   recurse into the single active continuation on the **same** working VDI.

3. **Live leaf mirroring.** When DFS finishes, the working VDI is back to the
   original `mirror_vdi` returned by `receive_start3`, positioned at the deepest
   active-path snapshot. Switch it back to writable and run the continuous live
   mirror for the running VM's leaf, exactly as the pre-existing SMAPIv3 design did.

4. **Metadata restoration.** Push the recorded (source snapshot, destination
   snapshot, snapshot time) tuples to the destination via a new RPC,
   `SR.set_snapshot_relations`, which writes `snapshot_of` / `snapshot_time` /
   `is_a_snapshot` into both the XAPI database and the storage backend's own
   metadata store. The orchestrator then updates each snapshot VM's VBD to reference
   the destination snapshot VDI.

### Why a tree, and not a chain

For a VM that only ever takes snapshots in chronological order, the snapshot history
is linear:

```
snap1 → snap2 → snap3 → live
```

Once the user **reverts** to an earlier snapshot (e.g. revert to `snap1`) and then
takes new snapshots `snap3', snap4'`, the history forks:

```
snap1 ─┬─ snap2          (the original, now-orphaned line)
       └─ snap3' → snap4' (the new, active line that leads to the live VM)
```

XAPI models this fork via each snapshot VM's `parent`/`children` pointers: both
`snap2` and `snap3'` are children of `snap1`, but only the chronologically-newer
descendant is on the **active path** that ultimately leads to the live VM. The
previous, chain-based design assumed a single path and silently dropped the
orphaned subtree, leaving the destination with a broken/incomplete topology after
migration. The new tree-based design preserves both lines.

### Key design decisions

#### Cross-snapshot disk identity by `userdevice`, not `snapshot_of`

A snapshot VDI's `snapshot_of` field points at the active VDI that existed *at the
time the snapshot was taken*. A revert destroys that active VDI and produces a new
one with a new ref, so pre-revert snapshot VDIs end up with `snapshot_of` pointing
at a stale ref. Using `snapshot_of` to find "the same disk" across snapshot VMs is
therefore unreliable.

Instead, the new design identifies each disk by its VBD **`userdevice`** (the disk
slot inside the VM, e.g. "0"). `userdevice` is preserved across reverts: every
snapshot VM that contains this disk has a VBD with the same userdevice pointing at
the snapshot VDI for that slot. We look up the userdevice once on the live VM's
VBD, then project each snapshot VM onto that single slot to obtain the snapshot
VDI we need.

#### Active path detection by walking `VM.parent`

Each snapshot VM has a `VM.parent` pointer to the previously-active snapshot VM at
the moment it was taken. Walking `parent` upward from the live VM yields the
ordered set of snapshot VMs that lie on the active path. Any snapshot VM that does
*not* appear in this walk is by definition on a reverted/inactive branch.

#### DFS, inactive-first, active-last

The recursive structure of the traversal is the single most important property of
this design and is what guarantees correctness with respect to the live mirror
hand-off. At every tree node:

1. **Mirror & anchor.** Run a one-shot QEMU mirror from the node's source snapshot
   VDI into the current `working_vdi`, then call `Remote.VDI.snapshot working_vdi`
   to take a destination snapshot. The freshly created destination snapshot serves
   two purposes simultaneously: it records this node's mirrored data, and it acts
   as a stable base from which any inactive subtree can be cloned.

2. **Partition children** by `on_active_path`. There is at most one active child
   per node (more than one would indicate corrupt XAPI state and is logged as a
   warning); the remaining children are inactive (reverted) subtrees.

3. **Recurse into inactive subtrees first.** For each inactive child, clone the
   just-created destination anchor (`Remote.VDI.clone dest_snapshot`) and use that
   clone as a fresh working VDI for the child subtree. After the subtree finishes,
   deactivate, detach, and destroy the clone. Each inactive subtree is fully
   self-contained: it never sees or touches `mirror_vdi`.

4. **Recurse into the active continuation last**, reusing the same `working_vdi`.
   When recursion bottoms out at the deepest active-path snapshot, `working_vdi` is
   *still* the original `mirror_vdi` returned by `receive_start3` — no
   post-traversal "splice" or rename step is needed. Phase 3's live leaf mirror
   simply switches that VDI to writable and continues mirroring on top of it.

Processing inactive subtrees before the active continuation also bounds the number
of simultaneously-attached destination VDIs to `O(depth of nesting)` rather than
`O(number of branches)`: each inactive branch's clone, datapath, NBD socket and
QEMU mirror job are torn down before the next branch starts.

### Migration phases

#### Phase 1: Snapshot tree discovery

```
Input:  the active VDI ref of the disk to be migrated

  1. Find the live VM that owns the VDI (via VDI.VBDs, filtering out
     VBDs whose VM is a snapshot).
  2. On that live VM, find the VBD pointing at the VDI and read its
     userdevice (e.g. "0"). This is the disk identity used for projection.
  3. Enumerate all snapshot VMs of the live VM (snapshot_of = live VM).
  4. Reconstruct the snapshot VM tree from each snapshot VM's
     parent / children pointers.
  5. Walk VM.parent upward from the live VM and record every snapshot
     VM encountered; this is the active-path membership set.
  6. Project each snapshot VM onto the userdevice slot: for each snapshot
     VM, find the VBD with the same userdevice; that VBD's VDI is the
     snapshot for this disk at that point. Snapshot VMs that do not
     contain the disk (e.g. the disk was hot-unplugged when the snapshot
     was taken) are transparently skipped, and their disk-bearing
     descendants are promoted to take their place, so no snapshot data
     is dropped from the tree.

Output: snapshot_tree_node tree, where each node carries
  { vdi_uuid; snapshot_time; on_active_path; children }
  with roots (VM.parent = null) ordered by snapshot_time ascending.
```

Concrete example: live VM has snapshots `snap1`, then `snap2`; user reverts to
`snap1` and takes `snap3` followed by `snap4`. The discovered tree is:

```
snap1 (on_active_path = true, oldest)
├── snap2 (on_active_path = false)   ← the original line, orphaned by revert
└── snap3 (on_active_path = true)
    └── snap4 (on_active_path = true, parent of live VM)
```

#### Phase 2: DFS tree traversal

For each root, recurse. At every node `N` with current working VDI `W`:

```
process_node(N, W):

  ── Mirror & anchor ──────────────────────────────────────────────
  1. Start an NBD proxy targeting W on the destination.
  2. QEMU mirror from N.vdi into W (one-shot, wait for completion).
  3. dest_snapshot ← Remote.VDI.snapshot(W)
  4. Record (N.vdi, dest_snapshot.vdi, N.snapshot_time) in the
     mirror-id-keyed mapping table.

  ── Partition children ───────────────────────────────────────────
  5. inactive_children := children where on_active_path = false
     active_children   := children where on_active_path = true   (≤ 1)

  ── Recurse into inactive subtrees ───────────────────────────────
  6. For each child in inactive_children:
       branch_vdi ← Remote.VDI.clone(dest_snapshot)
       attach branch_vdi read-only, build NBD URI
       process_node(child, branch_vdi)
       deactivate / detach / destroy branch_vdi

  ── Recurse into the active continuation ─────────────────────────
  7. For the (single) child in active_children:
       process_node(child, W)        ← same working VDI, unchanged
```

Worked trace for the example above, with `mirror_vdi` as the initial working VDI:

```
Step  Operation                                         working_vdi
────  ──────────────────────────────────────────────────  ─────────────
 1    mirror snap1  ─→ working_vdi                      mirror_vdi
 2    VDI.snapshot working_vdi  ─→ dest_snap_1          mirror_vdi
 3    clone(dest_snap_1) ─→ branch_v2; attach readonly  branch_v2
 4    mirror snap2  ─→ branch_v2                        branch_v2
 5    VDI.snapshot branch_v2 ─→ dest_snap_2             branch_v2
 6    destroy branch_v2                                 (gone)
 7    mirror snap3  ─→ working_vdi                      mirror_vdi
 8    VDI.snapshot working_vdi ─→ dest_snap_3           mirror_vdi
 9    mirror snap4  ─→ working_vdi                      mirror_vdi
10    VDI.snapshot working_vdi ─→ dest_snap_4           mirror_vdi
```

After step 10, `working_vdi` is the original `mirror_vdi`, sitting at the deepest
active-path snapshot (snap4). The destination's storage-layer topology mirrors the
source: a main chain from base through `dest_snap_1 → dest_snap_3 → dest_snap_4`
plus a side branch `dest_snap_2` hanging off the `dest_snap_1` anchor. The mapping
table accumulated during the walk is:

```
snap1 ↔ dest_snap_1   (snapshot_time T1)
snap2 ↔ dest_snap_2   (snapshot_time T2)
snap3 ↔ dest_snap_3   (snapshot_time T3)
snap4 ↔ dest_snap_4   (snapshot_time T4)
```

#### Phase 3: Live leaf mirroring

Identical to the pre-existing SMAPIv3 design, with one extra wrapper. Because Phase
2 ran with `mirror_vdi` activated read-only (snapshots are read-only operations),
we switch it back to writable before starting the live mirror:

```
Remote.VDI.deactivate dbg mirror_datapath dest_sr mirror_vdi mirror_vm
Remote.VDI.activate3  dbg mirror_datapath dest_sr mirror_vdi mirror_vm
```

Then we start the NBD proxy and call `Local.DATA.mirror` against the live VM's leaf
VDI exactly as before. Because Phase 2's recursion left `mirror_vdi` correctly
positioned, the live mirror lands on top of the full chain without any explicit
splicing step.

#### Phase 4: Metadata restoration

After the live leaf mirror reaches the "complete" state, the orchestrator in
`xapi_vm_migrate.ml` retrieves the recorded mappings and applies them to the
destination:

```
1. relations ← State.get_snapshot_mappings mirror_id          (in xapi_vm_migrate)
2. SMAPI.SR.set_snapshot_relations dbg dest_sr
       [(snap_dest, leaf_dest, time); ...]                   (new RPC)
   The mux-layer implementation iterates the list and, for each entry:
     - Db.VDI.set_snapshot_of  ~self:snap_dest ~value:leaf_dest
     - Db.VDI.set_snapshot_time ~self:snap_dest ~value:time
     - Db.VDI.set_is_a_snapshot ~self:snap_dest ~value:true
     - VDI.set_snapshot_metadata (RPC into the storage backend, so the
       backend's own custom-keys store also reflects the new relations)
3. For each (src snapshot, dest snapshot) pair, build a per-snapshot
   mirror record and let xapi's existing per-VDI continuation update the
   snapshot VMs' VBDs to point at the destination snapshot VDIs.
4. State.remove_snapshot_mappings mirror_id   (free the temporary state)
```

The destination ends up with a fully populated snapshot tree, both in the XAPI
database and in the underlying storage backend, with all snapshot VMs' VBDs
pointing at the right VDIs.

### Complete migration flow

```
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 1: SNAPSHOT TREE DISCOVERY                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Live VM ─→ VBD (userdevice = "0")                                  │
│             ↓                                                       │
│  Enumerate snapshot VMs of the live VM                              │
│  Project each snapshot VM onto userdevice "0"                       │
│  Reconstruct parent/children topology                               │
│  Mark active-path nodes by walking VM.parent from live VM           │
│                                                                     │
│  Result (revert example):                                           │
│                                                                     │
│      snap1 ─┬─ snap2  (inactive, reverted-orphan branch)            │
│             └─ snap3 ─ snap4  (active path → live VM)               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 2: DFS TREE TRAVERSAL                                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  At each node: mirror → snapshot (anchor)                           │
│  At each branch: clone anchor for inactive subtrees                 │
│  Active continuation: same working VDI (mirror_vdi)                 │
│                                                                     │
│  Source                       Destination                           │
│  ──────                       ───────────                           │
│  snap1   ── mirror   ──→   mirror_vdi  ─ snapshot ─→ dest_snap_1    │
│                                                          │ clone    │
│                                                          ▼          │
│  snap2   ── mirror   ──→   branch_v2   ─ snapshot ─→ dest_snap_2    │
│                            (then destroyed)                         │
│  snap3   ── mirror   ──→   mirror_vdi  ─ snapshot ─→ dest_snap_3    │
│  snap4   ── mirror   ──→   mirror_vdi  ─ snapshot ─→ dest_snap_4    │
│                                                                     │
│  Mapping table accumulated:                                         │
│    snap1↔dest_snap_1, snap2↔dest_snap_2,                            │
│    snap3↔dest_snap_3, snap4↔dest_snap_4                             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 3: LIVE LEAF MIRROR                                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  switch mirror_vdi: readonly → writable                             │
│  V1 (live) ── continuous QEMU mirror ──→ mirror_vdi (becomes V1')   │
│                                                                     │
│  Destination chain at end of Phase 3:                               │
│    V1'  → dest_snap_4 → dest_snap_3 → dest_snap_1 → base            │
│         (and dest_snap_2 hanging off dest_snap_1 as a side branch)  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 4: METADATA RESTORATION                                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  SR.set_snapshot_relations:                                         │
│    for each (snap_dest, leaf_dest, time):                           │
│      Db.VDI.set_snapshot_of  / snapshot_time / is_a_snapshot        │
│      VDI.set_snapshot_metadata  (persist into backend store too)    │
│                                                                     │
│  xapi: update each snapshot VM's VBD to point at the                │
│        corresponding destination snapshot VDI.                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

Final state on destination — both data AND topology preserved:

    V1' (live leaf)
     ↑
     ├─→ dest_snap_4 (Snapshot VM "snap4")   ✓
     ├─→ dest_snap_3 (Snapshot VM "snap3")   ✓
     ├─→ dest_snap_2 (Snapshot VM "snap2")   ✓  ← reverted branch preserved
     └─→ dest_snap_1 (Snapshot VM "snap1")   ✓
```

The result is that users experience seamless migration of VMs with snapshots —
including those with revert history — with all snapshot functionality fully
preserved on the destination host: snapshot VMs can boot, snapshot trees can be
inspected, and the user can still revert to any snapshot after migration.

## Implementation Approach

This section describes how the snapshot migration mechanism integrates into the existing SMAPIv3 migration code. The implementation touches several layers of the storage stack, from the RPC interface down to the migration orchestration logic.

### Storage Interface Layer

A new RPC call, `SR.set_snapshot_relations`, is added in `storage_interface.ml` for
restoring snapshot relationships after migration. It follows the same shape as the
pre-existing `SR.update_snapshot_info_dest` operation but is simpler: it takes a
list of `(snapshot_vdi, leaf_vdi, snapshot_time_string)` tuples. After xapi
finishes mirroring the whole snapshot tree, it calls this RPC once with the full
mapping list, telling the destination storage layer "these VDIs on the destination
are snapshots of that leaf VDI, taken at these times."

### Storage Multiplexer Layer

The actual implementation of `SR.set_snapshot_relations` goes in `storage_mux.ml`.
For each entry in the relations list, the mux:

```ocaml
Db.VDI.set_snapshot_of   ~__context ~self:snapshot_ref ~value:leaf_ref
Db.VDI.set_snapshot_time ~__context ~self:snapshot_ref ~value:timestamp
Db.VDI.set_is_a_snapshot ~__context ~self:snapshot_ref ~value:true
update_backend_snapshot_metadata ~dbg sr snapshot leaf snapshot_time
```

The first three lines update XAPI's own VDI metadata so that the destination pool
immediately knows the topology. The fourth line is a best-effort call into the
storage backend (`VDI.set_snapshot_metadata`) that pushes the same three fields
into the backend's custom-keys store, so the backend's own bookkeeping stays in
sync with XAPI's view. The backend call is wrapped in try/catch and only logged
on failure: data has already been migrated successfully, and the XAPI-level
relations are sufficient for the user-visible snapshot tree to function.

### Storage Migration Helper

During migration we need to temporarily stash the (src snapshot, dest snapshot,
snapshot time) tuples between the moment they are produced (inside `send_start`
in `storage_smapiv3_migrate.ml`) and the moment they are consumed (inside the
per-VDI continuation in `xapi_vm_migrate.ml`). The `storage_migrate_helper.ml`
module already protects existing mirror state with a mutex, so we add a parallel
hashtable using the same pattern:

```ocaml
type snapshot_relation = {
    src_vdi: Storage_interface.Vdi.t
  ; dest_vdi: Storage_interface.Vdi.t
  ; snapshot_time: string
}

let snapshot_mappings : (string, snapshot_relation list) Hashtbl.t
```

The key is the mirror ID and the value is the list of relations produced for that
mirror. Three small functions wrap the hashtable: `set_snapshot_mappings` to
store, `get_snapshot_mappings` to retrieve, and `remove_snapshot_mappings` to
clean up. All three take the module-level `mutex`.

### SMAPIv3 Migration Logic

This is where most of the work lives. The file `storage_smapiv3_migrate.ml`
contains the `MIRROR` module that drives the actual send-side mirror flow. The
implementation is organised as three layers, all in this one file.

#### Tree builder (Phase 1)

A small set of pure functions builds the snapshot tree from the XAPI database:

- `find_active_vm_for_vdi`: given the migrating VDI ref, find the live (non-snapshot)
  VM that has it attached.
- `find_userdevice_for_vdi`: read the `userdevice` of the live VM's VBD that
  references this VDI — this is the disk slot used to project snapshot VMs.
- `find_snapshot_vdi_by_userdevice`: on a snapshot VM, locate the VBD with the
  same userdevice and return the snapshot VDI it points at, together with the
  snapshot time in ISO8601 (`Date.to_rfc3339`).
- `build_active_path_predicate`: walks `VM.parent` upward from the live VM and
  returns a `Ref.t -> bool` membership predicate for the active path.
- `build_subtree_for_userdevice`: recursively constructs the tree from a root
  snapshot VM, sorted by snapshot_time ascending. When a snapshot VM does not
  contain the disk slot, it is dropped and its disk-bearing descendants are
  promoted to take its place.
- `get_snapshot_tree`: the top-level entry that wires the above together inside
  a `Server_helpers.exec_with_new_task` and returns a list of root
  `snapshot_tree_node` values.

The `snapshot_tree_node` type encodes the projection of one VM-level snapshot
tree onto one disk slot:

```ocaml
type snapshot_tree_node = {
    vdi_uuid: string
  ; snapshot_time: string
  ; on_active_path: bool
  ; children: snapshot_tree_node list
}
```

#### Mirror-and-anchor primitive

A few helpers package up the per-node steps so the DFS code itself stays small:

- `attach_snapshot_vdi` / `detach_snapshot_vdi`: attach a source snapshot VDI
  read-only on the source for the duration of the mirror.
- `wait_for_mirror`: polls `DATA.stat` for completion / failure with a fixed
  interval (`mirror_poll_interval`).
- `create_destination_snapshot`: calls `Remote.VDI.snapshot` on the destination
  to anchor whatever data currently lives in the working VDI.
- `mirror_snapshot_into_existing_dest`: the full per-node mirror sequence —
  attach source readonly, start the QEMU mirror, wait for completion, detach
  source, then `create_destination_snapshot`. Returns the destination snapshot
  VDI info.
- `prepare_branch_vdi`: produces a fresh working VDI for an inactive subtree by
  cloning a destination snapshot (`Remote.VDI.clone`), attaching it read-only,
  building its NBD URI, and returning a cleanup thunk that detaches and destroys
  the clone after the subtree finishes.
- `mirror_node_into`: wraps `mirror_snapshot_into_existing_dest` so each node
  becomes a single call that returns both the destination snapshot info and a
  `State.snapshot_relation` record.

All of these take their shared parameters via a `mirror_ctx` record so that the
DFS function below has a small, readable signature.

#### DFS processor (Phase 2)

```ocaml
let rec dfs_process_node ~ctx ~working_vdi ~working_dp ~nbd_uri ~counter
    ~total node =
  let dest_snapshot, this_relation =
    mirror_node_into ~ctx ~working_vdi ~working_dp ~nbd_uri ~counter ~total node
  in
  let inactive_children, active_children =
    List.partition (fun c -> not c.on_active_path) node.children
  in
  let inactive_relations =
    List.concat_map (fun child ->
      let branch_vdi, branch_dp, branch_nbd_uri, cleanup =
        prepare_branch_vdi ~ctx ~dest_snapshot
      in
      let rels =
        try
          dfs_process_node ~ctx ~working_vdi:branch_vdi ~working_dp:branch_dp
            ~nbd_uri:branch_nbd_uri ~counter ~total child
        with e -> (try cleanup () with _ -> ()) ; raise e
      in
      cleanup () ; rels
    ) inactive_children
  in
  let active_relations =
    List.concat_map (fun child ->
      dfs_process_node ~ctx ~working_vdi ~working_dp ~nbd_uri ~counter
        ~total child
    ) active_children
  in
  this_relation :: (inactive_relations @ active_relations)
```

The partition + inactive-first ordering is what gives the design its two key
properties: (a) the original `mirror_vdi` is never aliased into a non-active
subtree, so the active continuation always lands on it, and (b) the cleanup of
each inactive subtree's branch VDI runs before the next branch starts.

#### `send_start` integration

`send_start` calls `get_snapshot_tree` immediately after `VDI.attach3`. If the
tree is empty (no snapshots), the existing leaf-only fast path runs unchanged.
Otherwise:

1. `switch_vdi_to_readonly ~mirror_vdi` — deactivate + re-activate in read-only
   mode so the destination VDI can be safely snapshotted by Phase 2.
2. `List.concat_map (dfs_process_node ~working_vdi:mirror_vdi ...) snapshot_tree`
   — walk every root depth-first and collect a flat list of
   `snapshot_relation` records.
3. `switch_vdi_to_writable ~mirror_vdi` — deactivate + `activate3` so the live
   leaf mirror in Phase 3 has a writable target.
4. Start the NBD proxy for the leaf, call `Local.DATA.mirror`, register the
   send-side state, and `wait_for_mirror`.
5. `State.set_snapshot_mappings mirror_id snapshot_relations` so the
   orchestrator in `xapi_vm_migrate.ml` can pick them up after the live mirror
   reaches the complete state.

Note that the destination VDI created by `receive_start3` is activated writable;
the readonly/writable transitions are owned by the **send** side via the two
`switch_vdi_to_*` helpers, not by the receive side. This keeps `receive_start3`
identical to the snapshot-free path.

### VM Migration Orchestration

The `xapi_vm_migrate.ml` file orchestrates the overall VM-level migration. Two
integration points are needed.

**Inside `vdi_copy_fun`**, after the per-VDI mirror reaches the complete state,
the code retrieves the recorded snapshot mappings by mirror ID, makes the new
`SR.set_snapshot_relations` RPC call against the destination, builds a
per-snapshot mirror record for each (src, dest) pair so xapi's existing
continuation can rewrite the snapshot VMs' VBD references, and finally removes
the mapping table entry:

```ocaml
let snapshot_relations = get_snapshot_relations mirror_id in
call_set_snapshot_relations ~dest_sr ~leaf_vdi:remote_vdi snapshot_relations ;
let snapshot_mirror_records =
  List.filter_map create_snapshot_mirror_record snapshot_relations
in
let result = post_mirror mirror_id mirror_record in
List.iter (fun mr -> ignore (continuation mr)) snapshot_mirror_records ;
Option.iter Storage_migrate_helper.State.remove_snapshot_mappings mirror_id ;
result
```

**Inside `migrate_send'`**, the `extra_vdis` list traditionally bundled both
suspend VDIs and snapshot VDIs together so they would be copied alongside the
main mirror. With the new mechanism, SMAPIv3 snapshots are already migrated by
the DFS path and must *not* be copied again — doing so would create a parallel,
unrelated chain on the destination. The fix is a per-snapshot filter that
excludes snapshot VDIs sitting on SMAPIv3 SRs from the explicit copy list,
while suspend VDIs and SMAPIv1 snapshot VDIs continue to be copied as before:

```ocaml
let copyable_snapshots =
  List.filter
    (fun vconf -> Storage_mux_reg.smapi_version_of_sr vconf.sr <> SMAPIv3)
    snapshots_vdis
in
let extra_vdis = suspends_vdis @ copyable_snapshots in
```

The filter is per-VDI rather than a single global flag, so mixed-SR scenarios
(some snapshots on SMAPIv3, some on SMAPIv1) keep working without special-casing.

### Skeleton and Wrapper Layers

The RPC plumbing needs stubs in `storage_skeleton.ml` and forwarding logic in `storage_smapiv1_wrapper.ml`. Just follow what `update_snapshot_info_dest` does - these are mechanical changes.

## Additional Implementation Fixes

Two additional issues were identified and resolved during implementation to ensure correct and performant snapshot migration.

### Snapshot metadata consistency for SMAPIv1 to SMAPIv3 migration

When migrating from SMAPIv1 SR to SMAPIv3 SR, snapshot metadata fields (`snapshot_of`, `snapshot_time`, `is_a_snapshot`) were not properly synchronized between the XAPI database and the storage backend database. The migration only updated XAPI's database through `SR.scan`, leaving the storage backend with stale or missing metadata.

It can be easied verified by query the `snapshot_of` fields by XAPI CLI `xe vdi-param-get uuid=<SNAPSHOT VDI uuid> param-name=<snapshot-of>` and query the from gfs2 db with SQL `SELECT * FROM vdi_custom_keys where vdi_uuid='<SNAPSHOT VDI UUID>';` the snapshot_of in the xapi output is the latest one but in the storage db it is legacy. and moreover, when query the by XAPI CLI `xe vdi-param-get uuid=<LEAF VDI uuid> param-name=<snapshots>`, it will output one more snapshot more thant the actually snapshots, which the dummy VDI create during mirror but not clean-up, so it should removed as well.

To Adress above issues, there is one more API should be added to the xapi_storage_script, and two more step should be added to the migrate process

1. Add the new API `set_snapshot_metadata` which receive the VDI, snapshot_of, snapshot_time, is_snapshot parameter and set to the backend.

1. Add one step when update dest snapshot info, call the `set_snapshot_metadata` API to update the backend as well

```ocaml
  let set_snapshot_metadata ~dbg ~sr ~vdi ~snapshot_of ~snapshot_time ~is_a_snapshot =
    let vdi_str = Storage_interface.Vdi.string_of vdi in
    let snapshot_of_str = Storage_interface.Vdi.string_of snapshot_of in
    set ~dbg ~sr ~vdi:vdi_str ~key:_snapshot_of_key ~value:snapshot_of_str
    >>>= fun () ->
    set ~dbg ~sr ~vdi:vdi_str ~key:_snapshot_time_key ~value:snapshot_time
    >>>= fun () ->
    set ~dbg ~sr ~vdi:vdi_str ~key:_is_a_snapshot_key ~value:(string_of_bool is_a_snapshot)
```

2. During `receive_finalize_common` in SMAPIv1 migration, add `SMAPI.SR.scan` to move all the necessary VDI and relationships as well.

```ocaml
Server_helpers.exec_with_new_task "SR.scan after migration finalize" (fun __context ->
  let sr_uuid = Sr.string_of r.sr in
  let sr_ref = Db.SR.get_by_uuid ~__context ~uuid:sr_uuid in
  Helpers.call_api_functions ~__context (fun rpc session_id ->
    Client.Client.SR.scan ~rpc ~session_id ~sr:sr_ref
  )
)
```

This ensures snapshot metadata consistency across both XAPI and storage backend databases, allowing proper snapshot functionality after migration and correct removal of temporary migration VDIs.

### Mirror polling optimization

During SMAPIv3 mirror operations, `DATA.stat` was repeatedly calling `VDI.stat` → `Volume.stat` for each polling cycle to determine the correct datapath for RPC routing. This created a hard loop where hundreds of `Volume.stat` calls per second blocked storage GC.

The datapath information doesn't change during a mirror operation, but `DATA.stat` re-discovered it on every poll. This prevented the storage backend's GC from coalescing VDI data, leading to storage space issues and performance degradation.

Implement a lightweight cache in `xapi-storage-script/main.ml` that stores VDI stat responses keyed by `(SR, VDI)`:

```ocaml
let vdi_stat_cache = Hashtbl.create 16

let stat dbg sr vdi' _vm key =
  ...
  match Hashtbl.find_opt vdi_stat_cache cache_key with
  | Some cached_response ->
      (* Use cached response - no Volume.stat needed *)
      return cached_response
  | None ->
      (* Cache miss - call VDI.stat once *)
      VDI.stat ~dbg ~sr ~vdi >>>= fun response ->
      ...
```

The cache is populated when `DATA.mirror` starts and reused by subsequent `DATA.stat` polls. When the mirror completes or fails, the cache entry is automatically removed. This reduces `Volume.stat` calls from hundreds per second to a single call per mirror operation, allowing GC to complete normally.


### Error Handling

Snapshot discovery failures should log but return an empty list, letting the migration proceed without snapshots. If a snapshot mirror fails, stop immediately with a clear error - we don't want partial snapshot migration. Metadata restoration failures get logged as warnings but don't block the migration, since the data is already copied. VBD updates are best-effort per snapshot. Cleanup operations use try-catch and never raise errors.
