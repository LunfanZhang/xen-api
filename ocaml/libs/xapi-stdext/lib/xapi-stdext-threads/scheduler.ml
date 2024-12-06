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

module D = Debug.Make (struct let name = __MODULE__ end)

open D
module Delay = Xapi_stdext_threads.Threadext.Delay

let with_lock = Xapi_stdext_threads.Threadext.Mutex.execute

type func_ty = OneShot | Periodic of float

type t = {func: unit -> unit; ty: func_ty; name: string}

let delay = Delay.make ()

let queue_default = {func= (fun () -> ()); ty= OneShot; name= ""}

let (queue : t Ipq.t) = Ipq.create 50 queue_default

let lock = Mutex.create ()

module Clock = struct
  let span s = Mtime.Span.of_uint64_ns (Int64.of_float (s *. 1e9))

  let span_to_s span =
    Mtime.Span.to_uint64_ns span |> Int64.to_float |> fun ns -> ns /. 1e9

  let add_span clock secs =
    (* return mix or max available value if the add overflows *)
    match Mtime.add_span clock (span secs) with
    | Some t ->
        t
    | None when secs > 0. ->
        Mtime.max_stamp
    | None ->
        Mtime.min_stamp
end

let add_to_queue_internal ?(signal = true) name ty start newfunc =
  let ( ++ ) = Clock.add_span in
  let item =
    {Ipq.ev= {func= newfunc; ty; name}; Ipq.time= Mtime_clock.now () ++ start}
  in
  with_lock lock (fun () -> Ipq.add queue item) ;
  if signal then Delay.signal delay

let add_to_queue name ty start newfunc =
  add_to_queue_internal name ty start newfunc

let remove_from_queue name =
  with_lock lock @@ fun () ->
  let index = Ipq.find_p queue (fun {name= n; _} -> name = n) in
  if index > -1 then
    Ipq.remove queue index

let loop () =
  debug "%s started" __MODULE__ ;
  try
    while true do
      let empty = with_lock lock (fun () -> Ipq.is_empty queue) in
      if empty then
        Thread.delay 10.0
      (* Doesn't happen often - the queue isn't usually empty *)
      else
        let next = with_lock lock (fun () -> Ipq.maximum queue) in
        let now = Mtime_clock.now () in
        if Mtime.is_earlier next.Ipq.time ~than:now then (
          let todo =
            (with_lock lock (fun () -> Ipq.pop_maximum queue)).Ipq.ev
          in
          (try todo.func () with _ -> ()) ;
          match todo.ty with
          | OneShot ->
              ()
          | Periodic timer ->
              add_to_queue_internal ~signal:false todo.name todo.ty timer
                todo.func
        ) else (* Sleep until next event. *)
          let sleep =
            Mtime.(span next.Ipq.time now)
            |> Mtime.Span.(add ms)
            |> Clock.span_to_s
          in
          try ignore (Delay.wait delay sleep)
          with e ->
            let detailed_msg =
              match e with
              | Unix.Unix_error (code, _, _) ->
                  Unix.error_message code
              | _ ->
                  "unknown error"
            in
            error
              "Could not schedule interruptable delay (%s). Falling back to \
               normal delay. New events may be missed."
              detailed_msg ;
            Thread.delay sleep
    done
  with _ ->
    error
      "Scheduler thread died! This daemon will no longer function well and \
       should be restarted."
