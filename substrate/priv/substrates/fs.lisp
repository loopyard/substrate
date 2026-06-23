;; The Filesystem substrate — authored once, in one place.
;; Each capability's docstring, params, return shape, policy, example, and
;; native binding are a single declaration: code = data = docs. The agent reads
;; this surface (minus `bind` and the concrete predicates) in the same Lisp it
;; writes its programs in.

(substrate fs
  "Read and write files for the agent, jailed to a single root directory.
   Reads inside the jail are free; writes are rate-clamped and anything outside
   the safe area routes to a human approval queue. Nothing can escape the jail."

  (capability fs/list
    "List the entries of a directory (relative to the jail root)."
    (parameters (path string "directory path relative to the jail root, e.g. \"notes\""))
    (returns (record (entries (list string))))
    (policy  (deny-if escapes-jail))
    (example (fs/list :path "notes"))
    (bind    Substrate.FS.list/2))

  (capability fs/read
    "Read a file's contents. Returns the text and its byte length."
    (parameters (path string "file path relative to the jail root"))
    (returns (record (content string) (bytes integer)))
    (policy  (deny-if escapes-jail))
    (example (fs/read :path "notes/todo.txt"))
    (bind    Substrate.FS.read/2))

  (capability fs/write
    "Write text to a file, creating parent directories as needed. Writes outside
     the safe area need human approval; volume is rate-clamped."
    (parameters (path    string "file path relative to the jail root")
            (content string "text to write"))
    (returns (record (bytes integer) (path string)))
    (policy  (deny-if    escapes-jail)
             (rate       "5/min")
             (confirm-if outside-safe))
    (example (fs/write :path "notes/todo.txt" :content "buy milk"))
    (bind    Substrate.FS.write/2))

  (capability fs/delete
    "Delete a file. Deletions outside the safe area need human approval."
    (parameters (path string "file path relative to the jail root"))
    (returns (record (deleted string)))
    (policy  (deny-if    escapes-jail)
             (confirm-if outside-safe))
    (example (fs/delete :path "notes/old.txt"))
    (bind    Substrate.FS.delete/2)))
