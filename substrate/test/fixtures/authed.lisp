;; Test fixture: an authenticated local fetch. Secret comes from the env so the
;; suite can exercise the full load → resolve → inject → strip path hermetically.

(substrate authed
  "Authenticated local fetch (test fixture)."

  (resource :http_allow ["127.0.0.1"])
  (secret   :token      (env "SUBSTRATE_TEST_TOKEN"))

  (capability authed/get
    "GET a URL with a bearer token attached on the trusted side."
    (params  (url string "absolute URL"))
    (returns (record (status int) (body string) (bytes int)))
    (auth    (header "Authorization" (string "Bearer " (secret :token))))
    (policy  (deny-if host-denied)
             (rate    "60/min"))
    (bind    Substrate.HTTP.get/2)))
