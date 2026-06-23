;; The GitHub substrate — one self-contained artifact: capabilities + policy +
;; resources + secret + docs, all in this file. `Substrate.load`-ing it resolves
;; the token from the environment on the TRUSTED side and binds it into the
;; vault; the membrane weaves it into the Authorization header the instant before
;; the socket. The agent emits `(gh/get :url ...)` / `(gh/post :url ... :body ...)`
;; and the request goes out authenticated — it never sees, names, or can
;; exfiltrate the token, and `describe` never renders it.
;;
;;   GITHUB_TOKEN=ghp_xxx  mix run -e '{:ok, s} = Substrate.load("priv/substrates/github.lisp")'
;;
;; Read AND write: gh/get reads; gh/post creates (issues, comments), gh/patch
;; updates (close an issue, edit a comment), gh/delete removes. Every verb is
;; pinned to GitHub hosts and rate-clamped. To gate mutations behind a human, add
;; `(confirm-if ...)` to a write verb's policy — the call then queues for review.

(substrate gh
  "Authenticated GitHub access over HTTPS, restricted to GitHub hosts. Requests
   are signed on the trusted side; the agent supplies only a URL (and a body for
   writes) and never handles credentials. gh/get reads; gh/post, gh/patch and
   gh/delete write."

  ;; resources + secret bind the vault FROM THE FILE — no separate mount config.
  (resource :http_allow ["api.github.com" "raw.githubusercontent.com"])
  (secret   :gh_token   (env "GITHUB_TOKEN"))

  (capability gh/get
    "GET a GitHub URL, authenticated automatically. Only allowlisted GitHub hosts
     are reachable; volume is rate-clamped."
    (params  (url string "absolute https URL on an allowlisted GitHub host"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    ;; auth is trusted-tier: stripped at the wall like `bind`, resolved per call.
    (auth    (header "Authorization" (str "Bearer " (secret :gh_token)))
             (header "Accept"        "application/vnd.github+json"))
    (policy  (deny-if host-denied)
             (rate    "30/min"))
    (example (gh/get :url "https://api.github.com/repos/elixir-lang/elixir"))
    (bind    Substrate.HTTP.get/2))

  (capability gh/post
    "POST to a GitHub URL — create an issue, add a comment, etc. :body is a map,
     sent as JSON. Returns the created resource as :json."
    (params  (url  string "absolute https URL on an allowlisted GitHub host")
             (body any    "JSON body, e.g. {\"title\" \"Bug\" \"body\" \"...\"}"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (auth    (header "Authorization" (str "Bearer " (secret :gh_token)))
             (header "Accept"        "application/vnd.github+json"))
    (policy  (deny-if host-denied)
             (rate    "30/min"))
    (example (gh/post :url "https://api.github.com/repos/me/proj/issues"
                      :body {"title" "Found a bug" "body" "steps to repro..."}))
    (bind    Substrate.HTTP.post/2))

  (capability gh/patch
    "PATCH a GitHub URL — update an issue (e.g. close it), edit a comment. :body
     is a map, sent as JSON."
    (params  (url  string "absolute https URL on an allowlisted GitHub host")
             (body any    "JSON body, e.g. {\"state\" \"closed\"}"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (auth    (header "Authorization" (str "Bearer " (secret :gh_token)))
             (header "Accept"        "application/vnd.github+json"))
    (policy  (deny-if host-denied)
             (rate    "30/min"))
    (example (gh/patch :url "https://api.github.com/repos/me/proj/issues/7"
                       :body {"state" "closed"}))
    (bind    Substrate.HTTP.patch/2))

  (capability gh/delete
    "DELETE a GitHub URL — remove a comment, etc. Carries no body."
    (params  (url string "absolute https URL on an allowlisted GitHub host"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (auth    (header "Authorization" (str "Bearer " (secret :gh_token)))
             (header "Accept"        "application/vnd.github+json"))
    (policy  (deny-if host-denied)
             (rate    "30/min"))
    (example (gh/delete :url "https://api.github.com/repos/me/proj/issues/comments/42"))
    (bind    Substrate.HTTP.delete/2)))
