open Eio

type 'path target =
  | Localhost of {installDir: 'path option; hostName: string option}
  | Remote of {hostName: string}

type 'path recipient = RecipientFile of 'path | RecipientDir of 'path

type elevation = Sudo | Run0

type 'path config =
  { indexOutDir: 'path option
  ; recipient: 'path recipient
  ; identityFile: 'path
  ; secretsRoot: 'path option
  ; elevationStrategy: elevation
  ; ageExe: string
  ; prune: bool }

(* Result of a deployment: the names of the targets that failed, or [Success]
   if none did. *)
type status = Success | Failed of string list

let target_directory = "/var/lib/ageism"

(* Host names are used as SSH destinations and as file names under the
   secrets root, the recipient directory and the index directory, so they
   must not contain path separators, whitespace or a leading dot or dash. *)
let check_host_name name =
  let valid_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' | ':' -> true
    | _ -> false
  in
  if name = "" then Error "host name must not be empty"
  else if not (String.for_all valid_char name) then
    Error
      (Printf.sprintf
         "invalid host name %S: only letters, digits, '.', '-', '_' and ':' \
          are allowed"
         name )
  else if name.[0] = '.' || name.[0] = '-' then
    Error
      (Printf.sprintf "invalid host name %S: must not start with %C" name
         name.[0] )
  else Ok name

let validate_host_name name =
  match check_host_name name with
  | Ok name -> name
  | Error msg -> failwith msg

(* A deployable host. Local targets get an interactive privileged shell;
   remote targets are reached through a single multiplexed SSH connection
   whose control socket is [sock]. *)
type connection = {conn_name: string; conn_dir: string; conn_kind: kind}

and kind = Local of Shell.t | Ssh of {sock: string; host: string}

let shell_hostname sh =
  match
    List.find_opt (fun line -> line <> "") (Shell.run_exn sh "hostname")
  with
  | Some name -> name
  | None -> failwith "Could not determine the host name of localhost"

let elevation_command = function
  | Sudo -> ["sudo"; "sh"]
  | Run0 -> ["run0"; "sh"]

let rmtree ~env dir =
  try Path.rmtree ~missing_ok:true Path.(Stdenv.fs env / dir) with _ -> ()

(* [ssh_args ~sock host cmd] is the argv for running [cmd] on [host] as a new
   session multiplexed over the master connection at [sock]. *)
let ssh_args ~sock host cmd =
  [ "ssh"
  ; "-o"
  ; "ControlMaster=auto"
  ; "-o"
  ; "ControlPath=" ^ sock
  ; "root@" ^ host
  ; cmd ]

let connect ~env ~sw (config : _ Path.t config) (target : _ Path.t target) =
  match target with
  | Remote {hostName} ->
      let hostName = validate_host_name hostName in
      traceln "Connecting to %s" hostName ;
      (* Spawn a multiplexing master in the background. It authenticates and
         exits on failure before forking, so connection problems are raised
         here. ControlPersist ensures the master goes away even if we are
         killed before disconnecting. *)
      let sock_dir = Filename.temp_dir "ageism" "ssh" in
      let sock = Filename.concat sock_dir "ctl" in
      ( try
          Process.run (Stdenv.process_mgr env)
            [ "ssh"
            ; "-o"
            ; "ControlMaster=yes"
            ; "-o"
            ; "ControlPath=" ^ sock
            ; "-o"
            ; "ControlPersist=60"
            ; "-fN"
            ; "root@" ^ hostName ]
        with exn -> rmtree ~env sock_dir ; raise exn ) ;
      { conn_name= hostName
      ; conn_dir= target_directory
      ; conn_kind= Ssh {sock; host= hostName} }
  | Localhost {installDir; hostName} ->
      let conn_shell =
        Shell.spawn ~env ~sw (elevation_command config.elevationStrategy)
      in
      let conn_name =
        try
          validate_host_name
            ( match hostName with
            | Some name -> name
            | None -> shell_hostname conn_shell )
        with exn -> Shell.close conn_shell ; raise exn
      in
      let conn_dir =
        match installDir with
        | Some dir -> Path.native_exn dir
        | None -> target_directory
      in
      {conn_name; conn_dir; conn_kind= Local conn_shell}

(* Run [cmd] on the target, returning its standard output as a list of lines.
   Raises if the command fails. *)
let run_command ~env conn cmd =
  match conn.conn_kind with
  | Local shell -> Shell.run_exn shell cmd
  | Ssh {sock; host} ->
      Process.parse_out (Stdenv.process_mgr env) Buf_read.lines
        (ssh_args ~sock host cmd)
      |> List.of_seq

(* Names of the files already present on the target. *)
let deployed_entries ~env conn =
  ignore
    (run_command ~env conn
       ("mkdir -m 600 -p -- " ^ Filename.quote conn.conn_dir) ) ;
  run_command ~env conn ("ls -1A -- " ^ Filename.quote conn.conn_dir)

let recipient_file_for config host_name =
  match config.recipient with
  | RecipientFile file -> file
  | RecipientDir dir -> Path.(dir / (host_name ^ ".txt"))

(* Base64-encode [data] in lines of 76 characters. Every line has a length
   that is a multiple of 4, so none of them can be a 3-letter heredoc
   delimiter. *)
let base64_lines data =
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  in
  let len = String.length data in
  let out = Buffer.create (((len + 2) / 3 * 4 * 77 / 76) + 1) in
  let byte i = if i < len then Char.code data.[i] else 0 in
  let rec loop i =
    if i < len then begin
      let n = (byte i lsl 16) lor (byte (i + 1) lsl 8) lor byte (i + 2) in
      let digit k = alphabet.[(n lsr (18 - (6 * k))) land 63] in
      Buffer.add_char out (digit 0) ;
      Buffer.add_char out (digit 1) ;
      Buffer.add_char out (if i + 1 < len then digit 2 else '=') ;
      Buffer.add_char out (if i + 2 < len then digit 3 else '=') ;
      if (i + 3) mod 57 = 0 || i + 3 >= len then Buffer.add_char out '\n' ;
      loop (i + 3)
    end
  in
  loop 0 ; Buffer.contents out

(* Write [data] to [conn_dir]/[name] on the target with mode 0600. For a
   remote host the raw bytes are streamed to [cat] over the multiplexed SSH
   connection; on localhost they are passed base64-encoded in a heredoc to
   the elevated shell, so that the plaintext host identity never touches the
   local disk. *)
let upload ~env conn ~name ~data =
  let dest = conn.conn_dir ^ "/" ^ name in
  match conn.conn_kind with
  | Ssh {sock; host} ->
      Process.run (Stdenv.process_mgr env) ~stdin:(Flow.string_source data)
        (ssh_args ~sock host ("umask 077 && cat > " ^ Filename.quote dest))
  | Local shell ->
      ignore
        (Shell.run_exn shell
           (Printf.sprintf "umask 077 && base64 --decode > %s <<'EOF'\n%sEOF"
              (Filename.quote dest) (base64_lines data) ) )

(* Write [indexOutDir]/[hostName].json: an object mapping each source
   basename (without the .age suffix) to the deployed basename
   (sha256-<sha256>.<id>.age). *)
let save_index ~config conn names =
  match config.indexOutDir with
  | None -> ()
  | Some dir ->
      let open Ppx_yojson_conv_lib.Yojson_conv in
      let index =
        `Assoc
          (List.map
             (fun (base, name) -> (base, [%yojson_of: string] name))
             names )
      in
      Path.mkdirs ~exists_ok:true ~perm:0o755 dir ;
      Path.save ~create:(`Or_truncate 0o600)
        Path.(dir / (conn.conn_name ^ ".json"))
        (Yojson.Safe.pretty_to_string index ^ "\n")

