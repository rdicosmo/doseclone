(**************************************************************************************)
(*  Copyright (C) 2009 Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*  Copyright (C) 2009 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

(** Representation of a debian package description item. *)

open ExtLib
open Common
open Format822

let debug fmt = Util.make_debug "Debian.Packages" fmt
let info fmt = Util.make_info "Debian.Packages" fmt
let warning fmt = Util.make_warning "Debian.Packages" fmt
let fatal fmt = Util.make_fatal "Debian.Packages" fmt

(** debian package format *)
type package = {
  name : name ;
  version : version;
  architecture : string;
  multiarch : string;
  essential : bool;
  source : (name * version option) ;
  depends : vpkg list list;
  pre_depends : vpkg list list;
  recommends : vpkg list list;
  suggests : vpkg list;
  enhances : vpkg list;
  conflicts : vpkg list;
  breaks : vpkg list;
  replaces : vpkg list;
  provides : veqpkg list;
  extras : (string * string) list;
  priority : string;
}

let default_package = {
  name = "";
  version = "";
  architecture = "";
  multiarch = "";
  essential = false;
  depends = [];
  source = ("",None);
  pre_depends = [];
  recommends = [];
  suggests = [];
  enhances = [];
  conflicts = [];
  breaks = [];
  replaces = [];
  provides = [];
  extras = [];
  priority = "";
}

exception ParseError of string * string
exception IgnorePackage of string

let parse_s = Format822.parse_s
let parse_name _ s = Format822.parse_package s
let parse_version _ s = Format822.parse_version s
let parse_source _ s = Format822.parse_source s
let parse_vpkg _ s = Format822.parse_constr s
let parse_veqpkg _ s = Format822.parse_constr s
let parse_conj _ s = Format822.parse_vpkglist Format822.parse_constr s
let parse_cnf _ s = Format822.parse_vpkgformula Format822.parse_constr s
let parse_prov _ s = Format822.parse_veqpkglist Format822.parse_constr s

(* parse and convert to a specific type *)
let parse_bool field = function
  |("Yes"|"yes"|"True" |"true") -> true
  |("No" |"no" |"False"|"false") -> false (* this one usually is not there *)
  |s -> fatal "Field %s has a wrong value : %s" field s
let parse_string _ s = s
let parse_int _ s = int_of_string s

(* parse and return a string -> for extra fields *)
let parse_bool_s field = function
  |("Yes"|"yes"|"true" |"True") -> "true"
  |("No" |"no" |"false"|"False") -> "false" (* this one usually is not there *)
  |s -> fatal "Field %s has a wrong value : %s" field s
let parse_int_s _ s = string_of_int(int_of_string s)

let parse_architecture default_arch _ arch = 
  match default_arch with
  |None -> arch
  |Some default_arch ->
      if (default_arch = arch || arch = "all") then arch else
        raise (IgnorePackage (
          Printf.sprintf 
          "architecture: %s is different from %s (default) or 'all'" 
          arch default_arch
          )
        )
;;

let parse_multiarch _ = function
  |("None"|"none") -> "None"
  |("Allowed"|"allowed") -> "Allowed"
  |("Foreign"|"foreign") -> "Foreign"
  |("Same"|"Same") -> "Same"
  |s -> fatal "Field Multi-Arch has a wrong value : %s" s
;;

(* parse extra fields parse_f returns a string *)
let parse_e extras par =
  List.filter_map (fun (field, parse_f) ->
      try Some (field,parse_f par)
      with Not_found -> None
  ) extras
;;

let parse_package_stanza filter default_arch extras par = 
  let aux par = 
    let parse_arch = parse_architecture default_arch in
    let p = {
        name = parse_s ~err:"(MISSING NAME)" parse_name "Package" par;
        version = parse_s ~err:"(MISSING VERSION)" parse_version "Version" par;
        architecture = parse_s ~err:"(MISSING ARCH)" parse_arch "Architecture" par;
        multiarch = parse_s ~opt:"None" parse_multiarch "Multi-Arch" par;
        source = parse_s ~opt:("",None) parse_source "Source" par;

        essential = parse_s ~opt:false parse_bool "Essential" par;
        priority = parse_s ~opt:"" parse_string "Priority" par;

        depends = parse_s ~opt:[] ~multi:true parse_cnf "Depends" par;
        pre_depends = parse_s ~opt:[] ~multi:true parse_cnf "Pre-Depends" par;
        recommends = parse_s ~opt:[] ~multi:true parse_cnf "Recommends" par;
        suggests = parse_s ~opt:[] ~multi:true parse_conj "Suggests" par;
        enhances = parse_s ~opt:[] ~multi:true parse_conj "Enhances" par;
        conflicts = parse_s ~opt:[] ~multi:true parse_conj "Conflicts" par;
        breaks = parse_s ~opt:[] ~multi:true parse_conj "Breaks" par;
        replaces = parse_s ~opt:[] ~multi:true parse_conj "Replaces" par;
        provides = parse_s ~opt:[] ~multi:true parse_conj "Provides" par;
        extras = parse_e extras par;
    }
    in 
    if Option.is_none filter then Some p
    else if (Option.get filter) p then Some(p) else None
  in Format822.parse_packages_fields aux par
;;

(** parse a debian Packages file from the channel [ch] *)
let parse_packages_in ?filter ?(default_arch=None) ?(extras=[]) ch =
  let parse_packages = 
    Format822.parse_822_iter (
      parse_package_stanza filter default_arch extras
    ) 
  in
  parse_packages (Format822.start_from_channel ch)

(**/**)
let id p = (p.name,p.version,p.architecture)
let (>%) p1 p2 = Pervasives.compare (id p1) (id p2)
module Set = struct
  include Set.Make(struct 
    type t = package
    let compare = (>%)
  end)
end
(**/**)

let merge status packages =
  let merge_aux p1 p2 =
    if (p1 >% p2) = 0 then begin
      {p1 with
        essential = p1.essential || p2.essential;
        extras = List.unique (p1.extras @ p2.extras)
      }
    end else assert false
  in
  let h = Hashtbl.create (List.length status) in
  List.iter (fun p ->
    try
      match String.nsplit (assoc "Status" p.extras) " " with
      |[_;_;"installed"] -> Hashtbl.add h (id p) p
      |_ -> ()
    with Not_found -> ()
  ) status
  ;
  let ps = 
    List.fold_left (fun acc p ->
      try Set.add (merge_aux p (Hashtbl.find h (id p))) acc
      with Not_found -> Set.add p acc
    ) Set.empty (status @ packages)
  in
  Set.elements ps

let default_extras = [
  ("Status", parse_s parse_string "Status");
]

(** input_raw [file] : parse a debian Packages file from [file] *)
let input_raw ?filter ?(default_arch=None) ?(extras=[]) = 
  let module M = Format822.RawInput(Set) in
  let extras = default_extras @ extras in
  M.input_raw (parse_packages_in ?filter ~default_arch ~extras)

(** input_raw_ch ch : parse a debian Packages file from channel [ch] *)
let input_raw_ch ?(filter=None) ?(default_arch=None) ?(extras=[]) = 
  let module M = Format822.RawInput(Set) in
  let extras = default_extras @ extras in
  M.input_raw_ch (parse_packages_in ?filter ~default_arch ~extras)
