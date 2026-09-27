open Eio

type 'path target =
  | Localhost of {installDir: 'path option; hostName: string option}
  | Remote of {hostName: string}

type 'path recipient = RecipientFile of 'path | RecipientDir of 'path

type elevation = Sudo | Run0

type 'path config =
  { indexOutDir: 'path option
  ; recipient: 'path recipient
  ; secretsRoot: 'path option
  ; elevationStrategy: elevation }

(* Result of a deployment: the names of the targets that failed, or [Success]
   if none did. *)
type status = Success | Failed of string list

let target_directory = "/var/lib/ageism"

(* A deployable host with an open shell connection. *)
type connection = {conn_name: string; conn_dir: string; conn_shell: Shell.t}

let shell_hostname sh =
  match
    List.find_opt (fun line -> line <> "") (Shell.run_exn sh "hostname")
  with
  | Some name -> name
  | None -> failwith "Could not determine the host name of localhost"

let elevation_command = function
  | Sudo -> ["sudo"; "sh"]
  | Run0 -> ["run0"; "sh"]

let connect ~env ~sw (config : _ Path.t config) (target : _ Path.t target) =
  match target with
  | Remote {hostName} ->
      traceln "Connecting to %s" hostName ;
      let conn_shell = Shell.spawn ~env ~sw ["ssh"; "root@" ^ hostName] in
      {conn_name= hostName; conn_dir= target_directory; conn_shell}
  | Localhost {installDir; hostName} ->
      let conn_shell =
        Shell.spawn ~env ~sw (elevation_command config.elevationStrategy)
      in
      let conn_name =
        match hostName with
        | Some name -> name
        | None -> shell_hostname conn_shell
      in
      let conn_dir =
        match installDir with
        | Some dir -> Path.native_exn dir
        | None -> target_directory
      in
      {conn_name; conn_dir; conn_shell}

(* Sums of the secret files already present on the target. *)
let deployed_names conn =
  ignore
    (Shell.run_exn conn.conn_shell
       ("mkdir -m 600 -p -- " ^ Filename.quote conn.conn_dir) ) ;
  Shell.run_exn conn.conn_shell ("ls -1A -- " ^ Filename.quote conn.conn_dir)
  |> List.filter_map Secrets.sum_of_name

let recipient_file_for config host_name =
  match config.recipient with
  | RecipientFile file -> file
  | RecipientDir dir -> Path.(dir / (host_name ^ ".txt"))

(* Write [data] to [conn_dir]/[name] on the target. The data is sent
   base64-encoded in a here-document so that binary content never has to
   appear on the command line. *)
let upload conn ~name ~data =
  ignore
    (Shell.run_exn conn.conn_shell
       (Printf.sprintf
          "umask 077 && base64 --decode > %s <<'__AGEISM_DATA__'\n\
           %s\n\
           __AGEISM_DATA__"
          (Filename.quote (conn.conn_dir ^ "/" ^ name))
          (Secrets.base64 data) ) )

(* Write [indexOutDir]/[hostName].json: an object mapping each source
   basename (without the .age suffix) to the output basename
   (sha256-<sha256>.age). *)
let save_index ~config conn secrets =
  match config.indexOutDir with
  | None -> ()
  | Some dir ->
      let open Ppx_yojson_conv_lib.Yojson_conv in
      let index =
        `Assoc
          (List.map
             (fun (sum, path) ->
               let base = Filename.basename (Path.native_exn path) in
               ( Filename.chop_suffix base ".age"
               , [%yojson_of: string] (Secrets.sum_name sum ^ ".age") ) )
             secrets )
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

(* Everything needed to finish a target's deployment: the missing secrets
   already decrypted, plus the full secret list for the index file. *)
type 'a plan =
  { plan_conn: connection
  ; plan_pending: (string * string) list
  ; plan_secrets: (string * 'a Path.t) list }

(* Decryption phase: find the secrets missing on [conn] and decrypt them. *)
let prepare_target ~env ~cache ~secrets_root conn =
  let deployed = deployed_names conn in
  let secrets = Secrets.list ~root:secrets_root conn.conn_name in
  let missing = Secrets.select_missing deployed secrets in
  traceln "%s: %d/%d secret(s) missing" conn.conn_name (List.length missing)
    (List.length secrets) ;
  let pending =
    List.map
      (fun (sum, path) -> (sum, Secrets.decrypt ~env ~cache ~sum path))
      missing
  in
  {plan_conn= conn; plan_pending= pending; plan_secrets= secrets}

(* Deployment phase: re-encrypt the decrypted secrets for the target and
   upload them over its shell. *)
let deploy_target ~env ~config plan =
  let conn = plan.plan_conn in
  let recipient_file = recipient_file_for config conn.conn_name in
  List.iter
    (fun (sum, plaintext) ->
      let ciphertext = Secrets.encrypt ~env ~recipient_file plaintext in
      let name = Secrets.sum_name sum in
      upload conn ~name ~data:ciphertext ;
      traceln "%s: installed %s" conn.conn_name name )
    plan.plan_pending ;
  save_index ~config conn plan.plan_secrets

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
    ~finally:(fun () ->
      List.iter (fun conn -> Shell.close conn.conn_shell) !conns )
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
              Either.Left (prepare_target ~env ~cache ~secrets_root conn)
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
