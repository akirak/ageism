open Alcotest
open Eio
module Shell = Ageism__Shell
module Secrets = Ageism__Secrets

(* ---------- helpers ---------- *)

let with_env fn () = Eio_main.run (fun env -> fn env ())

let with_temp_dir fn =
  let dir = Filename.temp_dir "ageism" "test" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> fn dir)

let write_file path data =
  let oc = open_out_bin path in
  output_string oc data ; close_out oc

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic)
  @@ fun () -> really_input_string ic (in_channel_length ic)

let mkdir_p dir = ignore (Sys.command ("mkdir -p " ^ Filename.quote dir))

let make_script ~dir name body =
  let path = Filename.concat dir name in
  write_file path ("#!/bin/sh\n" ^ body) ;
  Unix.chmod path 0o755

let with_path ~dir fn =
  let old = Unix.getenv "PATH" in
  Unix.putenv "PATH" (dir ^ ":" ^ old) ;
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old) fn

let count_matching prefix file =
  if Sys.file_exists file then
    read_file file |> String.split_on_char '\n'
    |> List.filter (fun line -> String.starts_with ~prefix line)
    |> List.length
  else 0

(* Fake [sudo] that just runs its argument as the current user. *)
let fake_sudo = "exec \"$@\"\n"

(* Fake [age] that logs each invocation to $AGEISM_LOG, strips a CIPHER:
   prefix on --decrypt and adds a REKEYED: prefix on --encrypt, so tests can
   observe that rekeying really happened. *)
let fake_age =
  {|printf '%s\n' "$*" >> "$AGEISM_LOG"
case "$1" in
  --decrypt) exec sed 's/^CIPHER://' ;;
  --encrypt) exec sed 's/^/REKEYED:/' ;;
esac
exec cat
|}

let with_shell env fn =
  Switch.run
  @@ fun sw ->
  let sh = Shell.spawn ~env ~sw ["sh"] in
  Fun.protect ~finally:(fun () -> Shell.close sh) (fun () -> fn sh)

let fs_path ~env str = Path.(Stdenv.fs env / str)

let e2e_config ~env ~dir =
  Ageism.
    { indexOutDir= None
    ; recipient= RecipientFile (fs_path ~env (dir ^ "/recip.txt"))
    ; secretsRoot= Some (fs_path ~env (dir ^ "/secrets"))
    ; elevationStrategy= Sudo }

let status_str = function
  | Ageism.Success -> "ok"
  | Ageism.Failed names -> "failed:" ^ String.concat "," names

let check_ok msg status = check string msg "ok" (status_str status)

(* ---------- pure helpers ---------- *)

let test_is_sum () =
  check bool "sha256- plus 64 lowercase hex" true
    (Secrets.is_sum ("sha256-" ^ String.make 64 'a')) ;
  check bool "no prefix" false (Secrets.is_sum (String.make 64 'a')) ;
  check bool "too short" false
    (Secrets.is_sum ("sha256-" ^ String.make 63 'a')) ;
  check bool "too long" false
    (Secrets.is_sum ("sha256-" ^ String.make 65 'a')) ;
  check bool "non-hex" false
    (Secrets.is_sum ("sha256-" ^ String.make 64 'z')) ;
  check bool "empty" false (Secrets.is_sum "") ;
  check (option string) "sum_of_name strips the prefix"
    (Some (String.make 64 'a'))
    (Secrets.sum_of_name ("sha256-" ^ String.make 64 'a')) ;
  check (option string) "sum_of_name rejects other names" None
    (Secrets.sum_of_name "stale.txt")

let test_select_missing () =
  let deployed = ["aaa"; "bbb"; "stale"] in
  let secrets = [("aaa", 1); ("ccc", 2); ("bbb", 3)] in
  check
    (list (pair string int))
    "only missing, in order"
    [("ccc", 2)]
    (Secrets.select_missing deployed secrets) ;
  check
    (list (pair string int))
    "all present" []
    (Secrets.select_missing deployed [("aaa", 1)])

(* ---------- secrets ---------- *)

