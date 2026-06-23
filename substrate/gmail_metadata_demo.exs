# What the metadata-scope token CAN do, all through the substrate:
# profile (mailbox stats) -> recent (list ids) -> headers (From/Subject/Date),
# then count messages from Jeannette among the scanned window.
#
#   GMAIL_TOKEN=ya29... mix run gmail_metadata_demo.exs

alias Substrate.Server

window = String.to_integer(System.get_env("WINDOW") || "100")
needle = String.downcase(System.get_env("NEEDLE") || "jeannette")

{:ok, s} = Substrate.load("priv/substrates/gmail.lisp")

IO.puts("\n== gmail/profile (live) ==")

case Server.call(s, "gmail/profile", %{}) do
  {:disposition, :done, p} ->
    IO.puts("  #{p.email} — #{p.messages_total} messages, #{p.threads_total} threads")

  other ->
    IO.inspect(other, label: "  profile")
    System.halt(0)
end

IO.puts("\n== gmail/recent :count #{window} (live) ==")

ids =
  case Server.call(s, "gmail/recent", %{count: window}) do
    {:disposition, :done, r} ->
      IO.puts("  pulled #{r.count} recent ids (mailbox estimate ~#{r.estimate})")
      r.ids

    other ->
      IO.inspect(other, label: "  recent")
      []
  end

IO.puts("\n== gmail/headers for each (live) — scanning for \"#{needle}\" ==")

msgs =
  ids
  |> Enum.map(fn id ->
    case Server.call(s, "gmail/headers", %{id: id}) do
      {:disposition, :done, m} -> m
      _ -> nil
    end
  end)
  |> Enum.reject(&is_nil/1)

hits =
  Enum.filter(msgs, fn m ->
    String.contains?(String.downcase("#{m.from} #{m.to}"), needle)
  end)

IO.puts("  scanned #{length(msgs)} messages in the recent window")
IO.puts("  involving \"#{needle}\": #{length(hits)}")

for m <- Enum.take(hits, 15) do
  IO.puts("    - #{String.slice(m.subject || "(no subject)", 0, 55)}   [#{m.from}]")
end

IO.puts("\n== a few recent senders (to show real data flowing) ==")

for m <- Enum.take(msgs, 8) do
  IO.puts("  #{String.pad_trailing(String.slice(m.from || "?", 0, 32), 32)} | #{String.slice(m.subject || "", 0, 48)}")
end

IO.puts("\n== audit (trusted-side) — #{length(Substrate.audit(s))} calls adjudicated ==")
