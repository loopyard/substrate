;; The GitHub substrate — one self-contained artifact: capability + policy +
;; resources + secret + docs, all in this file. `Substrate.load`-ing it resolves
;; the token from the environment on the TRUSTED side and binds it into the
;; vault; the membrane weaves it into the Authorization header the instant before
;; the socket. The agent emits `(gh/get :url …)` and the request goes out
;; authenticated — it never sees, names, or can exfiltrate the token, and
;; `describe` never renders it.
;;
;;   GITHUB_TOKEN=ghp_xxx  mix run -e '{:ok, s} = Substrate.load("priv/manifests/github.lisp")'

(substrate gh
  "Authenticated GitHub access over HTTPS, restricted to GitHub hosts. Requests
   are signed on the trusted side; the agent supplies only a URL and never
   handles credentials."

  ;; resources + secret bind the vault FROM THE FILE — no separate mount config.
  (resource :http_allow ["api.github.com" "raw.githubusercontent.com"])
  (secret   :gh_token   (env "GITHUB_TOKEN"))

  (capability gh/get
    "GET a GitHub URL, authenticated automatically. Only allowlisted GitHub
     hosts are reachable; volume is rate-clamped."
    (params  (url string "absolute https URL on an allowlisted GitHub host"))
    (returns (record (status int) (body string) (bytes int)))
    ;; auth is trusted-tier: stripped at the wall like `bind`, resolved per call.
    (auth    (header "Authorization" (str "Bearer " (secret :gh_token)))
             (header "Accept"        "application/vnd.github+json"))
    (policy  (deny-if host-denied)
             (rate    "30/min"))
    (bind    Substrate.HTTP.get/2)))