let test_list env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/host1") ;
  write_file (dir ^ "/repo/real.age") "via-symlink\n" ;
  write_file (dir ^ "/repo/plain.age") "regular\n" ;
  Unix.symlink "../../repo/real.age" (dir ^ "/secrets/host1/a.age") ;
  Unix.symlink "../../repo/plain.age" (dir ^ "/secrets/host1/b.age") ;
  write_file (dir ^ "/secrets/host1/skip.txt") "ignored\n" ;
  let root = fs_path ~env (dir ^ "/secrets") in
  let entries = Secrets.list ~root "host1" in
  let sums = List.map fst entries in
  check int "two .age files" 2 (List.length entries) ;
  check bool "a.age has sum of its target" true
    (List.mem (Secrets.sha256sum "via-symlink\n") sums) ;
  check bool "b.age has sum of its target" true
    (List.mem (Secrets.sha256sum "regular\n") sums) ;
  check int "unknown host has no secrets" 0
    (List.length (Secrets.list ~root "nohost"))

let test_decrypt_caches env () =
  with_temp_dir
  @@ fun dir ->
  make_script ~dir "age" fake_age ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  (* Two files with identical contents share a sum. *)
  write_file (dir ^ "/a.age") "CIPHER:first\n" ;
  write_file (dir ^ "/b.age") "CIPHER:first\n" ;
  let cache = Hashtbl.create 4 in
  let sum = Secrets.sha256sum "CIPHER:first\n" in
  let plaintext =
    Secrets.decrypt ~env ~cache ~sum (fs_path ~env (dir ^ "/a.age"))
  in
  check string "decrypted" "first\n" plaintext ;
  let again =
    Secrets.decrypt ~env ~cache ~sum (fs_path ~env (dir ^ "/b.age"))
  in
  check string "cached" "first\n" again ;
  check int "age ran only once" 1
    (count_matching "--decrypt" (dir ^ "/age.log"))

(* ---------- shell ---------- *)

let test_shell_run env () =
  with_shell env
  @@ fun sh ->
  let output, status = Shell.run sh "echo hello; echo err >&2" in
  check (list string) "stdout and stderr" ["hello"; "err"] output ;
  check int "zero status" 0 status ;
  let _, status = Shell.run sh "( exit 3 )" in
  check int "non-zero status" 3 status ;
  (* The shell is stateful across commands. *)
  ignore (Shell.run_exn sh "x=42") ;
  check (list string) "persistent state" ["42"] (Shell.run_exn sh "echo $x")

let test_shell_run_exn env () =
  with_shell env
  @@ fun sh ->
  match Shell.run_exn sh "echo before; ( exit 7 )" with
  | _ -> fail "expected Command_failed"
  | exception Shell.Command_failed {status; output; _} ->
      check int "status" 7 status ;
      check (list string) "output" ["before"] output

let test_shell_heredoc env () =
  with_temp_dir
  @@ fun dir ->
  with_shell env
  @@ fun sh ->
  let file = dir ^ "/out" in
  ignore
    (Shell.run_exn sh
       (Printf.sprintf
          "umask 077 && base64 --decode > %s <<'EOF'\naGVsbG8K\nEOF"
          (Filename.quote file) ) ) ;
  check string "file contents" "hello\n" (read_file file) ;
  check int "file mode" 0o600 (Unix.stat file).Unix.st_perm

let test_shell_close env () =
  Switch.run
  @@ fun sw ->
  let sh = Shell.spawn ~env ~sw ["sh"] in
  Shell.close sh ;
  let failed =
    try
      ignore (Shell.run sh "echo x") ;
      false
    with _ -> true
  in
  check bool "run after close raises" true failed

(* ---------- deploy ---------- *)

let test_deploy_localhost env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/testhost") ;
  mkdir_p (dir ^ "/dest") ;
  write_file (dir ^ "/repo/a.age") "CIPHER:aaa\n" ;
  write_file (dir ^ "/repo/b.age") "CIPHER:bbb\n" ;
  Unix.symlink "../../repo/a.age" (dir ^ "/secrets/testhost/a.age") ;
  Unix.symlink "../../repo/b.age" (dir ^ "/secrets/testhost/b.age") ;
  write_file (dir ^ "/recip.txt") "age1fake\n" ;
  (* a.age is already deployed; stale.txt must be left alone. *)
  let sum_a = Secrets.sha256sum "CIPHER:aaa\n" in
  let sum_b = Secrets.sha256sum "CIPHER:bbb\n" in
  write_file (dir ^ "/dest/sha256-" ^ sum_a) "OLD\n" ;
  write_file (dir ^ "/dest/stale.txt") "stale\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age" fake_age ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  let target =
    Ageism.Localhost
      { installDir= Some (fs_path ~env (dir ^ "/dest"))
      ; hostName= Some "testhost" }
  in
  let config = e2e_config ~env ~dir in
  check_ok "deploy succeeds" (Ageism.deploy ~env config [target]) ;
  check string "missing secret rekeyed and installed" "REKEYED:bbb\n"
    (read_file (dir ^ "/dest/sha256-" ^ sum_b)) ;
  check string "existing secret untouched" "OLD\n"
    (read_file (dir ^ "/dest/sha256-" ^ sum_a)) ;
  check string "stale file kept" "stale\n"
    (read_file (dir ^ "/dest/stale.txt")) ;
  check int "decrypt called once" 1
    (count_matching "--decrypt" (dir ^ "/age.log")) ;
  check int "encrypt called once" 1
    (count_matching "--encrypt" (dir ^ "/age.log")) ;
  (* A second deploy is a no-op. *)
  check_ok "redeploy succeeds" (Ageism.deploy ~env config [target]) ;
  check int "no further decrypts" 1
    (count_matching "--decrypt" (dir ^ "/age.log"))

