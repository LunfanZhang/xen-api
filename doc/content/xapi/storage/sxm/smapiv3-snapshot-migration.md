---
Title: SMAPIv3 Migration with Snapshots
---

- [Overview](#overview)
- [Original SMAPIv3 Migration Design](#original-smapiv3-migration-design)
  - [Original preparation (SMAPIv3)](#original-preparation-smapiv3)
  - [Original mirror establishment](#original-mirror-establishment)
  - [Original finish](#original-finish)
  - [Xapi code walkthrough](#xapi-code-walkthrough)
- [Limitations of the Original Design](#limitations-of-the-original-design)
  - [Snapshot VDI handling problem](#snapshot-vdi-handling-problem)
  - [Metadata preservation problem](#metadata-preservation-problem)
  - [VBD update problem](#vbd-update-problem)
- [Enhanced SMAPIv3 Migration with Snapshots](#enhanced-smapiv3-migration-with-snapshots)
  - [Design principles](#design-principles)
  - [Enhanced preparation](#enhanced-preparation)
  - [Snapshot chain discovery](#snapshot-chain-discovery)
  - [Snapshot mirroring process](#snapshot-mirroring-process)
    - [Base-to-leaf ordering](#base-to-leaf-ordering)
    - [Sequential snapshot mirroring](#sequential-snapshot-mirroring)
    - [Activation mode management](#activation-mode-management)
  - [Snapshot metadata preservation](#snapshot-metadata-preservation)
    - [State storage](#state-storage)
    - [RPC interface](#rpc-interface)
    - [Metadata restoration](#metadata-restoration)
  - [Mirror record creation for snapshots](#mirror-record-creation-for-snapshots)
  - [Enhanced finish](#enhanced-finish)
- [Implementation Details](#implementation-details)
  - [Storage layer code](#storage-layer-code)
    - [get\_snapshot\_chain](#get_snapshot_chain)
    - [mirror\_single\_snapshot](#mirror_single_snapshot)
    - [process\_snapshots](#process_snapshots)
  - [Xapi layer code](#xapi-layer-code)
    - [Snapshot mapping retrieval](#snapshot-mapping-retrieval)
    - [Snapshot relation establishment](#snapshot-relation-establishment)
    - [VBD update integration](#vbd-update-integration)
  - [State management](#state-management)
  - [Error handling](#error-handling)

## Overview

This document describes the enhancements made to the SMAPIv3 storage migration (SXM) 
mechanism to support migrating VMs with snapshots. The original SMAPIv3 migration 
implementation only handled the primary VDI of a running VM, assuming no snapshot 
relationships existed. When a VM with snapshots was migrated using SMAPIv3, the 
snapshot VDIs and their metadata were not properly transferred, leading to data loss 
and broken snapshot relationships on the destination host.

This enhancement extends the SMAPIv3 migration process to:

1. Discover and enumerate all snapshots associated with a VDI being migrated
2. Mirror each snapshot VDI in the correct base-to-leaf order
3. Preserve snapshot metadata including `snapshot_time`, `snapshot_of`, and `is_a_snapshot`
4. Update VBD references for snapshot VMs to point to the migrated snapshot VDIs
5. Maintain the complete snapshot chain structure on the destination

The implementation follows the same architectural principles as the existing SXM 
infrastructure, introducing new helper functions and state management while maintaining 
compatibility with the existing SMAPIv1 migration path.

## Original SMAPIv3 Migration Design

Before examining the enhancements for snapshot support, it is important to understand 
how the original SMAPIv3 migration worked. This provides context for understanding 
both the limitations that needed to be addressed and how the new design builds upon 
the existing architecture.

### Original preparation (SMAPIv3)

The original preparation phase for SMAPIv3 was significantly simpler than SMAPIv1 
because the storage backend's mirror operation handles copying existing data. The 
preparation consisted of:

1. Create a single destination VDI (`mirror_vdi`) to receive mirrored data
2. Attach and activate this VDI on the destination host as read-only

This contrasts with SMAPIv1 which required creating both a leaf VDI for new writes 
and a parent VDI for existing data, plus a dummy snapshot to ensure the leaf was a 
differencing disk.

The `receive_start3` function in `storage_smapiv3_migrate.ml` handled this preparation:

```ocaml
let receive_start3 ~dbg ~sr ~vdi_info ~url ~dest ~verify_dest =
  let (module Remote) = get_remote_backend url verify_dest in
  
  (* Create destination VDI *)
  let leaf = Remote.VDI.create dbg sr vdi_info in
  
  (* Attach and activate as read-only *)
  let leaf_dp = Uuidx.(to_string (make ())) in
  ignore (Remote.VDI.attach3 dbg leaf_dp sr leaf.vdi (Vm.of_string "0") true) ;
  Remote.VDI.activate3 dbg leaf_dp sr leaf.vdi vm ;
  
  (* Extract NBD export information *)
  let nbd_export = extract_nbd_export_from_attach_info backend in
  
  {Mirror.mirror_vdi= leaf; mirror_datapath= leaf_dp; nbd_export}
```

### Original mirror establishment

The original mirroring process for SMAPIv3 worked as follows:

1. **NBD Proxy Setup**: xapi created an NBD proxy thread listening on a Unix domain 
socket at `/var/run/nbdproxy/export/<domain>`. This proxy forwarded connections via 
HTTPS to the remote xapi, which then proxied to the destination storage backend's 
NBD server.

2. **Mirror Start**: xapi called `Local.DATA.mirror dbg sr vdi vm nbd_uri` where 
`nbd_uri` pointed to the Unix domain socket. This instructed qemu-dp to start mirroring 
writes to the remote destination.

3. **Wait for Completion**: xapi polled the mirror status using `Local.DATA.stat` and 
waited for the existing data to finish copying.

The key code in `send_start` was:

```ocaml
let send_start ~dbg ~sr ~vdi ~mirror_vm ~url ~remote_mirror ~dest_sr ~verify_dest =
  match remote_mirror with
  | Mirror.SMAPIv3_mirror {nbd_export; mirror_datapath; mirror_vdi} ->
      let nbd_proxy_path =
        Printf.sprintf "/var/run/nbdproxy/export/%s" (Vm.string_of mirror_vm)
      in
      let nbd_uri =
        Uri.make ~scheme:"nbd+unix" ~host:"" ~path:nbd_export
          ~query:[("socket", [nbd_proxy_path])] ()
        |> Uri.to_string
      in
      
      (* Start NBD proxy thread *)
      let _ : Thread.t = Thread.create
        (fun () ->
          export_nbd_proxy ~remote_url:url ~mirror_vm ~sr:dest_sr
            ~vdi:mirror_vdi.vdi ~dp:mirror_datapath ~verify_dest
        ) ()
      in
      
      (* Start mirroring *)
      let mk = Local.DATA.mirror dbg sr vdi live_vm nbd_uri in
      mirror_wait ~dbg ~sr ~vdi ~vm:live_vm ~mirror_id mk
```

### Original finish

The finish phase for the original SMAPIv3 migration was straightforward:

1. Destroy the mirror datapath used for receiving writes
2. Clean up any transient state

Unlike SMAPIv1, there was no need to compose VDIs or delete snapshots, as the mirror 
operation directly wrote to the final destination VDI.

### Xapi code walkthrough

At the xapi layer, the VM migration code in `xapi_vm_migrate.ml` coordinated the 
storage migration. The `vdi_copy_fun` function determined which VDIs to migrate:

```ocaml
let vdi_copy_fun __context dbg vdi_map remote is_intra_pool remote_vdis so_far =
  let mirror = (* determine if VDI should be mirrored vs copied *) in
  
  if mirror then
    with_new_dp (fun new_dp ->
      let mirror_id, remote_vdi = mirror_to_remote new_dp in
      post_mirror mirror_id mirror_record
    )
  else
    (* copy operation for read-only VDIs *)
```

The critical point is that only the primary VDI of the running VM was mirrored. 
Snapshot VDIs were treated as regular read-only VDIs and handled through the copy 
path, which was designed for SMAPIv1.

## Limitations of the Original Design

The original SMAPIv3 migration design had several critical limitations when handling 
VMs with snapshots. These limitations stemmed from the assumption that migration only 
needed to handle a single active VDI without considering snapshot relationships.

### Snapshot VDI handling problem

The most fundamental problem was that snapshot VDIs were not mirrored at all during 
the SMAPIv3 migration process. When xapi enumerated the VDIs to migrate, it classified 
them as either:

1. **Mirrored VDIs**: Read-write VDIs attached to the running VM
2. **Copied VDIs**: Read-only VDIs, including snapshots

For SMAPIv1, this classification worked because the copy path (`DATA.copy`) handled 
both regular read-only VDIs and snapshots correctly. However, for SMAPIv3, the copy 
path was never invoked for snapshot VDIs because:

```ocaml
let extra_vdis = suspends_vdis @ snapshots_vdis in
let extra_vdi_map =
  List.map (fun vconf -> (* resolve to destination SR *)) extra_vdis
```

In SMAPIv3 migrations, `snapshots_vdis` were included in the extra VDI list expecting 
them to be copied, but the SMAPIv3 code path had no mechanism to handle this copying. 
The `send_start` function only knew how to mirror the single leaf VDI that was actively 
attached to the VM.

As a result, when a VM with snapshots was migrated:
- The leaf VDI was successfully mirrored to the destination
- Snapshot VDIs were never transferred
- The snapshot VM records pointed to non-existent VDIs on the destination
- Any attempt to use the snapshots after migration failed

### Metadata preservation problem

Even if snapshot VDIs were somehow transferred, the original design had no mechanism 
to preserve snapshot metadata. In the xapi database, snapshots are represented by 
three critical fields:

1. **`snapshot_of`**: References the VDI of which this is a snapshot
2. **`snapshot_time`**: Timestamp when the snapshot was created (ISO8601 format)
3. **`is_a_snapshot`**: Boolean flag indicating this VDI is a snapshot

During SMAPIv1 migration, these fields were preserved through the 
`SR.update_snapshot_info_dest` RPC call, which copied metadata from source snapshots 
to destination snapshots:

```ocaml
let update_snapshot_info_dest () ~dbg ~sr ~vdi ~src_vdi ~snapshot_pairs =
  List.iter (fun (local_snapshot, src_snapshot_info) ->
    set_snapshot_time __context ~dbg ~sr ~vdi:local_snapshot
      ~snapshot_time:src_snapshot_info.snapshot_time ;
    set_snapshot_of __context ~dbg ~sr ~vdi:local_snapshot ~snapshot_of:vdi ;
    set_is_a_snapshot __context ~dbg ~sr ~vdi:local_snapshot ~is_a_snapshot:true
  ) snapshot_pairs
```

The SMAPIv3 path had no equivalent mechanism. Without preserving `snapshot_time`, 
the temporal ordering of snapshots would be lost. Without `snapshot_of` relationships, 
the snapshot chain structure would be broken. This would render any migrated snapshots 
essentially useless even if their data was transferred.

### VBD update problem

The final critical issue was VBD reference updates. When a VM has snapshots, each 
snapshot is represented by a separate VM record (a snapshot VM). These snapshot VMs 
have VBD records that reference the snapshot VDIs.

During migration, xapi creates mirror records that map source VDIs to destination VDIs. 
These mirror records are later used to update VBD references to point to the new 
destination VDIs:

```ocaml
type mirror_record = {
  mr_local_vdi: Storage_interface.vdi;
  mr_remote_vdi: Storage_interface.vdi;
  mr_local_vdi_reference: API.ref_VDI;
  mr_remote_vdi_reference: API.ref_VDI;
  (* ... other fields ... *)
}
```

The original SMAPIv3 code only created a mirror record for the primary leaf VDI. 
Snapshot VDIs had no mirror records, so their VBD references were never updated. 
After migration, snapshot VMs' VBDs still pointed to the old source VDIs, which were 
either destroyed or inaccessible on the destination host.

## Enhanced SMAPIv3 Migration with Snapshots

The enhanced design addresses all three limitations of the original implementation 
while maintaining compatibility with the existing architecture. The solution introduces 
snapshot discovery, sequential mirroring, metadata preservation, and proper VBD updates.

### Design principles

The enhancement was guided by several key principles:

1. **Minimal disruption**: Build upon existing SMAPIv3 infrastructure rather than 
redesigning from scratch
2. **Metadata fidelity**: Preserve complete snapshot metadata including timestamps to 
maintain snapshot history
3. **Chain integrity**: Process snapshots in base-to-leaf order to maintain the correct 
dependency structure
4. **Reuse existing mechanisms**: Leverage the same NBD proxy and mirror operations 
used for leaf VDI mirroring
5. **Explicit state management**: Use dedicated state storage for snapshot mappings 
rather than implicit coupling

### Enhanced preparation

The preparation phase now needs to handle an additional concern: the destination VDI 
must be usable for multiple sequential mirror operations. Each snapshot and the final 
leaf VDI will be mirrored into the same destination VDI, with snapshots being taken 
between each mirror operation to preserve intermediate states.

The key change in `receive_start3` is the activation mode. Originally, the destination 
VDI was activated as read-write immediately:

```ocaml
Remote.VDI.activate3 dbg leaf_dp sr leaf.vdi vm ;
```

This is now changed to activate as read-only initially, allowing snapshots to be 
mirrored first:

```ocaml
Remote.VDI.activate_readonly dbg leaf_dp sr leaf.vdi vm ;
```

The VDI will be switched to read-write mode after all snapshots are processed, just 
before mirroring the live leaf VDI.

### Snapshot chain discovery

Before mirroring can begin, the system must discover all snapshots associated with 
the VDI being migrated. This is handled by the `get_snapshot_chain` function in 
`storage_smapiv3_migrate.ml`:

```ocaml
let get_snapshot_chain ~dbg ~vdi =
  D.debug "%s retrieving snapshot chain for VDI %s" __FUNCTION__ (s_of_vdi vdi) ;
  
  try
    Server_helpers.exec_with_new_task "get_snapshot_chain"
      ~subtask_of:(Ref.of_string dbg) (fun __context ->
        let vdi_uuid = s_of_vdi vdi in
        let vdi_ref = Db.VDI.get_by_uuid ~__context ~uuid:vdi_uuid in
        let snapshot_refs = Db.VDI.get_snapshots ~__context ~self:vdi_ref in
        
        D.debug "%s found %d snapshot(s) for VDI %s" __FUNCTION__
          (List.length snapshot_refs) vdi_uuid ;
        
        let snapshot_data =
          List.map (fun snap_ref ->
            let uuid = Db.VDI.get_uuid ~__context ~self:snap_ref in
            let snapshot_time = Db.VDI.get_snapshot_time ~__context ~self:snap_ref in
            let snapshot_time_str = Date.to_rfc3339 snapshot_time in
            (uuid, snapshot_time_str)
          ) snapshot_refs
        in
        (* Reverse to get base-to-leaf order (oldest first) *)
        List.rev snapshot_data
      )
  with e ->
    D.error "%s failed to retrieve snapshot chain: %s" __FUNCTION__
      (Printexc.to_string e) ;
    []
```

This function returns a list of `(uuid, snapshot_time)` tuples, providing both the 
snapshot VDI identifiers and their original creation timestamps. The timestamps are 
critical for preserving temporal ordering and will be stored alongside the VDI mappings.

The snapshots are retrieved from the database's `VDI.snapshots` field, which maintains 
a list of all snapshots taken from a particular VDI. The list is then reversed to 
obtain base-to-leaf order (oldest to newest). This ordering is essential because 
snapshots build upon each other, and they must be mirrored in dependency order.

### Snapshot mirroring process

Once the snapshot chain is discovered, each snapshot must be mirrored to the destination. 
This process reuses the same mirroring mechanism as the leaf VDI but applies it 
sequentially to each snapshot.

#### Base-to-leaf ordering

Snapshots are processed in base-to-leaf order (oldest first) for several reasons:

1. **Dependency preservation**: Each snapshot may contain references to blocks in 
earlier snapshots. Processing in order ensures these dependencies are satisfied.

2. **Incremental efficiency**: The qemu-dp mirror operation transfers only the blocks 
that differ from the current destination state. By processing snapshots sequentially 
from oldest to newest, each mirror operation only transfers the delta between consecutive 
snapshots.

3. **Metadata consistency**: The `snapshot_of` relationships form a chain from base 
to leaf. Establishing these relationships in order maintains consistency throughout 
the process.

The ordering is achieved by reversing the list returned from `Db.VDI.get_snapshots`, 
which returns snapshots in newest-first order by default.

#### Sequential snapshot mirroring

Each snapshot is mirrored through the `mirror_single_snapshot` function:

```ocaml
let mirror_single_snapshot ~dbg ~sr ~dest_sr ~url ~verify_dest ~mirror_vm ~copy_vm
    ~mirror_vdi ~mirror_datapath ~nbd_uri ~idx ~total ~snapshot_uuid ~snapshot_time =
  SXM.info "%s [%d/%d] mirroring snapshot %s" __FUNCTION__
    (idx + 1) total snapshot_uuid ;
  
  (* Start fresh NBD proxy for this snapshot *)
  let _ : Thread.t = start_nbd_proxy_thread ~url ~mirror_vm ~dest_sr
    ~mirror_vdi ~mirror_datapath ~verify_dest in
  Unix.sleepf mirror_poll_interval ;
  
  let dest_snapshot =
    mirror_snapshot_into_existing_dest ~dbg ~sr ~snapshot_vdi_uuid:snapshot_uuid
      ~dest_sr ~dest_url:url ~verify_dest ~mirror_vm ~copy_vm
      ~dest_vdi_info:mirror_vdi ~nbd_uri
  in
  
  D.debug "%s [%d/%d] snapshot %s mirrored to %s" __FUNCTION__
    (idx + 1) total snapshot_uuid (s_of_vdi dest_snapshot.vdi) ;
  
  (Vdi.of_string snapshot_uuid, dest_snapshot.vdi, snapshot_time)
```

The process for each snapshot:

1. **Start NBD proxy**: A fresh NBD proxy thread is started to handle the connection 
for this specific snapshot. This ensures clean connection state for each mirror operation.

2. **Attach and activate snapshot**: The source snapshot VDI is attached and activated 
in read-only mode:

   ```ocaml
   let attach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm =
     ignore (Local.VDI.attach3 dbg dp sr snapshot_vdi copy_vm false) ;
     Local.VDI.activate_readonly dbg dp sr snapshot_vdi copy_vm
   ```

3. **Mirror operation**: The snapshot data is mirrored to the destination using 
`Local.DATA.mirror`, exactly as the leaf VDI would be mirrored:

   ```ocaml
   let mirror_key = Local.DATA.mirror dbg sr snapshot_vdi copy_vm nbd_uri in
   ```

4. **Wait for completion**: The system polls the mirror status until it completes:

   ```ocaml
   wait_for_mirror_completion ~dbg ~sr ~vdi:snapshot_vdi ~vm:copy_vm
     ~error_msg:(Printf.sprintf "Snapshot %s mirror failed" snapshot_vdi_uuid)
     mirror_key
   ```

5. **Cleanup and snapshot**: After the mirror completes, the source snapshot VDI is 
detached, and a snapshot is taken of the destination VDI to preserve this state:

   ```ocaml
   detach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm ;
   let dest_snapshot =
     create_destination_snapshot ~dbg ~dest_sr ~dest_url ~verify_dest ~dest_vdi_info
   in
   ```

6. **Return mapping**: The function returns a tuple of `(source_vdi, dest_snapshot_vdi, snapshot_time)` 
which will be stored for later metadata restoration and VBD updates.

The destination snapshot creation is critical. Each time a snapshot is mirrored, a 
snapshot is taken on the destination to "freeze" that state. This creates a chain of 
destination snapshots that mirrors the structure of the source snapshot chain.

#### Activation mode management

A subtle but important aspect of the implementation is the management of VDI activation 
modes. The destination VDI starts activated as read-only during snapshot processing. 
This is because we are treating it as a base for multiple sequential operations, and 
read-only mode is safer for this scenario.

After all snapshots are processed, the destination VDI is switched to read-write mode 
before starting the mirror of the live leaf VDI:

```ocaml
let switch_vdi_to_writable ~dbg ~url ~verify_dest ~mirror_datapath ~dest_sr ~mirror_vdi ~mirror_vm =
  let (module Remote) = Storage_migrate_helper.get_remote_backend url verify_dest in
  D.debug "%s switching VDI %s to writable" __FUNCTION__ (s_of_vdi mirror_vdi.vdi) ;
  Remote.VDI.deactivate dbg mirror_datapath dest_sr mirror_vdi.vdi mirror_vm ;
  Remote.VDI.activate3 dbg mirror_datapath dest_sr mirror_vdi.vdi mirror_vm
```

This ensures the leaf VDI can be properly mirrored with write access, allowing the 
ongoing writes from the live VM to be replicated.

### Snapshot metadata preservation

Transferring the snapshot VDI data is only half the solution. The snapshot metadata 
must also be preserved to maintain the snapshot chain structure and temporal information.

#### State storage

During the snapshot mirroring process, mappings between source and destination snapshot 
VDIs are accumulated in a local reference:

```ocaml
let snapshot_mappings = ref [] in
let mappings =
  process_snapshots ~dbg ~sr ~dest_sr ~url ~verify_dest
    ~mirror_vm ~copy_vm ~mirror_vdi ~mirror_datapath ~nbd_uri
    ~snapshots:snapshot_chain
in
snapshot_mappings := mappings ;
```

After the leaf mirror operation completes, these mappings are stored in a global 
state table indexed by mirror ID:

```ocaml
if !snapshot_mappings <> [] then (
  D.debug "%s storing %d snapshot mapping(s) for mirror %s" __FUNCTION__
    (List.length !snapshot_mappings) mirror_id ;
  State.set_snapshot_mappings mirror_id !snapshot_mappings
)
```

The state management is in `storage_migrate_helper.ml`:

```ocaml
type snapshot_mappings_table =
  (string, (Storage_interface.Vdi.t * Storage_interface.Vdi.t * string) list)
  Hashtbl.t

let snapshot_mappings : snapshot_mappings_table = Hashtbl.create 10

let set_snapshot_mappings mirror_id mappings =
  Xapi_stdext_threads.Threadext.Mutex.execute mutex (fun () ->
    Hashtbl.replace snapshot_mappings mirror_id mappings
  )

let get_snapshot_mappings mirror_id =
  Xapi_stdext_threads.Threadext.Mutex.execute mutex (fun () ->
    Hashtbl.find_opt snapshot_mappings mirror_id |> Option.value ~default:[]
  )
```

The mutex protection ensures thread safety when multiple migrations might be occurring 
concurrently. The state is transient and exists only for the duration of the migration 
process.

#### RPC interface

To apply snapshot metadata on the destination host, a new RPC interface was introduced: 
`SR.set_snapshot_relations`. This RPC establishes snapshot relationships and restores 
metadata for a list of snapshots.

The interface definition in `storage_interface.ml`:

```ocaml
(** [set_snapshot_relations sr relations] establishes snapshot relationships
    for mirrored VDIs. Each relation represents (snapshot_vdi, leaf_vdi, snapshot_time)
    where snapshot_vdi will be marked as a snapshot of leaf_vdi with the given
    snapshot_time (ISO8601 format). Used during migrations after snapshots are
    mirrored to preserve snapshot metadata. *)
let set_snapshot_relations =
  let relations_p =
    Param.mk ~name:"relations"
      TypeCombinators.(list (pair (Vdi.t, pair (Vdi.t, Types.string))))
  in
  declare "SR.set_snapshot_relations" []
    (dbg_p @-> sr_p @-> relations_p @-> returning unit_p err)
```

The RPC takes a list of relations, where each relation is a tuple of:
- `snapshot_vdi`: The destination snapshot VDI
- `leaf_vdi`: The destination leaf VDI (what the snapshot is "of")
- `snapshot_time`: The original snapshot creation time in ISO8601 format

The implementation in `storage_mux.ml` applies these relationships:

```ocaml
let set_snapshot_relations () ~dbg ~sr ~relations =
  with_dbg ~name:"SR.set_snapshot_relations" ~dbg @@ fun _di ->
  debug "SR.set_snapshot_relations dbg:%s sr:%s relations:%d"
    dbg (s_of_sr sr) (List.length relations) ;
  Server_helpers.exec_with_new_task "SR.set_snapshot_relations"
    ~subtask_of:(Ref.of_string dbg) (fun __context ->
      List.iter
        (fun (snapshot, leaf, snapshot_time) ->
          let snapshot_ref, _ = find_vdi ~__context sr snapshot in
          let leaf_ref, _ = find_vdi ~__context sr leaf in
          set_snapshot_time __context ~dbg ~sr ~vdi:snapshot ~snapshot_time ;
          Db.VDI.set_snapshot_of ~__context ~self:snapshot_ref ~value:leaf_ref ;
          Db.VDI.set_is_a_snapshot ~__context ~self:snapshot_ref ~value:true
        )
        relations
    )
```

This implementation sets all three metadata fields:
1. `snapshot_time`: Restored from the original timestamp
2. `snapshot_of`: Set to point to the destination leaf VDI
3. `is_a_snapshot`: Marked as true

#### Metadata restoration

The metadata restoration happens in the xapi layer, in the `vdi_copy_fun` function 
of `xapi_vm_migrate.ml`. After the leaf VDI mirror operation completes, the snapshot 
mappings are retrieved and the relations are established:

```ocaml
if mirror then
  with_new_dp (fun new_dp ->
    let mirror_id, remote_vdi = mirror_to_remote new_dp in
    let mirror_record = get_mirror_record ~new_dp remote_vdi remote_vdi_ref in
    
    let snapshot_mappings = get_snapshot_mappings mirror_id in
    set_snapshot_relations ~dest_sr ~leaf_vdi:remote_vdi snapshot_mappings ;
    
    (* ... continue with VBD updates ... *)
  )
```

The `set_snapshot_relations` helper converts the flat tuple format used internally 
to the nested pair format expected by the RPC interface:

```ocaml
let set_snapshot_relations ~dest_sr ~leaf_vdi snapshot_mappings =
  let relations =
    List.map (fun (_src, dest, snapshot_time) ->
      (* Convert flat tuple to RPC nested pair format *)
      (dest, (leaf_vdi, snapshot_time))
    ) snapshot_mappings
  in
  match relations with
  | [] -> ()
  | _ ->
      debug "setting %d snapshot relation(s) on SR %s" (List.length relations)
        (Storage_interface.Sr.string_of dest_sr) ;
      try SMAPI.SR.set_snapshot_relations dbg dest_sr relations
      with e ->
        warn "failed to set snapshot relations on SR %s: %s"
          (Storage_interface.Sr.string_of dest_sr) (Printexc.to_string e)
```

This design keeps the RPC layer clean with proper type boundaries while allowing the 
business logic to work with more convenient flat tuples.

### Mirror record creation for snapshots

Beyond metadata, each snapshot needs a mirror record so that snapshot VMs' VBDs can 
be updated to point to the destination snapshot VDIs. The `create_snapshot_mirror_record` 
helper function creates these records:

```ocaml
let create_snapshot_mirror_record (src_vdi, dest_vdi, _snapshot_time) =
  let src_uuid = Storage_interface.Vdi.string_of src_vdi in
  let dest_uuid = Storage_interface.Vdi.string_of dest_vdi in
  try
    let src_ref = Db.VDI.get_by_uuid ~__context ~uuid:src_uuid in
    let dest_ref =
      XenAPI.VDI.get_by_uuid ~rpc:remote.rpc ~session_id:remote.session
        ~uuid:dest_uuid
    in
    Some {
      mr_dp= None
    ; mr_mirrored= false
    ; mr_local_sr= vconf.sr
    ; mr_local_vdi= src_vdi
    ; mr_remote_sr= dest_sr
    ; mr_remote_vdi= dest_vdi
    ; mr_local_xenops_locator=
        Xapi_xenops.xenops_vdi_locator ~__context ~self:src_ref
    ; mr_remote_xenops_locator=
        Xapi_xenops.xenops_vdi_locator_of dest_sr dest_vdi
    ; mr_local_vdi_reference= src_ref
    ; mr_remote_vdi_reference= dest_ref
    }
  with e ->
    warn "failed to create mirror record for snapshot %s: %s" src_uuid
      (Printexc.to_string e) ;
    None
```

Note that `mr_mirrored` is set to `false` because these VDIs were not actively mirrored 
in the traditional sense (as ongoing write replication), but rather copied as snapshots.

These mirror records are then passed to the `continuation` function which updates 
VBD references:

```ocaml
let snapshot_mirror_records =
  List.filter_map create_snapshot_mirror_record snapshot_mappings
in
let result = post_mirror mirror_id mirror_record in
List.iter (fun mr -> ignore (continuation mr)) snapshot_mirror_records ;
```

The `continuation` function is responsible for updating the VBD records of snapshot 
VMs to point to the new destination VDIs, ensuring that snapshot VMs are properly 
connected to their migrated disks.

### Enhanced finish

The finish phase is enhanced with cleanup of the snapshot mapping state:

```ocaml
Option.iter Storage_migrate_helper.State.remove_snapshot_mappings mirror_id ;
```

This removes the transient snapshot mapping data from the global state table, preventing 
memory leaks and ensuring clean state for subsequent migrations.

Additionally, the logic for determining which VDIs need to be copied as "extra" VDIs 
is updated to exclude snapshots when using SMAPIv3:

```ocaml
let has_smapiv3_snapshots =
  List.exists
    (fun vconf -> Storage_mux_reg.smapi_version_of_sr vconf.sr = SMAPIv3)
    snapshots_vdis
in
let extra_vdis =
  if has_smapiv3_snapshots then (
    debug "excluding SMAPIv3 snapshots from copy list (already mirrored)" ;
    suspends_vdis
  ) else
    suspends_vdis @ snapshots_vdis
in
```

This prevents double-processing of snapshots: SMAPIv3 snapshots are handled through 
the mirror path, while SMAPIv1 snapshots continue to use the copy path as before.

## Implementation Details

This section provides detailed code walkthroughs of the key functions implementing 
the enhanced snapshot migration. Understanding these implementations is essential for 
maintenance and future enhancements.

### Storage layer code

The storage layer code in `storage_smapiv3_migrate.ml` handles the core snapshot 
discovery and mirroring operations.

#### get\_snapshot\_chain

The `get_snapshot_chain` function is the entry point for discovering snapshots 
associated with a VDI:

```ocaml
let get_snapshot_chain ~dbg ~vdi =
  D.debug "%s retrieving snapshot chain for VDI %s" __FUNCTION__ (s_of_vdi vdi) ;
  
  try
    Server_helpers.exec_with_new_task "get_snapshot_chain"
      ~subtask_of:(Ref.of_string dbg) (fun __context ->
        let vdi_uuid = s_of_vdi vdi in
        let vdi_ref = Db.VDI.get_by_uuid ~__context ~uuid:vdi_uuid in
        let snapshot_refs = Db.VDI.get_snapshots ~__context ~self:vdi_ref in
        
        D.debug "%s found %d snapshot(s) for VDI %s" __FUNCTION__
          (List.length snapshot_refs) vdi_uuid ;
        
        let snapshot_data =
          List.map (fun snap_ref ->
            let uuid = Db.VDI.get_uuid ~__context ~self:snap_ref in
            let snapshot_time = Db.VDI.get_snapshot_time ~__context ~self:snap_ref in
            let snapshot_time_str = Date.to_rfc3339 snapshot_time in
            (uuid, snapshot_time_str)
          ) snapshot_refs
        in
        (* Reverse to get base-to-leaf order (oldest first) *)
        List.rev snapshot_data
      )
  with e ->
    D.error "%s failed to retrieve snapshot chain: %s" __FUNCTION__
      (Printexc.to_string e) ;
    []
```

Key implementation details:

1. **Task context**: Uses `Server_helpers.exec_with_new_task` to create a proper 
database task context with the correct parent-child relationship.

2. **Database access**: Retrieves snapshot references from `Db.VDI.get_snapshots` 
which returns all snapshots created from this VDI.

3. **Metadata extraction**: For each snapshot, retrieves both UUID and `snapshot_time`. 
The timestamp is converted to RFC 3339 (ISO8601) format using `Date.to_rfc3339`.

4. **Ordering**: The snapshot list is reversed to achieve base-to-leaf order. This 
is critical for correct dependency handling during mirroring.

5. **Error handling**: Any exceptions are caught and logged, returning an empty list 
as a safe fallback. This allows migrations to proceed even if snapshot discovery fails 
(though without snapshot support).

#### mirror\_single\_snapshot

The `mirror_single_snapshot` function handles mirroring of a single snapshot VDI:

```ocaml
let mirror_single_snapshot ~dbg ~sr ~dest_sr ~url ~verify_dest ~mirror_vm ~copy_vm
    ~mirror_vdi ~mirror_datapath ~nbd_uri ~idx ~total ~snapshot_uuid ~snapshot_time =
  SXM.info "%s [%d/%d] mirroring snapshot %s" __FUNCTION__
    (idx + 1) total snapshot_uuid ;
  
  (* Start fresh NBD proxy for this snapshot *)
  let _ : Thread.t = start_nbd_proxy_thread ~url ~mirror_vm ~dest_sr
    ~mirror_vdi ~mirror_datapath ~verify_dest in
  Unix.sleepf mirror_poll_interval ;
  
  let dest_snapshot =
    mirror_snapshot_into_existing_dest ~dbg ~sr ~snapshot_vdi_uuid:snapshot_uuid
      ~dest_sr ~dest_url:url ~verify_dest ~mirror_vm ~copy_vm
      ~dest_vdi_info:mirror_vdi ~nbd_uri
  in
  
  D.debug "%s [%d/%d] snapshot %s mirrored to %s" __FUNCTION__
    (idx + 1) total snapshot_uuid (s_of_vdi dest_snapshot.vdi) ;
  
  (Vdi.of_string snapshot_uuid, dest_snapshot.vdi, snapshot_time)
```

Key implementation details:

1. **Progress logging**: Logs progress as `[idx/total]` to provide visibility during 
long migrations with many snapshots.

2. **Fresh NBD proxy**: Each snapshot gets a new NBD proxy thread. This ensures clean 
connection state and avoids any potential issues with connection reuse.

3. **Sleep delay**: A short sleep (`mirror_poll_interval = 0.5s`) allows the NBD 
proxy thread to initialize before the mirror operation starts.

4. **Delegation**: The actual mirroring is delegated to `mirror_snapshot_into_existing_dest` 
which handles the detailed attach/mirror/detach/snapshot sequence.

5. **Return value**: Returns a tuple containing the source VDI, destination snapshot 
VDI, and original timestamp. This tuple is accumulated for later metadata restoration.

#### process\_snapshots

The `process_snapshots` function orchestrates the sequential processing of all snapshots:

```ocaml
let process_snapshots ~dbg ~sr ~dest_sr ~url ~verify_dest ~mirror_vm ~copy_vm
    ~mirror_vdi ~mirror_datapath ~nbd_uri ~snapshots =
  if snapshots = [] then
    []
  else (
    SXM.info "%s processing %d snapshot(s)" __FUNCTION__ (List.length snapshots) ;
    List.mapi
      (fun idx (snapshot_uuid, snapshot_time) ->
        mirror_single_snapshot ~dbg ~sr ~dest_sr ~url ~verify_dest
          ~mirror_vm ~copy_vm ~mirror_vdi ~mirror_datapath ~nbd_uri
          ~idx ~total:(List.length snapshots) ~snapshot_uuid ~snapshot_time
      )
      snapshots
  )
```

Key implementation details:

1. **Empty list handling**: Returns empty list immediately if there are no snapshots, 
avoiding unnecessary logging and processing.

2. **Sequential processing**: Uses `List.mapi` to process snapshots sequentially with 
index tracking. The sequential nature is important because each snapshot must complete 
before the next begins.

3. **Index propagation**: Passes the `idx` and `total` to `mirror_single_snapshot` 
for progress logging.

4. **Tuple destructuring**: Extracts `(snapshot_uuid, snapshot_time)` from each element, 
providing both identifiers and metadata to the mirror function.

### Xapi layer code

The xapi layer code in `xapi_vm_migrate.ml` coordinates the high-level migration flow 
and integrates snapshot handling with VBD updates.

#### Snapshot mapping retrieval

The `get_snapshot_mappings` helper retrieves stored snapshot mappings:

```ocaml
let get_snapshot_mappings mirror_id =
  match mirror_id with
  | Some mid ->
      let mappings = Storage_migrate_helper.State.get_snapshot_mappings mid in
      if mappings <> [] then
        debug "retrieved %d snapshot mapping(s) for mirror %s"
          (List.length mappings) mid ;
      mappings
  | None ->
      []
```

The `mirror_id` is an `option` type because not all VDI migrations produce a mirror 
ID (e.g., copy operations). If no mirror ID exists, an empty list is returned, gracefully 
handling the case where no snapshots were mirrored.

#### Snapshot relation establishment

The `set_snapshot_relations` helper establishes snapshot metadata on the destination:

```ocaml
let set_snapshot_relations ~dest_sr ~leaf_vdi snapshot_mappings =
  let relations =
    List.map (fun (_src, dest, snapshot_time) ->
      (* Convert flat tuple to RPC nested pair format *)
      (dest, (leaf_vdi, snapshot_time))
    ) snapshot_mappings
  in
  match relations with
  | [] ->
      ()
  | _ ->
      debug "setting %d snapshot relation(s) on SR %s" (List.length relations)
        (Storage_interface.Sr.string_of dest_sr) ;
      try SMAPI.SR.set_snapshot_relations dbg dest_sr relations
      with e ->
        warn "failed to set snapshot relations on SR %s: %s"
          (Storage_interface.Sr.string_of dest_sr) (Printexc.to_string e)
```

Key implementation details:

1. **Format conversion**: Converts from flat tuples `(src, dest, time)` used internally 
to nested pairs `(dest, (leaf, time))` required by the RPC interface. This keeps the 
RPC layer clean while allowing business logic to use more convenient representations.

2. **Empty list handling**: Returns immediately if there are no relations to set, 
avoiding unnecessary RPC calls.

3. **Best-effort**: Catches exceptions and logs warnings rather than failing the 
migration. This ensures that metadata restoration failures don't abort the entire 
migration, though the snapshots may not be fully functional.

4. **Source VDI ignored**: The source VDI (`_src`) is ignored at this stage because 
it's only needed for VBD updates, not metadata establishment.

#### VBD update integration

The main integration point is in the mirror handling branch of `vdi_copy_fun`:

```ocaml
if mirror then
  with_new_dp (fun new_dp ->
    let mirror_id, remote_vdi = mirror_to_remote new_dp in
    let mirror_record = get_mirror_record ~new_dp remote_vdi remote_vdi_ref in
    
    let snapshot_mappings = get_snapshot_mappings mirror_id in
    set_snapshot_relations ~dest_sr ~leaf_vdi:remote_vdi snapshot_mappings ;
    
    let snapshot_mirror_records =
      List.filter_map create_snapshot_mirror_record snapshot_mappings
    in
    
    let result = post_mirror mirror_id mirror_record in
    List.iter (fun mr -> ignore (continuation mr)) snapshot_mirror_records ;
    
    Option.iter Storage_migrate_helper.State.remove_snapshot_mappings mirror_id ;
    result
  )
```

The sequence is carefully ordered:

1. **Mirror completion**: The leaf VDI mirror is completed first
2. **Metadata establishment**: Snapshot relations are established on the destination
3. **Mirror record creation**: Mirror records are created for each snapshot
4. **VBD updates**: The main `post_mirror` processes the leaf VDI, then snapshot 
mirror records are processed
5. **Cleanup**: The transient state is removed

This ordering ensures that all destination VDIs exist and have correct metadata before 
any VBD references are updated.

### State management

The state management in `storage_migrate_helper.ml` uses a mutex-protected hashtable 
to provide thread-safe access to snapshot mappings:

```ocaml
type snapshot_mappings_table =
  (string, (Storage_interface.Vdi.t * Storage_interface.Vdi.t * string) list)
  Hashtbl.t

let snapshot_mappings : snapshot_mappings_table = Hashtbl.create 10

let set_snapshot_mappings mirror_id mappings =
  Xapi_stdext_threads.Threadext.Mutex.execute mutex (fun () ->
    Hashtbl.replace snapshot_mappings mirror_id mappings
  )

let get_snapshot_mappings mirror_id =
  Xapi_stdext_threads.Threadext.Mutex.execute mutex (fun () ->
    Hashtbl.find_opt snapshot_mappings mirror_id |> Option.value ~default:[]
  )

let remove_snapshot_mappings mirror_id =
  Xapi_stdext_threads.Threadext.Mutex.execute mutex (fun () ->
    Hashtbl.remove snapshot_mappings mirror_id
  )
```

Key design points:

1. **Thread safety**: All operations are protected by the same `mutex` used for other 
migration state, ensuring consistency across concurrent migrations.

2. **Transient storage**: The hashtable is in-memory only and not persisted. This is 
appropriate because the data is only needed during the migration process.

3. **Clean defaults**: `get_snapshot_mappings` returns an empty list if no mappings 
exist, allowing callers to use a simple pattern without explicit existence checks.

4. **Explicit cleanup**: `remove_snapshot_mappings` must be called explicitly to free 
memory. This is done in the migration completion path.

### Error handling

Error handling for snapshot mirroring follows the same patterns as the existing SXM 
infrastructure:

1. **Best-effort cleanup**: When snapshot mirroring fails, the system attempts to 
clean up attached VDIs but allows cleanup failures to be logged rather than propagated:

   ```ocaml
   with e ->
     D.error "%s snapshot mirror failed: %s" __FUNCTION__ (Printexc.to_string e) ;
     (* Best-effort cleanup *)
     (try detach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm with _ -> ()) ;
     raise e
   ```

2. **Mirror failure detection**: Mirror failures are detected through the `DATA.stat` 
polling and raised as `Migration_mirror_failure` errors.

3. **Metadata restoration failures**: Failures in `set_snapshot_relations` are logged 
as warnings but don't fail the migration. This allows partial success where the VDI 
data is transferred even if metadata restoration fails.

4. **VBD update failures**: Failures to create mirror records for snapshots are logged 
and those snapshots are skipped, but other snapshots and the primary VDI continue 
processing.

This error handling philosophy prioritizes completing the migration even if some 
secondary aspects (like snapshot metadata) fail, while ensuring cleanup of resources 
and proper logging for troubleshooting.
