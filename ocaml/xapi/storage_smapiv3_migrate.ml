(*
 * Copyright (c) Cloud Software Group
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

module D = Debug.Make (struct let name = __MODULE__ end)

module Date = Clock.Date
module Unixext = Xapi_stdext_unix.Unixext
module State = Storage_migrate_helper.State
module SXM = Storage_migrate_helper.SXM
open Storage_interface
open Storage_task
open Xmlrpc_client
open Storage_migrate_helper

module type SMAPIv2_MIRROR = Storage_interface.MIRROR

let s_of_sr = Storage_interface.Sr.string_of

let s_of_vdi = Storage_interface.Vdi.string_of

let s_of_vm = Storage_interface.Vm.string_of

let export_nbd_proxy ~remote_url ~mirror_vm ~sr ~vdi ~dp ~verify_dest =
  D.debug "%s spawning exporting nbd proxy" __FUNCTION__ ;
  let path =
    Printf.sprintf "/var/run/nbdproxy/export/%s" (Vm.string_of mirror_vm)
  in
  let proxy_srv = Fecomms.open_unix_domain_sock_server path in
  try
    let uri =
      Printf.sprintf "/services/SM/nbdproxy/import/%s/%s/%s/%s"
        (Vm.string_of mirror_vm) (Sr.string_of sr) (Vdi.string_of vdi) dp
    in

    let dest_url = Http.Url.set_uri (Http.Url.of_string remote_url) uri in
    D.debug "%s now waiting for connection at %s" __FUNCTION__ path ;
    let nbd_client, _addr = Unix.accept proxy_srv in
    D.debug "%s connection accepted" __FUNCTION__ ;
    let request =
      Http.Request.make
        ~query:(Http.Url.get_query_params dest_url)
        ~version:"1.0" ~user_agent:"export_nbd_proxy" Http.Put uri
    in
    D.debug "%s making request to dest %s" __FUNCTION__
      (Http.Url.to_string dest_url) ;
    let verify_cert = if verify_dest then Stunnel_client.pool () else None in
    let transport = Xmlrpc_client.transport_of_url ~verify_cert dest_url in
    with_transport ~stunnel_wait_disconnect:false transport
      (with_http request (fun (_response, s) ->
           D.debug "%s starting proxy" __FUNCTION__ ;
           Unixext.proxy (Unix.dup s) (Unix.dup nbd_client)
       )
      ) ;
    Unix.close proxy_srv
  with e ->
    D.debug "%s did not get connection due to %s, closing" __FUNCTION__
      (Printexc.to_string e) ;
    Unix.close proxy_srv ;
    raise e

(** Polling interval for mirror operations (in seconds) *)
let mirror_poll_interval = 0.5

(** Wait for a mirror operation to complete, checking status periodically.
    Raises Storage_error if the mirror fails. *)
let wait_for_mirror_completion ~dbg ~sr ~vdi ~vm ~error_msg mirror_key =
  let rec wait key =
    let {failed; complete; progress} : Mirror.status =
      Local.DATA.stat dbg sr vdi vm key
    in
    if complete then
      Option.iter (fun p -> D.debug "%s mirror completed, progress: %f" __FUNCTION__ p) progress
    else if failed then
      raise (Storage_interface.Storage_error (Migration_mirror_failure error_msg))
    else (
      Option.iter (fun p -> D.debug "%s mirror progress: %f" __FUNCTION__ p) progress ;
      Unix.sleepf mirror_poll_interval ;
      wait key
    )
  in
  match mirror_key with
  | Storage_interface.Mirror.CopyV1 _ ->
      ()
  | Storage_interface.Mirror.MirrorV1 _ ->
      wait mirror_key

(** Attach and activate a snapshot VDI for reading *)
let attach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm =
  D.debug "%s attaching snapshot VDI %s with dp %s" __FUNCTION__
    (s_of_vdi snapshot_vdi) dp ;
  ignore (Local.VDI.attach3 dbg dp sr snapshot_vdi copy_vm false) ;
  Local.VDI.activate_readonly dbg dp sr snapshot_vdi copy_vm

(** Detach and deactivate a snapshot VDI *)
let detach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm =
  D.debug "%s detaching snapshot VDI %s" __FUNCTION__ (s_of_vdi snapshot_vdi) ;
  Local.VDI.deactivate dbg dp sr snapshot_vdi copy_vm ;
  Local.VDI.detach dbg dp sr snapshot_vdi copy_vm

(** Create a snapshot of the destination VDI to preserve the mirrored state *)
let create_destination_snapshot ~dbg ~dest_sr ~dest_url ~verify_dest ~dest_vdi_info =
  let (module Remote) =
    Storage_migrate_helper.get_remote_backend dest_url verify_dest
  in
  D.debug "%s creating snapshot of destination VDI %s" __FUNCTION__
    (s_of_vdi dest_vdi_info.vdi) ;
  Remote.VDI.snapshot dbg dest_sr
    {dest_vdi_info with sm_config= [("snapshot_parent", "true")]}

(** [mirror_snapshot_into_existing_dest] mirrors a single snapshot VDI into an
    existing destination VDI (typically the mirror_vdi created by receive_start3).
    After mirroring completes, it snapshots the destination VDI to preserve the
    snapshot state. *)
let mirror_snapshot_into_existing_dest ~dbg ~sr ~snapshot_vdi_uuid ~dest_sr
    ~dest_url ~verify_dest ~mirror_vm ~copy_vm ~dest_vdi_info ~nbd_uri =
  SXM.info "%s mirroring snapshot %s into VDI %s" __FUNCTION__
    snapshot_vdi_uuid (s_of_vdi dest_vdi_info.vdi) ;

  let snapshot_vdi = Vdi.of_string snapshot_vdi_uuid in
  let dp = Uuidx.(to_string (make ())) in

  try
    attach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm ;
    
    D.debug "%s starting QEMU mirror from snapshot %s" __FUNCTION__ snapshot_vdi_uuid ;
    let mirror_key = Local.DATA.mirror dbg sr snapshot_vdi copy_vm nbd_uri in
    
    wait_for_mirror_completion ~dbg ~sr ~vdi:snapshot_vdi ~vm:copy_vm
      ~error_msg:(Printf.sprintf "Snapshot %s mirror failed" snapshot_vdi_uuid)
      mirror_key ;
    
    detach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm ;
    
    let dest_snapshot =
      create_destination_snapshot ~dbg ~dest_sr ~dest_url ~verify_dest ~dest_vdi_info
    in
    D.debug "%s destination snapshot created: %s" __FUNCTION__
      (s_of_vdi dest_snapshot.vdi) ;
    
    dest_snapshot
  with e ->
    D.error "%s snapshot mirror failed: %s" __FUNCTION__ (Printexc.to_string e) ;
    (* Best-effort cleanup *)
    (try detach_snapshot_vdi ~dbg ~dp ~sr ~snapshot_vdi ~copy_vm with _ -> ()) ;
    raise e

let mirror_wait ~dbg ~sr ~vdi ~vm ~mirror_id mirror_key =
  let rec mirror_wait_rec key =
    let {failed; complete; progress} : Mirror.status =
      Local.DATA.stat dbg sr vdi vm key
    in
    if complete then (
      Option.fold ~none:()
        ~some:(fun p -> D.info "%s progress is %f" __FUNCTION__ p)
        progress ;
      D.info "%s qemu mirror %s completed" mirror_id __FUNCTION__
    ) else if failed then (
      Option.iter
        (fun (snd_state : State.Send_state.t) -> snd_state.failed <- true)
        (State.find_active_local_mirror mirror_id) ;
      D.info "%s qemu mirror %s failed" mirror_id __FUNCTION__ ;
      State.find_active_local_mirror mirror_id
      |> Option.iter (fun (s : State.Send_state.t) -> s.failed <- true) ;
      Updates.add (Dynamic.Mirror mirror_id) updates ;
      raise
        (Storage_interface.Storage_error
           (Migration_mirror_failure "Mirror failed during syncing")
        )
    ) else (
      Option.fold ~none:()
        ~some:(fun p -> D.info "%s progress is %f" __FUNCTION__ p)
        progress ;
      mirror_wait_rec key
    )
  in

  match mirror_key with
  | Storage_interface.Mirror.CopyV1 _ ->
      ()
  | Storage_interface.Mirror.MirrorV1 _ ->
      D.debug "%s waiting for mirroring to be done" __FUNCTION__ ;
      mirror_wait_rec mirror_key

(** Helper to extract NBD export name from backend attach info *)
let nbd_export_of_attach_info backend =
  let _, _, _, nbds = Storage_interface.implementations_of_backend backend in
  match nbds with
  | [] ->
      None
  | nbd :: _ ->
      let _socket, export = Storage_interface.parse_nbd_uri nbd in
      Some export

(** Retrieve snapshot chain for a VDI in base-to-leaf order.
    Returns list of (uuid, snapshot_time) tuples to preserve metadata. *)
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

(** Start NBD proxy thread for remote mirroring *)
let start_nbd_proxy_thread ~url ~mirror_vm ~dest_sr ~mirror_vdi ~mirror_datapath ~verify_dest =
  Thread.create
    (fun () ->
      export_nbd_proxy ~remote_url:url ~mirror_vm ~sr:dest_sr
        ~vdi:mirror_vdi.vdi ~dp:mirror_datapath ~verify_dest
    )
    ()

(** Switch destination VDI from readonly to writable mode *)
let switch_vdi_to_writable ~dbg ~url ~verify_dest ~mirror_datapath ~dest_sr ~mirror_vdi ~mirror_vm =
  let (module Remote) = Storage_migrate_helper.get_remote_backend url verify_dest in
  D.debug "%s switching VDI %s to writable" __FUNCTION__ (s_of_vdi mirror_vdi.vdi) ;
  Remote.VDI.deactivate dbg mirror_datapath dest_sr mirror_vdi.vdi mirror_vm ;
  Remote.VDI.activate3 dbg mirror_datapath dest_sr mirror_vdi.vdi mirror_vm

(** Mirror a single snapshot and record the mapping with metadata *)
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

(** Process all snapshots in base-to-leaf order, preserving metadata *)
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

module MIRROR : SMAPIv2_MIRROR = struct
  type context = unit

  let send_start _ctx ~dbg ~task_id:_ ~dp ~sr ~vdi ~mirror_vm ~mirror_id
      ~local_vdi:_ ~copy_vm ~live_vm ~url ~remote_mirror ~dest_sr ~verify_dest
      =
    D.debug
      "%s dbg: %s dp: %s sr: %s vdi:%s mirror_vm:%s mirror_id: %s live_vm: %s \
       url:%s dest_sr:%s verify_dest:%B"
      __FUNCTION__ dbg dp (s_of_sr sr) (s_of_vdi vdi) (s_of_vm mirror_vm)
      mirror_id (s_of_vm live_vm) url (s_of_sr dest_sr) verify_dest ;
    ignore (Local.VDI.attach3 dbg dp sr vdi (Vm.of_string "0") true) ;
    (* TODO we are not activating the VDI here because SMAPIv3 does not support
       activating the VDI again on dom 0 when it is already activated on the live_vm.
       This means that if the VM shutsdown while SXM is in progress the
       mirroring for SMAPIv3 will fail.*)
    
    (* Track snapshot mappings created during mirroring *)
    let snapshot_mappings = ref [] in
    
    (* Get snapshot chain for migration *)
    let snapshot_chain = get_snapshot_chain ~dbg ~vdi in
    if snapshot_chain <> [] then
      SXM.info "%s found %d snapshot(s) to mirror" __FUNCTION__ (List.length snapshot_chain) ;
    
    match remote_mirror with
    | Mirror.Vhd_mirror _ ->
        raise
          (Storage_error
             (Migration_preparation_failure
                "Incorrect remote mirror format for SMAPIv3"
             )
          )
    | Mirror.SMAPIv3_mirror {nbd_export; mirror_datapath; mirror_vdi} -> (
      try
        let nbd_proxy_path =
          Printf.sprintf "/var/run/nbdproxy/export/%s" (Vm.string_of mirror_vm)
        in
        let nbd_uri =
          Uri.make ~scheme:"nbd+unix" ~host:"" ~path:nbd_export
            ~query:[("socket", [nbd_proxy_path])]
            ()
          |> Uri.to_string
        in
        (* Mirror snapshots and switch VDI to writable mode *)
        let mappings =
          process_snapshots ~dbg ~sr ~dest_sr ~url ~verify_dest
            ~mirror_vm ~copy_vm ~mirror_vdi ~mirror_datapath ~nbd_uri
            ~snapshots:snapshot_chain
        in
        snapshot_mappings := mappings ;
        
        if mappings <> [] then
          SXM.info "%s %d snapshot(s) mirrored successfully" __FUNCTION__
            (List.length mappings) ;
        
        switch_vdi_to_writable ~dbg ~url ~verify_dest ~mirror_datapath
          ~dest_sr ~mirror_vdi ~mirror_vm ;
        
        (* Start NBD proxy for leaf mirror *)
        D.debug "%s starting NBD proxy for leaf mirror" __FUNCTION__ ;
        let _ : Thread.t = start_nbd_proxy_thread ~url ~mirror_vm ~dest_sr
          ~mirror_vdi ~mirror_datapath ~verify_dest in

        D.info "%s nbd_proxy_path: %s nbd_url %s" __FUNCTION__ nbd_proxy_path
          nbd_uri ;
        let mk = Local.DATA.mirror dbg sr vdi live_vm nbd_uri in

        D.debug "%s Updating active local mirrors: id=%s" __FUNCTION__ mirror_id ;
        let alm =
          State.Send_state.
            {
              url
            ; dest_sr
            ; remote_info=
                Some
                  {dp= mirror_datapath; vdi= mirror_vdi.vdi; url; verify_dest}
            ; local_dp= dp
            ; tapdev= None
            ; failed= false
            ; watchdog= None
            ; vdi
            ; live_vm
            ; mirror_key= Some mk
            }
        in
        State.add mirror_id (State.Send_op alm) ;
        D.debug "%s Updated mirror_id %s in the active local mirror"
          __FUNCTION__ mirror_id ;
        mirror_wait ~dbg ~sr ~vdi ~vm:live_vm ~mirror_id mk ;
        
        (* Store snapshot mappings for retrieval by xapi_vm_migrate *)
        if !snapshot_mappings <> [] then (
          D.debug "%s storing %d snapshot mapping(s) for mirror %s" __FUNCTION__
            (List.length !snapshot_mappings) mirror_id ;
          State.set_snapshot_mappings mirror_id !snapshot_mappings
        )
      with e ->
        D.error "%s caught exception during mirror: %s" __FUNCTION__
          (Printexc.to_string e) ;
        raise
          (Storage_interface.Storage_error
             (Migration_mirror_failure (Printexc.to_string e))
          )
    )

  let receive_start _ctx ~dbg:_ ~sr:_ ~vdi_info:_ ~id:_ ~similar:_ =
    Storage_interface.unimplemented __FUNCTION__

  let receive_start2 _ctx ~dbg:_ ~sr:_ ~vdi_info:_ ~id:_ ~similar:_ ~vm:_ =
    Storage_interface.unimplemented __FUNCTION__

  let receive_start3 _ctx ~dbg ~sr ~vdi_info ~mirror_id ~similar:_ ~vm ~url
      ~verify_dest =
    D.debug "%s dbg: %s sr: %s vdi: %s id: %s vm: %s url: %s verify_dest: %B"
      __FUNCTION__ dbg (s_of_sr sr)
      (string_of_vdi_info vdi_info)
      mirror_id (s_of_vm vm) url verify_dest ;
    let module Remote = StorageAPI (Idl.Exn.GenClient (struct
      let rpc =
        Storage_utils.rpc ~srcstr:"smapiv2" ~dststr:"dst_smapiv2"
          (Storage_utils.connection_args_of_uri ~verify_dest url)
    end)) in
    let on_fail : (unit -> unit) list ref = ref [] in
    try
      (* We drop cbt_metadata VDIs that do not have any actual data *)
      let (vdi_info : vdi_info) =
        {vdi_info with sm_config= [("base_mirror", mirror_id)]}
      in
      let leaf_dp = Remote.DP.create dbg Uuidx.(to_string (make ())) in
      let leaf = Remote.VDI.create dbg sr vdi_info in
      D.info "Created leaf VDI for mirror receive: %s" (string_of_vdi_info leaf) ;
      on_fail := (fun () -> Remote.VDI.destroy dbg sr leaf.vdi) :: !on_fail ;
      let backend = Remote.VDI.attach3 dbg leaf_dp sr leaf.vdi vm true in
      let nbd_export =
        match nbd_export_of_attach_info backend with
        | None ->
            raise
              (Storage_error
                 (Migration_preparation_failure "Cannot parse nbd uri")
              )
        | Some export ->
            export
      in
      D.debug "%s activating (readonly) dp %s sr: %s vdi: %s vm: %s" __FUNCTION__ leaf_dp
        (s_of_sr sr) (s_of_vdi leaf.vdi) (s_of_vm vm) ;
      Remote.VDI.activate_readonly dbg leaf_dp sr leaf.vdi vm ;
      let qcow2_res =
        {Mirror.mirror_vdi= leaf; mirror_datapath= leaf_dp; nbd_export}
      in
      let remote_mirror = Mirror.SMAPIv3_mirror qcow2_res in
      D.debug
        "%s updating receiving state lcoally to id: %s vm: %s vdi_info: %s"
        __FUNCTION__ mirror_id (s_of_vm vm)
        (string_of_vdi_info vdi_info) ;
      State.add mirror_id
        State.(
          Recv_op
            Receive_state.
              {
                sr
              ; leaf_vdi= qcow2_res.mirror_vdi.vdi
              ; leaf_dp= qcow2_res.mirror_datapath
              ; remote_vdi= vdi_info.vdi
              ; mirror_vm= vm
              ; dummy_vdi=
                  Vdi.of_string "dummy"
                  (* No dummy_vdi is needed when migrating from SMAPIv3 SRs, having a
                     "dummy" VDI here is fine as cleanup code for SMAPIv3 will not
                     access dummy_vdi, and all the clean up functions will ignore
                     exceptions when trying to clean up the dummy VDIs even if they
                     do access dummy_vdi. The same applies to parent_vdi *)
              ; parent_vdi= Vdi.of_string "dummy"
              ; url
              ; verify_dest
              }
        ) ;
      remote_mirror
    with e ->
      List.iter
        (fun op ->
          try op ()
          with e ->
            D.warn "Caught exception in on_fail: %s performing cleaning up"
              (Printexc.to_string e)
        )
        !on_fail ;
      raise e

  let receive_finalize _ctx ~dbg:_ ~id:_ =
    Storage_interface.unimplemented __FUNCTION__

  let receive_finalize2 _ctx ~dbg:_ ~id:_ =
    Storage_interface.unimplemented __FUNCTION__

  let receive_finalize3 _ctx ~dbg ~mirror_id ~sr ~url ~verify_dest =
    D.debug "%s dbg:%s id: %s sr: %s url: %s verify_dest: %B" __FUNCTION__ dbg
      mirror_id (s_of_sr sr) url verify_dest ;
    let (module Remote) =
      Storage_migrate_helper.get_remote_backend url verify_dest
    in
    let open State.Receive_state in
    let recv_state = State.find_active_receive_mirror mirror_id in
    Option.iter
      (fun r ->
        Remote.DP.destroy2 dbg r.leaf_dp r.sr r.leaf_vdi r.mirror_vm false ;
        Remote.VDI.remove_from_sm_config dbg r.sr r.leaf_vdi "base_mirror"
      )
      recv_state ;
    State.remove_receive_mirror mirror_id

  let receive_cancel _ctx ~dbg:_ ~id:_ =
    Storage_interface.unimplemented __FUNCTION__

  let list _ctx = Storage_interface.unimplemented __FUNCTION__

  let stat _ctx = Storage_interface.unimplemented __FUNCTION__

  let receive_cancel2 _ctx ~dbg ~mirror_id ~url ~verify_dest =
    D.debug "%s dbg:%s mirror_id:%s url:%s verify_dest:%B" __FUNCTION__ dbg
      mirror_id url verify_dest ;
    let (module Remote) =
      Storage_migrate_helper.get_remote_backend url verify_dest
    in
    let receive_state = State.find_active_receive_mirror mirror_id in
    let open State.Receive_state in
    Option.iter
      (fun r ->
        D.log_and_ignore_exn (fun () -> Remote.DP.destroy dbg r.leaf_dp false) ;
        D.log_and_ignore_exn (fun () -> Remote.VDI.destroy dbg r.sr r.leaf_vdi)
      )
      receive_state ;
    State.remove_receive_mirror mirror_id

  let has_mirror_failed _ctx ~dbg ~mirror_id ~sr =
    match State.find_active_local_mirror mirror_id with
    | Some ({mirror_key= Some mk; vdi; live_vm; _} : State.Send_state.t) ->
        let {failed; _} : Mirror.status =
          Local.DATA.stat dbg sr vdi live_vm mk
        in
        failed
    | _ ->
        false

  (* TODO currently we make the pre_deactivate_hook for SMAPIv3 a noop while for
     SMAPIv1 it will do a final check of the state of the mirror and report error
     if there is a mirror failure. We leave this for SMAPIv3 because the Data.stat
     call, which checks for the state of the mirror stops working once the domain
     has been paused, which happens before VDI.deactivate, hence we cannot do this check in
     pre_deactivate_hook. Instead we work around this by doing mirror check in mirror_wait
     as we repeatedly poll the state of the mirror job. In the future we might
     want to invent a different hook that can be called to do a final check just
     before the VM is paused. *)
  let pre_deactivate_hook _ctx ~dbg ~dp ~sr ~vdi =
    D.debug "%s dbg: %s dp: %s sr: %s vdi: %s" __FUNCTION__ dbg dp (s_of_sr sr)
      (s_of_vdi vdi)
end
