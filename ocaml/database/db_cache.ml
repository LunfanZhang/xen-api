(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
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

open Db_interface

module D = Debug.Make (struct let name = "db_cache" end)

open D

(** Masters will use this to modify the in-memory cache directly *)
module Local_db : DB_ACCESS2 = Db_cache_impl

(** Slaves will use this to call the master by XMLRPC *)
module Remote_db : DB_ACCESS2 =
Db_interface_compat.OfCompat (Db_rpc_client_v1.Make (struct
  let initialise () =
    ignore (Master_connection.start_master_connection_watchdog ()) ;
    ignore (Master_connection.open_secure_connection ())

  let rpc request = Master_connection.execute_remote_fn request
end))

let get = function
  | Db_ref.In_memory _ ->
      (module Local_db : DB_ACCESS2)
  | Db_ref.Remote ->
      (module Remote_db : DB_ACCESS2)

let lifecycle_state_of ~obj fld =
  let open Datamodel in
  let {fld_states; _} = StringMap.find obj all_lifecycles in
  StringMap.find fld fld_states

module DB = Db_interface_compat.OfCached (Local_db)

let apply_delta_to_cache entry db_ref =
  match entry with
  | Redo_log.CreateRow (tblname, objref, kvs) ->
      debug "Redoing create_row %s (%s)" tblname objref ;
      DB.create_row db_ref tblname kvs objref
  | Redo_log.DeleteRow (tblname, objref) ->
      debug "Redoing delete_row %s (%s)" tblname objref ;
      DB.delete_row db_ref tblname objref
  | Redo_log.WriteField (tblname, objref, fldname, newval) ->
      let removed =
        try lifecycle_state_of ~obj:tblname fldname = Removed_s
        with Not_found ->
          warn "no lifetime information about %s.%s, ignoring write_field"
            tblname fldname ;
          true
      in
      if not removed then (
        debug "Redoing write_field %s (%s) [%s -> %s]" tblname objref fldname
          newval ;
        DB.write_field db_ref tblname objref fldname newval
      ) else
        info
          "Field has been removed from the datamodel, ignoring write_field %s \
           (%s) [%s -> %s]"
          tblname objref fldname newval
