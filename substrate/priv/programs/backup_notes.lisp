;; A PROGRAM that runs ON the roots substrate.
;;
;; It is written in the substrate's own lisp and submitted to `Substrate.eval`.
;; Every (fs/read ...) and (fs/write ...) is a capability call that passes
;; through the membrane — the `deny-if outside-roots` wall checks each one.
;;
;; The program does NOT know the allowlist. It just names paths and handles the
;; two answers a capability can give back: (:done r) or (:denied d).

;; Read a source note, then try to fan it out to several backup locations.
;; Some are inside /home (allowed), some are not (/root, /etc, a .. climb-out).
(let [src   "/home/agent/notes.txt"
      saved (case (fs/read :path src)
              (:done r)   (:content r)
              (:denied _) "(unreadable)")]

  (for [dest (list "/home/agent/backup/notes.bak"   ;; allowed
                   "/root/notes.stolen"             ;; outside roots -> denied
                   "/etc/notes.bak"                 ;; outside roots -> denied
                   "/home/../root/sneaky.bak")]     ;; climb-out -> resolved, denied
    (case (fs/write :path dest :content saved)
      (:done r)   (io/print :text (string "saved  -> " (:path r)))
      (:denied d) (io/print :text (string "denied -> " dest " :: " (:reason d))))))
