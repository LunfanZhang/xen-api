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
  - [The approach in one paragraph](#the-approach-in-one-paragraph)
  - [A worked example](#a-worked-example)
  - [Walking through the migration](#walking-through-the-migration)
  - [Design notes](#design-notes)
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

                V1 (original base)
               /  \
              V2   S1 (snapshot, taken at T2)
             /  \ 
    (leaf) V3    S2 (snapshot, taken at T1)

Snapshot Chain (XAPI's View):
      S1 (snapshot of S2) → S2 (snapshot of V3) → V3 (leaf) 
``` 

In this structure:
- `V3` is the current leaf VDI (writable, receiving new writes 
  from the running VM) and sits on top of `V2` (intermediate parent), which sits on top 
  of `V1` (the original base). Snapshots `S1` and `S2` branch off from intermediate points 
  in this chain. This parent-child structure exists in the storage backend but is not 
  visible to XAPI.
- XAPI can only see the leaf and its snapshots, not the parent nodes V2 and V1 which are hidden nodes.
- To read full bootable data from disk, the backend must traverse 
  from leaf to base: `V3` → `V2` → `V1`, with snapshots branching off at intermediate points.

The nested storage structure represents the actual VDI parent-child relationships in 
the storage backend (not visible to XAPI), while the snapshot chain represents XAPI's 
view of the leaf and its snapshots. During migration, XAPI works with the snapshot chain 
to ensure all snapshot data and metadata are preserved, even though it cannot see the 
underlying storage hierarchy. The key challenge is that the backend's storage chain 
(`V3` → `V2` → `V1`) must be faithfully reproduced on the destination for snapshots 
to remain functional after migration.

### Loss of snapshot bases

The original SMAPIv3 migration mechanism was designed for live VM migration, mirroring 
the active leaf VDI. When a VM with snapshots was migrated, XAPI would transfer the 
visible VDIs (leaf and snapshots) but the underlying storage hierarchy, especially the chain between each node and its parent was not preserved.

When a VM with snapshots was migrated, the following occurred:

```
Original SMAPIv3 Migration:

Source SR                           Destination SR
---------                           --------------

      V1                                        V1`
     /  \                                         \ 
    V2   S1 ------copy-------→               V2`   S1' (copied)
   /  \                                        \ 
 V3   S2  ------copy------→              V3'    S2' (copied)
  │
  └──mirror  ----------→

What gets transferred:
  V3 (leaf) -----mirrored-----→  V3'
  S1 (snapshot) -----copied-----→   S1'
  S2 (snapshot) -----copied-----→   S2'

What is LOST:
  chain between leaf V3` and V2` - not transferred
  chain between V2` and V1` - not transferred
```

The critical problem is that While `V3` (leaf) is mirrored and `S1`, `S2` (snapshots) are 
copied to the destination, the parent-child chain between each node is not recreated which results in several separate trees in the dest SR. This breaks the storage structure because, the snapshots S1' and S2' on the destination have no parent nodes to reference. The storage backend expects the nested hierarchy but only receives isolated VDIs.

Although `V3`, `V2` and `V1` physically exist on the destination, they cannot function properly without the chain for base nodes they depend on, assume for the leaf it is only some delta inside.

This creates several serious issues: Even though `V3`, `V2` and `V1` exist on the destination,  the missing parent-child chain breaks the storage backend's nested hierarchy. The backend cannot properly traverse the VDI dependencies, so during the VM start-up, the data-path cannot fetch the full disk data (only gets the delta in the leaf), so naturally, the VM fails to start when it boots. The critical issue is that the migration appears successful with no error report, and since the chain is lost, there is no way to rollback.

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
                V1 (original base)
               /  \
              V2   S1
             /  \ 
     (leaf)V3   S2

Step 1: Copy snapshot to Destination
   copy S1 S2 into the destination SR, when copying, it will try to find the similar VDI in the destination SR, if found, it will use the similar VDI, if not, it will create a new VDI.
   
   The copying process (using sparse_dd) reads all blocks and flattens them into a 
   complete image on the destination.

Step 2: mirror the leaf to the destination
   during mirror, the first step is take the snapshot base on the leaf. it turn the nested storage into below:
   before mirror:
                V1 (original base)
               /  \
              V2   S1
             /  \ 
           V3`   S2
          /  \
   (leaf) V3  dummy (snapshot for migration)

   - mirror the leaf V3 to the destination.
   - copy the dummy to the destination.
   - compose the snapshot.

Step 3: Result on Destination
                             V1 (original base)
                           /  \
             V2`          V2   S1
           /               \ 
         V3               S2
   
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

This topology is functionally correct, and the VM can still run normally. The main side effect is reduced space efficiency, especially after multiple migrations.

## New SMAPIv3 Migration Mechanism

### The approach in one paragraph

The fix is straightforward in spirit: **mirror the entire snapshot tree, not just
the leaf**. We keep the existing NBD-backed QEMU mirror — it already works well
for a single VDI — and apply it once per snapshot, walking the snapshot tree
depth-first. After mirroring each snapshot's data into a destination VDI, we ask
the destination SR to take a snapshot of that VDI, which anchors the data into
a real parent on the destination chain. The mirrored leaf at the end naturally
inherits this chain as its base, so the destination ends up with exactly the
same parent-child topology as the source. A small piece of metadata (the
mapping from source snapshot VDIs to destination snapshot VDIs) is sent over at
the end so XAPI's database and the backend's own bookkeeping both reflect the
new layout.

### A worked example

We will use one running example throughout the rest of this section. A user
takes two snapshots, then **reverts** to the first one and takes two more:

```
Action timeline                      Resulting snapshot tree

  T1: take snap1                            snap1
  T2: take snap2                           /     \
  T3: revert to snap1                  snap2    snap3
  T4: take snap3                                  |
  T5: take snap4                                snap4
  T6: VM keeps running                            |
                                                live
```

Two things to notice:

- The tree has a **branch** at `snap1`. `snap2` belongs to the original line
  that was abandoned by the revert; `snap3 → snap4 → live` is the active line
  the running VM is on today.
- XAPI models this branching via each snapshot VM's `parent` / `children`
  pointers. Walking `VM.parent` upward from the live VM gives the active path
  (`snap4 → snap3 → snap1`); every snapshot VM not on that walk is on a
  reverted side branch.

The source storage backend reproduces the same shape one level down, as a tree
of VDIs with `snap1`'s VDI as the shared base for both branches. The goal of
migration is to reproduce *that* tree on the destination.

### Walking through the migration

Migration runs in four phases. We describe each in terms of the example above.

**Phase 1 — Discover the snapshot tree.** We need to know which destination
VDIs to create and how they should be related. Starting from the disk being
migrated, we find the live VM that owns it, read the VBD `userdevice` (the disk
slot, e.g. `"0"`), then enumerate all of the live VM's snapshot VMs. Projecting
each snapshot VM onto the same `userdevice` slot gives us the snapshot VDI for
that disk at that point in history. The `parent` / `children` pointers among
the snapshot VMs give us the tree shape, and a single walk of `VM.parent`
upward from the live VM marks which nodes are on the active path.

For our example, the result is:

```
snap1   (active path)
├── snap2   (inactive — orphaned by the revert)
└── snap3   (active path)
    └── snap4   (active path, immediate parent of the live VM)
```

**Phase 2 — Mirror the tree.** We walk the tree depth-first, carrying along a
*working VDI* on the destination. The working VDI starts as `mirror_vdi`,
the destination VDI returned by `receive_start3` for the live leaf. At each
node we do the same two things:

1. Run a one-shot QEMU mirror from the node's source snapshot VDI into the
   working VDI.
2. Ask the destination SR to take a snapshot of the working VDI. The newly
   created destination snapshot serves two purposes at once: it records the
   mirrored data as a real VDI on the destination chain, and it acts as a
   stable anchor that we can clone if this node turns out to be a branch
   point.

When a node has more than one child (a branch point, caused by a revert), we
**recurse into the inactive subtrees first, on a clone of the anchor**, and
into the active continuation **last, on the same working VDI**. The clone is
torn down as soon as its subtree finishes. This way the working VDI never
leaves the active path, so when the recursion bottoms out it is still
`mirror_vdi`, sitting on top of the deepest active-path snapshot — ready for
the live mirror to take over. No "splice" or rename step is required.

Applied to our example, with `W` denoting the working VDI:

| Step | Source                | Operation                         | W after step           |
| ---- | --------------------- | --------------------------------- | ---------------------- |
| 1    | `snap1`               | mirror → `W`; snapshot → `D1`     | `mirror_vdi`           |
| 2    | (clone `D1`)          | clone, attach                     | `branch_vdi`           |
| 3    | `snap2`               | mirror → `W`; snapshot → `D2`     | `branch_vdi`           |
| 4    |                       | destroy `branch_vdi`              | `mirror_vdi`           |
| 5    | `snap3`               | mirror → `W`; snapshot → `D3`     | `mirror_vdi`           |
| 6    | `snap4`               | mirror → `W`; snapshot → `D4`     | `mirror_vdi`           |

At the end the destination has the chain `D1 → D3 → D4 ← mirror_vdi` plus
`D2` hanging off `D1` — the exact shape of the source tree. We also kept a
table of `(source snapshot VDI, destination snapshot VDI, snapshot time)`
tuples that Phase 4 will need.

**Phase 3 — Mirror the live leaf.** This is the original SMAPIv3 flow, with
one small wrapper. The snapshots in Phase 2 were taken while `mirror_vdi` was
attached read-only; we now flip it back to writable and run the continuous
QEMU mirror from the running VM's leaf into `mirror_vdi`, exactly as before.
Because Phase 2 left `mirror_vdi` positioned on the correct chain, the live
mirror lands on top of a complete base — no separate splicing step.

**Phase 4 — Restore metadata.** Snapshot VDIs exist on the destination, but
the destination SR does not yet know they are snapshots. We send the mapping
table accumulated in Phase 2 to the destination via a new RPC,
`SR.set_snapshot_relations`, which for each entry sets `snapshot_of`,
`snapshot_time` and `is_a_snapshot` in the XAPI database *and* pushes the same
fields into the backend's own custom-keys store. Finally, the orchestrator
in `xapi_vm_migrate.ml` updates each snapshot VM's VBD to reference the
destination snapshot VDI. The destination now has both the data and the
topology, in both XAPI and the storage backend, and the snapshot tree is
fully usable: snapshots can be inspected, booted, and reverted to.

### notes

Two non-obvious choices are worth to be mentioned:

- **Disk identity by `userdevice`, not `snapshot_of`.** A snapshot VDI's
  `snapshot_of` points at the active VDI that existed at the time the snapshot
  was taken; a revert destroys that VDI, so pre-revert snapshots end up
  pointing at a stale ref. The VBD `userdevice` (disk slot inside the VM)
  survives reverts, so it is the reliable way to follow "the same disk" across
  the snapshot VM tree.

- **DFS, inactive-first, active-last.** Processing inactive subtrees before
  the active continuation is what lets us reuse `mirror_vdi` as the working
  VDI for the whole active path: each inactive branch comes and goes on a
  short-lived clone, and `mirror_vdi` is never displaced. It also bounds the
  number of simultaneously-attached destination VDIs to `O(tree depth)`
  rather than `O(branch count)`.

## Implementation Approach

The implementation follows the four-phase flow described above and is spread
across four files. Roughly:

| File                                            | Role                                                                                                  |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `ocaml/xapi/storage_smapiv3_migrate.ml`         | Send-side: builds the snapshot tree, runs the DFS, mirrors each node, anchors with a dest snapshot.   |
| `ocaml/xapi/storage_migrate_helper.ml`          | Shared state: a small mutex-protected table that carries snapshot mappings between sender and caller. |
| `ocaml/xapi-idl/storage/storage_interface.ml`   | Adds one new RPC, `SR.set_snapshot_relations`, used by xapi to push the final mapping to the dest SR. |
| `ocaml/xapi/storage_mux.ml`                     | Implements `SR.set_snapshot_relations` in the receive-side mux.                                       |
| `ocaml/xapi/xapi_vm_migrate.ml`                 | Top-level orchestration: invokes the RPC after the leaf mirror completes and remaps snapshot-VM VBDs. |

The rest of this section walks the code in the order data flows through it.

### Send side: snapshot tree mirroring

All of the new send-side work lives in `storage_smapiv3_migrate.ml` and is
organised in three logical layers, all called from `send_start`.

**Building the tree.** A handful of small pure functions translate the design's
"project all snapshot VMs onto one disk slot" idea into code:

- `find_active_vm_for_vdi` — find the live (non-snapshot) VM that owns the
  migrating VDI.
- `find_userdevice_for_vdi` — read the live VM's VBD `userdevice` for that
  VDI; this is the disk slot used everywhere below.
- `find_snapshot_vdi_by_userdevice` — on a snapshot VM, locate the VBD with
  the same userdevice and return the snapshot VDI it points at, together with
  its snapshot time (formatted via `Date.to_rfc3339`).
- `build_active_path_predicate` — walks `VM.parent` upward from the live VM
  and returns a `Ref.t -> bool` membership predicate.
- `build_subtree_for_userdevice` — recursively builds the tree from a root
  snapshot VM, sorted by snapshot time. Snapshot VMs that do not contain the
  disk slot (e.g. the disk was hot-unplugged when the snapshot was taken) are
  transparently skipped and their disk-bearing descendants are promoted.
- `get_snapshot_tree` — top-level entry that wires the above together inside
  a `Server_helpers.exec_with_new_task` and returns a list of root nodes.

Each node is a `snapshot_tree_node`:

```ocaml
type snapshot_tree_node = {
    vdi_uuid: string
  ; snapshot_time: string
  ; on_active_path: bool
  ; children: snapshot_tree_node list
}
```

**Mirror-and-anchor primitives.** The per-node work (attach source, run a
one-shot QEMU mirror, wait for it, take a destination snapshot, detach source)
is packaged behind a few helpers so the DFS itself stays small:

- `attach_snapshot_vdi` / `detach_snapshot_vdi` — attach/detach a source
  snapshot VDI read-only on the source side for the duration of the mirror.
- `wait_for_mirror` — polls `DATA.stat` for completion/failure at a fixed
  interval.
- `create_destination_snapshot` — calls `Remote.VDI.snapshot` on the
  destination to anchor whatever data is in the working VDI. It also
  propagates the source `content_id` onto the new destination snapshot (see
  the [content_id fix](#propagating-content_id-from-source-snapshots-to-destination-snapshots)
  below).
- `mirror_snapshot_into_existing_dest` — the full per-node sequence: attach
  source readonly, start the mirror, wait, detach source, then anchor.
- `prepare_branch_vdi` — for an inactive subtree: clones the just-created
  destination anchor, attaches the clone read-only, builds its NBD URI, and
  returns a cleanup thunk that detaches and destroys the clone when the
  subtree is finished.
- `mirror_node_into` — wraps `mirror_snapshot_into_existing_dest` so each
  node call returns both the destination snapshot info and a
  `State.snapshot_relation` record.

All of these accept a shared `mirror_ctx` record so the DFS function below
has a small signature.

**The DFS itself.** This is the only piece of new logic that is non-trivial,
and it is a direct translation of the design:

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
        try dfs_process_node ~ctx ~working_vdi:branch_vdi
              ~working_dp:branch_dp ~nbd_uri:branch_nbd_uri
              ~counter ~total child
        with e -> (try cleanup () with _ -> ()) ; raise e
      in
      cleanup () ; rels
    ) inactive_children
  in
  let active_relations =
    List.concat_map (fun child ->
      dfs_process_node ~ctx ~working_vdi ~working_dp ~nbd_uri
        ~counter ~total child
    ) active_children
  in
  this_relation :: (inactive_relations @ active_relations)
```

The partition + inactive-first ordering is what gives the design its two key
properties: (a) `mirror_vdi` is never aliased into a non-active subtree, so
the active continuation always lands back on it; (b) each inactive subtree's
branch VDI is torn down before the next one starts. If the tree contains more
than one active-path child at any node (which would indicate corrupt XAPI
state) the code logs a warning and continues defensively.

**`send_start` integration.** When `send_start` runs, it now calls
`get_snapshot_tree` immediately after the source VDI is attached. If the tree
is empty the existing leaf-only fast path is unchanged. Otherwise the flow is:

1. `switch_vdi_to_readonly` — deactivate + re-activate `mirror_vdi` in
   read-only mode so the destination VDI can be safely snapshotted by the
   DFS (read/write while another datapath is snapshotting is not allowed).
2. `List.concat_map (dfs_process_node ~working_vdi:mirror_vdi ...) snapshot_tree`
   — walk every root depth-first and collect a flat list of
   `snapshot_relation` records.
3. `switch_vdi_to_writable` — flip back to writable so the live leaf mirror
   has a writable target.
4. Start the NBD proxy, call `Local.DATA.mirror`, register the send-side
   state, and `wait_for_mirror` for the leaf.
5. `State.set_snapshot_mappings mirror_id snapshot_relations` so the
   orchestrator in `xapi_vm_migrate.ml` can pick them up after the live
   mirror reaches the complete state.

The readonly/writable transitions are owned by the **send** side via the two
`switch_vdi_to_*` helpers, so `receive_start3` does not need to know anything
about the snapshot-aware flow and remains identical to the snapshot-free path.

### Shared state: `storage_migrate_helper.ml`

The list of `(source snapshot, destination snapshot, snapshot time)` tuples
produced by the DFS needs to survive from the moment `send_start` finishes
until the orchestrator in `xapi_vm_migrate.ml` is ready to publish them. The
existing `storage_migrate_helper.ml` module already protects mirror state
with a mutex, so a small parallel table is added using the same pattern:

```ocaml
type snapshot_relation = {
    src_vdi: Storage_interface.Vdi.t
  ; dest_vdi: Storage_interface.Vdi.t
  ; snapshot_time: string   (* ISO8601 *)
}

let snapshot_mappings : (string, snapshot_relation list) Hashtbl.t
```

The key is the `mirror_id`, and three small functions — `set_snapshot_mappings`,
`get_snapshot_mappings`, `remove_snapshot_mappings` — wrap the table under
the existing module-level mutex.

### The new RPC: `SR.set_snapshot_relations`

Once the live mirror is complete, xapi tells the destination SR which dest
VDIs are snapshots of the migrated leaf. A new RPC,
`SR.set_snapshot_relations`, is added to `storage_interface.ml`; it takes the
destination SR plus a list of `(snapshot_vdi, leaf_vdi, snapshot_time_string)`
tuples. Compared with the pre-existing `SR.update_snapshot_info_dest`, it is
simpler: there is no content_id matching, because content_ids have already
been propagated per-snapshot during the DFS (see fix below), and the call
takes the full mapping list in one go rather than one snapshot at a time.

The implementation lives in `storage_mux.ml` and, for each entry, updates
both XAPI's database and the storage backend's own custom-keys store:

```ocaml
List.iter
  (fun (snapshot, leaf, snapshot_time) ->
    let snapshot_ref, _ = find_vdi ~__context sr snapshot in
    let leaf_ref, _     = find_vdi ~__context sr leaf in
    set_snapshot_time __context ~dbg ~sr ~vdi:snapshot ~snapshot_time ;
    Db.VDI.set_snapshot_of  ~__context ~self:snapshot_ref ~value:leaf_ref ;
    Db.VDI.set_is_a_snapshot ~__context ~self:snapshot_ref ~value:true ;
    update_backend_snapshot_metadata
      ~dbg sr snapshot leaf snapshot_time
  ) relations
```

The first three calls update XAPI's own VDI metadata so the destination pool
knows the topology immediately. The fourth call is a best-effort push into
the storage backend's own metadata store (via `VDI.set_snapshot_metadata`)
so the backend's bookkeeping stays in sync with XAPI's view; failures here
are logged but not raised, since the data has already been migrated and the
XAPI-level relations are sufficient for the user-visible snapshot tree to
function. The matching stubs in `storage_skeleton.ml` and forwarding in
`storage_smapiv1_wrapper.ml` follow `update_snapshot_info_dest` mechanically.

### Orchestration: `xapi_vm_migrate.ml`

The VM-level orchestrator picks up the mapping list after the leaf mirror is
complete and ties everything together. Inside `vdi_copy_fun`, once
`mirror_to_remote` returns, the code:

1. retrieves the recorded relations for this mirror with
   `Storage_migrate_helper.State.get_snapshot_mappings`;
2. calls `SR.set_snapshot_relations` against the destination SR to publish
   the snapshot/leaf relationships (failures here are logged but do not
   abort: the data is already on the destination);
3. builds one `mirror_record` per `(src snapshot, dest snapshot)` pair via
   `create_snapshot_mirror_record` so the surrounding per-VDI continuation
   can rewrite each snapshot VM's VBD to point at its destination VDI;
4. hands the leaf mirror record **together with all per-snapshot records**
   to `post_mirror` as a single list, then removes the mapping table entry.

```ocaml
let snapshot_relations = get_snapshot_relations mirror_id in
call_set_snapshot_relations ~dest_sr ~leaf_vdi:remote_vdi snapshot_relations ;
let snapshot_mirror_records =
  List.filter_map create_snapshot_mirror_record snapshot_relations
in
(* Single-shot continuation: feed leaf + every snapshot in one list to
   [post_mirror] so [with_many] is invoked exactly once per disk.
   See the fix below for why multiple invocations are unsafe. *)
let all_mirror_records = mirror_record :: snapshot_mirror_records in
let result = post_mirror mirror_id all_mirror_records in
Option.iter Storage_migrate_helper.State.remove_snapshot_mappings mirror_id ;
result
```

The other touch in `xapi_vm_migrate.ml` is a one-line filter inside
`migrate_send'`. Historically the `extra_vdis` list bundled both suspend
VDIs and snapshot VDIs together, so the existing copy path would transfer
snapshots as standalone VDIs. With the new mechanism, SMAPIv3 snapshots are
already migrated by the DFS and must **not** be copied again — doing so
would create a parallel, unrelated chain on the destination. The fix
filters out snapshot VDIs that sit on SMAPIv3 SRs, while suspend VDIs and
SMAPIv1 snapshot VDIs continue to be copied as before:

```ocaml
let copyable_snapshots =
  List.filter
    (fun vconf -> Storage_mux_reg.smapi_version_of_sr vconf.sr <> SMAPIv3)
    snapshots_vdis
in
let extra_vdis = suspends_vdis @ copyable_snapshots in
```

The filter is per-VDI rather than a single global flag, so mixed-SR
scenarios (some snapshots on SMAPIv3, some on SMAPIv1) keep working without
special-casing.

### Error handling

The new code follows the surrounding migration code's conservative error
policy: snapshot tree discovery failures log and return an empty list (the
migration falls back to the leaf-only fast path); a snapshot mirror that
fails during the DFS aborts the whole migration immediately, since a partial
tree on the destination is worse than no tree; metadata-only failures
(`SR.set_snapshot_relations`, `set_content_id`, `VDI.set_snapshot_metadata`)
are logged as warnings but do not abort, because the data is already on the
destination and XAPI-level relations are usually sufficient. Cleanup paths
(`prepare_branch_vdi`'s cleanup thunk, branch VDI teardown) are wrapped in
`try/with` so they never mask the original exception.

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


### Single-shot continuation in `with_many` (multi-disk migration fix)

VMs with more than one disk failed after the first disk's mirror tree was
built. The second disk's `post_mirror` call raised `Db_exn.DBCache_NotFound`
because xapi's outer `with_many` driver re-entered `with_remote_vdi` for an
already-destroyed local leaf, and that leaf's database row had been removed by
the previous disk's `post_mirror` cleanup.

Root cause: the original orchestration in `vdi_copy_fun` called

```ocaml
let result = post_mirror mirror_id mirror_record in
List.iter (fun mr -> ignore (continuation mr)) snapshot_mirror_records ;
```

which invoked `with_many`'s continuation **N+1 times** for a single disk (once
for the leaf, then once per snapshot). `with_many` is a CPS helper: each
invocation of its continuation pops back to the outer recursion frame and
proceeds to the *next* item in the disk list. Calling it more than once per
item causes the tail of the disk list to be processed multiple times with
stale, partially-destroyed state.

Fix:

1. Concatenate the leaf mirror record with the per-snapshot mirror records and
   hand them all to `post_mirror` as a single list, so the continuation is
   invoked exactly once per disk.
2. Change `with_many`'s accumulator to append a list per item (`ys @ acc`)
   instead of cons-ing a single value (`y :: acc`), so the final `fn` receives
   a flat list containing every leaf and every snapshot mirror record from
   every disk.
3. Update `post_mirror`'s signature to take `mirror_records : mirror_record
   list` and forward the whole list to `continuation`.
4. In the non-mirror branch (`copy`/no-mirror path) wrap the single
   `mirror_record` in a singleton list so the new continuation contract holds
   uniformly.

```ocaml
(* xapi_vm_migrate.ml *)
let rec with_many withfn many fn =
  let rec inner l acc =
    match l with
    | [] -> fn acc
    | x :: xs -> withfn x (fun ys -> inner xs (ys @ acc))   (* was: y :: acc *)
  in
  inner many []

let post_mirror mirror_id mirror_records =
  let result = continuation mirror_records in
  ...
```

After this change the existing per-VDI logic in the surrounding `migrate_send'`
continues to operate on a flat `mirror_record list` covering every disk and
every snapshot, so VBD remapping for both the leaf and the snapshot VMs
continues to work without any further structural changes.

### Propagating `content_id` from source snapshots to destination snapshots

After the multi-disk fix the migration reached
`SR.update_snapshot_info_dest`, which then failed with
`Content_ids_do_not_match` on every snapshot pair. The destination backend's
`assert_content_ids_match` requires the destination snapshot's `content_id` to
equal the source snapshot's `content_id`.

Why this breaks for SMAPIv3 mirror but not for SMAPIv1 SXM:

- SMAPIv1 SXM transfers the snapshot's `content_id` along with the snapshot
  copy itself (see `storage_smapiv1_migrate.ml`, which calls
  `Remote.VDI.set_content_id` right after the copy completes).
- The new SMAPIv3 path mirrors raw block data over NBD and then calls
  `Remote.VDI.snapshot` on the destination. The destination SR's
  `VDI.snapshot` auto-generates a fresh `content_id`, which never matches the
  source.

Fix, mirroring the legacy SMAPIv1 pattern, lives entirely in
`create_destination_snapshot` / `mirror_snapshot_into_existing_dest` in
`storage_smapiv3_migrate.ml`:

1. Before attaching the source snapshot for mirroring, capture its
   `content_id` via `Local.VDI.stat`.
2. After `Remote.VDI.snapshot` produces the destination snapshot, immediately
   call `Remote.VDI.set_content_id` to overwrite the auto-generated value
   with the captured source `content_id`.

```ocaml
let create_destination_snapshot ~dbg ~dest_sr ~dest_url ~verify_dest
    ~dest_vdi_info ~src_content_id =
  let (module Remote) = get_remote_backend dest_url verify_dest in
  let dest_snapshot =
    Remote.VDI.snapshot dbg dest_sr
      {dest_vdi_info with sm_config= [("snapshot_parent", "true")]}
  in
  Remote.VDI.set_content_id dbg dest_sr dest_snapshot.vdi src_content_id ;
  {dest_snapshot with content_id= src_content_id}
```

`set_content_id` failures are logged as warnings rather than raised, so that
exceptional cleanup paths are not masked by a metadata-only error.
