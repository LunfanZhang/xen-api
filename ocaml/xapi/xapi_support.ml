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
module D = Debug.Make (struct let name = "xapi_support" end)

open D

let support_url = "ftp://support.xensource.com/uploads/"

(* URL to which the crashdump/whatever will be uploaded *)
let upload_url name =
  let uuid = Xapi_inventory.lookup Xapi_inventory._installation_uuid in
  Printf.sprintf "%s%s-%s" support_url uuid name

open Forkhelpers

let do_upload label file url options =
  let proxy =
    if List.mem_assoc "http_proxy" options then
      List.assoc "http_proxy" options
    else
      Option.value (Sys.getenv_opt "http_proxy") ~default:""
  in
  let env = Helpers.env_with_path [("URL", url); ("PROXY", proxy)] in
  match
    with_logfile_fd label (fun log_fd ->
        let pid =
          safe_close_and_exec ~env None (Some log_fd) (Some log_fd) []
            !Xapi_globs.upload_wrapper [file]
        in
        waitpid_fail_if_bad_exit pid
    )
  with
  | Success _ ->
      debug "Upload succeeded"
  | Failure (log, exn) ->
      debug "Upload failed, output: %s" log ;
      raise exn
