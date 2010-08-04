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

(** Solver output and diagnostic *)

(** Failures reasons for sat solver *)
type reason =
  |Dependency of (Cudf.package * Cudf_types.vpkg list * Cudf.package list)
  (** Package [p] has an unfulfilled dependency on [pl]. None of [pl] safisfy
   * the dependency of [p] *)
  |EmptyDependency of (Cudf.package * Cudf_types.vpkg list)
  (** Package [p] has an broken dependency on [vpkglist]. No package in the
      universe can be expanded from [vpkglist] *)
  |Conflict of (Cudf.package * Cudf.package)
  (** Package [p] conflict with Package [q] *)

(** Results are given as functions and computed only if needed *)
type result =
  |Success of (unit -> Cudf.package list)
  (** List of installed packages. We build a new package and set [Installed] =
      True . These packages cannot be used to query the old cudf universe.*)
  |Failure of (unit -> reason list)
  (** list of failure reasons *)

(** User request. This type is only used to document the action corresponding to
    the result *)
type request =
  |Package of Cudf.package (** Package to be processed *)
  |PackageList of Cudf.package list (** Package list to be processed *)

(** The result of the prover *)
type diagnosis = { result : result ; request : request }

(** True is the result is Success, False otherwise *)
val is_solution : diagnosis -> bool

(* val print : ?pp:(?short:bool -> Cudf.package -> string) -> ?explain:bool -> out_channel -> diagnosis -> unit
*)

(** Print the result of the solver.
 
    @param explain : add a more verbose explanation of the failure or
    print the list of installed packages. 
    @param pp : print a cudf package
*)
val print :
  ?pp:(Cudf.package -> (string * string)) -> 
    ?failure:bool -> ?success:bool -> ?explain:bool -> 
      Format.formatter -> diagnosis -> unit
