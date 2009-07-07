
open IprLib
open ExtLib 
open Common

exception Done

module Options =
struct
  let cudf = ref false
  let verbose = ref false
  let outdir = ref ""
end

let usage = Printf.sprintf "usage: %s [-options] [cudf doc]" Sys.argv.(0)

let options =
  [
   ("--verbose", Arg.Set Options.verbose, "");
   ("--cudf", Arg.Set  Options.cudf, "print the cudf solution (if any)");
   ("--outdir", Arg.String (fun l -> Options.outdir := l),  "Specify the output directory");
   ("--debug", Arg.Unit (fun () -> Util.set_verbosity Util.Summary), "Print debug information");
  ]

let main () =
  let input_file = ref "" in

  let _ =
    try Arg.parse options (fun f -> input_file := f) usage
    with Arg.Bad s -> failwith s
  in

  Printf.eprintf "parsing CUDF ...%!"; 
  let timer = Util.Timer.create "Parse" in
  Util.Timer.start timer;
  let (universe,request) = 
    match IprLib.parse_cudf !input_file with
    |u,None -> 
        (Printf.eprintf "This cudf document does not contain a valid request\n" ; exit 1)
    |u,Some(r) -> u,r
  in
  Util.Timer.stop timer ();
  Printf.eprintf "done.\n%!"; 

  Printf.eprintf "Prepare ...%!";
  let timer = Util.Timer.create "Prepare" in
  Util.Timer.start timer;
  let problem = Cudfsolver.init universe request in
  Util.Timer.stop timer ();
  Printf.eprintf "done.\n%!"; 

  Printf.eprintf "Solve ...%!";
  let timer = Util.Timer.create "Solve" in
  Util.Timer.start timer;
  let result = Cudfsolver.solve problem in
  Util.Timer.stop timer ();
  Printf.eprintf "done.\n%!"; 

  match result with
  |{Diagnostic.result = Diagnostic.Success f } ->
      if !Options.cudf then begin
        let oc = 
          if !Options.outdir <> "" then begin
            let tmpfile =
              if !input_file = "" then (Filename.temp_file "solution" ".cudf")
              else "sol-"^(Filename.basename !input_file)
            in
            let dirname = !Options.outdir in
            if not(Sys.file_exists dirname) then Unix.mkdir dirname 0o740;
            let fname = (Filename.concat dirname tmpfile) in
            let _ = Printf.printf "cudf solution saved in %s\n" fname in
            open_out fname
          end else stdout
        in
        List.iter (fun pkg ->
          Printf.fprintf oc "%s\n" 
          (Cudf_printer.string_of_package 
          { pkg with Cudf.installed = true })
        ) (f ())
      end
      else
        Diagnostic.print stdout result
  |_ -> Diagnostic.print ~explain:true stdout result

;;

main () ;;


