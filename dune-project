(lang dune 3.23)

(name ageism)

(generate_opam_files true)

(package
 (name ageism)
 (depends
  (ocaml (>= 5.2))
   cmdliner
   digestif
   eio
   fmt
   eio_main
   yojson
   ppx_yojson_conv
  (alcotest :with-test)))

 ; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
