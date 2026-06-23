# Zoned policy: write governance depends on location. Run: mix run zoned_demo.exs
alias Substrate.Show

defmodule D do
  def hr(t), do: IO.puts("\n\e[1m\e[36m══ #{t}\e[0m")
  def note(t), do: IO.puts("\e[2m   #{t}\e[0m")

  def run(s, src) do
    IO.puts("\e[33m   agent> #{String.trim(src)}\e[0m")
    res = Substrate.eval(s, src)
    case res do
      {:fault, m} -> IO.puts("   => \e[31mfault: #{m}\e[0m")
      v when is_binary(v) -> IO.puts(v |> String.split("\n") |> Enum.map_join("\n", &("   " <> &1)))
      _ -> IO.puts("   => #{Show.form(res)}")
    end
    res
  end

  def burst(s, n, zone) do
    res = for i <- 1..n, do: Substrate.eval(s, ~s|(fs/write :path "#{zone}/#{i}.txt" :content "x")|)
    tally = Enum.frequencies_by(res, fn {:disposition, t, _} -> t end)
    {Map.get(tally, :done, 0), Map.get(tally, :"rate-limited", 0)}
  end
end

root = Path.join(System.tmp_dir!(), "zoned_root")
File.rm_rf!(root)
for z <- ~w(bulk data published archive), do: File.mkdir_p!(Path.join(root, z))
File.write!(Path.join(root, "archive/2025.txt"), "last year's records")

{:ok, s} = Substrate.start_link(name: nil)
substrate = "priv/substrates/zoned.lisp" |> File.read!() |> Substrate.read_substrate()
:ok = Substrate.mount(s, substrate, credentials: %{fs_root: root})
IO.puts("\e[1mzoned substrate up.\e[0m  bulk=unlimited  data=5/min  published=approval  archive=read-only")

D.hr("the policy the agent sees (location-guarded rate visible; mechanism abstracted)")
D.run(s, "(describe fs/write)")

D.hr("bulk/ — UNLIMITED writes (no rule fires, executes freely)")
{d, l} = D.burst(s, 12, "bulk")
D.note("12 writes to bulk/ => #{d} :done, #{l} :rate-limited")

D.hr("data/ — RATE-LIMITED by location (5/min; bulk above did NOT consume this budget)")
{d, l} = D.burst(s, 8, "data")
D.note("8 writes to data/ => #{d} :done, #{l} :rate-limited")

D.hr("published/ — HUMAN APPROVAL (confirm-if → queue)")
q = D.run(s, ~s|(fs/write :path "published/post.txt" :content "ship it")|)
{:disposition, :queued, %{handle: h}} = q
D.note("[human] approves #{h}")
Substrate.approve(s, h)
D.run(s, ~s|(await "#{h}")|)
q2 = D.run(s, ~s|(fs/write :path "published/leak.txt" :content "oops")|)
{:disposition, :queued, %{handle: h2}} = q2
D.note("[human] rejects #{h2}")
Substrate.deny(s, h2)
D.run(s, ~s|(await "#{h2}")|)

D.hr("archive/ — READ-ONLY (writes denied, reads allowed)")
D.run(s, ~s|(fs/write :path "archive/tamper.txt" :content "nope")|)
D.run(s, ~s|(fs/read :path "archive/2025.txt")|)

IO.puts("\n\e[1m\e[32m✓ one capability, four regimes — governance follows the write location.\e[0m")