(* Name used to report failures for [target] before a connection exists. *)
let target_name = function
  | Remote {hostName} -> hostName
  | Localhost {hostName= Some name; _} -> name
  | Localhost {hostName= None; _} -> "localhost"

(* Everything needed to finish a target's deployment: the decrypted host
   identity and the missing secrets already decrypted, the files to prune,
   plus the name each secret has on the target for the index file. *)
type plan =
  { plan_conn: connection
  ; plan_identity: (string * string) option
  ; plan_pending: (string * string) list
  ; plan_names: (string * string) list
  ; plan_stale: string list }

(* Close the target's connection: exit the interactive shell for localhost,
   or ask the SSH multiplexing master to exit and remove its socket
   directory. *)
let disconnect ~env conn =
  match conn.conn_kind with
  | Local shell -> Shell.close shell
  | Ssh {sock; host} ->
      ( try
          Process.run (Stdenv.process_mgr env)
            ["ssh"; "-o"; "ControlPath=" ^ sock; "-O"; "exit"; "root@" ^ host]
        with _ -> () ) ;
      rmtree ~env (Filename.dirname sock)

(* Pretty-print a table of the secrets' statuses: a ballot box with check (☑)
   if the secret is already deployed on the target, or a ballot box (☐) if it
   is missing and has to be uploaded. *)
