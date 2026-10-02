open Eio

(* Deployed secret files are named sha256-<sum>.<id>.age, where <sum> is the
   sha256 of the source .age file and <id> identifies the host identity that
   can decrypt the secret. *)
let sum_prefix = "sha256-"

(* Name of the encrypted host identity file in a secrets directory. The name
   is reserved: it is deployed as an identity, never as a secret. *)
let identity_file = "identity.age"

let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let is_sum name =
  String.length name = String.length sum_prefix + 64
  && String.starts_with ~prefix:sum_prefix name
  && String.for_all is_hex (String.sub name (String.length sum_prefix) 64)

(* [id_of_sum sum] is the identity ID: the first 8 hex characters of the
   sha256 of the encrypted identity file. *)
let id_of_sum sum = String.sub sum 0 8

(* The name under which the decrypted host identity is stored on the
   target. *)
let deployed_identity_name id = "identity." ^ id

(* The name under which a rekeyed secret is stored on the target. *)
let deployed_name ~id sum = sum_prefix ^ sum ^ "." ^ id ^ ".age"

(* The bare sum of a deployed file name, or [None] if [name] does not look
   like a deployed secret. The identity suffix and the .age extension are
   ignored; the legacy sha256-<sum> form is also recognised. *)
let sum_of_name name =
  let name =
    if Filename.check_suffix name ".age" then
      String.sub name 0 (String.length name - 4)
    else name
  in
  let len = String.length name in
  let name =
    if
      len > 9
      && name.[len - 9] = '.'
      && String.for_all is_hex (String.sub name (len - 8) 8)
    then String.sub name 0 (len - 9)
    else name
  in
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
   sum is the sha256 of the dereferenced (symlink-followed) contents. The
   reserved identity file is not a secret. *)
let list ~root host_name =
  let dir = Path.(root / host_name) in
  if Path.is_directory dir then
    Path.read_dir dir
    |> List.filter_map (fun entry ->
        if Filename.check_suffix entry ".age" && entry <> identity_file then
          let path = Path.(dir / entry) in
          Some (sha256sum (Path.load path), path)
        else None )
  else []

(* The encrypted host identity of [host_name] as a (sum, path) pair, where
   sum is the sha256 of the encrypted file, or [None] if the secrets
   directory contains no identity file. *)
let identity ~root host_name =
  let path = Path.(root / host_name / identity_file) in
  if Path.is_file path then Some (sha256sum (Path.load path), path) else None

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
