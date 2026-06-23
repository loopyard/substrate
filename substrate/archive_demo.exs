# A rate-limited substrate confined to one path. Run: mix run archive_demo.exs
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
end

# The "certain path": only this directory is reachable. Bound at L0.
archive = Path.join(System.tmp_dir!(), "archive_root")
File.rm_rf!(archive)
File.mkdir_p!(archive)
File.write!(Path.join(archive, "2026-q1.txt"), "Q1: shipped the membrane")
File.write!(Path.join(archive, "2026-q2.txt"), "Q2: shipped the live registry")
# A sibling secret OUTSIDE the archive — proves the restriction is real.
File.write!(Path.join(System.tmp_dir!(), "NOT_the_archive.txt"), "off limits")

{:ok, s} = Substrate.start_link(name: nil)
substrate = "priv/substrates/archive.lisp" |> File.read!() |> Substrate.read_substrate()
:ok = Substrate.mount(s, substrate, credentials: %{fs_root: archive})
IO.puts("\e[1marchive substrate up.\e[0m confined to: #{archive}  (rate: 3/min)")

D.hr("1. THE SURFACE — read-only (no write/delete capability exists at all)")
D.run(s, "(describe archive)")

D.hr("2. PATH RESTRICTION — escapes are :denied, before any work (no budget spent)")
D.run(s, ~s|(archive/read :path "../NOT_the_archive.txt")|)
D.run(s, ~s|(archive/list :path "../..")|)
D.note("denied at the membrane — the read never reaches the disk")

D.hr("3. RATE LIMIT — allowed reads inside the path, then errno flips at the budget")
D.run(s, """
(for [f (list "2026-q1.txt" "2026-q2.txt" "2026-q1.txt" "2026-q2.txt" "2026-q1.txt")]
  (case (archive/read :path f)
    (:done r)         (log "read" f "->" (:bytes r) "bytes")
    (:rate-limited e) (log "read" f ":rate-limited, retry-after" (:retry_after e) "s")))
""")
D.note("same call, same signature — 3 succeed, then the membrane clamps")

D.hr("4. NO WRITE SURFACE — there is nothing to misuse")
D.run(s, ~s|(archive/write :path "2026-q2.txt" :content "tampered")|)

IO.puts("\n\e[1m\e[32m✓ rate-limited + path-restricted, by construction.\e[0m")