let pp_secret_statuses ~deployed ppf secrets =
  let rows =
    List.map
      (fun (sum, path) ->
        ( Filename.chop_suffix
            (Filename.basename (Path.native_exn path))
            ".age"
        , List.mem sum deployed ) )
      secrets
  in
  let pp_row ppf (name, is_deployed) =
    Fmt.pf ppf "  %s %s" (if is_deployed then "☑" else "☐") name
  in
  Fmt.(vbox (list ~sep:cut pp_row)) ppf rows

(* Decryption phase: find the identity and the secrets missing on [conn] and
   decrypt them. *)
let prepare_target ~env ~cache ~config ~secrets_root conn =
  let entries = deployed_entries ~env conn in
  let deployed =
    List.filter_map
      (fun name ->
        Option.map (fun sum -> (sum, name)) (Secrets.sum_of_name name) )
      entries
  in
  let secrets = Secrets.list ~root:secrets_root conn.conn_name in
  let identity = Secrets.identity ~root:secrets_root conn.conn_name in
  let id = Option.map (fun (sum, _) -> Secrets.id_of_sum sum) identity in
  if id = None && secrets <> [] then
    failwith
      "secrets cannot be deployed without an identity.age file in the \
       secrets directory" ;
  let missing = Secrets.select_missing (List.map fst deployed) secrets in
  traceln "%s: %d/%d secret(s) to deploy" conn.conn_name
    (List.length missing) (List.length secrets) ;
  traceln "%a" (pp_secret_statuses ~deployed:(List.map fst deployed)) secrets ;
  (* The deployed name of [sum]: the name of the file already on the target,
     or a new name carrying the host identity's ID. *)
  let name_of sum =
    match List.assoc_opt sum deployed with
    | Some name -> name
    | None -> Secrets.deployed_name ~id:(Option.get id) sum
  in
  let plan_identity =
    match identity with
    | Some (sum, path) ->
        let name = Secrets.deployed_identity_name (Option.get id) in
        if List.mem name entries then None
        else
          Some
            ( name
            , Secrets.decrypt ~env ~cache ~age:config.ageExe
                ~identity:config.identityFile ~sum path )
    | None -> None
  in
  let plan_pending =
    List.map
      (fun (sum, path) ->
        ( name_of sum
        , Secrets.decrypt ~env ~cache ~age:config.ageExe
            ~identity:config.identityFile ~sum path ) )
      missing
  in
  let plan_names =
    List.map
      (fun (sum, path) ->
        ( Filename.chop_suffix
            (Filename.basename (Path.native_exn path))
            ".age"
        , name_of sum ) )
      secrets
  in
  (* With [prune], the deployed secrets not in [plan_names] and the
     identities that none of the remaining secrets use are removed. Other
     files are left alone. Nothing is pruned for a host without a secrets
     directory, so a wrong --secrets-root cannot wipe the target. *)
  let plan_stale =
    if not config.prune then []
    else if not (Path.is_directory Path.(secrets_root / conn.conn_name)) then (
      traceln "%s: no secrets directory, not pruning" conn.conn_name ;
      [] )
    else
      let kept = List.map snd plan_names in
      let ids =
        Option.to_list id @ List.filter_map Secrets.id_of_secret_name kept
      in
      List.filter
        (fun name ->
          match Secrets.id_of_identity_name name with
          | Some i -> not (List.mem i ids)
          | None ->
              Secrets.sum_of_name name <> None && not (List.mem name kept) )
        entries
  in
  {plan_conn= conn; plan_identity; plan_pending; plan_names; plan_stale}

(* Deployment phase: upload the host identity, re-encrypt the decrypted
   secrets for the target and upload them over its shell, then remove the
   stale files. *)
let deploy_target ~env ~config plan =
  let conn = plan.plan_conn in
  let recipient_file = recipient_file_for config conn.conn_name in
  Option.iter
    (fun (name, plaintext) ->
      upload ~env conn ~name ~data:plaintext ;
      traceln "%s: installed %s" conn.conn_name name )
    plan.plan_identity ;
  List.iter
    (fun (name, plaintext) ->
      let ciphertext =
        Secrets.encrypt ~env ~age:config.ageExe ~recipient_file plaintext
      in
      upload ~env conn ~name ~data:ciphertext ;
      traceln "%s: installed %s" conn.conn_name name )
    plan.plan_pending ;
  if plan.plan_stale <> [] then (
    ignore
      (run_command ~env conn
         ( "rm -f -- "
         ^ String.concat " "
             (List.map
                (fun name -> Filename.quote (conn.conn_dir ^ "/" ^ name))
                plan.plan_stale ) ) ) ;
    List.iter
      (fun name -> traceln "%s: removed %s" conn.conn_name name)
      plan.plan_stale ) ;
  save_index ~config conn plan.plan_names

let deploy ~env config targets =
  let secrets_root =
    match config.secretsRoot with
    | Some root ->
        (* Re-root under [fs] so that absolute paths and symlinks escaping
           the working directory subtree can be followed. *)
        Path.(Stdenv.fs env / Path.native_exn root)
    | None -> failwith "A secrets directory must be specified"
  in
  Switch.run
  @@ fun sw ->
  let conns = ref [] in
  Fun.protect
    ~finally:(fun () -> List.iter (disconnect ~env) !conns)
    (fun () ->
      let cache = Hashtbl.create 8 in
      (* Phase 1: connect to every target and decrypt its missing secrets. A
         failure on one target does not abort the others. *)
      let plans, failed =
        List.partition_map
          (fun target ->
            try
              let conn = connect ~env ~sw config target in
              conns := conn :: !conns ;
              Either.Left
                (prepare_target ~env ~cache ~config ~secrets_root conn)
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                traceln "%s: preparation failed: %s" (target_name target)
                  (Printexc.to_string exn) ;
                Either.Right (target_name target) )
          targets
      in
      (* Phase 2: deploy to all targets concurrently, collecting the names of
         any targets that fail. *)
      let failed =
        failed
        @ ( List.map
              (fun plan ->
                Fiber.fork_promise ~sw (fun () ->
                    try
                      deploy_target ~env ~config plan ;
                      None
                    with
                    | Eio.Cancel.Cancelled _ as exn -> raise exn
                    | exn ->
                        traceln "%s: deployment failed: %s"
                          plan.plan_conn.conn_name (Printexc.to_string exn) ;
                        Some plan.plan_conn.conn_name ) )
              plans
          |> List.filter_map Promise.await_exn )
      in
      match failed with
      | [] -> Success
      | names ->
          traceln "deployment failed on: %s" (String.concat ", " names) ;
          Failed names )
