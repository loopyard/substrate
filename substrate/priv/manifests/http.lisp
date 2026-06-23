;; The HTTP(S) substrate — outbound web access, default-deny by host.
;;
;; The agent can reach the network ONLY through `http/get`, and only for hosts
;; on the L0 allowlist (`:http_allow` in the vault). `deny-if host-denied` is the
;; whole posture: an empty/absent allowlist denies everything, and the agent can
;; neither read the list nor name a host outside it. Volume is rate-clamped so a
;; capability that *is* allowed still can't be used to hammer a host.

(substrate http
  "Make outbound HTTP(S) GET requests, restricted to an allowlisted set of hosts.
   Default-deny: a request to any host not explicitly allowed is refused. Use the
   returned :body together with the fs substrate to save a download to disk."

  (capability http/get
    "Fetch a URL with GET. Returns the HTTP status, the response body, and its
     byte length. Only allowlisted hosts are reachable; everything else is denied."
    (params (url string "absolute http(s) URL, e.g. \"https://example.com/file.txt\""))
    (returns (record (status int) (body string) (bytes int)))
    (policy  (deny-if host-denied)
             (rate    "10/min"))
    (example (http/get :url "https://example.com"))
    (bind    Substrate.HTTP.get/2)))
