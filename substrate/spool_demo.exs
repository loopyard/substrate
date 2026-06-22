# 10-files-per-second write substrate. Run: mix run spool_demo.exs
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

  # fire a burst of N writes as fast as possible; tally the dispositions
  def burst(s, n, prefix) do
    results =
      for i <- 1..n do
        Substrate.eval(s, ~s|(spool/write :path "#{prefix}/#{i}.txt" :content "x")|)
      end
    done    = Enum.count(results, &match?({:disposition, :done, _}, &1))
    limited = Enum.count(results, &match?({:disposition, :"rate-limited", _}, &1))
    {done, limited}
  end
end

root = Path.join(System.tmp_dir!(), "spool_root")
File.rm_rf!(root)
File.mkdir_p!(root)

{:ok, s} = Substrate.start_link(name: nil)
manifest = "priv/manifests/spool.lisp" |> File.read!() |> Substrate.read_manifest()
:ok = Substrate.mount(s, manifest, credentials: %{fs_root: root})
IO.puts("\e[1mspool substrate up.\e[0m cap: 10 writes/second")

D.hr("the policy the agent sees (rate kept, mechanism abstracted)")
D.run(s, "(describe spool/write)")

D.hr("burst of 25 writes in one second")
{done, limited} = D.burst(s, 25, "burst1")
D.note("=> #{done} :done, #{limited} :rate-limited   (cap is 10/sec)")

D.hr("wait for the 1-second window to reset, then burst 25 more")
Process.sleep(1100)
{done2, limited2} = D.burst(s, 25, "burst2")
D.note("=> #{done2} :done, #{limited2} :rate-limited   (window reset → 10 more allowed)")

on_disk = root |> File.ls!() |> Enum.flat_map(fn d -> File.ls!(Path.join(root, d)) end) |> length()
IO.puts("\n\e[1m\e[32m✓ #{done + done2} files written across two seconds, ≤10 per second. (on disk: #{on_disk})\e[0m")
