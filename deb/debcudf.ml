(*****************************************************************************)
(*  Copyright (C) 2009  <pietro.abate@pps.jussieu.fr>                        *)
(*                                                                           *)
(*  This library is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU Lesser General Public License as           *)
(*  published by the Free Software Foundation, either version 3 of the       *)
(*  License, or (at your option) any later version.  A special linking       *)
(*  exception to the GNU Lesser General Public License applies to this       *)
(*  library, see the COPYING file for more information.                      *)
(*****************************************************************************)

(** Debian Specific Ipr to Cudf conversion routines *)

open IprLib
open ExtLib
open Common

open Ipr

let virtual_table = Hashtbl.create 50000
let unit_table = Hashtbl.create 50000
let versions_table = Hashtbl.create 50000
let temp_versions_table = Hashtbl.create 50000
let versioned_table = Hashtbl.create 50000

(* this function is copy of a the same function in
   ipr but not exported in ipr.mli . At the moment is used
   only here ... *)
let cudfop = function
  |Some(("<<" | "<"),v) -> Some(`Lt,v)
  |Some((">>" | ">"),v) -> Some(`Gt,v)
  |Some("<=",v) -> Some(`Leq,v)
  |Some(">=",v) -> Some(`Geq,v)
  |Some("=",v) -> Some(`Eq,v)
  |None -> None
  |_ -> assert false

let init_versions_table =
  let add name version =
    try
      let l = Hashtbl.find temp_versions_table name in
      Hashtbl.replace temp_versions_table name (version::l)
    with Not_found -> Hashtbl.add temp_versions_table name [version]
  in
  fun pkg ->
    add pkg.name pkg.version;
    begin
      List.iter (fun (name,sel) ->
        match cudfop sel with
          |None -> ()
          |Some(_,version) -> add name version
      ) 
      (pkg.provides @ pkg.conflicts)
    end
    ;
    begin
      List.iter (fun disjunction ->
        List.iter (fun (name,sel) ->
          match cudfop sel with
            |None -> ()
            |Some(_,version) -> add name version
        ) disjunction
      )
      (pkg.depends @ pkg.pre_depends)
    end
;;

let init_virtual_table pkg =
  let add name =
    if not(Hashtbl.mem virtual_table name)
    then Hashtbl.add virtual_table name ()
  in
  List.iter (fun (name,_) -> add name) pkg.provides

let init_unit_table pkg =
  if not(Hashtbl.mem unit_table pkg.name)
  then Hashtbl.add unit_table pkg.name ()

let init_versioned_table pkg =
  let add name =
    if not(Hashtbl.mem versioned_table name)
    then Hashtbl.add versioned_table name ()
  in
  List.iter (fun (name,_) -> add name) pkg.conflicts
  ;
  begin
    List.iter (fun disjunction ->
      List.iter (fun (name,_)-> add name) disjunction
    ) (pkg.depends @ pkg.pre_depends)
  end
;;

let init_tables pkglist =
  List.iter (fun pkg ->
    init_versions_table pkg;
    init_virtual_table pkg;
    init_versioned_table pkg;
    init_unit_table pkg;
  ) pkglist
  ;
  Hashtbl.iter (fun k l ->
    Hashtbl.add versions_table k
    (List.unique (List.sort ~cmp:Version.compare l))
  ) temp_versions_table
  ;
  Hashtbl.clear temp_versions_table
;;

(* versions start from 1 *)
let get_version (package,version) =
  let l = Hashtbl.find versions_table package in
  let i = fst(List.findi (fun i a -> a = version) l) in
  i + 1

let loadl l =
  List.flatten (
    List.map (fun (name,sel) ->
      match cudfop sel with
        |None ->
            if (Hashtbl.mem virtual_table name) &&
            (Hashtbl.mem versioned_table name) then
              [(Ipr.escape (name^"--virtual"), None);
               (Ipr.escape name, None)]
            else
              [(Ipr.escape name, None)]
        |Some(op,v) ->
            [(Ipr.escape name,Some(op,get_version (name,v)))]
    ) l
  )

let loadlc name l = (Ipr.escape name, None)::(loadl l)

let loadlp l =
  List.map (fun (name,sel) ->
    match cudfop sel with
      |None  ->
          if (Hashtbl.mem unit_table name) || (Hashtbl.mem versioned_table name)
          then (Ipr.escape (name^"--virtual"),None)
          else (Ipr.escape name, None)
      |Some(`Eq,v) ->
          if (Hashtbl.mem unit_table name) || (Hashtbl.mem versioned_table name)
          then (Ipr.escape (name^"--virtual"),Some(`Eq,get_version (name,v)))
          else (Ipr.escape name,Some(`Eq,get_version (name,v)))
      |_ -> assert false
  ) l

let loadll ll = List.map loadl ll

(* ========================================= *)

let tocudf ?(inst=false) pkg =
    { Cudf.package = Ipr.escape pkg.name ;
      Cudf.version = get_version (pkg.name,pkg.version) ;
      Cudf.depends = loadll (pkg.depends @ pkg.pre_depends);
      Cudf.conflicts = loadlc pkg.name pkg.conflicts ;
      Cudf.provides = loadlp pkg.provides ;
      Cudf.installed = inst ;
      Cudf.keep = None ;
      Cudf.extra = [("number",`Version pkg.version)]
    }

let load_universe ?(init=true) l =
  let timer = Util.Timer.create "Debian.Debcudf.load_universe" in
  Util.Timer.start timer;
  if init then init_tables l ;
  let pl = Cudf.load_universe (List.map tocudf l) in
  Util.Timer.stop timer pl
