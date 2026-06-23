;; A rate-limited, path-restricted substrate.
;;
;; Two clamps make this safe:
;;   * path restriction — `deny-if escapes-jail` confines EVERY call to the one
;;     directory bound as the archive root at mount (the "certain path"). The
;;     root is a credential at L0; the agent can never name it.
;;   * rate limit — every capability carries `(rate "N/min")`; the membrane
;;     returns :rate-limited once the budget for the window is spent.
;;
;; It is also read-only *by construction*: the surface has no write or delete
;; capability, so there is no write to govern — capability-secure, not
;; policy-secure.

(substrate archive
  "Read-only, rate-limited access to a single archived directory. Nothing
   outside the archive root is reachable, and call volume is clamped."

  (capability archive/list
    "List entries under the archive root (path is relative to it)."
    (params (path string "directory path relative to the archive root, e.g. \".\""))
    (returns (record (entries (list string))))
    (policy  (deny-if escapes-jail)
             (rate    "3/min"))
    (example (archive/list :path "."))
    (bind    Substrate.FS.list/2))

  (capability archive/read
    "Read a file from the archive. Returns its text and byte length."
    (params (path string "file path relative to the archive root"))
    (returns (record (content string) (bytes int)))
    (policy  (deny-if escapes-jail)
             (rate    "3/min"))
    (example (archive/read :path "2026-q2.txt"))
    (bind    Substrate.FS.read/2)))
