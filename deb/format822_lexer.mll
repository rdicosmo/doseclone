(*****************************************************************************)
(*  libCUDF - CUDF (Common Upgrade Description Format) manipulation library  *)
(*  Copyright (C) 2009-2011  Stefano Zacchiroli <zack@pps.jussieu.fr>        *)
(*                                                                           *)
(*  Adapted for Dose3                                                        *)
(*                                                                           *)
(*  This library is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU Lesser General Public License as           *)
(*  published by the Free Software Foundation, either version 3 of the       *)
(*  License, or (at your option) any later version.  A special linking       *)
(*  exception to the GNU Lesser General Public License applies to this       *)
(*  library, see the COPYING file for more information.                      *)
(*****************************************************************************)

{
  open Format822_parser

  let get_range { Lexing.lex_start_p = start_pos;
                  Lexing.lex_curr_p = end_pos } =
    (start_pos, end_pos)

}

let lower_letter = [ 'a' - 'z' ]
let upper_letter = [ 'A' - 'Z' ]
let letter = lower_letter | upper_letter
let digit = [ '0' - '9' ]
let blank = [ ' ' '\t' ]
let ident = (letter | digit | '-')+

rule token_822 = parse
  | (ident as field) ':' blank*
    ([^'\n']* as rest)          { FIELD(field, (get_range lexbuf, rest)) }
  | ' ' ([^'\n']* as rest)      { CONT(get_range lexbuf, rest) }
  | '#' [^'\n']* ('\n'|eof)     { token_822 lexbuf }
  | blank* '\n'                 { Lexing.new_line lexbuf; EOL }
  | eof                         { EOF }
  | _                           { raise (Format822.Parse_error_822
                                           ("unexpected RFC 822 token",
                                            (lexbuf.Lexing.lex_start_p,
                                             lexbuf.Lexing.lex_curr_p))) }
