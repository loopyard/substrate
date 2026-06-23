;; The clearest possible statement of the wall: ABSOLUTE paths, an allowlist of
;; roots. You can write to /home — you can NOT write to /root.
;;
;; Unlike `dir.lisp` (which jails the agent to ONE directory and only ever lets
;; it hold relative paths), here the agent names real absolute paths: "/home/...",
;; "/root/...", "/etc/passwd". The confinement is `deny-if outside-roots`, which
;; re-resolves every path and refuses anything not inside an allowlisted root
;; (`:fs_roots`, declared below). The list is bound at L0 — the agent can neither
;; read it nor add to it.
;;
;; The point this makes that nothing else does: the process runs as root, so the
;; OS would happily let it write to /root or /etc. The substrate is the only
;; thing that says no.

(substrate fs
  "Read and write files by absolute path, confined to an allowlist of roots.
   /home is open; /root, /etc, and everything else are refused at the membrane —
   regardless of the OS-level permissions of the process underneath."

  ;; The allowlist, bound into the vault FROM THIS FILE. /home is in. Nothing
  ;; else is. Default-deny: a path under no listed root is refused.
  (resource :fs_roots ["/home"])

  (capability fs/read
    "Read a file by absolute path. DENIED unless the path sits inside an allowed root."
    (parameters  (path string "absolute file path, e.g. \"/home/agent/notes.txt\""))
    (returns (record (content string) (bytes integer)))
    (policy  (deny-if outside-roots))
    (example (fs/read :path "/home/agent/notes.txt"))
    (bind    Substrate.FS.read_at/2))

  (capability fs/write
    "Write text to a file by absolute path. DENIED unless the path sits inside an
     allowed root; parent dirs are created as needed."
    (parameters  (path    string "absolute file path, e.g. \"/home/agent/notes.txt\"")
             (content string "text to write"))
    (returns (record (bytes integer) (path string)))
    (policy  (deny-if outside-roots))
    (example (fs/write :path "/home/agent/notes.txt" :content "buy milk"))
    (bind    Substrate.FS.write_at/2)))
