;; A write substrate capped at 10 files per second.
;;
;; The cap is one policy line — `(rate "10/sec")`. The membrane counts writes in
;; the current 1-second window and returns :rate-limited once 10 are spent; the
;; window then resets. The signature never changes (ABI frozen, errno dynamic).

(substrate spool
  "Append-style file writing, jailed to one root and capped at 10 writes/second."

  (capability spool/write
    "Write text to a file (relative to the jail root). Max 10 per second."
    (params (path    string "file path relative to the jail root")
            (content string "text to write"))
    (returns (record (bytes int) (path string)))
    (policy  (deny-if escapes-jail)
             (rate    "10/sec"))
    (example (spool/write :path "events/0001.txt" :content "hello"))
    (bind    Substrate.FS.write/2))

  (capability spool/read
    "Read a file back (not rate-limited)."
    (params (path string "file path relative to the jail root"))
    (returns (record (content string) (bytes int)))
    (policy  (deny-if escapes-jail))
    (example (spool/read :path "events/0001.txt"))
    (bind    Substrate.FS.read/2)))