let test_deploy_resolves_hostname env () =
  with_temp_dir
  @@ fun dir ->
  let host = Unix.gethostname () in
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/" ^ host) ;
  mkdir_p (dir ^ "/dest") ;
  write_file (dir ^ "/repo/x.age") "CIPHER:xxx\n" ;
  Unix.symlink "../../repo/x.age" (dir ^ "/secrets/" ^ host ^ "/x.age") ;
  write_file (dir ^ "/recip.txt") "age1fake\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age" fake_age ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  check_ok "deploy succeeds"
    (Ageism.deploy ~env (e2e_config ~env ~dir)
       [ Ageism.Localhost
           {installDir= Some (fs_path ~env (dir ^ "/dest")); hostName= None}
       ] ) ;
  let sum = Secrets.sha256sum "CIPHER:xxx\n" in
  check string "secret installed under resolved host" "REKEYED:xxx\n"
    (read_file (dir ^ "/dest/sha256-" ^ sum))

let test_deploy_shared_secret env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/h1") ;
  mkdir_p (dir ^ "/secrets/h2") ;
  mkdir_p (dir ^ "/dest1") ;
  mkdir_p (dir ^ "/dest2") ;
  mkdir_p (dir ^ "/recips") ;
  write_file (dir ^ "/repo/shared.age") "CIPHER:shared\n" ;
  Unix.symlink "../../repo/shared.age" (dir ^ "/secrets/h1/s.age") ;
  Unix.symlink "../../repo/shared.age" (dir ^ "/secrets/h2/t.age") ;
  write_file (dir ^ "/recips/h1.txt") "age1h1\n" ;
  write_file (dir ^ "/recips/h2.txt") "age1h2\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age" fake_age ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  let config =
    { (e2e_config ~env ~dir) with
      Ageism.recipient= RecipientDir (fs_path ~env (dir ^ "/recips")) }
  in
  let target install_dir host_name =
    Ageism.Localhost
      { installDir= Some (fs_path ~env (dir ^ "/" ^ install_dir))
      ; hostName= Some host_name }
  in
  check_ok "deploy succeeds"
    (Ageism.deploy ~env config [target "dest1" "h1"; target "dest2" "h2"]) ;
  let sum = Secrets.sha256sum "CIPHER:shared\n" in
  check string "installed on h1" "REKEYED:shared\n"
    (read_file (dir ^ "/dest1/sha256-" ^ sum)) ;
  check string "installed on h2" "REKEYED:shared\n"
    (read_file (dir ^ "/dest2/sha256-" ^ sum)) ;
  check int "shared secret decrypted once" 1
    (count_matching "--decrypt" (dir ^ "/age.log")) ;
  check int "rekeyed once per host" 2
    (count_matching "--encrypt" (dir ^ "/age.log"))

let test_deploy_index env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/testhost") ;
  mkdir_p (dir ^ "/dest") ;
  write_file (dir ^ "/repo/a.age") "CIPHER:aaa\n" ;
  write_file (dir ^ "/repo/b.age") "CIPHER:bbb\n" ;
  Unix.symlink "../../repo/a.age" (dir ^ "/secrets/testhost/a.age") ;
  Unix.symlink "../../repo/b.age" (dir ^ "/secrets/testhost/b.age") ;
  write_file (dir ^ "/recip.txt") "age1fake\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age" fake_age ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  let config =
    { (e2e_config ~env ~dir) with
      Ageism.indexOutDir= Some (fs_path ~env (dir ^ "/index")) }
  in
  check_ok "deploy succeeds"
    (Ageism.deploy ~env config
       [ Ageism.Localhost
           { installDir= Some (fs_path ~env (dir ^ "/dest"))
           ; hostName= Some "testhost" } ] ) ;
  let sum_a = Secrets.sha256sum "CIPHER:aaa\n" in
  let sum_b = Secrets.sha256sum "CIPHER:bbb\n" in
  let index = read_file (dir ^ "/index/testhost.json") in
  let contains frag =
    let n = String.length frag in
    let rec loop i =
      i + n <= String.length index
      && (String.sub index i n = frag || loop (i + 1))
    in
    loop 0
  in
  check bool "maps a to its sum.age" true
    (contains (Printf.sprintf "\"a\": \"sha256-%s.age\"" sum_a)) ;
  check bool "maps b to its sum.age" true
    (contains (Printf.sprintf "\"b\": \"sha256-%s.age\"" sum_b))

