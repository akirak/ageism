open Eio

(** An interactive shell spawned as a child process, with commands written
    to [stdin] and output read line-by-line from [stdout].  This is used
    both for remote hosts (via [ssh root@HOST]) and for localhost (via an
    elevation command such as [sudo sh]). *)
type t = {stdin: [`Close | `Flow | `W] Resource.t; stdout: Buf_read.t}

exception
  Command_failed of {command: string; status: int; output: string list}

let () =
  Printexc.register_printer
  @@ function
  | Command_failed {command; status; output} ->
      Some
        (Printf.sprintf "Shell command failed (status %d): %s%s" status
           command
           ( match output with
           | [] -> ""
           | lines -> "\n" ^ String.concat "\n" lines ) )
  | _ -> None

let ready_marker = "AGEISM_READY"

let status_marker = "AGEISM_STATUS_"

(* Wait until the freshly spawned shell is ready to accept commands,
   discarding any output produced during its start-up (banners, MOTD,
   etc). *)
let await_ready t =
  Flow.copy_string ("printf '" ^ ready_marker ^ "\\n'\n") t.stdin ;
  let rec loop () = if Buf_read.line t.stdout <> ready_marker then loop () in
  loop ()

let spawn ~env ~sw args =
  let mgr = Stdenv.process_mgr env in
  let child_stdin, stdin = Process.pipe ~sw mgr in
  let stdout, child_stdout = Process.pipe ~sw mgr in
  ignore
    (Process.spawn ~sw mgr
       ~stdin:(child_stdin : [`Close | `Flow | `R] Resource.t)
       ~stdout:(child_stdout : [`Close | `Flow | `W] Resource.t)
       ~stderr:(child_stdout : [`Close | `Flow | `W] Resource.t)
       args ) ;
  (* Close our copies of the child's pipe ends so that the child's exit is
     observed as EOF/EPIPE rather than blocking forever. *)
  Resource.close child_stdin ;
  Resource.close child_stdout ;
  let t =
    { stdin: [`Close | `Flow | `W] Resource.t
    ; stdout=
        Buf_read.of_flow
          ~max_size:(64 * 1024 * 1024)
          (stdout : Flow.source_ty Resource.t) }
  in
  await_ready t ; t

(* Run [cmd] in the shell and return (output lines, exit status). A status
   marker is printed after the command so that the end of its output can be
   detected on the byte stream. *)
let run t cmd =
  Flow.copy_string
    (Printf.sprintf "%s\nprintf '\\n%s%%d\\n' $?\n" cmd status_marker)
    t.stdin ;
  let rec loop acc =
    let line = Buf_read.line t.stdout in
    if String.starts_with ~prefix:status_marker line then
      let status =
        String.sub line
          (String.length status_marker)
          (String.length line - String.length status_marker)
        |> int_of_string
      in
      (* The newline printed before the status marker leaves a spurious empty
         line when the output ended with a newline; remove it. *)
      let acc = match acc with "" :: rest -> rest | _ -> acc in
      (List.rev acc, status)
    else loop (line :: acc)
  in
  loop []

let run_exn t cmd =
  let output, status = run t cmd in
  if status = 0 then output
  else raise (Command_failed {command= cmd; status; output})

let close t =
  try
    Flow.copy_string "exit\n" t.stdin ;
    Resource.close t.stdin
  with _ -> ()
