;; The Gmail substrate — read freely, send only with a human's blessing.
;;
;; The agent wires into someone's mailbox through three typed capabilities. The
;; OAuth access token is resolved on the TRUSTED side at load (`(secret :gmail_token
;; …)`) and woven into the Authorization header by the membrane the instant before
;; the socket — the agent supplies only intent (a query, an id, a to/subject/body)
;; and never sees, names, or can exfiltrate the token.
;;
;; The whole posture the operator asked for is two policy lines:
;;
;;   - reads (search, read) carry no policy -> they run immediately.
;;   - `gmail/send` carries `(confirm-if always)` -> it is NEVER sent directly.
;;     The call is enqueued for human review; a person inspects the exact
;;     to/subject/body in the approval queue and, on approve, the membrane runs
;;     the real send. "Queue it, a human reviews and sends" — declaratively.
;;
;;   GMAIL_TOKEN=ya29.xxx  mix substrate.agent priv/substrates/gmail.lisp \
;;     --goal "Find unread mail from Jane and draft a reply."

(substrate gmail
  "Read a mailbox and compose replies. Searching and reading messages is free;
   SENDING is never automatic — every send is queued for a human to review and
   release. The agent supplies only intent; the OAuth token stays trusted-side."

  ;; The OAuth access token, resolved trusted-side and woven into the bearer
  ;; header per call. Never rendered by `describe`, never a value in L2.
  (secret :gmail_token (env "GMAIL_TOKEN"))

  (capability gmail/profile
    "Mailbox stats: the address and total message/thread counts. Works even on a
     restricted metadata-scope token."
    (params)
    (returns (record (email string) (messages_total int) (threads_total int)))
    (auth    (header "Authorization" (str "Bearer " (secret :gmail_token))))
    (example (gmail/profile))
    (bind    Substrate.Gmail.profile/2))

  (capability gmail/recent
    "List the most recent message ids (no search query needed). `estimate` is
     Gmail's whole-mailbox size."
    (params  (count int "how many recent ids to return (1..500)"))
    (returns (record (ids (list string)) (count int) (estimate int)))
    (auth    (header "Authorization" (str "Bearer " (secret :gmail_token))))
    (policy  (rate "30/min"))
    (example (gmail/recent :count 25))
    (bind    Substrate.Gmail.recent/2))

  (capability gmail/headers
    "Read a message's headers (From/To/Subject/Date) and snippet — the read that
     works under a metadata-scope token."
    (params  (id string "the message id from gmail/recent or gmail/search"))
    (returns (record (id string) (from string) (to string) (subject string)
                     (date string) (snippet string)))
    (auth    (header "Authorization" (str "Bearer " (secret :gmail_token))))
    (policy  (rate "120/min"))
    (example (gmail/headers :id "18f0a1b2c3d4e5f6"))
    (bind    Substrate.Gmail.headers/2))

  (capability gmail/search
    "Search the mailbox with Gmail query syntax. Returns matching message ids."
    (params  (query string "Gmail search, e.g. \"is:unread from:jane@acme.com\""))
    (returns (record (ids (list string)) (count int) (query string)))
    (auth    (header "Authorization" (str "Bearer " (secret :gmail_token))))
    (policy  (rate "30/min"))
    (example (gmail/search :query "is:unread newer_than:7d"))
    (bind    Substrate.Gmail.search/2))

  (capability gmail/read
    "Read one message: its From/To/Subject/Date headers, snippet, and body text."
    (params  (id string "the message id from gmail/search"))
    (returns (record (id string) (from string) (subject string)
                     (date string) (snippet string) (body string)))
    (auth    (header "Authorization" (str "Bearer " (secret :gmail_token))))
    (policy  (rate "60/min"))
    (example (gmail/read :id "18f0a1b2c3d4e5f6"))
    (bind    Substrate.Gmail.read/2))

  (capability gmail/send
    "Send an email. ALWAYS queued for human review first — the operator sees the
     to/subject/body and approves before anything leaves the building."
    (params  (to      string "recipient email address")
             (subject string "subject line")
             (body    string "plain-text message body"))
    (returns (record (id string) (thread_id string) (to string) (subject string)))
    (auth    (header "Authorization" (str "Bearer " (secret :gmail_token))))
    (policy  (confirm-if always)
             (rate       "20/hour"))
    (example (gmail/send :to "jane@acme.com" :subject "Re: lunch" :body "Sounds good!"))
    (bind    Substrate.Gmail.send/2)))
