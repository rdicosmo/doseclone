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

(** Internal data package data format. Packages dependencies and conflicts are
    all expanded and explicit *)

open ExtLib
open CudfAdd

type package = {
  id : int ; (** package id relative to the universe *)
  pkg : Cudf.package; (** cudf package *)
  depends : (Cudf_types.vpkg list * int list * Cudf.package list) list ;
  conflicts : (Cudf.package * int) list (** cudf package and package id *)
}

type universe = {
  index : package array ; (** the array index is equal to the package id *)
  maps : CudfAdd.maps (** maps to associate a cudf package to an id *)
}

let default_package = {
  id = 0;
  pkg = Cudf.default_package;
  depends = [] ;
  conflicts = [] 
}

let __load maps universe =
  let cmp (x : int) (y : int) = x = y in
  let to_sat = maps.map#vartoint in
  let a = Array.create (Cudf.universe_size universe) default_package in
  Cudf.iter_packages (fun pkg ->
    let id = to_sat pkg in
    let cl =
      List.map (fun p ->
        (p,to_sat p)
      ) (maps.who_conflicts pkg)
    in
    let dll =
      List.map (fun disjunction ->
        let (l1,l2,l3) =
          List.fold_left (fun (l1,l2,l3) vpkg ->
            let dl = maps.who_provides vpkg in
            let el =
              List.map(fun p ->
                (* remove self provides *)
                (* let i = to_sat p in if i <> id then Some i else None *)
                to_sat p
              ) dl 
            in
            (vpkg::l1,el @ l2, dl @ l3)
          ) ([],[],[]) disjunction
        (* XXX Maybe here we can gain something if we use a set instead of a list *)
        in (l1,List.unique ~cmp l2, List.unique ~cmp:Cudf.(=%) l3)
      ) pkg.Cudf.depends
    in
    let p = {
      id = id;
      pkg = pkg;
      depends = dll;
      conflicts = cl
    }
    in
    a.(id) <- p
  ) universe;
  a

(** trasfrom a cudf package list in a Mdf universe. All references are
    explicit and given in terms of integer *)
let load_from_list pkglist =
  let universe = Cudf.load_universe pkglist in
  let maps = build_maps universe in
  let index = __load maps universe in
  { index = index ; maps = maps }

(** transform a cudf universe in a mdf universe. All references are
    explicit and given in terms of integer *)
let load_from_universe universe =
  let maps = build_maps universe in
  let index = __load maps universe in
  { index = index ; maps = maps }
