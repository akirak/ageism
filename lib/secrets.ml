open Eio

(* Deployed secret files are named sha256-<sum> where <sum> is the sha256 of
   the source .age file. *)
let sum_prefix = "sha256-"

let sum_name sum = sum_prefix ^ sum

let is_sum name =
  String.length name = String.length sum_prefix + 64
  && String.starts_with ~prefix:sum_prefix name
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       (String.sub name (String.length sum_prefix) 64)

(* The bare sum of a deployed file name, or [None] if [name] does not look
   like a deployed secret. *)
let sum_of_name name =
  if is_sum name then Some (String.sub name (String.length sum_prefix) 64)
  else None

(* [select_missing deployed secrets] is the elements of [secrets] whose sums
   are not in [deployed]. *)
let select_missing deployed secrets =
  List.filter (fun (sum, _) -> not (List.mem sum deployed)) secrets

(* Run [args] with [input] on its standard input and return its standard
   output. Raises if the command fails. *)
let run_capture ~env ~input args =
  Process.parse_out (Stdenv.process_mgr env) Buf_read.take_all
    ~stdin:(Flow.string_source input)
    args

let sha256sum data = Digestif.SHA256.(digest_string data |> to_hex)

(* Pairs of (sum, path) for each *.age file under [root]/[host_name], where
   sum is the sha256 of the dereferenced (symlink-followed) contents. *)
let list ~root host_name =
  let dir = Path.(root / host_name) in
  if Path.is_directory dir then
    Path.read_dir dir
    |> List.filter_map (fun entry ->
        if Filename.check_suffix entry ".age" then
          let path = Path.(dir / entry) in
          Some (sha256sum (Path.load path), path)
        else None )
  else []

(* Decrypt an .age file, keeping the result in [cache] so a secret shared by
   several hosts is decrypted only once. *)
let decrypt ~env ~cache ~age ~sum path =
  match Hashtbl.find_opt cache sum with
  | Some plaintext -> plaintext
  | None ->
      let plaintext =
        run_capture ~env ~input:(Path.load path) [age; "--decrypt"]
      in
      Hashtbl.add cache sum plaintext ;
      plaintext

let encrypt ~env ~age ~recipient_file plaintext =
  run_capture ~env ~input:plaintext
    [age; "--encrypt"; "--recipients-file"; Path.native_exn recipient_file]
