open Cmdliner

let main ~env (config : string Ageism.config)
    (targets : string Ageism.target list) =
  let open Ageism in
  let toEioPath = fun str -> Eio.Path.(Eio.Stdenv.fs env / str) in
  let toEioTarget = function
    | Localhost {installDir; hostName} ->
        Localhost {installDir= Option.map toEioPath installDir; hostName}
    | Remote {hostName} -> Remote {hostName}
  in
  let eio_config =
    { indexOutDir= Option.map toEioPath config.indexOutDir
    ; secretsRoot= Option.map toEioPath config.secretsRoot
    ; recipient=
        ( match config.recipient with
        | RecipientFile fileStr -> RecipientFile (toEioPath fileStr)
        | RecipientDir dirStr -> RecipientDir (toEioPath dirStr) )
    ; elevationStrategy= config.elevationStrategy
    ; ageExe= config.ageExe }
  in
  match Ageism.(deploy ~env eio_config (List.map toEioTarget targets)) with
  | Ageism.Success -> Cmd.Exit.ok
  | Ageism.Failed _ -> Cmd.Exit.some_error

let main_t (env : Eio_unix.Stdenv.base) =
  let open Args in
  let main = main ~env in
  Cmdliner.Term.(const main $ config_t $ targets_t)

let eval_command env =
  let doc = "An age secret deployment tool for NixOS" in
  let version = "%%VERSION%%" in
  Cmdliner.Cmd.(eval' (v (info "ageism" ~version ~doc) (main_t env)))

let () = Eio_main.run @@ fun env -> exit (eval_command env)
