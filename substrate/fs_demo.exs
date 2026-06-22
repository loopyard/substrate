# Substrate — filesystem capability, end to end.
# Run: mix run fs_demo.exs
alias Substrate.Show

defmodule Demo do
  def hr(t), do: IO.puts("\n\e[1m\e[36m══ #{t}\e[0m")
  def note(t), do: IO.puts("\e[2m   #{t}\e[0m")

  def run(s, src) do
    IO.puts("\e[33m   agent> #{String.trim(src)}\e[0m")
    res = Substrate.eval(s, src)
    case res do
      {:fault, msg}         -> IO.puts("   => \e[31mfault: #{msg}\e[0m")
      {:disposition, _, _}  -> IO.puts("   => #{Show.form(res)}")
      str when is_binary(str) -> IO.puts(indent(str))
      other                 -> IO.puts("   => #{Show.form(other)}")
    end
    res
  end

  defp indent(str), do: str |> String.split("\n") |> Enum.map_join("\n", &("   " <> &1))
end

# --- L0/L2 authoring: mount the fs substrate, bind the jail root (named once) ---
root = Path.join(System.tmp_dir!(), "fs_jail_demo")
File.rm_rf!(root)
File.mkdir_p!(Path.join(root, "notes"))
File.write!(Path.join(root, "notes/todo.txt"), "buy milk\nship substrate")
File.write!(Path.join(root, "notes/ideas.txt"), "an operating system for agents")

{:ok, s} = Substrate.start_link(name: nil)
manifest = "priv/manifests/fs.lisp" |> File.read!() |> Substrate.read_manifest()
:ok = Substrate.mount(s, manifest, credentials: %{fs_root: root})
IO.puts("\e[1mSubstrate up.\e[0m jail root bound at L0 (the agent can never name it): #{root}")

Demo.hr("1. ATTACH + INTROSPECT — the self-describing surface (bind stripped)")
Demo.run(s, "(describe fs)")
Demo.note("drill into one — note: no `bind`, no mechanism, policy abstracted:")
Demo.run(s, "(describe fs/write)")

Demo.hr("2. HAPPY PATH — a call returns a disposition, not a raw value")
Demo.run(s, ~s|(fs/read :path "notes/todo.txt")|)

Demo.hr("3. THE WALL — zero ambient authority; no referent for these symbols")
Demo.run(s, ~s|(read-file "/etc/passwd")|)
Demo.run(s, ~s|(System/getenv "HOME")|)
Demo.run(s, ~s|(fs/root)|)
Demo.note("there is no expression that yields the jail root — it isn't a value here")

Demo.hr("4. PATH JAIL — escape is :denied at the membrane (deny-if)")
Demo.run(s, ~s|(fs/read :path "../../../etc/passwd")|)

Demo.hr("5. CODE-AS-ACTION — one program: loop + agent-defined fn + dispositions")
Demo.run(s, """
(defn summarize [name]
  (let [r (fs/read :path (str "notes/" name))]
    (case r
      (:done d)   (log name "->" (:bytes d) "bytes")
      (:denied e) (log name "denied"))))
(let [listing (fs/list :path "notes")]
  (case listing
    (:done d)   (for [f (:entries d)] (summarize f))
    (:denied e) (log "cannot list")))
""")

Demo.hr("6. CONFIRM-IF — effect outside the safe area routes to a human queue")
File.write!(Path.join(root, "secret.txt"), "top secret")
File.write!(Path.join(root, "secret2.txt"), "also secret")
q1 = Demo.run(s, ~s|(fs/delete :path "secret.txt")|)
{:disposition, :queued, %{handle: h1}} = q1
Demo.note("[human] approves #{h1}")
Substrate.approve(s, h1)
Demo.run(s, ~s|(await "#{h1}")|)

q2 = Demo.run(s, ~s|(fs/delete :path "secret2.txt")|)
{:disposition, :queued, %{handle: h2}} = q2
Demo.note("[human] rejects #{h2}")
Substrate.deny(s, h2)
Demo.run(s, ~s|(await "#{h2}")|)

Demo.hr("7. RATE-LIMIT — same call, errno flips when the budget is spent (5/min)")
Demo.run(s, """
(for [i (list 1 2 3 4 5 6 7)]
  (case (fs/write :path (str "notes/n" i ".txt") :content "x")
    (:done r)         (log "write" i "ok ->" (:bytes r) "bytes")
    (:rate-limited e) (log "write" i ":rate-limited retry-after" (:retry_after e) "s")
    (:denied d)       (log "write" i "denied")))
""")

Demo.hr("8. LIVE SURFACE — revoke mid-flight: ABI frozen, errno dynamic")
Demo.run(s, ~s|(fs/read :path "notes/ideas.txt")|)
Substrate.revoke(s, "fs/read")
Demo.note("[admin] revoked fs/read at runtime (a registry write)")
Demo.run(s, ~s|(fs/read :path "notes/ideas.txt")|)
Demo.note("the signature is STILL on the surface — it didn't vanish, it returns :denied:")
Demo.run(s, "(describe fs)")
Substrate.restore(s, "fs/read")
Demo.note("[admin] restored fs/read")
Demo.run(s, ~s|(fs/read :path "notes/ideas.txt")|)

IO.puts("\n\e[1m\e[32m✓ demo complete — wall + disposition model are structural, not vibes.\e[0m")
