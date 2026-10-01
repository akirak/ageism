type 'path target =
  | Localhost of {installDir: 'path option; hostName: string option}
  | Remote of {hostName: string}

(** Command used to obtain root permission on localhost *)
type elevation = Sudo | Run0

type 'path recipient = RecipientFile of 'path | RecipientDir of 'path

type 'path config =
  { indexOutDir: 'path option
  ; recipient: 'path recipient
  ; secretsRoot: 'path option
  ; elevationStrategy: elevation
  ; ageExe: string }

(** Result of {!deploy}. [Failed names] lists the targets whose deployment
    failed; other targets were still deployed. *)
type status = Success | Failed of string list

val deploy :
     env:Eio_unix.Stdenv.base
  -> 'a Eio.Path.t config
  -> 'a Eio.Path.t target list
  -> status
