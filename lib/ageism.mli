type 'path target =
  | Localhost of {installDir: 'path option; hostName: string option}
  | Remote of {hostName: string}

(** Command used to obtain root permission on localhost *)
type elevation = Sudo | Run0

type 'path recipient = RecipientFile of 'path | RecipientDir of 'path

type 'path config =
  { indexOutDir: 'path option
  ; recipient: 'path recipient
  ; identityFile: 'path
  ; secretsRoot: 'path option
  ; elevationStrategy: elevation
  ; ageExe: string }

(** Result of {!deploy}. [Failed names] lists the targets whose deployment
    failed; other targets were still deployed. *)
type status = Success | Failed of string list

val check_host_name : string -> (string, string) result
(** [check_host_name name] is [Ok name] if [name] can be used as a host name:
    non-empty, consisting of letters, digits, ['.'], ['-'], ['_'] and [':'],
    and not starting with ['.'] or ['-']. *)

val deploy :
     env:Eio_unix.Stdenv.base
  -> 'a Eio.Path.t config
  -> 'a Eio.Path.t target list
  -> status
