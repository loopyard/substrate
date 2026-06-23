;; STDOUT as a capability — not ambient power.
;;
;; Talking to the operator is an effect like any other: it crosses the trust
;; boundary, so it is GRANTED, not taken. Mount this alongside another substrate
;; to give the agent a voice; leave it out and the agent simply has no way to
;; print. Either way the call shows up on the surface and lands in the audit —
;; there is no back door to stdout.

(substrate io
  "Write a line to the operator's console. The one effect whose payload is words
   instead of bytes on disk or packets on a wire — but still an effect: it leaves
   the sandbox, so it passes the membrane and is recorded like every other call."

  (capability io/print
    "Print one line to the operator's stdout, tagged as agent output. Returns the
     text that was written."
    (params  (text string "the line to print"))
    (returns (record (printed string)))
    (example (io/print :text "saved /home/agent/notes.txt"))
    (bind    Substrate.Stdio.write/2)))
