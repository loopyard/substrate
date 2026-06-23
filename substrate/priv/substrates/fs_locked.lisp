;; The locked Filesystem substrate — default-deny on writes.
;;
;; Reads are jailed (can't leave the root) but otherwise free. WRITES are
;; deny-all-except: `deny-if write-denied` refuses any path not inside an
;; allowlisted dir (`:fs_allow` in the vault). With no allowlist, every write is
;; denied; opening a directory is an L0 act, never something the agent can do.
;;
;; Pair this with the http substrate to let an agent download from a few hosts
;; and save only into a few directories — and nothing else.

(substrate fs
  "Jailed filesystem access with default-deny writes. Reads stay inside the jail
   root; writes are refused unless the target sits inside an allowlisted
   directory. Nothing can escape the jail."

  (capability fs/list
    "List the entries of a directory (relative to the jail root)."
    (parameters (path string "directory path relative to the jail root"))
    (returns (record (entries (list string))))
    (policy  (deny-if escapes-jail))
    (example (fs/list :path "downloads"))
    (bind    Substrate.FS.list/2))

  (capability fs/read
    "Read a file's contents. Returns the text and its byte length."
    (parameters (path string "file path relative to the jail root"))
    (returns (record (content string) (bytes integer)))
    (policy  (deny-if escapes-jail))
    (example (fs/read :path "downloads/page.html"))
    (bind    Substrate.FS.read/2))

  (capability fs/write
    "Write text to a file. DENIED unless the target is inside an allowlisted
     directory; volume is rate-clamped."
    (parameters (path    string "file path relative to the jail root")
            (content string "text to write"))
    (returns (record (bytes integer) (path string)))
    (policy  (deny-if escapes-jail)
             (deny-if write-denied)
             (rate    "20/min"))
    (example (fs/write :path "downloads/page.html" :content "..."))
    (bind    Substrate.FS.write/2)))