let test_deploy_remote env () =
  with_temp_dir
  @@ fun dir ->
  let fake_dir = dir ^ "/var-lib-ageism" in
  mkdir_p fake_dir ;
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/fakehost") ;
  write_file (dir ^ "/repo/r.age") "CIPHER:rrr\n" ;
  Unix.symlink "../../repo/r.age" (dir ^ "/secrets/fakehost/r.age") ;
  write_file (dir ^ "/recip.txt") "age1fake\n" ;
  make_script ~dir "age" fake_age ;
  (* Fake [ssh]: skip -o option pairs, succeed immediately for the master
     (-fN) and control commands (-O), and run the remote command under sh
     with the target directory rewritten into a writable location. *)
  make_script ~dir "ssh"
    (Printf.sprintf
       {|while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -fN) exit 0 ;;
    -O) exit 0 ;;
    *@*) shift; break ;;
    *) shift ;;
  esac
done
exec sh -c "$(echo "$*" | sed 's|/var/lib/ageism|%s|g')"
|}
       fake_dir ) ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  check_ok "deploy succeeds"
    (Ageism.deploy ~env (e2e_config ~env ~dir)
       [Ageism.Remote {hostName= "fakehost"}] ) ;
  let sum = Secrets.sha256sum "CIPHER:rrr\n" in
  check string "secret installed remotely" "REKEYED:rrr\n"
    (read_file (fake_dir ^ "/sha256-" ^ sum))

let test_deploy_failure env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/testhost") ;
  mkdir_p (dir ^ "/dest") ;
  write_file (dir ^ "/repo/a.age") "CIPHER:aaa\n" ;
  Unix.symlink "../../repo/a.age" (dir ^ "/secrets/testhost/a.age") ;
  write_file (dir ^ "/recip.txt") "age1fake\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age" "exit 1\n" ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  check string "deploy reports failure when age fails" "failed:testhost"
    ( status_str
    @@ Ageism.deploy ~env (e2e_config ~env ~dir)
         [ Ageism.Localhost
             { installDir= Some (fs_path ~env (dir ^ "/dest"))
             ; hostName= Some "testhost" } ] ) ;
  let sum = Secrets.sha256sum "CIPHER:aaa\n" in
  check bool "nothing was installed" false
    (Sys.file_exists (dir ^ "/dest/sha256-" ^ sum))

let test_deploy_decrypts_all_before_uploading env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/h1") ;
  mkdir_p (dir ^ "/secrets/h2") ;
  mkdir_p (dir ^ "/dest1") ;
  mkdir_p (dir ^ "/dest2") ;
  write_file (dir ^ "/repo/a.age") "CIPHER:aaa\n" ;
  write_file (dir ^ "/repo/b.age") "CIPHER:bbb\n" ;
  Unix.symlink "../../repo/a.age" (dir ^ "/secrets/h1/a.age") ;
  Unix.symlink "../../repo/b.age" (dir ^ "/secrets/h2/b.age") ;
  write_file (dir ^ "/recip.txt") "age1fake\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age" fake_age ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  let target install_dir host_name =
    Ageism.Localhost
      { installDir= Some (fs_path ~env (dir ^ "/" ^ install_dir))
      ; hostName= Some host_name }
  in
  check_ok "deploy succeeds"
    (Ageism.deploy ~env (e2e_config ~env ~dir)
       [target "dest1" "h1"; target "dest2" "h2"] ) ;
  (* Phase separation: every --decrypt must precede every --encrypt. *)
  let lines =
    read_file (dir ^ "/age.log")
    |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "")
  in
  let indices pred =
    List.mapi (fun i line -> (i, line)) lines
    |> List.filter_map (fun (i, line) -> if pred line then Some i else None)
  in
  let decrypts = indices (String.starts_with ~prefix:"--decrypt") in
  let encrypts = indices (String.starts_with ~prefix:"--encrypt") in
  check int "decrypt calls" 2 (List.length decrypts) ;
  check bool "all decrypts precede all encrypts" true
    (List.fold_left max (-1) decrypts < List.hd encrypts)

