open Cmdliner

let index_out_dir =
  let doc = "Write the index file to $(docv)/HOSTNAME.json." in
  let env = Cmd.Env.info "AGEISM_INDEX_OUT_DIR" ~doc in
  Arg.(
    value
    & opt (some string) None
    & info ["index-out-dir"] ~docv:"DIR" ~doc ~env )

let recipient_file =
  let doc = "Use the age recipient file at $(docv)." in
  let env = Cmd.Env.info "AGEISM_RECIPIENT_FILE" ~doc in
  Arg.(
    value
    & opt (some string) None
    & info ["recipient-file"] ~docv:"FILE" ~doc ~env )

let recipient_dir =
  let doc =
    "Use the age recipient file (public key) at $(docv)/HOSTNAME.txt."
  in
  let env = Cmd.Env.info "AGEISM_RECIPIENT_DIR" ~doc in
  Arg.(
    value
    & opt (some string) None
    & info ["recipient-dir"] ~docv:"DIR" ~doc ~env )

let install_dir_a =
  let doc =
    "Transfer the secrets to $(docv). This is intended for use in \
     nixos-install."
  in
  let env = Cmd.Env.info "AGEISM_INSTALL_DIR" ~doc in
  Arg.(
    value
    & opt (some string) None
    & info ["install-dir"] ~docv:"DIR" ~doc ~env )

let secrets_root_a =
  let doc = "Root of the secrets for all hosts." in
  let env = Cmd.Env.info "AGEISM_SECRETS_ROOT" ~doc in
  Arg.(
    value
    & opt (some string) None
    & info ["secrets-root"] ~docv:"DIR" ~doc ~env )

let hosts_a =
  let doc = "Host to which secrets are deployed." in
  Arg.(value & pos_all string [] & info [] ~docv:"HOST" ~doc)

let age_exe_a =
  let doc = "Use $(docv) as the age executable." in
  let env = Cmd.Env.info "AGEISM_AGE" ~doc in
  Arg.(value & opt string "age" & info ["age"] ~docv:"EXE" ~doc ~env)

let elevation_a =
  let doc = "Privilege elevation strategy." in
  let env = Cmd.Env.info "AGEISM_ELEVATION" ~doc in
  Arg.(
    value
    & opt (enum [("sudo", Ageism.Sudo); ("run0", Ageism.Run0)]) Ageism.Sudo
    & info ["elevation"] ~docv:"STRATEGY" ~doc ~env )

let config_t =
  let open Ageism in
  let make_config indexOutDir recipientFile recipientDir secretsRoot
      elevationStrategy ageExe =
    { indexOutDir
    ; secretsRoot
    ; elevationStrategy
    ; ageExe
    ; recipient=
        ( match recipientFile with
        | Some file -> RecipientFile file
        | None ->
          begin match recipientDir with
          | Some dir -> RecipientDir dir
          | None -> failwith "You must specify at least one recipient"
          end ) }
  in
  Term.(
    const make_config $ index_out_dir $ recipient_file $ recipient_dir
    $ secrets_root_a $ elevation_a $ age_exe_a )

let targets_t =
  let open Ageism in
  let make_targets installDir hosts =
    match hosts with
    | [] -> [Localhost {installDir; hostName= None}]
    | _ -> List.map (fun hostName -> Remote {hostName}) hosts
  in
  Term.(const make_targets $ install_dir_a $ hosts_a)
