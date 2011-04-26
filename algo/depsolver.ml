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

open ExtLib
open Common
open CudfAdd

let debug fmt = Util.make_debug "Depsolver" fmt
let info fmt = Util.make_info "Depsolver" fmt
let warning fmt = Util.make_warning "Depsolver" fmt
let fatal fmt = Util.make_fatal "Depsolver" fmt

type solver = {
  mdf : Mdf.universe ;
  solver : Depsolver_int.solver
}

(** 
 * @param check if the universe is consistent *)
let load ?(check=true) universe =
  let is_consistent check universe =
    if check then Cudf_checker.is_consistent universe
    else (true,None)
  in
  match is_consistent check universe with
  |true,None ->
      let mdf = Mdf.load_from_universe universe in
      let solver = Depsolver_int.init_solver mdf.Mdf.index in
      { mdf = mdf ; solver = solver }
  |false,Some(r) -> 
      fatal "%s"
      (Cudf_checker.explain_reason (r :> Cudf_checker.bad_solution_reason)) ;
  |_,_ -> assert false

let reason maps =
  let from_sat = maps.map#inttovar in
  List.map (function
    |Diagnostic_int.Dependency(i,vl,il) ->
        Diagnostic.Dependency(from_sat i,vl,List.map from_sat il)
    |Diagnostic_int.Missing(i,vl) ->
        Diagnostic.Missing(from_sat i,vl)
    |Diagnostic_int.Conflict(i,j) ->
        Diagnostic.Conflict(from_sat i,from_sat j)
  )

let result maps result = 
  let from_sat = maps.map#inttovar in
  match result with
  |Diagnostic_int.Success f_int ->
      Diagnostic.Success (fun ?(all=false) () ->
        List.map (fun i ->
          {(from_sat i) with Cudf.installed = true}
        ) (f_int ~all ())
      )
  |Diagnostic_int.Failure f -> Diagnostic.Failure (fun () -> reason maps (f ()))

let request maps result = 
  let from_sat = maps.map#inttovar in
  match result with
  |Diagnostic_int.Sng i -> Diagnostic.Package (from_sat i)
  |Diagnostic_int.Lst il -> Diagnostic.PackageList (List.map from_sat il)

let diagnosis maps res req =
  let result = result maps res in
  let request = request maps req in
  { Diagnostic.result = result ; request = request }

let univcheck ?callback universe =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  match callback with
  |None -> Depsolver_int.univcheck mdf
  |Some f ->
      let callback_int (res,req) = f (diagnosis maps res req) in
      Depsolver_int.univcheck ~callback:callback_int mdf

let listcheck ?callback universe pkglist =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  match callback with
  |None -> Depsolver_int.listcheck mdf idlist
  |Some f ->
      let callback_int (res,req) = f (diagnosis maps res req) in
      Depsolver_int.listcheck ~callback:callback_int mdf idlist

let edos_install s pkg =
  let maps = s.mdf.Mdf.maps in
  let req = Diagnostic_int.Sng (maps.map#vartoint pkg) in
  let res = Depsolver_int.solve s.solver req in
  diagnosis maps res req

let edos_coinstall s pkglist =
  let maps = s.mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  let req = Diagnostic_int.Lst idlist in
  let res = Depsolver_int.solve s.solver req in
  diagnosis maps res req

let trim universe =
  let trimmed_pkgs = ref [] in
  let callback d =
    if Diagnostic.is_solution d then
      match d.Diagnostic.request with
      | Diagnostic.Package p -> trimmed_pkgs := p::!trimmed_pkgs
      | _ -> assert false
  in
  ignore (univcheck ~callback universe);
  Cudf.load_universe !trimmed_pkgs

let dependency_closure ?maxdepth ?conjunctive universe pkglist =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  let closure = Depsolver_int.dependency_closure ?maxdepth ?conjunctive mdf idlist in
  List.map maps.map#inttovar closure

let reverse_dependencies universe =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let rev = Depsolver_int.reverse_dependencies mdf in
  let h = Cudf_hashtbl.create (Array.length rev) in
  Array.iteri (fun i l ->
    Cudf_hashtbl.add h (maps.map#inttovar i) (List.map maps.map#inttovar l)
  ) rev ;
  h

let reverse_dependency_closure ?maxdepth universe pkglist =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  let reverse = Depsolver_int.reverse_dependencies mdf in
  let closure = Depsolver_int.reverse_dependency_closure ?maxdepth reverse idlist in
  List.map maps.map#inttovar closure

type enc = Cnf | Dimacs

let output_clauses ?(enc=Cnf) universe =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let solver = Depsolver_int.init_solver ~buffer:true mdf.Mdf.index in
  let clauses = Depsolver_int.S.dump solver.Depsolver_int.constraints in
  let buff = Buffer.create (Cudf.universe_size universe) in
  let to_cnf dump =
    let str (v, p) = 
      let pkg = maps.map#inttovar (abs v) in
      let pol = if p then "" else "!" in
      Printf.sprintf "%s%s-%d" pol pkg.Cudf.package pkg.Cudf.version
    in
    List.iter (fun l ->
      List.iter (fun var -> Printf.bprintf buff " %s" (str var)) l;
      Printf.bprintf buff "\n"
    ) dump
  in
  let to_dimacs dump =
    let str (v, p) =
      if p then Printf.sprintf "%d" v else Printf.sprintf "-%d" v in
    let varnum = solver.Depsolver_int.nr_variables in
    let closenum = (List.length clauses) in
    Printf.bprintf buff "p cnf %d %d\n" varnum closenum;
    List.iter (fun l ->
      List.iter (fun var -> Printf.bprintf buff " %s" (str var)) l;
      Printf.bprintf buff " 0\n"
    ) dump
  in
  if enc = Cnf then to_cnf clauses ;
  if enc = Dimacs then to_dimacs clauses;
  Buffer.contents buff
;;

(** check if a cudf request is satisfiable. we do not care about
 * universe consistency . We try to installa dummy package *)
let check_request (_,pkglist,request) =
  let deps = 
    let k = 
      List.filter_map (fun pkg ->
        if pkg.Cudf.installed then
          match pkg.Cudf.keep with
          |`Keep_package -> Some(pkg.Cudf.package,None)
          |`Keep_version -> Some(pkg.Cudf.package,Some(`Eq,pkg.Cudf.version))
          |_ -> None
        else None
      ) pkglist
    in
    let l = request.Cudf.install @ request.Cudf.upgrade in
    debug "request consistency (keep %d) (install %d) (upgrade %d) (remove %d) (# %d)"
    (List.length k) (List.length request.Cudf.install) 
    (List.length request.Cudf.upgrade)
    (List.length request.Cudf.remove)
    (List.length pkglist);
    List.map (fun j -> [j]) (l @ k) 
  in
  let dummy = {
    Cudf.default_package with
    Cudf.package = "dummy";
    version = 1;
    depends = deps;
    conflicts = request.Cudf.remove}
  in
  let universe = Cudf.load_universe (dummy::pkglist) in
  let solver = load ~check:false universe in
  edos_install solver dummy

