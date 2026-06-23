# Live Gmail slice demo — read freely, send only with a human's approval.
# Run with a Gmail OAuth access token in the env:
#
#   GMAIL_TOKEN=ya29... mix run gmail_live.exs
#
# `Substrate.load` resolves `(secret :gmail_token (env "GMAIL_TOKEN"))` trusted-side;
# the token is never a value the agent (or this script's "intent" half) handles.

alias Substrate.Server

token = System.get_env("GMAIL_TOKEN") || raise "set GMAIL_TOKEN"

# Owner's address, so the test send goes to the mailbox itself (safe + visible).
me =
  case :httpc.request(
         :get,
         {~c"https://gmail.googleapis.com/gmail/v1/users/me/profile",
          [{~c"Authorization", to_charlist("Bearer " <> token)}]},
         [ssl: [verify: :verify_none], timeout: 15_000],
         body_format: :binary
       ) do
    {:ok, {{_, 200, _}, _, body}} ->
      {:ok, %{"emailAddress" => addr}} = Substrate.JSON.decode(body)
      addr

    other ->
      IO.inspect(other, label: "profile lookup failed")
      raise "could not read mailbox profile — is the token valid / scoped?"
  end

IO.puts("\n=== mailbox: #{me} ===")

{:ok, server} = Substrate.load("priv/substrates/gmail.lisp")

IO.puts("\n== 1. gmail/search  (live, free) ==")
ids =
  case Server.call(server, "gmail/search", %{query: "in:inbox newer_than:30d"}) do
    {:disposition, :done, %{ids: ids, count: count}} ->
      IO.puts("  found #{count} message(s)")
      ids

    other ->
      IO.inspect(other, label: "  search")
      []
  end

case List.first(ids) do
  nil ->
    IO.puts("\n== 2. gmail/read  (skipped — empty inbox) ==")

  first ->
    IO.puts("\n== 2. gmail/read first message  (live, free) ==")

    case Server.call(server, "gmail/read", %{id: first}) do
      {:disposition, :done, m} ->
        IO.puts("  from:    #{m.from}")
        IO.puts("  subject: #{m.subject}")
        IO.puts("  snippet: #{String.slice(m.snippet || "", 0, 90)}")

      other ->
        IO.inspect(other, label: "  read")
    end
end

IO.puts("\n== 3. gmail/send  (confirm-if always -> queued, NOT sent) ==")

{:disposition, :queued, %{handle: handle}} =
  Server.call(server, "gmail/send", %{
    to: me,
    subject: "Substrate live test",
    body: "This email was composed as agent INTENT, parked at the capability wall, and only sent after a human approved it. — substrate"
  })

IO.puts("  queued as #{handle} — nothing left the building yet")

IO.puts("\n== 4. operator reviews the queue (trusted side) ==")

for {h, name, args} <- Server.pending(server) do
  IO.puts("  #{h}  #{name}")
  IO.puts("       to:      #{args.to}")
  IO.puts("       subject: #{inspect(args.subject)}")
  IO.puts("       body:    #{inspect(String.slice(args.body, 0, 70))}")
end

IO.puts("\n== 5. human approves -> the REAL send fires ==")

case Server.approve(server, handle) do
  {:disposition, :done, sent} ->
    IO.puts("  SENT ✓  id=#{sent.id}  to=#{sent.to}")

  other ->
    IO.inspect(other, label: "  approve")
end

IO.puts("\n== audit (trusted-side log) ==")

for %{seq: n, cap: cap, outcome: out} <- Substrate.audit(server) do
  IO.puts("  ##{n}  #{cap}  ->  #{inspect(out)}")
end