let test_deploy_partial_failure env () =
  with_temp_dir
  @@ fun dir ->
  mkdir_p (dir ^ "/repo") ;
  mkdir_p (dir ^ "/secrets/h1") ;
  mkdir_p (dir ^ "/secrets/h2") ;
  mkdir_p (dir ^ "/dest1") ;
  mkdir_p (dir ^ "/dest2") ;
  mkdir_p (dir ^ "/recips") ;
  write_file (dir ^ "/repo/shared.age") "CIPHER:shared\n" ;
  Unix.symlink "../../repo/shared.age" (dir ^ "/secrets/h1/s.age") ;
  Unix.symlink "../../repo/shared.age" (dir ^ "/secrets/h2/s.age") ;
  (* h1's recipient file makes the fake [age --encrypt] fail. *)
  write_file (dir ^ "/recips/h1.txt") "bad\n" ;
  write_file (dir ^ "/recips/h2.txt") "good\n" ;
  make_script ~dir "sudo" fake_sudo ;
  make_script ~dir "age"
    {|case "$1" in
  --decrypt) exec sed 's/^CIPHER://' ;;
  --encrypt) grep -q bad "$3" && exit 1; exec sed 's/^/REKEYED:/' ;;
esac
exec cat
|} ;
  Unix.putenv "AGEISM_LOG" (dir ^ "/age.log") ;
  with_path ~dir
  @@ fun () ->
  let config =
    { (e2e_config ~env ~dir) with
      Ageism.recipient= RecipientDir (fs_path ~env (dir ^ "/recips")) }
  in
  let target install_dir host_name =
    Ageism.Localhost
      { installDir= Some (fs_path ~env (dir ^ "/" ^ install_dir))
      ; hostName= Some host_name }
  in
  check string "deploy reports the failed target" "failed:h1"
    ( status_str
    @@ Ageism.deploy ~env config [target "dest1" "h1"; target "dest2" "h2"]
    ) ;
  let sum = Secrets.sha256sum "CIPHER:shared\n" in
  check bool "nothing installed on h1" false
    (Sys.file_exists (dir ^ "/dest1/sha256-" ^ sum)) ;
  check string "h2 still installed" "REKEYED:shared\n"
    (read_file (dir ^ "/dest2/sha256-" ^ sum))

let test_deploy_requires_secrets_dir env () =
  let failed =
    try
      ignore
        (Ageism.deploy ~env
           { (e2e_config ~env ~dir:"/nonexistent") with
             Ageism.secretsRoot= None }
           [] ) ;
      false
    with _ -> true
  in
  check bool "raises without secrets dir" true failed

(* ---------- suite ---------- *)

let () =
  run "ageism"
    [ ( "secrets"
      , [ test_case "is_sum" `Quick test_is_sum
        ; test_case "select_missing" `Quick test_select_missing
        ; test_case "list" `Quick (with_env test_list)
        ; test_case "decrypt caches by sum" `Quick
            (with_env test_decrypt_caches) ] )
    ; ( "shell"
      , [ test_case "run" `Quick (with_env test_shell_run)
        ; test_case "run_exn failure" `Quick (with_env test_shell_run_exn)
        ; test_case "heredoc write" `Quick (with_env test_shell_heredoc)
        ; test_case "close" `Quick (with_env test_shell_close) ] )
    ; ( "deploy"
      , [ test_case "localhost" `Quick (with_env test_deploy_localhost)
        ; test_case "resolves hostname" `Quick
            (with_env test_deploy_resolves_hostname)
        ; test_case "shared secret decrypted once" `Quick
            (with_env test_deploy_shared_secret)
        ; test_case "writes index file" `Quick (with_env test_deploy_index)
        ; test_case "remote via ssh" `Quick (with_env test_deploy_remote)
        ; test_case "propagates failure" `Quick
            (with_env test_deploy_failure)
        ; test_case "decrypts all before uploading" `Quick
            (with_env test_deploy_decrypts_all_before_uploading)
        ; test_case "partial failure" `Quick
            (with_env test_deploy_partial_failure)
        ; test_case "requires secrets dir" `Quick
            (with_env test_deploy_requires_secrets_dir) ] ) ]
