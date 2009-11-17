(***************************************************************************************)
(*  Copyright (C) 2009  Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*                                                                                     *)
(*  This library is free software: you can redistribute it and/or modify               *)
(*  it under the terms of the GNU Lesser General Public License as                     *)
(*  published by the Free Software Foundation, either version 3 of the                 *)
(*  License, or (at your option) any later version.  A special linking                 *)
(*  exception to the GNU Lesser General Public License applies to this                 *)
(*  library, see the COPYING file for more information.                                *)
(***************************************************************************************)

open Common
open CudfAdd

let strongconflicts cudfgraph universe pkglist =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  let intgraph = Strongdeps.cudfint maps cudfgraph in
  let l = Strongconflicts_int.strongconflicts intgraph mdf idlist in
  List.map (fun (x,y) -> (maps.map#inttovar x,maps.map#inttovar y)) l

