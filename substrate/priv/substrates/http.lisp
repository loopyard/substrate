;; The HTTP(S) substrate — outbound web access, default-deny by host.
;;
;; The agent reaches the network ONLY through these verbs, and only for hosts on
;; the L0 allowlist (`:http_allow` in the vault). `deny-if host-denied` is the
;; whole posture: an empty/absent allowlist denies everything, and the agent can
;; neither read the list nor name a host outside it. Volume is rate-clamped so a
;; capability that *is* allowed still can't be used to hammer a host.
;;
;; GET/DELETE carry no body. POST/PUT/PATCH take `:body` — a map (sent as JSON
;; for you) or a string. Every response carries :status/:body/:bytes, plus a
;; decoded :json when the body parses, so an API result is usable without a
;; separate parse step.

(substrate http
  "Make outbound HTTP(S) requests, restricted to an allowlisted set of hosts.
   Default-deny: a request to any host not explicitly allowed is refused. GET and
   DELETE send no body; POST/PUT/PATCH take :body (a map, sent as JSON, or a
   string). Responses include a decoded :json field when the body is JSON."

  (capability http/get
    "Fetch a URL with GET. Only allowlisted hosts are reachable; everything else
     is denied."
    (params  (url string "absolute http(s) URL, e.g. \"https://example.com/x\""))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (policy  (deny-if host-denied)
             (rate    "10/min"))
    (example (http/get :url "https://example.com"))
    (bind    Substrate.HTTP.get/2))

  (capability http/post
    "POST to a URL. :body is a map (sent as JSON) or a string. Returns the status
     and the response (with a decoded :json when the reply is JSON)."
    (params  (url  string "absolute http(s) URL on an allowlisted host")
             (body any    "request body — a map (sent as JSON) or a string"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (policy  (deny-if host-denied)
             (rate    "10/min"))
    (example (http/post :url "https://example.com/items" :body {"name" "widget"}))
    (bind    Substrate.HTTP.post/2))

  (capability http/put
    "PUT to a URL (replace). :body is a map (sent as JSON) or a string."
    (params  (url  string "absolute http(s) URL on an allowlisted host")
             (body any    "request body — a map (sent as JSON) or a string"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (policy  (deny-if host-denied)
             (rate    "10/min"))
    (example (http/put :url "https://example.com/items/1" :body {"name" "gadget"}))
    (bind    Substrate.HTTP.put/2))

  (capability http/patch
    "PATCH a URL (partial update). :body is a map (sent as JSON) or a string."
    (params  (url  string "absolute http(s) URL on an allowlisted host")
             (body any    "request body — a map (sent as JSON) or a string"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (policy  (deny-if host-denied)
             (rate    "10/min"))
    (example (http/patch :url "https://example.com/items/1" :body {"name" "gadget"}))
    (bind    Substrate.HTTP.patch/2))

  (capability http/delete
    "DELETE a URL. Carries no body."
    (params  (url string "absolute http(s) URL on an allowlisted host"))
    (returns (record (status int) (body string) (bytes int) (json any)))
    (policy  (deny-if host-denied)
             (rate    "10/min"))
    (example (http/delete :url "https://example.com/items/1"))
    (bind    Substrate.HTTP.delete/2)))
