(******************************************************************************)
(*  This file is part of the Dose library http://www.irill.org/software/dose  *)
(*                                                                            *)
(*  Copyright (C) 2009-2012 Pietro Abate <pietro.abate@pps.jussieu.fr>        *)
(*                                                                            *)
(*  This library is free software: you can redistribute it and/or modify      *)
(*  it under the terms of the GNU Lesser General Public License as            *)
(*  published by the Free Software Foundation, either version 3 of the        *)
(*  License, or (at your option) any later version.  A special linking        *)
(*  exception to the GNU Lesser General Public License applies to this        *)
(*  library, see the COPYING file for more information.                       *)
(*                                                                            *)
(*  Work developed with the support of the Mancoosi Project                   *)
(*  http://www.mancoosi.org                                                   *)
(*                                                                            *)
(******************************************************************************)

open ExtLib
open Common
open Algo
open Debian

module Options = struct
  open OptParse
  let description = (
    "Check for Debian Package Coinstallability."^
    "Return the list of binary package. If --src <Sources> is specified"^
    "then we return the list of corresponding source packages")

  let options = OptParser.make ~description
  include Boilerplate.MakeOptions(struct let options = options end)

  include Boilerplate.DistcheckOptions
  let default = List.remove Boilerplate.DistcheckOptions.default_options "successes" in
  Boilerplate.DistcheckOptions.add_options ~default options ;;

  include Boilerplate.InputOptions
  let default = List.remove Boilerplate.InputOptions.default_options "inputtype" in
  Boilerplate.InputOptions.add_options ~default options ;;

  include Boilerplate.DistribOptions;;
  (* remove other not used --deb options *)
  let default = List.remove Boilerplate.DistribOptions.default_options "deb-host-arch" in
  let default = ["deb-triplettable";"deb-cputable"]@default in
  Boilerplate.DistribOptions.add_options ~default options ;;
  
  let sources = StdOpt.str_option ()
  let dump = StdOpt.str_option ()
  let triplettable = StdOpt.str_option ()
  let cputable = StdOpt.str_option ()

  open OptParser
  add options ~long_name:"src" ~help:"Associate Sources file" sources;
  add options ~long_name:"dump" ~help:"dump the cudf file" dump;
  add options ~long_name:"deb-triplettable" ~help:"Path to an architecture triplet table like /usr/share/dpkg/triplettable" triplettable;
  add options ~long_name:"deb-cputable" ~help:"Path to a cpu table like /usr/share/dpkg/cputable" cputable;

end

include Util.Logging(struct let label = __FILE__ end) ;;

let timer = Util.Timer.create "Solver" 

let main () =
  let posargs = OptParse.OptParser.parse_argv Options.options in
  Boilerplate.enable_debug (OptParse.Opt.get Options.verbose);
  Boilerplate.enable_timers (OptParse.Opt.get Options.timers) ["Solver"];
  Boilerplate.enable_bars (OptParse.Opt.get Options.progress)
    ["Depsolver_int.univcheck";"Depsolver_int.init_solver"] ;
  Boilerplate.all_quiet (OptParse.Opt.get Options.quiet);

  let options = Options.set_deb_options () in

  let (fg,bg) = Options.parse_cmdline (`Deb,false) posargs in

  if (((OptParse.Opt.is_set Options.triplettable)
       || OptParse.Opt.is_set Options.cputable)
      && (OptParse.Opt.is_set Options.sources)) then begin
    let ttfile = if OptParse.Opt.is_set Options.triplettable then
        Some (OptParse.Opt.get Options.triplettable)
      else None in
    let ctfile = if OptParse.Opt.is_set Options.cputable then
        Some (OptParse.Opt.get Options.cputable)
      else None in
    Architecture.read_triplettable ~ttfile ~ctfile ()
  end;

  let cudftodeb_table = Hashtbl.create 30000 in
  let cudftosrc_table = Hashtbl.create 30000 in

  let deb_load_list options ?(status=[]) sources urilist =
    let native = Option.get options.Debian.Debcudf.native in
    let archs =
      if native <> "" then
        native :: options.Debian.Debcudf.foreign
      else []
    in
    let dll =
      List.map (fun filelist ->
        Debian.Packages.input_raw ~archs filelist
      ) urilist
    in
    let pkglist = List.flatten dll in
    let pkglist = if status = [] then pkglist else Debian.Packages.merge status pkglist in
    let origsourcelist = 
      if not(Option.is_none sources) then
        Sources.input_raw ~archs [Option.get sources]
      else []
    in
    let srclist = 
      if not(Option.is_none sources) then
        Sources.sources2packages ~noindep:true ~profiles:false native native origsourcelist
      else []
    in
    let tables = Debian.Debcudf.init_tables (srclist@pkglist) in
    let from_cudf (p,i) = (p,Debian.Debcudf.get_real_version tables (p,i)) in
    let to_cudf (p,v) = (p,Debian.Debcudf.get_cudf_version tables (p,v)) in
    let srcl =
      let dl = List.map (Debian.Debcudf.tocudf tables ~options) srclist in
      List.iter2 (fun cudfpkg -> fun srcpkg ->
        let id = (cudfpkg.Cudf.package,cudfpkg.Cudf.version) in
        Hashtbl.add cudftosrc_table id srcpkg
      ) dl origsourcelist;
      dl
    in

    let cll =
      List.map (fun l ->
        List.map (fun debpkg ->
          let cudfpkg = Debian.Debcudf.tocudf tables ~options debpkg in
          let id = (cudfpkg.Cudf.package,cudfpkg.Cudf.version) in
          Hashtbl.add cudftodeb_table id debpkg;
          cudfpkg
        ) (Debian.Packages.merge status l)
      ) dll
    in
    let preamble = Debian.Debcudf.preamble in
    (preamble,cll,srcl,from_cudf,to_cudf)
  in

  let sources = OptParse.Opt.opt Options.sources in
  let (preamble,pkgll,srclist,from_cudf,to_cudf) = deb_load_list options sources [fg;bg] in

  let (fg_pkglist, bg_pkglist) = match pkgll with [fg;bg] -> (fg,bg) | _ -> assert false in

  let fg_pkglist = 
    if OptParse.Opt.get Options.latest then CudfAdd.latest fg_pkglist
    else fg_pkglist
  in
  let universe = 
    let s = CudfAdd.to_set (srclist @ fg_pkglist @ bg_pkglist) in
    Cudf.load_universe (CudfAdd.Cudf_set.elements s) 
  in
  let universe_size = Cudf.universe_size universe in

  if OptParse.Opt.is_set Options.dump then begin
    let oc = open_out (OptParse.Opt.get Options.dump) in
    info "Dumping Cudf file";

    Cudf_printer.pp_preamble oc Debcudf.preamble;
    Printf.fprintf oc "\n";
    Cudf_printer.pp_universe oc universe
  end;

  let checklist = 
    if OptParse.Opt.is_set Options.checkonly then begin
      info "--checkonly specified, consider all packages as background packages";
      List.flatten (
        List.map (fun ((n,a),c) ->
          let (name,filter) = Debian.Debutil.debvpkg to_cudf ((n,a),c) in
          Cudf.lookup_packages ~filter universe name
        ) (OptParse.Opt.get Options.checkonly)
      )
    end else fg_pkglist
  in

  let pp = CudfAdd.pp from_cudf in

  info "Solving..." ;
  let failure = OptParse.Opt.get Options.failure in
  let explain = OptParse.Opt.get Options.explain in
  let minimal = OptParse.Opt.get Options.minimal in
  let oc = 
    if OptParse.Opt.is_set Options.outfile then
      open_out (OptParse.Opt.get Options.outfile)
    else
      stdout
  in

  let fmt =
    if OptParse.Opt.is_set Options.outfile then
      Format.formatter_of_out_channel oc
    else
      Format.std_formatter
  in

  if failure then Format.fprintf fmt "@[<v 1>report:@,";

  let global_constraints = not(OptParse.Opt.get Options.deb_ignore_essential) in

  Util.Timer.start timer;
  let result = Depsolver.edos_coinstall ~global_constraints universe checklist in
  ignore(Util.Timer.stop timer ());

  let exitcode = 
    if Diagnostic.is_solution result then begin
      let is = Diagnostic.get_installationset result in
      begin if Option.is_none sources then
        List.iter (fun cudfpkg ->
          try
            let id = (cudfpkg.Cudf.package,cudfpkg.Cudf.version) in
            let debpkg = Hashtbl.find cudftodeb_table id in
            Printf.fprintf oc "%a\n" Debian.Printer.pp_package debpkg
          with Not_found -> assert false
        ) is
      else
        let l = 
          List.unique (
            List.map (fun binpkg ->
              let cudfpkg = Sources.get_src_package universe binpkg in
              let id = (cudfpkg.Cudf.package,cudfpkg.Cudf.version) in
              Hashtbl.find cudftosrc_table id
            ) is
          )
        in
        List.iter (Printf.fprintf oc "%a\n" Debian.Printer.pp_source) l
      end; 0 (* exit code 0 . All packages are installable *)
    end
    else begin
      Diagnostic.fprintf ~pp ~minimal ~failure ~explain fmt result;
      1 (* at least one package is not installable *)
    end
  in
  
  if failure then Format.fprintf fmt "@]@.";
  
  let fn = List.length fg_pkglist in
  let bn = List.length bg_pkglist in
  
  let nb,nf = 
    let cl = List.length checklist in
    if cl != 0 then ((fn + bn) - cl,cl) else (bn,fn)
  in
  
  if nb > 0 && failure then begin
    Format.fprintf fmt "background-packages: %d@." nb;
    Format.fprintf fmt "foreground-packages: %d@." nf
  end;

  if failure then begin
    Format.fprintf fmt "total-packages: %d@." universe_size;
  (*  Format.fprintf fmt "broken-packages: %d@." nbp; *)
  end;
  Boilerplate.exit(exitcode)
;;

Boilerplate.if_application
~alternatives:["dose-debcoinstall";"deb-coinstall"] __FILE__ main ;;

