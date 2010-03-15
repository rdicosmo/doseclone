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

(** Specialized Ocamlgraph modules *)

open Graph
open Common

let print_package = CudfAdd.print_package
let depgraphbar = Util.Progress.create "SyntacticDependencyGraph.dependency_graph"

(** generic operation over imperative graphs *)
module GraphOper (G : Sig.I) = struct

  (** transitive reduction.  Uses the transitive reduction algorithm from The
      Transitive Reduction of a Directed Graph, Aho, Garey and Ullman, 1972 - 
      with the proviso that we know that our graph already is a transitive 
      closure *)
  let transitive_reduction graph =
    let timer = Util.Timer.create "Defaultgraph.GraphOper.transitive_reduction" in
    Util.Timer.start timer;
    G.iter_vertex (fun v ->
      List.iter (fun v' ->
        if v <> v' then
        List.iter (fun v'' ->
          if v' <> v'' then
            G.remove_edge graph v v''
        ) (G.succ graph v')
      ) (G.succ graph v);
    ) graph;
    Util.Timer.stop timer ()

  module O = Oper.I(G) 

end

(** syntactic dependency graph. Vertex are Cudf packages and
    are indexed considering only the pair name,version .
    Edges are labelled with
    - [OrDepends] : disjuctive dependency
    - [DirDepends] : direct dependecy 
    - [Conflict] : conflict
    *) 
module SyntacticDependencyGraph = struct

  module PkgV = struct
      type t = Pkg of Cudf.package | Or of (Cudf.package * int)
      let compare x y = match (x,y) with
        |Or (p1,i1), Or (p2,i2) when (i1 = i2) && (CudfAdd.equal p1 p2) -> 0
        |Or (p1,i1), Or (p2,i2) -> CudfAdd.compare p1 p2
        |Pkg p1, Pkg p2 -> CudfAdd.compare p1 p2
        |Pkg _, Or _ -> 1
        |Or _, Pkg _ -> -1
      let hash = function
        |Pkg p -> Hashtbl.hash (p.Cudf.package,p.Cudf.version)
        |Or (p,i) -> Hashtbl.hash (p.Cudf.package,p.Cudf.version,i)
      let equal x y = match (x,y) with
        |Or (p1,i1), Or (p2,i2) -> (i1 = i2) && (CudfAdd.equal p1 p2)
        |Pkg p1, Pkg p2 -> CudfAdd.equal p1 p2
        |_ -> false
  end

  module PkgE = struct
    type t = OrDepends | DirDepends | Conflict

    let compare = Pervasives.compare
    let hash = Hashtbl.hash
    let equal x y = ((compare x y) = 0)
    let default = DirDepends
  end

  module G = Imperative.Digraph.ConcreteLabeled(PkgV)(PkgE) 

  let string_of_vertex vertex =
    match G.V.label vertex with
    |PkgV.Pkg p -> Printf.sprintf "Pkg %s" (print_package p)
    |PkgV.Or (p, _) -> Printf.sprintf "Or %s" (print_package p)

  let string_of_edge edge =
    let label =
      match G.E.label edge with
      |PkgE.DirDepends -> "Direct"
      |PkgE.OrDepends -> "Disjunctive"
      |PkgE.Conflict -> "Conflict"
    in
    let src = G.E.src edge in
    let dst = G.E.dst edge in
    Printf.sprintf "%s %s %s"
    (string_of_vertex src)
    label
    (string_of_vertex dst)

  module Display = struct
      include G
      let vertex_name v =
        match G.V.label v with
        |PkgV.Pkg i -> Printf.sprintf "\"%s\"" (print_package i)
        |PkgV.Or (i,c) -> Printf.sprintf "\"Or%s-%d\"" (print_package i) c

      let graph_attributes = fun _ -> []
      let get_subgraph = fun _ -> None

      let default_edge_attributes = fun _ -> []
      let default_vertex_attributes = fun _ -> []

      let vertex_attributes v =
        match G.V.label v with
        |PkgV.Or _ -> [`Label "Or"]
        |_ -> []

      let edge_attributes e =
        let t =
          match G.E.label e with
          |PkgE.DirDepends -> [`Style `Solid]
          |PkgE.OrDepends -> [`Style `Dashed]
          |PkgE.Conflict -> [`Color 0xFF0000; `Style `Solid; `Label "#"]
        in
        t
    end

  (** Graphviz outoput module *)
  module D = Graph.Graphviz.Dot(Display) 
  module S = Set.Make(PkgV)

  (** Build the syntactic dependency graph from the give cudf universe *)
  let dependency_graph universe =
    let timer = Util.Timer.create "SyntacticDependencyGraph.dependency_graph" in
    Util.Timer.start timer;
    let maps = CudfAdd.build_maps universe in
    Util.Progress.set_total depgraphbar (Cudf.universe_size universe);
    let gr = G.create () in
    Cudf.iter_packages (fun pkg ->
      Util.Progress.progress depgraphbar;
      let vpid = G.V.create (PkgV.Pkg pkg) in
      let c = ref 0 in
      List.iter (function
        |[(pkgname,constr)] ->
            List.iter (fun p ->
              let vp = G.V.create (PkgV.Pkg p) in
              let edge = G.E.create vpid PkgE.DirDepends vp in
              G.add_edge_e gr edge
            ) (maps.CudfAdd.who_provides (pkgname,constr))
        |l ->
            match List.flatten (List.map maps.CudfAdd.who_provides l) with 
            |[] -> ()
            |[p] ->
                let vp = G.V.create (PkgV.Pkg p) in
                let edge = G.E.create vpid PkgE.DirDepends vp in
                G.add_edge_e gr edge
            |l ->
                begin
                  let vor = G.V.create (PkgV.Or (pkg,!c)) in
                  let edgeor = G.E.create vpid PkgE.OrDepends vor in
                  G.add_edge_e gr edgeor;
                  incr c;
                  List.iter (fun p ->
                    let vp = G.V.create (PkgV.Pkg p) in
                    let oredge = G.E.create vor PkgE.OrDepends vp in
                    G.add_edge_e gr oredge
                  ) l
                end
      ) pkg.Cudf.depends
      ;
      List.iter (fun p ->
        if not(CudfAdd.equal p pkg) then
          let vp = G.V.create (PkgV.Pkg p) in
          let edge = G.E.create vpid PkgE.Conflict vp in
          G.add_edge_e gr edge
      ) (maps.CudfAdd.who_conflicts pkg)
    ) universe
    ;
    Util.Timer.stop timer gr
  ;;

end

(******************************************************)

(** Imperative bidirectional graph. *)
module PackageGraph = struct

  module PkgV = struct
      type t = Cudf.package
      let compare = CudfAdd.compare
      let hash = CudfAdd.hash
      let equal = CudfAdd.equal
  end

  module G = Imperative.Digraph.ConcreteBidirectional(PkgV)
  module UG = Imperative.Graph.Concrete(PkgV)
  module O = GraphOper(G)

  module DisplayF (G : Sig.I) =
    struct
      include G
      let vertex_name v = Printf.sprintf "\"%s\"" (print_package v)

      let graph_attributes = fun _ -> []
      let get_subgraph = fun _ -> None

      let default_edge_attributes = fun _ -> []
      let default_vertex_attributes = fun _ -> []

      let vertex_attributes v = []

      let edge_attributes e = []
    end
  module Display = DisplayF(G)
  
  (** Build the dependency graph from the given cudf universe *)
  let dependency_graph universe =
    let maps = CudfAdd.build_maps universe in
    let gr = G.create () in
    Cudf.iter_packages (fun pkg ->
      List.iter (function
        |[(pkgname,constr)] ->
            List.iter (G.add_edge gr pkg) (maps.CudfAdd.who_provides (pkgname,constr))
        |l ->
            match List.flatten (List.map maps.CudfAdd.who_provides l) with 
            |[p] -> G.add_edge gr pkg p
            |_ -> ()
      ) pkg.Cudf.depends
    ) universe
    ;
    gr

  (** Build the conflict graph from the given cudf universe *)
  let conflict_graph universe =
    let maps = CudfAdd.build_maps universe in
    let gr = UG.create () in
    Cudf.iter_packages (fun pkg ->
      List.iter (fun (pkgname,constr) ->
        List.iter (UG.add_edge gr pkg)
        (maps.CudfAdd.who_provides (pkgname,constr))
      ) pkg.Cudf.conflicts
    ) universe
    ;
    gr

  let undirect graph =
    let gr = UG.create () in
    G.iter_edges (UG.add_edge gr) graph;
    G.iter_vertex (UG.add_vertex gr) graph;
    gr

  (** List of connected components of the given graph *)
  let connected_components graph =
    let module Dfs = Traverse.Dfs(UG) in
    let h = Hashtbl.create (UG.nb_vertex graph) in
    let l = ref [] in
    let cc graph vp =
      let g = UG.create () in
      let collect vc = List.iter (UG.add_edge g vp) (UG.succ graph vc) in
      Dfs.prefix_component collect graph vp;
      g
    in
    UG.iter_vertex (fun v ->
      if not(Hashtbl.mem h v) then begin
        Hashtbl.add h v ();
        let c = cc graph v in
        if not (UG.is_empty c) then begin
          UG.iter_vertex (fun x -> Hashtbl.add h x ()) c ;
          l := c :: !l
        end
      end
    ) graph ;
    !l

  module D = Graph.Graphviz.Dot(Display)
  module S = Set.Make(PkgV)
end

(******************************************************)

(** Integer matrix graph. *)
module MatrixGraph(Pr : sig val pr : int -> string end) = struct

  module G = Imperative.Matrix.Digraph

  module Display =
    struct
      include G
      let vertex_name v = Printf.sprintf "\"%s\"" (Pr.pr v)

      let graph_attributes = fun _ -> []
      let get_subgraph = fun _ -> None

      let default_edge_attributes = fun _ -> []
      let default_vertex_attributes = fun _ -> []

      let vertex_attributes v = []

      let edge_attributes e = []
    end
  
  module D = Graph.Graphviz.Dot(Display)
  module S = Set.Make(struct type t = int let compare = Pervasives.compare end)
end

(******************************************************)

(** Integer Imperative Bidirectional Graph *)
module IntPkgGraph = struct

  module PkgV = struct
      type t = int
      let compare = Pervasives.compare
      let hash i = i
      let equal = (=)
  end

  module G = Imperative.Digraph.ConcreteBidirectional(PkgV)

  (** add to the graph all conjunctive dependencies of package id *)
  let conjdepgraph_int graph index id =
    G.add_vertex graph id;
    Array.iter (function
      |(_,[|p|],_) -> G.add_edge graph id p
      | _ -> ()
    ) index.(id).Mdf.depends

  (** for all if in idlist add to the graph all conjunctive dependencies *)
  let conjdepgraph index idlist =
    let graph = G.create ~size:(List.length idlist) () in
    List.iter (conjdepgraph_int graph index) idlist ;
    graph

  (** given a graph return the conjunctive dependency closure of the package id *)
  let conjdeps graph id =
    let module Dfs = Traverse.Dfs(G) in
    let l = ref [] in
    let collect id = l := id :: !l in
    Dfs.prefix_component collect graph id;
    !l

  module S = Set.Make(PkgV)
  module SO = GraphOper(G)
end

(******************************************************)

(** transform an integer graph in a cudf graph *)
let intcudf index intgraph =
  let module PG = PackageGraph.G in
  let module SG = IntPkgGraph.G in
  let trasformtimer = Util.Timer.create "Defaultgraphs.intcudf" in
  Util.Timer.start trasformtimer;
  let cudfgraph = PG.create () in
  SG.iter_edges (fun x y ->
    let p = index.(x) in
    let q = index.(y) in
    PG.add_edge cudfgraph p.Mdf.pkg q.Mdf.pkg
  ) intgraph ;
  SG.iter_vertex (fun v ->
    let p = index.(v) in
    PG.add_vertex cudfgraph p.Mdf.pkg
  ) intgraph ;
  Common.Util.print_info "cudfgraph: nodes %d , edges %d"
  (PG.nb_vertex cudfgraph) (PG.nb_edges cudfgraph);
  Util.Timer.stop trasformtimer cudfgraph

(** transform a cudf graph into a integer graph *)
let cudfint maps cudfgraph =
  let module PG = PackageGraph.G in
  let module SG = IntPkgGraph.G in
  let trasformtimer = Util.Timer.create "DefaultGraphs.cudfint" in
  Util.Timer.start trasformtimer;
  let intgraph = SG.create () in
  PG.iter_edges (fun x y ->
    SG.add_edge intgraph
    (maps.CudfAdd.map#vartoint x) (maps.CudfAdd.map#vartoint y)
  ) cudfgraph;
  PG.iter_vertex (fun v ->
    SG.add_vertex intgraph (maps.CudfAdd.map#vartoint v)
  ) cudfgraph;
  Common.Util.print_info "intcudf: nodes %d , edges %d"
  (SG.nb_vertex intgraph) (SG.nb_edges intgraph);
  Util.Timer.stop trasformtimer intgraph

(******************************************************)

(** Imperative bidirectional graph. The Strong dependency graph
    is represented as a graph with (package name, package version)
    nodes *)
module StrongDepGraph = struct

  module PkgV = struct
      type t = (string * string)
      let compare = compare
      let hash = Hashtbl.hash
      let equal = (=)
  end

  module G = Imperative.Digraph.ConcreteBidirectional(PkgV)
  module O = GraphOper(G)

  module Display =
    struct
      include G
      let vertex_name (n,v) = Printf.sprintf "\"(%s,%s)\"" n v

      let graph_attributes = fun _ -> []
      let get_subgraph = fun _ -> None

      let default_edge_attributes = fun _ -> []
      let default_vertex_attributes = fun _ -> []

      let vertex_attributes v = []

      let edge_attributes e = []
    end
  
  module D = Graph.Graphviz.Dot(Display)

  module DIn = Dot.Parse (Builder.I(G))(
    struct
      let node (id,_) _ =
        match id with
        |Graph.Dot_ast.String s -> 
            let rex = Str.regexp "(\\([a-zA-Z0-9_-.]+\\),\\([a-zA-Z0-9.-]+\\))" in
            if Str.string_match rex s 0 then
              (Str.matched_group 1 s , Str.matched_group 2 s)
            else (s,"")
        |_ -> assert false
      let edge _ = ()
    end
  )

  (* PackageGraph.G -> StrongDepGraph.G *)
  let transform_out pkggraph =
    let timer = Util.Timer.create "Defaultgraph.StrongDepGraph.transform_out" in
    Util.Timer.start timer;
    let version p =
      try (p.Cudf.package,Cudf.lookup_package_property p "Number")
      with Not_found -> (p.Cudf.package,string_of_int p.Cudf.version)
    in
    let graph = G.create () in
    PackageGraph.G.iter_edges (fun p q ->
      let (np,vp) = version p in
      let (nq,vq) = version q in
      G.add_edge graph (np,vp) (nq,vq)
    ) pkggraph ;
    PackageGraph.G.iter_vertex (fun p ->
      let (np,vp) = version p in
      G.add_vertex graph (np,vp)
    ) pkggraph;
    Util.Timer.stop timer graph

  (* StrongDepGraph.G -> PackageGraph.G *)
  let transform_in pkglist graph =
    let timer = Util.Timer.create "Defaultgraph.StrongDepGraph.transform_in" in
    Util.Timer.start timer;
    let vermap = CudfAdd.realversionmap pkglist in
    let package vermap (n,v) =
        try Hashtbl.find vermap (n,v) with Not_found -> assert false
    in
    let pkggraph = PackageGraph.G.create () in
    G.iter_edges (fun p q ->
      let x = package vermap p in
      let y = package vermap q in
      PackageGraph.G.add_edge pkggraph x y
    ) graph ;
    G.iter_vertex (fun p ->
      let v = package vermap p in
      PackageGraph.G.add_vertex pkggraph v
    ) graph;
    Util.Timer.stop timer pkggraph

  let load pkglist filename =
    let timer = Util.Timer.create "Defaultgraph.StrongDepGraph.load" in
    Util.Timer.start timer;
    let ic = open_in filename in
    let graph = ((Marshal.from_channel ic) :> G.t) in
    close_in ic ;
    Common.Util.print_info "Load Strong Dependencies graph";
    let tg = transform_in pkglist graph in
    (* we assume the graph is detransitivitized *)
    let sg = PackageGraph.O.O.add_transitive_closure tg in
    Common.Util.print_info "done";
    Util.Timer.stop timer sg

  (* StrongDepGraph.G -> PackageGraph.G *)
  let out ?(dump=None) ?(dot=false) ?(detrans=false) pkggraph =
    Common.Util.print_info "Dumping Graph : nodes %d , edges %d"
    (PackageGraph.G.nb_vertex pkggraph) (PackageGraph.G.nb_edges pkggraph) ;
    
    let cudfgraph = transform_out pkggraph in

    if detrans then begin
      O.transitive_reduction cudfgraph;
      Common.Util.print_info "After transitive reduction : nodes %d , edges %d"
      (G.nb_vertex cudfgraph) (G.nb_edges cudfgraph)
    end ;

    if dump <> None then begin
      let f = Option.get dump in
      Common.Util.print_info "Dumping graph in %s\n" f ;
      let oc = open_out f in
      Marshal.to_channel oc (cudfgraph :> G.t) [];
      close_out oc
    end ;

    if dot then begin
      D.output_graph stdout cudfgraph;
      print_newline ();
    end
  ;;

  module S = Set.Make(PkgV)
end
