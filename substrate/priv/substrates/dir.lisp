;; The simplest substrate: read and write files, confined to ONE directory.
;;
;; The directory — the "jail root" — is named once, at load, in the vault. The
;; agent only ever passes RELATIVE paths, and `deny-if escapes-jail` re-resolves
;; every path against the root and refuses anything that climbs out (`..`,
;; absolute paths, symlinks resolving outside). The root is not a value the agent
;; holds, so it can neither read it nor name a path outside it.

(substrate dir
  "Read and write files inside a single directory. Every path is relative to
   that directory; nothing can escape it."

  (capability dir/read
    "Read a file inside the directory. Returns the text and its byte length."
    (parameters  (path string "file path relative to the directory, e.g. \"notes.txt\""))
    (returns (record (content string) (bytes integer)))
    (policy  (deny-if escapes-jail))
    (example (dir/read :path "notes.txt"))
    (bind    Substrate.FS.read/2))

  (capability dir/write
    "Write text to a file inside the directory, creating parent dirs as needed."
    (parameters  (path    string "file path relative to the directory")
             (content string "text to write"))
    (returns (record (bytes integer) (path string)))
    (policy  (deny-if escapes-jail))
    (example (dir/write :path "notes.txt" :content "buy milk"))
    (bind    Substrate.FS.write/2)))
