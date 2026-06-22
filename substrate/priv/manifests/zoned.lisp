;; Zoned filesystem — one write capability whose policy depends on WHERE you
;; write. Four zones under the jail root, four different governance regimes:
;;
;;   bulk/*       unlimited writes        (no rule fires → executes freely)
;;   data/*       rate-limited 5/min      (rate guarded by location)
;;   published/*  human approval          (confirm-if → :queued)
;;   archive/*    read-only               (deny-if → writes refused, reads OK)
;;
;; The agent calls the same fs/write either way; the membrane reads the path and
;; applies the matching regime. Reads are allowed everywhere in the jail.

(substrate fs
  "A zoned file store. Write policy depends on location: bulk is unlimited,
   data is rate-limited, published needs human approval, archive is read-only.
   Reads are allowed across the jail; nothing escapes it."

  (capability fs/write
    "Write a file. Governance depends on the target zone (see the namespace doc)."
    (params (path    string "file path: bulk/…, data/…, published/…  (archive/… is read-only)")
            (content string "text to write"))
    (returns (record (bytes int) (path string)))
    (policy  (deny-if    escapes-jail)      ; never leave the jail
             (deny-if    in-archive)        ; archive zone is read-only
             (confirm-if in-published)      ; published zone needs a human
             (rate       "5/min" in-data))  ; data zone throttled; bulk falls through → unlimited
    (example (fs/write :path "bulk/event-001.txt" :content "hi"))
    (bind    Substrate.FS.write/2))

  (capability fs/read
    "Read any file in the jail — every zone is readable, including archive."
    (params (path string "file path relative to the jail root"))
    (returns (record (content string) (bytes int)))
    (policy  (deny-if escapes-jail))
    (example (fs/read :path "archive/2025.txt"))
    (bind    Substrate.FS.read/2)))
